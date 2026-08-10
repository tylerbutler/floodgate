import floodgate
import floodgate/doc_store
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
import gleam/otp/static_supervisor
import gleeunit/should
import shelf
import shelf/bag
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

pub fn supervised_shelf_backend_restarts_and_rehydrates_test() {
  let dir = unique_dir()
  let name = shelf_store.new_name()
  let backend = shelf_store.from_name(name, dir)
  let tenant = "shelf-restart"
  let topic = store.topic(tenant, "doc")
  let assert Ok(#(_channels, sess)) =
    floodgate.start_with_backend(tenant, "shelf-restart-secret", backend)

  session.create(sess, topic) |> should.be_false
  session.join(sess, topic, "c1") |> should.be_true
  let assert session.Assigned(1, _) =
    session.submit(sess, topic, "c1", 1, 0, "durable-op")
  store.put_summary(backend, topic, "summary-1", 1)
  store.put_obj(backend, topic, "blob-1", "blob-body")
  store.create_ref(backend, tenant, "refs/heads/main", "blob-1")
  |> should.be_true

  let assert Ok(pid) = process.subject_owner(process.named_subject(name))
  process.kill(pid)

  // Document data stays available from doc_store while the shared owner restarts.
  store.get_ops(backend, topic) |> should.equal([#(1, "durable-op")])
  let restarted_pid = await_shelf_restart(name, pid, 500)
  { restarted_pid == pid } |> should.be_false

  session.sequence_number(sess, topic) |> should.equal(1)
  store.get_summary(backend, topic) |> should.equal(#("summary-1", 1))
  store.get_obj(backend, topic, "blob-1") |> should.equal(Ok("blob-body"))
  store.list_refs(backend, tenant)
  |> should.equal([#("refs/heads/main", "blob-1")])
  store.create_ref(backend, tenant, "refs/heads/main", "replacement")
  |> should.be_false
  store.create_ref(backend, tenant, "refs/heads/next", "blob-1")
  |> should.be_true
}

pub fn supervised_shelf_backends_use_independent_names_test() {
  let first = shelf_store.from_name(shelf_store.new_name(), unique_dir())
  let second = shelf_store.from_name(shelf_store.new_name(), unique_dir())
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> store.supervise(first)
    |> store.supervise(second)
    |> static_supervisor.start

  store.put_document(first, "document:first:doc")
  store.put_document(second, "document:second:doc")

  store.has_document(first, "document:first:doc") |> should.be_true
  store.has_document(first, "document:second:doc") |> should.be_false
  store.has_document(second, "document:first:doc") |> should.be_false
  store.has_document(second, "document:second:doc") |> should.be_true
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

fn await_shelf_restart(
  name: process.Name(shelf_store.Msg),
  old: process.Pid,
  attempts: Int,
) -> process.Pid {
  case attempts <= 0 {
    True -> panic as "shelf store was not restarted"
    False ->
      case process.subject_owner(process.named_subject(name)) {
        Ok(pid) if pid != old -> pid
        _ -> {
          process.sleep(10)
          await_shelf_restart(name, old, attempts - 1)
        }
      }
  }
}

/// Refs are served through a bag index rather than a full table scan. Opening
/// must fill a missing or partial index left by an older version or interrupted
/// startup. Ops need no shared index now that they live in `doc_store`.
pub fn shelf_backend_rebuilds_partial_ref_index_on_open_test() {
  let dir = unique_dir()
  let tenant = "reindex"

  ensure_dir(dir)
  let refs = open_table(dir, "floodgate_refs", "refs.dets", string_pair_key())
  let assert Ok(Nil) =
    set.insert(into: refs, key: #(tenant, "refs/heads/main"), value: "main-sha")
  let assert Ok(Nil) =
    set.insert(into: refs, key: #(tenant, "refs/heads/next"), value: "next-sha")
  let assert Ok(Nil) = set.close(refs)
  let refs_index =
    open_bag_table(
      dir,
      "floodgate_refs_index",
      "refs_index.dets",
      decode.string,
      decode.string,
    )
  let assert Ok(Nil) =
    bag.insert(into: refs_index, key: tenant, value: "refs/heads/main")
  let assert Ok(Nil) = bag.close(refs_index)

  let reopened = shelf_store.new(dir)
  store.list_refs(reopened, tenant)
  |> should.equal([
    #("refs/heads/main", "main-sha"),
    #("refs/heads/next", "next-sha"),
  ])
}

/// Reading a document that was never written must not bring it into existence.
///
/// Opening a shelf table creates its DETS file, so without the read/write split
/// in `doc_store.open` a `get_ops` — reachable from unauthenticated REST paths
/// via `session.exists` — would create a file, make `has_document` true, and let
/// an unauthenticated caller litter the data directory.
pub fn shelf_backend_reads_do_not_create_documents_test() {
  let backend = shelf_store.new(unique_dir())
  let topic = "document:cold/tenant:never-written"

  store.get_ops(backend, topic) |> should.equal([])
  store.get_summary(backend, topic) |> should.equal(#("", 0))
  store.get_obj(backend, topic, "some-sha") |> should.equal(Error(Nil))
  store.has_document(backend, topic) |> should.be_false

  // A write is what creates it.
  store.put_document(backend, topic)
  store.has_document(backend, topic) |> should.be_true
}

/// Document ids are client-supplied and unbounded. Hex-encoding the path
/// components means traversal, separators, unicode, and length are all handled
/// by one code path rather than a sanitising conditional.
pub fn shelf_backend_stores_hostile_document_ids_test() {
  let backend = shelf_store.new(unique_dir())
  let hostile = [
    "../../escape",
    "with/slash",
    "with:colon:parts",
    "ünïcødé-🌊",
    "",
  ]

  list.each(hostile, fn(document_id) {
    let topic = store.topic("hostile", document_id)
    store.put_op(backend, topic, 1, "body-" <> document_id)
    store.get_ops(backend, topic)
    |> should.equal([#(1, "body-" <> document_id)])
  })

  // Each landed in its own file rather than colliding into one.
  list.each(hostile, fn(document_id) {
    store.get_ops(backend, store.topic("hostile", document_id))
    |> list.length
    |> should.equal(1)
  })
}

/// Evicting a document's table must be invisible: it is a cache drop, not a
/// delete, because `WriteThrough` already put every write on disk.
///
/// Driven through the open-file cap rather than the idle timer so it is
/// deterministic — with room for one table, opening a second evicts the first,
/// and reading the first back has to reopen it. This is the close-then-reopen
/// path ADR-005 recorded as untestable ("the closure interface has no
/// `close()`"), which per-document tables finally make reachable.
pub fn doc_store_reopens_evicted_documents_test() {
  setenv("FLOODGATE_MAX_OPEN_DOCUMENTS", "1")
  let docs = doc_store.started(unique_dir())
  setenv("FLOODGATE_MAX_OPEN_DOCUMENTS", "")

  let first = store.topic("evict", "first")
  let second = store.topic("evict", "second")

  doc_store.put_op(docs, first, 1, "first-body")
  doc_store.put_summary(docs, first, "first-summary", 1)
  doc_store.put_obj(docs, first, "first-sha", "first-object")
  doc_store.open_count(docs) |> should.equal(1)

  // Opening the second document is what pushes the first out.
  doc_store.put_op(docs, second, 1, "second-body")
  doc_store.open_count(docs) |> should.equal(1)

  // So this can only be answered by reopening the closed file.
  doc_store.get_ops(docs, first) |> should.equal([#(1, "first-body")])
  doc_store.get_summary(docs, first) |> should.equal(#("first-summary", 1))
  doc_store.get_obj(docs, first, "first-sha")
  |> should.equal(Ok("first-object"))
  doc_store.exists(docs, first) |> should.be_true

  // And it went both ways — the second survived being evicted in turn.
  doc_store.get_ops(docs, second) |> should.equal([#(1, "second-body")])
}

/// A document survives the process that wrote it.
///
/// Simulates a restart honestly: the idle sweep closes every file first, so the
/// second store opens the same directory cold and can only answer from DETS.
/// This is the cross-restart durability ADR-005 listed as untestable.
pub fn doc_store_reads_back_documents_after_a_restart_test() {
  let dir = unique_dir()
  setenv("FLOODGATE_DOC_IDLE_MS", "100")
  let before = doc_store.started(dir)
  setenv("FLOODGATE_DOC_IDLE_MS", "")

  let topic = store.topic("restart", "doc")
  doc_store.put_marker(before, topic)
  doc_store.put_op(before, topic, 1, "survives")
  doc_store.put_summary(before, topic, "summary-sha", 1)
  doc_store.put_obj(before, topic, "obj-sha", "object-body")

  // Let the sweep close the file, so nothing is left open for the next store.
  process.sleep(300)
  doc_store.open_count(before) |> should.equal(0)

  let after = doc_store.started(dir)
  doc_store.exists(after, topic) |> should.be_true
  doc_store.get_ops(after, topic) |> should.equal([#(1, "survives")])
  doc_store.get_summary(after, topic) |> should.equal(#("summary-sha", 1))
  doc_store.get_obj(after, topic, "obj-sha") |> should.equal(Ok("object-body"))

  // And a document that was never written is still absent.
  doc_store.exists(after, store.topic("restart", "other")) |> should.be_false
}

/// The idle sweep closes tables nobody has touched. Same guarantee as above,
/// reached through the timer rather than the cap.
pub fn doc_store_evicts_idle_documents_test() {
  setenv("FLOODGATE_DOC_IDLE_MS", "100")
  let docs = doc_store.started(unique_dir())
  setenv("FLOODGATE_DOC_IDLE_MS", "")

  let topic = store.topic("idle", "doc")
  doc_store.put_op(docs, topic, 1, "body")
  doc_store.open_count(docs) |> should.equal(1)

  // Two full windows: the sweep runs at half the window, so one window is not
  // enough to guarantee it has fired.
  process.sleep(300)
  doc_store.open_count(docs) |> should.equal(0)

  doc_store.get_ops(docs, topic) |> should.equal([#(1, "body")])
  doc_store.open_count(docs) |> should.equal(1)
}

@external(erlang, "floodgate_ffi", "setenv")
fn setenv(name: String, value: String) -> Nil

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

fn open_bag_table(
  dir: String,
  name: String,
  path: String,
  key: decode.Decoder(k),
  value: decode.Decoder(v),
) -> bag.PBag(k, v) {
  let config =
    shelf.config(name: name, path: path, base_directory: dir)
    |> shelf.write_mode(mode: shelf.WriteThrough)
  let assert Ok(table) = bag.open_config(config: config, key: key, value: value)
  table
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

  // Objects are keyed by topic, not tenant, so they land in the document's own
  // storage and another document in the same tenant cannot see them.
  store.get_obj(backend, topic, "missing") |> should.equal(Error(Nil))
  store.put_obj(backend, topic, "object-sha", "object-body")
  store.get_obj(backend, topic, "object-sha")
  |> should.equal(Ok("object-body"))
  store.get_obj(backend, topic <> "-other", "object-sha")
  |> should.equal(Error(Nil))

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
    _recovery,
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
  let assert Ok(blob_sha) = git.create(backend, topic, "blobs", blob_body)
  let assert Ok(blob_json) =
    git.object_response(
      backend,
      "http://floodgate.test",
      tenant,
      topic,
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
