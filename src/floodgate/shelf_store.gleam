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
import shelf/bag.{type PBag}
import shelf/set.{type PSet}

type Tables {
  Tables(
    docs: PSet(String, Bool),
    ops: PSet(#(String, Int), String),
    /// `topic → sn`, so a document's ops can be found without scanning every
    /// document's. See `new` for why this is a separate index rather than the
    /// ops table itself being keyed by topic.
    ops_index: PBag(String, Int),
    summaries: PSet(String, #(String, Int)),
    objects: PSet(#(String, String), String),
    refs: PSet(#(String, String), String),
    /// `tenant → ref`, the same index for `list_refs`.
    refs_index: PBag(String, String),
  )
}

/// Build a shelf-backed storage backend rooted at `data_dir`. DETS files are
/// created under that directory (created if missing).
///
/// `get_ops` and `list_refs` used to `set.to_list` the entire table and filter,
/// so a single document's catch-up cost was proportional to every op in the
/// server — paid on every reconnect and every delta request. DETS has no
/// `ordered_set` and shelf has no partial-key match, so each is now served from
/// a bag table keyed by topic/tenant.
///
/// The bag is an *index*, not the store: keeping the set as the authority
/// preserves `put_op`'s overwrite-by-`(topic, sn)` semantics, which a bag cannot
/// (it dedupes only exact duplicates, so re-putting an sn with different
/// contents would leave two entries where `memory_store`'s dict leaves one).
/// Re-putting the same key is a no-op in the bag, so the index cannot drift from
/// the set even under overwrite.
pub fn new(data_dir: String) -> store.Backend {
  ensure_dir(data_dir)
  let tables = open_tables(data_dir)
  backfill_indexes(tables)

  store.Backend(
    // No processes of its own: shelf tables are ETS + DETS, not actors.
    //
    // The ETS tables are owned by whichever process calls this function, and the
    // closures below capture the handles, so they do not survive that process's
    // death. In the shipped server that is not a live exposure: the owner is the
    // process running `main`, which the generated entrypoint `spawn_link`s under
    // a trapping parent that calls `init:stop(1)` — so its death halts the node,
    // the container restarts it, and the tables are reopened from DETS. Nothing
    // is lost, because `WriteThrough` has already flushed every write and shelf's
    // guardian process closes DETS cleanly when the owner dies.
    //
    // What is *not* supported is surviving that in place, which would need the
    // handles themselves to be late-bound (named ETS tables plus a supervised
    // owner), not just the owner supervised. Worth knowing if floodgate is ever
    // embedded and this is called from a process that can die independently.
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
      let _ = bag.insert(into: tables.ops_index, key: topic, value: sn)
      Nil
    },
    get_ops: fn(topic) {
      bag.lookup(from: tables.ops_index, key: topic)
      |> result.unwrap([])
      |> list.filter_map(fn(sn) {
        set.lookup(from: tables.ops, key: #(topic, sn))
        |> result.map(fn(contents) { #(sn, contents) })
        |> result.replace_error(Nil)
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
      let _ = bag.insert(into: tables.refs_index, key: tenant, value: ref)
      Nil
    },
    create_ref: fn(tenant, ref, sha) {
      case set.insert_new(into: tables.refs, key: #(tenant, ref), value: sha) {
        Ok(_) -> {
          // Only index a ref that this call actually created, so a losing
          // create leaves no trace.
          let _ = bag.insert(into: tables.refs_index, key: tenant, value: ref)
          True
        }
        Error(_) -> False
      }
    },
    get_ref: fn(tenant, ref) {
      set.lookup(from: tables.refs, key: #(tenant, ref))
      |> result.replace_error(Nil)
    },
    list_refs: fn(tenant) {
      bag.lookup(from: tables.refs_index, key: tenant)
      |> result.unwrap([])
      |> list.filter_map(fn(ref) {
        set.lookup(from: tables.refs, key: #(tenant, ref))
        |> result.map(fn(sha) { #(ref, sha) })
        |> result.replace_error(Nil)
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
    ops_index: open_bag(
      data_dir,
      "floodgate_ops_index",
      "ops_index.dets",
      decode.string,
      decode.int,
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
    refs_index: open_bag(
      data_dir,
      "floodgate_refs_index",
      "refs_index.dets",
      decode.string,
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

/// Populate the index tables from the tables they index, when they are empty and
/// those are not.
///
/// This is the upgrade path: a DETS directory written before the indexes existed
/// has ops and refs but no index files, and without this every pre-existing
/// document would read back as having no history at all. It is the one-time
/// version of exactly the scan the indexes remove from the hot path, so it is
/// paid once at startup rather than on every reconnect. On a fresh install both
/// sides are empty and it does nothing.
fn backfill_indexes(tables: Tables) -> Nil {
  case bag.size(of: tables.ops_index) {
    Ok(0) ->
      set.to_list(from: tables.ops)
      |> result.unwrap([])
      |> list.each(fn(entry) {
        let #(#(topic, sn), _contents) = entry
        let _ = bag.insert(into: tables.ops_index, key: topic, value: sn)
        Nil
      })
    _ -> Nil
  }
  case bag.size(of: tables.refs_index) {
    Ok(0) ->
      set.to_list(from: tables.refs)
      |> result.unwrap([])
      |> list.each(fn(entry) {
        let #(#(tenant, ref), _sha) = entry
        let _ = bag.insert(into: tables.refs_index, key: tenant, value: ref)
        Nil
      })
    _ -> Nil
  }
}

fn open_bag(
  data_dir: String,
  name: String,
  path: String,
  key: decode.Decoder(k),
  value: decode.Decoder(v),
) -> PBag(k, v) {
  let config =
    shelf.config(name: name, path: path, base_directory: data_dir)
    |> shelf.write_mode(mode: shelf.WriteThrough)
  let assert Ok(table) = bag.open_config(config: config, key: key, value: value)
  make_bag_public(table)
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

/// The same FFI: it reads the table type back from `ets:info`, and `PBag` has
/// the identical record layout to `PSet`, so a bag stays a bag.
@external(erlang, "floodgate_shelf_ffi", "make_table_public")
fn make_bag_public(table: PBag(k, v)) -> PBag(k, v)
