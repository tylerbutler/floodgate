import floodgate
import floodgate/auth
import floodgate/git
import floodgate/memory_store
import floodgate/session
import floodgate/store
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import signet/jwt
import signet/types

pub fn main() {
  gleeunit.main()
}

pub fn start_registers_channel_test() {
  let assert Ok(_) = floodgate.start("fluid", "test-jwt-secret")
  floodgate.topic_prefix |> should.equal("document:")
}

/// The readiness probe both Docker and levee's integration harness use is
/// `GET /health`, so the body has to match levee's `HealthController` exactly.
pub fn health_body_matches_levee_test() {
  floodgate.health_body() |> should.equal("{\"status\":\"ok\"}")
}

/// `PORT` is the Docker/PaaS convention levee already honours; `FLOODGATE_PORT`
/// stays available for running alongside a levee server.
pub fn resolve_port_prefers_port_then_floodgate_port_test() {
  floodgate.resolve_port("8080", "3001") |> should.equal(8080)
  floodgate.resolve_port("", "3001") |> should.equal(3001)
  floodgate.resolve_port("", "") |> should.equal(3000)
  floodgate.resolve_port("not-a-port", "") |> should.equal(3000)
}

// ─────────────────────────────────────────────────────────────────────────────
// Levee REST parity — see docs/adr/009-floodgate-standalone-repo.md
// ─────────────────────────────────────────────────────────────────────────────

/// Levee's `DocumentController.create/2` uses `params["id"] || generate/0`, so
/// `POST /documents/:tenant` must create the document the caller asked for.
pub fn requested_document_id_honours_body_id_test() {
  floodgate.requested_document_id("{\"id\":\"my-doc\"}")
  |> should.equal(Some("my-doc"))
  floodgate.requested_document_id("{}") |> should.equal(None)
  floodgate.requested_document_id("") |> should.equal(None)
  // An empty id is not a usable document id — fall back to generating one.
  floodgate.requested_document_id("{\"id\":\"\"}") |> should.equal(None)
}

/// Messages mirror levee's `Plugs.Auth.error_response/1`. Statuses do not:
/// every rejection stays 401 to preserve the Routerlicious contract, where 401
/// means "refresh the token and retry" and 403 is fatal. Levee answers 403 for
/// wrong tenant/document and missing scopes. Deliberate — see ADR-009.
pub fn auth_error_response_matches_levee_test() {
  floodgate.auth_error_status(auth.MissingAuthorization) |> should.equal(401)
  floodgate.auth_error_message(auth.MissingAuthorization)
  |> should.equal("Missing Authorization header")

  floodgate.auth_error_status(auth.BadFormat) |> should.equal(401)
  floodgate.auth_error_message(auth.BadFormat)
  |> string.contains("Invalid Authorization header format")
  |> should.be_true

  floodgate.auth_error_status(auth.BadSignature) |> should.equal(401)

  floodgate.auth_error_status(auth.BadClaims(jwt.TokenExpired(1, 2)))
  |> should.equal(401)
  floodgate.auth_error_message(auth.BadClaims(jwt.TokenExpired(1, 2)))
  |> string.contains("expired")
  |> should.be_true

  // Levee answers 403 for these; floodgate stays 401 so the official driver
  // can refresh and retry rather than treating the rejection as fatal.
  floodgate.auth_error_status(
    auth.BadClaims(jwt.MissingScope(types.DocWrite, [])),
  )
  |> should.equal(401)
  floodgate.auth_error_message(
    auth.BadClaims(jwt.MissingScope(types.DocWrite, [])),
  )
  |> string.contains("scope")
  |> should.be_true

  floodgate.auth_error_status(auth.BadClaims(jwt.DocumentMismatch("a", "b")))
  |> should.equal(401)
  floodgate.auth_error_status(auth.BadClaims(jwt.TenantMismatch("a", "b")))
  |> should.equal(401)
}

pub fn standalone_storage_backend_selection_test() {
  let assert Ok(_) = floodgate.backend_from_name("ets")
  let assert Ok(_) = floodgate.backend_from_name("shelf")
  let assert Ok(_) = floodgate.backend_from_name("memory")
  floodgate.backend_from_name("postgres")
  |> should.equal(Error(floodgate.UnsupportedStorageBackend("postgres")))
}

pub fn session_sequences_per_document_test() {
  let s = session.start()
  session.join(s, "document:t:seqbasic", "c1") |> should.be_false
  session.join(s, "document:t:seqbasic", "c2") |> should.be_true
  let assert session.Assigned(1, _) =
    session.submit(s, "document:t:seqbasic", "c1", 1, 0, "a")
  let assert session.Assigned(2, _) =
    session.submit(s, "document:t:seqbasic", "c1", 2, 0, "b")
}

pub fn session_create_marks_document_existing_without_audience_client_test() {
  let s = session.start()
  session.create(s, "document:t:created") |> should.be_false
  session.clients(s, "document:t:created") |> should.equal([])
  session.join(s, "document:t:created", "c1") |> should.be_true
  session.clients(s, "document:t:created") |> should.equal(["c1"])
}

pub fn supervised_session_restarts_and_rehydrates_test() {
  let topic = "document:fluid:supervised-restart"
  // The backend outlives the session actor, which is what makes a restart
  // recoverable: `docs` is in-memory only and rebuilt from persisted ops.
  let backend = memory_store.new()
  let assert Ok(#(_channels, sess)) =
    floodgate.start_with_backend("fluid", "test-jwt-secret", backend)

  session.create(sess, topic) |> should.be_false
  let assert session.Joined(_, _, _, _) =
    session.join_sequenced(sess, topic, "c1", "{}", 1000)
  let before = session.sequence_number(sess, topic)
  before |> should.not_equal(0)

  // Kill it the way a real crash would, and confirm the supervisor brings it
  // back under the same registered name.
  let assert Ok(pid) = session.owner(sess)
  process.kill(pid)
  let assert Ok(restarted_pid) = await_restart(sess, pid, 100)
  { restarted_pid == pid } |> should.be_false

  // The handle still resolves — it holds the name, not the dead Subject — and
  // the sequence state comes back from storage rather than restarting at 0.
  session.exists(sess, topic) |> should.be_true
  session.sequence_number(sess, topic) |> should.equal(before)
}

/// Poll until the session's name resolves to a pid other than `dead`.
fn await_restart(
  sess: session.Session,
  dead: process.Pid,
  attempts: Int,
) -> Result(process.Pid, Nil) {
  case attempts <= 0 {
    True -> Error(Nil)
    False ->
      case session.owner(sess) {
        Ok(pid) if pid != dead -> Ok(pid)
        _ -> {
          process.sleep(10)
          await_restart(sess, dead, attempts - 1)
        }
      }
  }
}

pub fn session_create_persists_document_existence_test() {
  let topic = "document:t:persist-created"
  // Shared backend: a fresh session over the same store sees the document.
  let backend = memory_store.new()
  let s1 = session.start_with_backend(backend)
  session.create(s1, topic) |> should.be_false
  session.exists(s1, topic) |> should.be_true

  let s2 = session.start_with_backend(backend)
  session.exists(s2, topic) |> should.be_true
  session.create(s2, topic) |> should.be_true
}

pub fn initialized_document_starts_at_summary_checkpoint_test() {
  let topic = "document:t:initialized-checkpoint"
  // A shared backend outlives the session actor: a fresh session over the same
  // storage still sees the persisted summary checkpoint.
  let backend = memory_store.new()
  let s = session.start_with_backend(backend)

  session.create_initialized(s, topic, fn() {
    Ok(Some(#("initial-summary", 7)))
  })
  |> should.equal(session.Created)
  session.summary(s, topic) |> should.equal(#("initial-summary", 7))
  session.sequence_number(s, topic) |> should.equal(7)

  let restarted = session.start_with_backend(backend)
  session.summary(restarted, topic) |> should.equal(#("initial-summary", 7))
  session.sequence_number(restarted, topic) |> should.equal(7)
  let assert session.Joined(True, 8, 7, _) =
    session.join_sequenced(restarted, topic, "c1", "{}", 1000)
}

pub fn duplicate_initialized_document_preserves_existing_state_test() {
  let topic = "document:t:duplicate-initialized"
  let s = session.start()

  session.create_initialized(s, topic, fn() {
    Ok(Some(#("original-summary", 4)))
  })
  |> should.equal(session.Created)
  session.create_initialized(s, topic, fn() { Error(Nil) })
  |> should.equal(session.AlreadyExists)

  session.summary(s, topic) |> should.equal(#("original-summary", 4))
  session.sequence_number(s, topic) |> should.equal(4)
}

pub fn session_rejects_future_reference_sequence_number_test() {
  let s = session.start()
  session.join(s, "document:t:reject-future", "c1")
  session.submit(s, "document:t:reject-future", "c1", 1, 10, "a")
  |> should.equal(session.Rejected(0))
}

pub fn session_leave_removes_client_test() {
  let s = session.start()
  session.join(s, "document:t:leave", "c1")
  session.clients(s, "document:t:leave") |> should.equal(["c1"])
  session.leave(s, "document:t:leave", "c1")
  session.clients(s, "document:t:leave") |> should.equal([])
}

pub fn read_presence_does_not_pin_write_minimum_sequence_number_test() {
  let topic = "document:t:read-presence"
  let s = session.start()
  let assert session.Joined(False, 1, 0, _) =
    session.join_sequenced(s, topic, "writer", "{}", 1000)
  session.join_presence(s, topic, "reader", "read") |> should.be_true
  let roster =
    session.roster(s, topic)
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  let assert [#("reader", reader), #("writer", writer)] = roster
  reader |> string.contains("\"mode\":\"read\"") |> should.be_true
  writer |> string.contains("\"mode\":\"write\"") |> should.be_true

  let assert session.MessageAssigned(2, 1, _) =
    session.submit_message(s, topic, "writer", 1, 1, fn(_, _) { "first" })
  let assert session.MessageAssigned(3, 2, _) =
    session.submit_message(s, topic, "writer", 2, 2, fn(_, _) { "second" })
}

pub fn connect_returns_an_atomic_document_snapshot_test() {
  let topic = "document:t:connect-snapshot"
  let s = session.start()
  session.create_initialized(s, topic, fn() { Ok(Some(#("summary-4", 4))) })

  let assert session.Connected(
    True,
    [],
    [#(5, join_message)],
    "summary-4",
    4,
    5,
    Some(#(5, membership_message)),
  ) =
    session.connect(
      s,
      topic,
      "writer",
      "write",
      "{\"mode\":\"write\"}",
      "{}",
      1000,
    )
  membership_message |> should.equal(join_message)

  let assert session.MessageAssigned(6, 5, "app-op") =
    session.submit_message(s, topic, "writer", 1, 5, fn(_, _) { "app-op" })
  let assert session.Connected(
    True,
    [#("writer", "{\"mode\":\"write\"}")],
    initial_ops,
    "summary-4",
    4,
    6,
    None,
  ) =
    session.connect(
      s,
      topic,
      "reader",
      "read",
      "{\"mode\":\"read\"}",
      "{}",
      2000,
    )
  initial_ops |> should.equal([#(5, join_message), #(6, "app-op")])
}

pub fn sequenced_join_and_leave_are_persisted_as_protocol_ops_test() {
  let topic = "document:t:protocol-membership"
  let s = session.start()
  let join_data = "{\"clientId\":\"c1\",\"detail\":{\"mode\":\"write\"}}"
  let assert session.Joined(False, 1, 0, join_message) =
    session.join_sequenced(s, topic, "c1", join_data, 1000)
  join_message |> string.contains("\"type\":\"join\"") |> should.be_true

  let assert session.Left(2, 0, leave_message) =
    session.leave_sequenced(s, topic, "c1", 2000)
  leave_message |> string.contains("\"type\":\"leave\"") |> should.be_true
  session.since(s, topic, 0)
  |> should.equal([#(1, join_message), #(2, leave_message)])
}

pub fn reconnect_starts_from_current_sequence_checkpoint_test() {
  let topic = "document:t:reconnect-checkpoint"
  let s = session.start()
  session.join(s, topic, "c1")
  let assert session.Assigned(1, _) =
    session.submit(s, topic, "c1", 1, 0, "before-disconnect")
  session.leave(s, topic, "c1")
  session.clients(s, topic) |> should.equal([])

  session.join(s, topic, "c2")
  let assert session.Assigned(2, 1) =
    session.submit(s, topic, "c2", 1, 0, "after-reconnect")
}

pub fn since_returns_history_after_sn_test() {
  let s = session.start()
  session.join(s, "document:t:since", "c1")
  let assert session.Assigned(1, _) =
    session.submit(s, "document:t:since", "c1", 1, 0, "a")
  let assert session.Assigned(2, _) =
    session.submit(s, "document:t:since", "c1", 2, 0, "b")
  session.since(s, "document:t:since", 1) |> should.equal([#(2, "b")])
}

pub fn submit_message_persists_the_built_message_test() {
  let topic = "document:t:atomic-message"
  let s = session.start()
  session.join(s, topic, "c1")

  let assert session.MessageAssigned(1, 0, message) =
    session.submit_message(s, topic, "c1", 1, 0, fn(sn, msn) {
      "message-" <> int.to_string(sn) <> "-" <> int.to_string(msn)
    })
  message |> should.equal("message-1-0")
  session.since(s, topic, 0) |> should.equal([#(1, message)])
}

pub fn summary_stores_latest_handle_test() {
  let s = session.start()
  session.set_summary(s, "document:t:d2", "sha-abc", 5)
  session.summary(s, "document:t:d2") |> should.equal(#("sha-abc", 5))
}

pub fn sequenced_summary_advances_past_response_and_stores_context_test() {
  let topic = "document:t:sequenced-summary"
  let s = session.start()
  session.join(s, topic, "c1")
  let assert session.SummaryAssigned(1, 2, _) =
    session.submit_summary(
      s,
      topic,
      "c1",
      1,
      0,
      "summary",
      "ack",
      Some("summary-handle"),
    )
  session.summary(s, topic) |> should.equal(#("summary-handle", 1))
  session.sequence_number(s, topic) |> should.equal(2)
  let assert session.Assigned(3, _) =
    session.submit(s, topic, "c1", 2, 2, "after-summary")
}

pub fn summary_nack_does_not_replace_latest_summary_test() {
  let topic = "document:t:nacked-summary"
  let s = session.start()
  session.join(s, topic, "c1")
  session.set_summary(s, topic, "existing-handle", 0)
  let assert session.SummaryAssigned(1, 2, _) =
    session.submit_summary(
      s,
      topic,
      "c1",
      1,
      0,
      "invalid-summary",
      "nack",
      None,
    )
  session.summary(s, topic) |> should.equal(#("existing-handle", 0))
}

pub fn ops_persist_across_session_restart_test() {
  let backend = memory_store.new()
  let s1 = session.start_with_backend(backend)
  session.join(s1, "document:t:persist", "c1")
  let assert session.Assigned(_, _) =
    session.submit(s1, "document:t:persist", "c1", 1, 0, "DURABLE")
  // A fresh session actor over the same store still sees the op.
  let s2 = session.start_with_backend(backend)
  session.since(s2, "document:t:persist", 0) |> should.equal([#(1, "DURABLE")])
}

pub fn sequence_continues_after_session_restart_test() {
  let backend = memory_store.new()
  let s1 = session.start_with_backend(backend)
  session.join(s1, "document:t:resume", "c1")
  let assert session.Assigned(1, _) =
    session.submit(s1, "document:t:resume", "c1", 1, 0, "x")
  // Fresh actor over the same store resumes numbering after the last SN.
  let s2 = session.start_with_backend(backend)
  session.join(s2, "document:t:resume", "c2")
  let assert session.Assigned(2, _) =
    session.submit(s2, "document:t:resume", "c2", 1, 0, "y")
  session.sequence_number(s2, "document:t:resume") |> should.equal(2)
}

pub fn git_create_fetch_roundtrip_test() {
  let storage = memory_store.new()
  store.open(storage)
  let body = "{\"content\":\"aGk=\",\"encoding\":\"base64\"}"
  let assert Ok(sha) = git.create(storage, "t", "blobs", body)
  sha |> should.equal("32f95c0d1244a78b2be1bab8de17906fabb2c4a8")
  git.fetch(storage, "t", sha) |> should.equal(Ok(body))
  git.fetch(storage, "t", "nope") |> should.equal(Error(Nil))
}

pub fn git_ref_roundtrip_test() {
  let storage = memory_store.new()
  store.open(storage)
  git.create_ref(storage, "t", "heads/main", "commit-sha")
  |> should.be_true
  git.create_ref(storage, "t", "heads/main", "replacement")
  |> should.be_false
  git.get_ref(storage, "t", "refs/heads/main")
  |> should.equal(Ok("commit-sha"))
  git.list_refs(storage, "t")
  |> should.equal([#("refs/heads/main", "commit-sha")])
}

pub fn git_commit_history_follows_first_parent_test() {
  let storage = memory_store.new()
  store.open(storage)
  let first_body =
    "{\"tree\":\"tree-1\",\"parents\":[],\"message\":\"first\",\"author\":{}}"
  let assert Ok(first_sha) =
    git.create(storage, "history", "commits", first_body)
  let second_body =
    "{\"tree\":\"tree-2\",\"parents\":[\""
    <> first_sha
    <> "\"],\"message\":\"second\",\"author\":{}}"
  let assert Ok(second_sha) =
    git.create(storage, "history", "commits", second_body)

  git.commit_history_response(
    storage,
    "http://localhost",
    "history",
    second_sha,
    2,
  )
  |> list.length
  |> should.equal(2)
}
