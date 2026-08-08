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
////
//// Only data that is *not* document-scoped lives in the shared tables below.
//// A document's own marker, ops, summary pointer, and git objects live in one
//// DETS file per document — see `floodgate/doc_store` for why, and for the
//// ownership and lifetime rules that come with it.

import floodgate/admin_auth.{AdminSession, AdminUser}
import floodgate/doc_store.{type DocStore}
import floodgate/store
import gleam/dynamic/decode
import gleam/list
import gleam/otp/static_supervisor
import gleam/result
import shelf
import shelf/bag.{type PBag}
import shelf/set.{type PSet}

type Tables {
  Tables(
    /// `#(topic, sha) → body`, the pre-per-document objects table. Retained
    /// read-only as a fallback so blobs written before the split stay
    /// readable; nothing writes to it any more. See `new`.
    objects: PSet(#(String, String), String),
    refs: PSet(#(String, String), String),
    /// `tenant → ref`, the same index for `list_refs`.
    refs_index: PBag(String, String),
    /// `tenant id → #(name, secret1, secret2)`. Small (one row per tenant),
    /// so — unlike ops/refs — a full-table scan for `list_tenants` needs no
    /// index.
    tenants: PSet(String, #(String, String, String)),
    /// `github id → #(github_username, display_name, email, created_at)` —
    /// the admin UI's OAuth-backed user accounts. Keyed directly by GitHub's
    /// own numeric user id, so — like `tenants` — no reverse index is needed.
    admin_users: PSet(String, #(String, String, String, Int)),
    /// `session id → #(user_id, created_at, expires_at)` — the admin UI's
    /// opaque bearer/cookie sessions.
    admin_sessions: PSet(String, #(String, Int, Int)),
  )
}

/// A shelf-backed backend rooted at `data_dir`, with the per-document store
/// started eagerly and unsupervised. For tests and embedding; a runtime should
/// use `supervised`. Mirrors `memory_store.new`/`memory_store.supervised`.
pub fn new(data_dir: String) -> store.Backend {
  backend(data_dir, doc_store.started(data_dir), fn(builder) { builder })
}

/// A shelf-backed backend whose per-document store is started by the runtime's
/// supervision tree. `store.supervise` must be applied to the tree before
/// anything calls into the backend — `serve_with_backend` does this first, for
/// exactly this reason.
pub fn supervised(data_dir: String) -> store.Backend {
  let docs = doc_store.new(data_dir)
  backend(data_dir, docs, fn(builder) { doc_store.supervise(builder, docs) })
}

/// Build the storage boundary over the shared tables plus `docs`.
///
/// Shared tables hold only what is not document-scoped. `list_refs` used to
/// `set.to_list` the whole refs table and filter, so one tenant's cost was
/// proportional to every ref on the server; DETS has no `ordered_set` and shelf
/// has no partial-key match, so it is served from a bag keyed by tenant.
///
/// The bag is an *index*, not the store: keeping the set as the authority
/// preserves `put_ref`'s overwrite-by-`(tenant, ref)` semantics, which a bag
/// cannot (it dedupes only exact duplicates, so re-putting a ref with a
/// different sha would leave two entries where `memory_store`'s dict leaves
/// one). Re-putting the same key is a no-op in the bag, so the index cannot
/// drift from the set even under overwrite.
fn backend(
  data_dir: String,
  docs: DocStore,
  supervise: fn(static_supervisor.Builder) -> static_supervisor.Builder,
) -> store.Backend {
  ensure_dir(data_dir)
  let tables = open_tables(data_dir)
  backfill_indexes(tables)

  store.Backend(
    // The shared tables' ETS handles are owned by whichever process calls this
    // function, and the closures below capture them, so they do not survive that
    // process's death. In the shipped server that is not a live exposure: the
    // owner is the process running `main`, which the generated entrypoint
    // `spawn_link`s under a trapping parent that calls `init:stop(1)` — so its
    // death halts the node, the container restarts it, and the tables are
    // reopened from DETS. Nothing is lost, because `WriteThrough` has already
    // flushed every write and shelf's guardian process closes DETS cleanly when
    // the owner dies.
    //
    // Per-document tables are *not* like this: they are owned by `doc_store`'s
    // supervised actor and resolved by name at call time, so they do survive in
    // place. See `floodgate/doc_store`.
    supervise: supervise,
    open: fn() { Nil },
    put_document: fn(topic) { doc_store.put_marker(docs, topic) },
    has_document: fn(topic) { doc_store.exists(docs, topic) },
    put_op: fn(topic, sn, contents) {
      doc_store.put_op(docs, topic, sn, contents)
    },
    get_ops: fn(topic) { doc_store.get_ops(docs, topic) },
    put_summary: fn(topic, handle, sn) {
      doc_store.put_summary(docs, topic, handle, sn)
    },
    get_summary: fn(topic) { doc_store.get_summary(docs, topic) },
    put_obj: fn(topic, sha, data) { doc_store.put_obj(docs, topic, sha, data) },
    // Objects moved into the per-document file. The shared table is still
    // consulted on a miss so blobs written before the split stay readable
    // without a migration that would have to walk each ref's commit → tree →
    // blob graph to work out which document every sha belonged to.
    get_obj: fn(topic, sha) {
      case doc_store.get_obj(docs, topic, sha) {
        Ok(data) -> Ok(data)
        Error(Nil) ->
          set.lookup(from: tables.objects, key: #(topic, sha))
          |> result.replace_error(Nil)
      }
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
    create_tenant: fn(name) {
      let id = store.generate_tenant_id()
      let secret1 = store.generate_tenant_secret()
      let secret2 = store.generate_tenant_secret()
      let _ =
        set.insert(into: tables.tenants, key: id, value: #(
          name,
          secret1,
          secret2,
        ))
      store.TenantWithSecrets(id:, name:, secret1:, secret2:)
    },
    get_tenant: fn(id) {
      set.lookup(from: tables.tenants, key: id)
      |> result.map(fn(data) { store.TenantInfo(id:, name: data.0) })
      |> result.replace_error(Nil)
    },
    get_tenant_secrets: fn(id) {
      set.lookup(from: tables.tenants, key: id)
      |> result.map(fn(data) { #(data.1, data.2) })
      |> result.replace_error(Nil)
    },
    regenerate_tenant_secret: fn(id, slot) {
      case set.lookup(from: tables.tenants, key: id) {
        Error(_) -> Error(Nil)
        Ok(#(name, secret1, secret2)) -> {
          let new_secret = store.generate_tenant_secret()
          let updated = case slot {
            store.Slot1 -> #(name, new_secret, secret2)
            store.Slot2 -> #(name, secret1, new_secret)
          }
          let _ = set.insert(into: tables.tenants, key: id, value: updated)
          Ok(new_secret)
        }
      }
    },
    register_tenant: fn(id, secret) {
      let _ =
        set.insert(into: tables.tenants, key: id, value: #(
          id,
          secret,
          store.generate_tenant_secret(),
        ))
      Nil
    },
    unregister_tenant: fn(id) {
      let _ = set.delete_key(from: tables.tenants, key: id)
      Nil
    },
    tenant_exists: fn(id) {
      set.member(of: tables.tenants, key: id) |> result.unwrap(False)
    },
    list_tenants: fn() {
      set.to_list(from: tables.tenants)
      |> result.unwrap([])
      |> list.map(fn(entry) {
        let #(id, data) = entry
        store.TenantInfo(id:, name: data.0)
      })
    },
    put_admin_user: fn(user) {
      let _ =
        set.insert(into: tables.admin_users, key: user.id, value: #(
          user.github_username,
          user.display_name,
          user.email,
          user.created_at,
        ))
      Nil
    },
    get_admin_user: fn(id) {
      set.lookup(from: tables.admin_users, key: id)
      |> result.map(fn(data) {
        let #(github_username, display_name, email, created_at) = data
        AdminUser(id:, github_username:, display_name:, email:, created_at:)
      })
      |> result.replace_error(Nil)
    },
    admin_user_count: fn() {
      set.to_list(from: tables.admin_users) |> result.unwrap([]) |> list.length
    },
    put_admin_session: fn(session) {
      let _ =
        set.insert(into: tables.admin_sessions, key: session.id, value: #(
          session.user_id,
          session.created_at,
          session.expires_at,
        ))
      Nil
    },
    get_admin_session: fn(id) {
      set.lookup(from: tables.admin_sessions, key: id)
      |> result.map(fn(data) {
        let #(user_id, created_at, expires_at) = data
        AdminSession(id:, user_id:, created_at:, expires_at:)
      })
      |> result.replace_error(Nil)
    },
    delete_admin_session: fn(id) {
      let _ = set.delete_key(from: tables.admin_sessions, key: id)
      Nil
    },
  )
}

fn open_tables(data_dir: String) -> Tables {
  Tables(
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
    tenants: open(
      data_dir,
      "floodgate_tenants",
      "tenants.dets",
      decode.string,
      tenant_value(),
    ),
    admin_users: open(
      data_dir,
      "floodgate_admin_users",
      "admin_users.dets",
      decode.string,
      admin_user_value(),
    ),
    admin_sessions: open(
      data_dir,
      "floodgate_admin_sessions",
      "admin_sessions.dets",
      decode.string,
      admin_session_value(),
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

/// Populate the ref index from the refs table, when it is empty and refs are
/// not.
///
/// This is the upgrade path: a DETS directory written before the index existed
/// has refs but no index file, and without this every pre-existing tenant would
/// list no refs at all. It is the one-time version of exactly the scan the index
/// removes from the hot path, so it is paid once at startup rather than on every
/// request. On a fresh install both sides are empty and it does nothing.
fn backfill_indexes(tables: Tables) -> Nil {
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

fn string_pair_key() -> decode.Decoder(#(String, String)) {
  use a <- decode.field(0, decode.string)
  use b <- decode.field(1, decode.string)
  decode.success(#(a, b))
}

fn tenant_value() -> decode.Decoder(#(String, String, String)) {
  use name <- decode.field(0, decode.string)
  use secret1 <- decode.field(1, decode.string)
  use secret2 <- decode.field(2, decode.string)
  decode.success(#(name, secret1, secret2))
}

fn admin_user_value() -> decode.Decoder(#(String, String, String, Int)) {
  use github_username <- decode.field(0, decode.string)
  use display_name <- decode.field(1, decode.string)
  use email <- decode.field(2, decode.string)
  use created_at <- decode.field(3, decode.int)
  decode.success(#(github_username, display_name, email, created_at))
}

fn admin_session_value() -> decode.Decoder(#(String, Int, Int)) {
  use user_id <- decode.field(0, decode.string)
  use created_at <- decode.field(1, decode.int)
  use expires_at <- decode.field(2, decode.int)
  decode.success(#(user_id, created_at, expires_at))
}

@external(erlang, "floodgate_shelf_ffi", "ensure_dir")
fn ensure_dir(dir: String) -> Nil

@external(erlang, "floodgate_shelf_ffi", "make_table_public")
fn make_table_public(table: PSet(k, v)) -> PSet(k, v)

/// The same FFI: it reads the table type back from `ets:info`, and `PBag` has
/// the identical record layout to `PSet`, so a bag stays a bag.
@external(erlang, "floodgate_shelf_ffi", "make_table_public")
fn make_bag_public(table: PBag(k, v)) -> PBag(k, v)
