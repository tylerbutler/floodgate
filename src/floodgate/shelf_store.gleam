//// Shelf-backed implementation of the Floodgate storage boundary.
////
//// Replaces the hand-written `floodgate_store_ffi` raw-ETS backend with
//// `shelf` (typed ETS + DETS) — the same library `levee_storage` uses. This is
//// deliberately independent of `levee_storage`: Floodgate keeps its own
//// topic/tenant key model and its `store.Backend` closure seam, so the two
//// server stacks stay decoupled (ADR-004).
////
//// Tables are opened in `WriteThrough` mode so writes reach DETS immediately
//// and survive restarts without a save lifecycle. (levee_storage uses
//// `WriteBack` + a GenServer that calls `save`/`close`; Floodgate has no such
//// storage process, so WriteThrough delivers the same durability guarantee.)
////
//// Shelf creates `protected` ETS tables (owner-only writes), but Floodgate
//// writes from session actors and REST handler processes, so each table is
//// swapped to `public` after opening — see `floodgate_shelf_ffi:make_table_public`,
//// the analogue of levee's `storage_ffi_helpers:make_table_public`.

import floodgate/store
import gleam/dynamic/decode
import gleam/list
import gleam/result
import shelf
import shelf/set.{type PSet}

type Tables {
  Tables(
    docs: PSet(String, Bool),
    ops: PSet(#(String, Int), String),
    summaries: PSet(String, #(String, Int)),
    objects: PSet(#(String, String), String),
    refs: PSet(#(String, String), String),
  )
}

/// Build a shelf-backed storage backend rooted at `data_dir`. DETS files are
/// created under that directory (created if missing).
pub fn new(data_dir: String) -> store.Backend {
  ensure_dir(data_dir)
  let tables = open_tables(data_dir)

  store.Backend(
    // No processes of its own: shelf tables are ETS + DETS, not actors.
    //
    // Known limitation: the ETS tables are owned by whichever process calls
    // this function — `main`, via `floodgate.serve` — and the closures below
    // capture the table handles. If that process died the tables would go with
    // it and the captured handles would be stale. Fixing that means opening the
    // tables in a supervised process and resolving them by name at call time,
    // the same treatment `session` and `memory_store` got; it is a separate
    // change because the handles, not just the owner, have to become late-bound.
    supervise: fn(builder) { builder },
    open: fn() { Nil },
    put_document: fn(topic) {
      let _ = set.insert(into: tables.docs, key: topic, value: True)
      Nil
    },
    has_document: fn(topic) {
      set.member(of: tables.docs, key: topic) |> result.unwrap(False)
    },
    put_op: fn(topic, sn, contents) {
      let _ = set.insert(into: tables.ops, key: #(topic, sn), value: contents)
      Nil
    },
    get_ops: fn(topic) {
      set.to_list(from: tables.ops)
      |> result.unwrap([])
      |> list.filter_map(fn(entry) {
        let #(#(entry_topic, sn), contents) = entry
        case entry_topic == topic {
          True -> Ok(#(sn, contents))
          False -> Error(Nil)
        }
      })
    },
    put_summary: fn(topic, handle, sn) {
      let _ =
        set.insert(into: tables.summaries, key: topic, value: #(handle, sn))
      Nil
    },
    get_summary: fn(topic) {
      set.lookup(from: tables.summaries, key: topic) |> result.unwrap(#("", 0))
    },
    put_obj: fn(tenant, sha, data) {
      let _ = set.insert(into: tables.objects, key: #(tenant, sha), value: data)
      Nil
    },
    get_obj: fn(tenant, sha) {
      set.lookup(from: tables.objects, key: #(tenant, sha))
      |> result.replace_error(Nil)
    },
    put_ref: fn(tenant, ref, sha) {
      let _ = set.insert(into: tables.refs, key: #(tenant, ref), value: sha)
      Nil
    },
    create_ref: fn(tenant, ref, sha) {
      case set.insert_new(into: tables.refs, key: #(tenant, ref), value: sha) {
        Ok(_) -> True
        Error(_) -> False
      }
    },
    get_ref: fn(tenant, ref) {
      set.lookup(from: tables.refs, key: #(tenant, ref))
      |> result.replace_error(Nil)
    },
    list_refs: fn(tenant) {
      set.to_list(from: tables.refs)
      |> result.unwrap([])
      |> list.filter_map(fn(entry) {
        let #(#(entry_tenant, ref), sha) = entry
        case entry_tenant == tenant {
          True -> Ok(#(ref, sha))
          False -> Error(Nil)
        }
      })
    },
  )
}

fn open_tables(data_dir: String) -> Tables {
  Tables(
    docs: open(
      data_dir,
      "floodgate_docs",
      "docs.dets",
      decode.string,
      decode.bool,
    ),
    ops: open(
      data_dir,
      "floodgate_ops",
      "ops.dets",
      topic_sn_key(),
      decode.string,
    ),
    summaries: open(
      data_dir,
      "floodgate_summaries",
      "summaries.dets",
      decode.string,
      handle_sn_value(),
    ),
    objects: open(
      data_dir,
      "floodgate_objects",
      "objects.dets",
      string_pair_key(),
      decode.string,
    ),
    refs: open(
      data_dir,
      "floodgate_refs",
      "refs.dets",
      string_pair_key(),
      decode.string,
    ),
  )
}

fn open(
  data_dir: String,
  name: String,
  path: String,
  key: decode.Decoder(k),
  value: decode.Decoder(v),
) -> PSet(k, v) {
  let config =
    shelf.config(name: name, path: path, base_directory: data_dir)
    |> shelf.write_mode(mode: shelf.WriteThrough)
  let assert Ok(table) = set.open_config(config: config, key: key, value: value)
  make_table_public(table)
}

fn topic_sn_key() -> decode.Decoder(#(String, Int)) {
  use topic <- decode.field(0, decode.string)
  use sn <- decode.field(1, decode.int)
  decode.success(#(topic, sn))
}

fn string_pair_key() -> decode.Decoder(#(String, String)) {
  use a <- decode.field(0, decode.string)
  use b <- decode.field(1, decode.string)
  decode.success(#(a, b))
}

fn handle_sn_value() -> decode.Decoder(#(String, Int)) {
  use handle <- decode.field(0, decode.string)
  use sn <- decode.field(1, decode.int)
  decode.success(#(handle, sn))
}

@external(erlang, "floodgate_shelf_ffi", "ensure_dir")
fn ensure_dir(dir: String) -> Nil

@external(erlang, "floodgate_shelf_ffi", "make_table_public")
fn make_table_public(table: PSet(k, v)) -> PSet(k, v)
