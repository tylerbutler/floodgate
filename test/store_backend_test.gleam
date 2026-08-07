import floodgate
import floodgate/git
import floodgate/memory_store
import floodgate/session
import floodgate/shelf_store
import floodgate/store
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleeunit/should
import shelf
import shelf/set

/// A fresh, unique on-disk data directory so each run starts from empty DETS
/// (shelf persists via WriteThrough, so reused dirs would leak state between
/// runs). Lives under build/, which is gitignored and cleaned by `gleam clean`.
fn unique_dir() -> String {
  "build/floodgate_shelf_test/"
  <> { crypto.strong_random_bytes(8) |> bit_array.base16_encode }
}

type RuntimeObservation {
  RuntimeObservation(
    existing: Bool,
    roster: List(#(String, String)),
    initial_ops: List(#(Int, String)),
    summary: #(String, Int),
    current_sequence_number: Int,
    deltas_json: String,
    blob_json: String,
    refs_json: String,
  )
}

pub fn shelf_backend_satisfies_storage_boundary_test() {
  assert_backend_contract(
    shelf_store.new(unique_dir()),
    "document:backend-contract:shelf",
    "backend-contract-shelf",
  )
}

pub fn actor_memory_backend_satisfies_storage_boundary_test() {
  assert_backend_contract(
    memory_store.new(),
    "document:backend-contract:memory",
    "backend-contract-memory",
  )
}

/// The memory backend's actor holds every document, op, and ref for the
/// runtime, so before it was supervised its death left every `store.*` call
/// timing out forever with nothing to restart it. Its state does not survive —
/// there is nothing to rehydrate an in-memory store from — but the *service*
/// does, and the `Backend` closures keep working because they resolve the
/// actor's name at call time rather than capturing a `Subject`.
pub fn supervised_memory_backend_restarts_after_a_crash_test() {
  let name = memory_store.new_name()
  let backend = memory_store.from_name(name)
  let assert Ok(#(_channels, _sess)) =
    floodgate.start_with_backend(
      "memory-restart",
      "memory-restart-secret",
      backend,
    )

  let topic = "document:memory-restart:doc"
  store.put_document(backend, topic)
  store.has_document(backend, topic) |> should.be_true

  let assert Ok(pid) = process.subject_owner(process.named_subject(name))
  process.kill(pid)

  // The supervisor restarts it under the same name; the same `Backend` value
  // still reaches it.
  await_restart(name, pid, 100)
  store.has_document(backend, topic) |> should.be_false
  store.put_document(backend, topic)
  store.has_document(backend, topic) |> should.be_true
}

fn await_restart(
  name: process.Name(memory_store.Msg),
  old: process.Pid,
  attempts: Int,
) -> Nil {
  case attempts <= 0 {
    True -> panic as "memory store was not restarted"
    False ->
      case process.subject_owner(process.named_subject(name)) {
        Ok(pid) if pid != old -> Nil
        _ -> {
          process.sleep(10)
          await_restart(name, old, attempts - 1)
        }
      }
  }
}

/// Ops and refs are served through bag indexes rather than a full table scan.
/// A DETS directory written before those indexes existed has no index files, so
/// opening it must rebuild them — otherwise every pre-existing document would
/// read back as having no history.
pub fn shelf_backend_rebuilds_missing_indexes_on_open_test() {
  let dir = unique_dir()
  let topic = "document:reindex:doc"
  let tenant = "reindex"

  // Write the ops and refs tables the way a pre-index floodgate did — no index
  // files at all — then close them so the reopen below is a genuine cold start.
  ensure_dir(dir)
  let ops = open_table(dir, "floodgate_ops", "ops.dets", topic_sn_key())
  let assert Ok(Nil) = set.insert(into: ops, key: #(topic, 1), value: "first")
  let assert Ok(Nil) = set.insert(into: ops, key: #(topic, 2), value: "second")
  let assert Ok(Nil) = set.close(ops)

  let refs = open_table(dir, "floodgate_refs", "refs.dets", string_pair_key())
  let assert Ok(Nil) =
    set.insert(into: refs, key: #(tenant, "refs/heads/main"), value: "main-sha")
  let assert Ok(Nil) = set.close(refs)

  let reopened = shelf_store.new(dir)
  store.get_ops(reopened, topic)
  |> should.equal([#(1, "first"), #(2, "second")])
  store.list_refs(reopened, tenant)
  |> should.equal([#("refs/heads/main", "main-sha")])
}

fn open_table(
  dir: String,
  name: String,
  path: String,
  key: decode.Decoder(k),
) -> set.PSet(k, String) {
  let config =
    shelf.config(name: name, path: path, base_directory: dir)
    |> shelf.write_mode(mode: shelf.WriteThrough)
  let assert Ok(table) =
    set.open_config(config: config, key: key, value: decode.string)
  table
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

@external(erlang, "floodgate_shelf_ffi", "ensure_dir")
fn ensure_dir(dir: String) -> Nil

pub fn backend_substitution_preserves_runtime_session_and_historian_observations_test() {
  let memory_observation = observe_runtime_contract(memory_store.new())
  let shelf_observation =
    observe_runtime_contract(shelf_store.new(unique_dir()))

  shelf_observation |> should.equal(memory_observation)
}

fn assert_backend_contract(
  backend: store.Backend,
  topic: String,
  tenant: String,
) {
  store.open(backend)

  store.has_document(backend, topic) |> should.be_false
  store.put_document(backend, topic)
  store.has_document(backend, topic) |> should.be_true

  store.put_op(backend, topic, 2, "second")
  store.put_op(backend, topic, 1, "first")
  store.get_ops(backend, topic)
  |> should.equal([#(1, "first"), #(2, "second")])

  // Re-putting a sequence number replaces it rather than accumulating. The
  // shelf backend indexes ops by topic to avoid scanning the whole table, so
  // this is what pins the index to the set it indexes.
  store.put_op(backend, topic, 2, "second-replaced")
  store.get_ops(backend, topic)
  |> should.equal([#(1, "first"), #(2, "second-replaced")])

  // And one document's ops never surface in another's.
  let other = topic <> "-other"
  store.put_op(backend, other, 1, "other-first")
  store.get_ops(backend, other) |> should.equal([#(1, "other-first")])
  store.get_ops(backend, topic)
  |> should.equal([#(1, "first"), #(2, "second-replaced")])

  store.get_summary(backend, topic) |> should.equal(#("", 0))
  store.put_summary(backend, topic, "summary-sha", 2)
  store.get_summary(backend, topic) |> should.equal(#("summary-sha", 2))

  store.get_obj(backend, tenant, "missing") |> should.equal(Error(Nil))
  store.put_obj(backend, tenant, "object-sha", "object-body")
  store.get_obj(backend, tenant, "object-sha")
  |> should.equal(Ok("object-body"))

  store.create_ref(backend, tenant, "refs/heads/z", "z-sha")
  |> should.be_true
  store.create_ref(backend, tenant, "refs/heads/z", "replacement")
  |> should.be_false
  store.put_ref(backend, tenant, "refs/heads/a", "a-sha")
  store.get_ref(backend, tenant, "refs/heads/z")
  |> should.equal(Ok("z-sha"))
  store.list_refs(backend, tenant)
  |> should.equal([
    #("refs/heads/a", "a-sha"),
    #("refs/heads/z", "z-sha"),
  ])

  // Refs are indexed by tenant for the same reason ops are by topic: a losing
  // `create_ref` must leave no index entry, an overwrite must not duplicate one,
  // and another tenant's refs must not appear here.
  store.put_ref(backend, tenant, "refs/heads/a", "a-sha-2")
  store.put_ref(backend, tenant <> "-other", "refs/heads/elsewhere", "e-sha")
  store.list_refs(backend, tenant)
  |> should.equal([
    #("refs/heads/a", "a-sha-2"),
    #("refs/heads/z", "z-sha"),
  ])
}

// This exercises runtime composition, session output, and Historian JSON
// directly. HTTP and Socket.IO traversal is covered by the live suite.
fn observe_runtime_contract(backend: store.Backend) -> RuntimeObservation {
  let topic = "document:backend-runtime:document"
  let tenant = "backend-runtime"
  let assert Ok(#(_channels, sess)) =
    floodgate.start_with_backend(tenant, "backend-runtime-secret", backend)
  session.create_initialized(sess, topic, fn() { Ok(Some(#("summary-7", 7))) })

  let session.Connected(
    existing,
    roster,
    initial_ops,
    summary_handle,
    summary_sequence_number,
    current_sequence_number,
    _membership,
  ) =
    session.connect(
      sess,
      topic,
      "socket-client",
      "write",
      "{\"mode\":\"write\"}",
      "{\"clientId\":\"socket-client\"}",
      1_700_000_000,
    )

  let assert session.MessageAssigned(_, _, _) =
    session.submit_message(
      sess,
      topic,
      "socket-client",
      1,
      current_sequence_number,
      fn(sn, msn) {
        json.object([
          #("sequenceNumber", json.int(sn)),
          #("minimumSequenceNumber", json.int(msn)),
          #("type", json.string("op")),
          #("contents", json.string("runtime-body")),
        ])
        |> json.to_string
      },
    )

  let deltas_json =
    session.since(sess, topic, 7)
    |> list.map(session.stored_message_json)
    |> json.preprocessed_array
    |> json.to_string

  let blob_body = "{\"content\":\"d2lyZQ==\",\"encoding\":\"base64\"}"
  let assert Ok(blob_sha) = git.create(backend, tenant, "blobs", blob_body)
  let assert Ok(blob_json) =
    git.object_response(
      backend,
      "http://floodgate.test",
      tenant,
      "blobs",
      blob_sha,
      blob_body,
      False,
    )
  git.put_ref(backend, tenant, "refs/heads/document", blob_sha)
  let refs_json =
    git.list_refs(backend, tenant)
    |> list.map(fn(ref) {
      git.ref_response("http://floodgate.test", tenant, ref.0, ref.1)
    })
    |> json.preprocessed_array
    |> json.to_string

  RuntimeObservation(
    existing,
    roster,
    initial_ops,
    #(summary_handle, summary_sequence_number),
    current_sequence_number,
    deltas_json,
    json.to_string(blob_json),
    refs_json,
  )
}
