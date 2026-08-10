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
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import shelf
import shelf/bag.{type PBag}
import shelf/set.{type PSet}

const retry_attempts = 500

const retry_delay_ms = 10

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

pub type Msg {
  Ping(process.Subject(Nil))
}

pub fn new_name() -> process.Name(Msg) {
  process.new_name("floodgate_shelf_store")
}

pub fn start_named(
  name: process.Name(Msg),
  data_dir: String,
) -> Result(actor.Started(process.Subject(Msg)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(self) {
    ensure_dir(data_dir)
    let tables = open_tables(data_dir)
    backfill_indexes(tables)
    publish_tables(name, tables)
    actor.initialised(tables)
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(fn(tables, message) {
    case message {
      Ping(reply) -> {
        process.send(reply, Nil)
        actor.continue(tables)
      }
    }
  })
  |> actor.named(name)
  |> actor.start
}

pub fn child_spec(
  name: process.Name(Msg),
  data_dir: String,
) -> supervision.ChildSpecification(process.Subject(Msg)) {
  supervision.worker(fn() { start_named(name, data_dir) })
}

/// A shelf-backed backend rooted at `data_dir`, with both stores started
/// eagerly and unsupervised. For tests and embedding; runtimes use `supervised`.
pub fn new(data_dir: String) -> store.Backend {
  ensure_dir(data_dir)
  let tables = open_tables(data_dir)
  backfill_indexes(tables)
  backend(fn() { Ok(tables) }, doc_store.started(data_dir), fn(builder) {
    builder
  })
}

/// A shelf backend whose shared table owner and per-document store are both
/// part of the runtime supervision tree.
pub fn supervised(data_dir: String) -> store.Backend {
  from_name(new_name(), data_dir)
}

/// A supervised shelf backend with an explicit shared-table owner name.
pub fn from_name(name: process.Name(Msg), data_dir: String) -> store.Backend {
  let docs = doc_store.new(data_dir)
  backend(fn() { lookup_tables(name) }, docs, fn(builder) {
    builder
    |> static_supervisor.add(child_spec(name, data_dir))
    |> doc_store.supervise(docs)
  })
}

/// Build the storage boundary over restart-resolved shared tables plus `docs`.
fn backend(
  resolve: fn() -> Result(Tables, Nil),
  docs: DocStore,
  supervise: fn(static_supervisor.Builder) -> static_supervisor.Builder,
) -> store.Backend {
  store.Backend(
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
    // Legacy objects remain readable from the old shared table.
    get_obj: fn(topic, sha) {
      case doc_store.get_obj(docs, topic, sha) {
        Ok(data) -> Ok(data)
        Error(Nil) ->
          optional(
            run(resolve, fn(tables) {
              set.lookup(from: tables.objects, key: #(topic, sha))
            }),
          )
      }
    },
    put_ref: fn(tenant, ref, sha) {
      let assert Ok(Nil) =
        run(resolve, fn(tables) {
          use _ <- result.try(set.insert(
            into: tables.refs,
            key: #(tenant, ref),
            value: sha,
          ))
          bag.insert(into: tables.refs_index, key: tenant, value: ref)
        })
      Nil
    },
    create_ref: fn(tenant, ref, sha) {
      create_ref(resolve, tenant, ref, sha, False, retry_attempts)
    },
    get_ref: fn(tenant, ref) {
      optional(
        run(resolve, fn(tables) {
          set.lookup(from: tables.refs, key: #(tenant, ref))
        }),
      )
    },
    list_refs: fn(tenant) {
      let assert Ok(refs) =
        run(resolve, fn(tables) { list_refs(tables, tenant) })
      refs
    },
    create_tenant: fn(name) {
      let id = store.generate_tenant_id()
      let secret1 = store.generate_tenant_secret()
      let secret2 = store.generate_tenant_secret()
      let assert Ok(Nil) =
        run(resolve, fn(tables) {
          set.insert(into: tables.tenants, key: id, value: #(
            name,
            secret1,
            secret2,
          ))
        })
      store.TenantWithSecrets(id:, name:, secret1:, secret2:)
    },
    get_tenant: fn(id) {
      run(resolve, fn(tables) { set.lookup(from: tables.tenants, key: id) })
      |> result.map(fn(data) { store.TenantInfo(id:, name: data.0) })
      |> optional
    },
    get_tenant_secrets: fn(id) {
      run(resolve, fn(tables) { set.lookup(from: tables.tenants, key: id) })
      |> result.map(fn(data) { #(data.1, data.2) })
      |> optional
    },
    regenerate_tenant_secret: fn(id, slot) {
      let new_secret = store.generate_tenant_secret()
      run(resolve, fn(tables) {
        use data <- result.try(set.lookup(from: tables.tenants, key: id))
        let #(name, secret1, secret2) = data
        let updated = case slot {
          store.Slot1 -> #(name, new_secret, secret2)
          store.Slot2 -> #(name, secret1, new_secret)
        }
        set.insert(into: tables.tenants, key: id, value: updated)
        |> result.map(fn(_) { new_secret })
      })
      |> optional
    },
    register_tenant: fn(id, secret) {
      let assert Ok(Nil) =
        run(resolve, fn(tables) {
          set.insert(into: tables.tenants, key: id, value: #(
            id,
            secret,
            store.generate_tenant_secret(),
          ))
        })
      Nil
    },
    unregister_tenant: fn(id) {
      let assert Ok(Nil) =
        run(resolve, fn(tables) {
          set.delete_key(from: tables.tenants, key: id)
        })
      Nil
    },
    tenant_exists: fn(id) {
      let assert Ok(found) =
        run(resolve, fn(tables) { set.member(of: tables.tenants, key: id) })
      found
    },
    list_tenants: fn() {
      let assert Ok(tenants) =
        run(resolve, fn(tables) { set.to_list(from: tables.tenants) })
      tenants
      |> list.map(fn(entry) {
        let #(id, data) = entry
        store.TenantInfo(id:, name: data.0)
      })
    },
    put_admin_user: fn(user) {
      let assert Ok(Nil) =
        run(resolve, fn(tables) {
          set.insert(into: tables.admin_users, key: user.id, value: #(
            user.github_username,
            user.display_name,
            user.email,
            user.created_at,
          ))
        })
      Nil
    },
    get_admin_user: fn(id) {
      run(resolve, fn(tables) { set.lookup(from: tables.admin_users, key: id) })
      |> result.map(fn(data) {
        let #(github_username, display_name, email, created_at) = data
        AdminUser(id:, github_username:, display_name:, email:, created_at:)
      })
      |> optional
    },
    admin_user_count: fn() {
      let assert Ok(count) =
        run(resolve, fn(tables) { set.size(of: tables.admin_users) })
      count
    },
    put_admin_session: fn(session) {
      let assert Ok(Nil) =
        run(resolve, fn(tables) {
          set.insert(into: tables.admin_sessions, key: session.id, value: #(
            session.user_id,
            session.created_at,
            session.expires_at,
          ))
        })
      Nil
    },
    get_admin_session: fn(id) {
      run(resolve, fn(tables) {
        set.lookup(from: tables.admin_sessions, key: id)
      })
      |> result.map(fn(data) {
        let #(user_id, created_at, expires_at) = data
        AdminSession(id:, user_id:, created_at:, expires_at:)
      })
      |> optional
    },
    delete_admin_session: fn(id) {
      let assert Ok(Nil) =
        run(resolve, fn(tables) {
          set.delete_key(from: tables.admin_sessions, key: id)
        })
      Nil
    },
  )
}

fn run(
  resolve: fn() -> Result(Tables, Nil),
  operation: fn(Tables) -> Result(a, shelf.ShelfError),
) -> Result(a, shelf.ShelfError) {
  run_attempt(resolve, operation, retry_attempts)
}

fn run_attempt(
  resolve: fn() -> Result(Tables, Nil),
  operation: fn(Tables) -> Result(a, shelf.ShelfError),
  attempts: Int,
) -> Result(a, shelf.ShelfError) {
  case resolve() {
    Ok(tables) ->
      case operation(tables) {
        Error(shelf.TableClosed) -> retry(resolve, operation, attempts)
        result -> result
      }
    Error(Nil) -> retry(resolve, operation, attempts)
  }
}

fn retry(
  resolve: fn() -> Result(Tables, Nil),
  operation: fn(Tables) -> Result(a, shelf.ShelfError),
  attempts: Int,
) -> Result(a, shelf.ShelfError) {
  case attempts <= 0 {
    True -> Error(shelf.TableClosed)
    False -> {
      process.sleep(retry_delay_ms)
      run_attempt(resolve, operation, attempts - 1)
    }
  }
}

fn optional(result: Result(a, shelf.ShelfError)) -> Result(a, Nil) {
  case result {
    Ok(value) -> Ok(value)
    Error(shelf.NotFound) -> Error(Nil)
    other -> {
      let assert Ok(value) = other
      Ok(value)
    }
  }
}

fn list_refs(
  tables: Tables,
  tenant: String,
) -> Result(List(#(String, String)), shelf.ShelfError) {
  use refs <- result.try(case bag.lookup(from: tables.refs_index, key: tenant) {
    Ok(refs) -> Ok(refs)
    Error(shelf.NotFound) -> Ok([])
    Error(error) -> Error(error)
  })
  refs
  |> list.try_map(fn(ref) {
    case set.lookup(from: tables.refs, key: #(tenant, ref)) {
      Ok(sha) -> Ok(Some(#(ref, sha)))
      Error(shelf.NotFound) -> Ok(None)
      Error(error) -> Error(error)
    }
  })
  |> result.map(fn(values) {
    list.filter_map(values, fn(value) {
      case value {
        Some(value) -> Ok(value)
        None -> Error(Nil)
      }
    })
  })
}

fn create_ref(
  resolve: fn() -> Result(Tables, Nil),
  tenant: String,
  ref: String,
  sha: String,
  created: Bool,
  attempts: Int,
) -> Bool {
  case resolve() {
    Error(Nil) -> retry_create_ref(resolve, tenant, ref, sha, created, attempts)
    Ok(tables) ->
      case set.insert_new(into: tables.refs, key: #(tenant, ref), value: sha) {
        Ok(Nil) ->
          index_created_ref(resolve, tables, tenant, ref, sha, True, attempts)
        Error(shelf.KeyAlreadyPresent) if created ->
          case set.lookup(from: tables.refs, key: #(tenant, ref)) {
            Ok(existing) if existing == sha ->
              index_created_ref(
                resolve,
                tables,
                tenant,
                ref,
                sha,
                True,
                attempts,
              )
            Ok(_) -> False
            Error(shelf.TableClosed) ->
              retry_create_ref(resolve, tenant, ref, sha, True, attempts)
            other -> {
              let assert Ok(_) = other
              False
            }
          }
        Error(shelf.KeyAlreadyPresent) -> False
        Error(shelf.TableClosed) ->
          retry_create_ref(resolve, tenant, ref, sha, True, attempts)
        other -> {
          let assert Ok(Nil) = other
          False
        }
      }
  }
}

fn index_created_ref(
  resolve: fn() -> Result(Tables, Nil),
  tables: Tables,
  tenant: String,
  ref: String,
  sha: String,
  created: Bool,
  attempts: Int,
) -> Bool {
  case bag.insert(into: tables.refs_index, key: tenant, value: ref) {
    Ok(Nil) -> created
    Error(shelf.TableClosed) ->
      retry_create_ref(resolve, tenant, ref, sha, created, attempts)
    other -> {
      let assert Ok(Nil) = other
      False
    }
  }
}

fn retry_create_ref(
  resolve: fn() -> Result(Tables, Nil),
  tenant: String,
  ref: String,
  sha: String,
  created: Bool,
  attempts: Int,
) -> Bool {
  case attempts <= 0 {
    True -> panic as "shelf storage unavailable"
    False -> {
      process.sleep(retry_delay_ms)
      create_ref(resolve, tenant, ref, sha, created, attempts - 1)
    }
  }
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

/// Fill missing ref-index entries from the authoritative refs table.
///
/// This repairs both a missing pre-index file and a partially written index.
/// Document ops no longer need a shared index because they live in `doc_store`.
fn backfill_indexes(tables: Tables) -> Nil {
  let assert Ok(ref_count) = set.size(of: tables.refs)
  let assert Ok(ref_index_count) = bag.size(of: tables.refs_index)
  case ref_index_count < ref_count {
    True -> {
      let assert Ok(refs) = set.to_list(from: tables.refs)
      refs
      |> list.each(fn(entry) {
        let #(#(tenant, ref), _sha) = entry
        let assert Ok(Nil) =
          bag.insert(into: tables.refs_index, key: tenant, value: ref)
        Nil
      })
    }
    False -> Nil
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

@external(erlang, "floodgate_shelf_ffi", "publish_tables")
fn publish_tables(name: process.Name(Msg), tables: Tables) -> Nil

@external(erlang, "floodgate_shelf_ffi", "lookup_tables")
fn lookup_tables(name: process.Name(Msg)) -> Result(Tables, Nil)
