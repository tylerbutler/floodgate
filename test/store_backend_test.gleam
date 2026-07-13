import floodgate
import floodgate/git
import floodgate/memory_store
import floodgate/session
import floodgate/store
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleeunit/should

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

pub fn ets_backend_satisfies_storage_boundary_test() {
  assert_backend_contract(
    store.ets(),
    "document:backend-contract:ets",
    "backend-contract-ets",
  )
}

pub fn actor_memory_backend_satisfies_storage_boundary_test() {
  assert_backend_contract(
    memory_store.new(),
    "document:backend-contract:memory",
    "backend-contract-memory",
  )
}

pub fn backend_substitution_preserves_runtime_session_and_historian_observations_test() {
  let memory_observation = observe_runtime_contract(memory_store.new())
  let ets_observation = observe_runtime_contract(store.ets())

  ets_observation |> should.equal(memory_observation)
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
