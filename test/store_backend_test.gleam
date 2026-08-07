import floodgate
import floodgate/git
import floodgate/memory_store
import floodgate/session
import floodgate/shelf_store
import floodgate/store
import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleeunit/should

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
