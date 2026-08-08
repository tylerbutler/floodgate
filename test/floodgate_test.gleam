import floodgate
import floodgate/auth
import floodgate/git
import floodgate/memory_store
import floodgate/session
import floodgate/store
import gleam/erlang/process
import gleam/int
import gleam/json
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

/// An unregistered tenant is its own `auth.AuthError` variant (not a token
/// claims mismatch — no token has been parsed yet), but stays on the same 401
/// contract as every other rejection.
pub fn unknown_tenant_error_matches_401_contract_test() {
  floodgate.auth_error_status(auth.UnknownTenant("ghost-tenant"))
  |> should.equal(401)
  floodgate.auth_error_message(auth.UnknownTenant("ghost-tenant"))
  |> should.equal("Unknown tenant 'ghost-tenant'")
}

// ─────────────────────────────────────────────────────────────────────────────
// Tenant admin API — response shapes must match the Lustre UI's decoders in
// server/levee_admin/src/levee_admin/api.gleam exactly.
// ─────────────────────────────────────────────────────────────────────────────

/// `{id, name}` — `api.gleam`'s `tenant_decoder`. No secrets, ever.
pub fn tenant_info_json_matches_admin_ui_decoder_shape_test() {
  floodgate.tenant_info_json(store.TenantInfo(id: "t-1", name: "Acme"))
  |> json_to_string
  |> should.equal("{\"id\":\"t-1\",\"name\":\"Acme\"}")
}

/// `{id, name, secret1, secret2}` — `api.gleam`'s
/// `tenant_with_secrets_decoder`, used by both create and show.
pub fn tenant_with_secrets_json_matches_admin_ui_decoder_shape_test() {
  floodgate.tenant_with_secrets_json(store.TenantWithSecrets(
    id: "t-1",
    name: "Acme",
    secret1: "s1",
    secret2: "s2",
  ))
  |> json_to_string
  |> should.equal(
    "{\"id\":\"t-1\",\"name\":\"Acme\",\"secret1\":\"s1\",\"secret2\":\"s2\"}",
  )
}

pub fn decode_tenant_name_requires_name_field_test() {
  floodgate.decode_tenant_name("{\"name\":\"Acme\"}")
  |> should.equal(Ok("Acme"))
  floodgate.decode_tenant_name("{}") |> should.equal(Error(Nil))
  floodgate.decode_tenant_name("not json") |> should.equal(Error(Nil))
}

/// Only `"1"` and `"2"` are valid slots — matching levee's
/// `Integer.parse/1` guard, which also rejects `"01"` and out-of-range values.
pub fn parse_tenant_slot_accepts_only_one_or_two_test() {
  floodgate.parse_tenant_slot("1") |> should.equal(Ok(store.Slot1))
  floodgate.parse_tenant_slot("2") |> should.equal(Ok(store.Slot2))
  floodgate.parse_tenant_slot("3") |> should.equal(Error(Nil))
  floodgate.parse_tenant_slot("0") |> should.equal(Error(Nil))
  floodgate.parse_tenant_slot("01") |> should.equal(Error(Nil))
  floodgate.parse_tenant_slot("") |> should.equal(Error(Nil))
}

// ─────────────────────────────────────────────────────────────────────────────
// Startup tenant compatibility, through the real `start_with_backend` path —
// see `tenant_store_test.gleam` for the lower-level `store.ensure_startup_tenant`
// contract this exercises.
// ─────────────────────────────────────────────────────────────────────────────

/// `FLOODGATE_TENANT_ID`/`FLOODGATE_JWT_SECRET` keep authorizing existing
/// deployments unchanged: the configured tenant is registered with `secret1`
/// equal to the configured secret, and both secret slots resolve through the
/// same tenant store the admin API reads and writes.
pub fn start_with_backend_seeds_the_configured_tenant_test() {
  let backend = memory_store.new()
  let assert Ok(_) =
    floodgate.start_with_backend("fluid", "test-jwt-secret", backend)

  store.tenant_exists(backend, "fluid") |> should.be_true
  let assert Ok(#(secret1, _secret2)) =
    store.get_tenant_secrets(backend, "fluid")
  secret1 |> should.equal("test-jwt-secret")
}

/// A second `start_with_backend` against the *same* backend — the shape of a
/// process restart against persistent shelf storage — must not roll back a
/// secret the admin API already rotated for the seeded tenant.
pub fn start_with_backend_does_not_reset_a_rotated_startup_secret_test() {
  let backend = memory_store.new()
  let assert Ok(_) =
    floodgate.start_with_backend("fluid", "test-jwt-secret", backend)

  let assert Ok(rotated_secret2) =
    store.regenerate_tenant_secret(backend, "fluid", store.Slot2)

  let assert Ok(_) =
    floodgate.start_with_backend("fluid", "test-jwt-secret", backend)
  store.get_tenant_secrets(backend, "fluid")
  |> should.equal(Ok(#("test-jwt-secret", rotated_secret2)))
}

fn json_to_string(value: json.Json) -> String {
  json.to_string(value)
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
  let session.Joined(_, _, _, _) =
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

/// A summary is five independent DETS writes with no transaction, so a crash can
/// land between them. They are ordered so that every prefix is safe — objects,
/// then ops, then the session's summary pointer, then the ref that mirrors it —
/// which leaves exactly one prefix that is not: a summary pointer with no ref at
/// all, since `GET /commits?sha=<id>` resolves through that ref and without it the
/// document cannot be loaded. Rehydration repairs it.
pub fn missing_summary_ref_is_restored_on_rehydrate_test() {
  let backend = memory_store.new()
  let tenant = "ref-repair"
  let doc = "doc"
  let topic = "document:" <> tenant <> ":" <> doc

  // The state a crash between `put_summary` and the ref write leaves behind.
  store.put_obj(backend, tenant, "commit-sha", "{}")
  store.put_summary(backend, topic, "commit-sha", 5)
  git.get_ref(backend, tenant, git.summary_ref(doc)) |> should.equal(Error(Nil))

  // Touching the document rehydrates it, which is where the repair runs.
  let s = session.start_with_backend(backend)
  session.sequence_number(s, topic) |> should.equal(5)
  git.get_ref(backend, tenant, git.summary_ref(doc))
  |> should.equal(Ok("commit-sha"))
}

/// A ref that merely lags is safe — a client discovering an older snapshot just
/// replays more ops — and clients may move refs through the Historian API, so the
/// repair must only fill in a missing ref, never overwrite one.
pub fn existing_summary_ref_is_left_alone_on_rehydrate_test() {
  let backend = memory_store.new()
  let tenant = "ref-keep"
  let doc = "doc"
  let topic = "document:" <> tenant <> ":" <> doc

  git.put_ref(backend, tenant, git.summary_ref(doc), "client-chosen-sha")
  store.put_summary(backend, topic, "commit-sha", 5)

  let s = session.start_with_backend(backend)
  session.sequence_number(s, topic) |> should.equal(5)
  git.get_ref(backend, tenant, git.summary_ref(doc))
  |> should.equal(Ok("client-chosen-sha"))
}

/// `initialMessages` is served from a per-document op history that used to be
/// unbounded and extended with `list.append` — a leak that also copied the whole
/// list on every op. It is now newest-first and capped at 1000, matching levee's
/// `@max_history_size`, and reversed on the way out. This pins both halves: the
/// cap, and the order clients actually need.
pub fn initial_messages_are_capped_and_oldest_first_test() {
  let topic = "document:t:history-cap"
  let s = session.start()
  session.join(s, topic, "c1") |> should.be_false

  submit_ops(s, topic, 1, 1005)

  let session.Connected(_, _, initial_ops, _, _, _, _) =
    session.connect(s, topic, "c2", "read", "{}", "{}", 0)

  list.length(initial_ops) |> should.equal(1000)
  // The newest 1000 of 1005, oldest first: sequence numbers 6 through 1005.
  let assert [oldest, ..] = initial_ops
  oldest.0 |> should.equal(6)
  let assert Ok(newest) = list.last(initial_ops)
  newest.0 |> should.equal(1005)
}

fn submit_ops(
  s: session.Session,
  topic: String,
  csn: Int,
  through: Int,
) -> Nil {
  case csn > through {
    True -> Nil
    False -> {
      let assert session.Assigned(_, _) =
        session.submit(s, topic, "c1", csn, 0, "op-" <> int.to_string(csn))
      submit_ops(s, topic, csn + 1, through)
    }
  }
}

/// `docs` is a cache over storage, but nothing ever dropped from it: a server
/// that had seen a million documents held a million of them, each with up to
/// 1000 ops of history. The sweep evicts the ones with no connected client, and
/// `doc/3` rebuilds them — the same path a supervised restart takes, which is
/// what makes eviction safe rather than lossy.
pub fn idle_documents_are_evicted_and_rehydrate_test() {
  let topic = "document:fluid:idle-evict"
  // Sweeps every 50 ms, evicting anything untouched for 100 ms. Read once at
  // start, so restoring the variable straight away leaves other tests on the
  // 5 minute default.
  setenv("FLOODGATE_DOC_IDLE_MS", "100")
  let backend = memory_store.new()
  let sess = session.start_with_backend(backend)
  setenv("FLOODGATE_DOC_IDLE_MS", "")

  let session.Joined(_, _, _, _) =
    session.join_sequenced(sess, topic, "c1", "{}", 1000)
  let before = session.sequence_number(sess, topic)
  session.cached_documents(sess) |> should.equal(1)

  // A document with a connected client is never evicted, however idle.
  process.sleep(250)
  session.cached_documents(sess) |> should.equal(1)

  let session.Left(_, _, _) = session.leave_sequenced(sess, topic, "c1", 2000)
  process.sleep(250)
  session.cached_documents(sess) |> should.equal(0)

  // Evicting it lost nothing: the numbering comes back from persisted ops.
  session.sequence_number(sess, topic) |> should.equal(before + 1)
}

@external(erlang, "floodgate_ffi", "setenv")
fn setenv(name: String, value: String) -> Nil

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
  let topic = store.topic("t", "doc")
  let assert Ok(sha) = git.create(storage, topic, "blobs", body)
  sha |> should.equal("32f95c0d1244a78b2be1bab8de17906fabb2c4a8")
  git.fetch(storage, topic, sha) |> should.equal(Ok(body))
  git.fetch(storage, topic, "nope") |> should.equal(Error(Nil))
  // Objects are document-scoped: the same tenant, a different document, does
  // not see it. This is what makes a document's storage self-contained.
  git.fetch(storage, store.topic("t", "other"), sha)
  |> should.equal(Error(Nil))
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
  let topic = store.topic("history", "doc")
  let first_body =
    "{\"tree\":\"tree-1\",\"parents\":[],\"message\":\"first\",\"author\":{}}"
  let assert Ok(first_sha) = git.create(storage, topic, "commits", first_body)
  let second_body =
    "{\"tree\":\"tree-2\",\"parents\":[\""
    <> first_sha
    <> "\"],\"message\":\"second\",\"author\":{}}"
  let assert Ok(second_sha) = git.create(storage, topic, "commits", second_body)

  git.commit_history_response(
    storage,
    "http://localhost",
    "history",
    topic,
    second_sha,
    2,
  )
  |> list.length
  |> should.equal(2)
}

// ── Per-document sequencing ────────────────────────────────────────────────

/// The point of one actor per document: work on one must not block another.
///
/// `create_initialized` runs its build closure *inside* the mailbox — which is
/// why it alone has a 10 s timeout rather than 1 s — so under the old single
/// actor a slow initial-summary build stalled every other document on the node.
/// Here a 600 ms build on one document must not delay a join on another.
pub fn slow_document_does_not_block_another_test() {
  let backend = memory_store.new()
  let sess = session.start_with_backend(backend)

  process.spawn_unlinked(fn() {
    session.create_initialized(sess, "document:t:slow", fn() {
      process.sleep(600)
      Ok(Some(#("slow-summary", 1)))
    })
  })
  // Let the slow build take its actor's mailbox before racing it.
  process.sleep(50)

  // The slow build is genuinely mid-flight: its actor is up and holding its own
  // mailbox. Without this the timing assertion below would also pass if the
  // spawn had failed and nothing slow were running at all.
  let assert Ok(_) = session.document_owner(sess, "document:t:slow")

  let started = now_ms()
  let session.Joined(_, _, _, _) =
    session.join_sequenced(sess, "document:t:fast", "c1", "{}", 1000)
  let elapsed = now_ms() - started

  // Generous enough not to be flaky, tight enough to fail outright if the two
  // documents still share a mailbox — that would put this at ~550 ms.
  { elapsed < 300 } |> should.be_true

  // And the slow build really did take its 600 ms and then commit, so the join
  // above overlapped it rather than following it.
  process.sleep(700)
  session.summary(sess, "document:t:slow")
  |> should.equal(#("slow-summary", 1))
}

/// A crash now costs one document's roster instead of every document's. Under
/// the old single actor, killing the sequencer discarded `client_states` for
/// everything on the node at once.
pub fn document_crash_does_not_disturb_other_documents_test() {
  let backend = memory_store.new()
  let sess = session.start_with_backend(backend)
  let victim = "document:t:crash-victim"
  let bystander = "document:t:crash-bystander"

  let session.Joined(_, _, _, _) =
    session.join_sequenced(sess, victim, "c1", "{}", 1000)
  let session.Joined(_, _, _, _) =
    session.join_sequenced(sess, bystander, "c2", "{}", 1000)
  let victim_sn = session.sequence_number(sess, victim)

  let assert Ok(pid) = session.document_owner(sess, victim)
  process.kill(pid)
  process.sleep(50)

  // The bystander kept its in-memory roster — it was never touched.
  session.clients(sess, bystander) |> should.equal(["c2"])

  // The victim rehydrates from storage on next touch: numbering survives, the
  // roster does not. That is the documented restart contract, now scoped to one
  // document rather than all of them.
  session.sequence_number(sess, victim) |> should.equal(victim_sn)
  session.clients(sess, victim) |> should.equal([])
}

/// The failure mode the ETS registry introduces: a row can outlive its actor for
/// a moment, so a caller can resolve a subject that is already dead. `call_doc`
/// has to turn that into a retry rather than a panic that takes the caller — a
/// channel process, in production — down with it.
pub fn call_against_a_dead_document_actor_recovers_test() {
  let backend = memory_store.new()
  let sess = session.start_with_backend(backend)
  let topic = "document:t:stale-row"

  let session.Joined(_, _, _, _) =
    session.join_sequenced(sess, topic, "c1", "{}", 1000)
  let before = session.sequence_number(sess, topic)

  // Kill it and call straight away, without giving the owner's monitor time to
  // clear the row — so the call really does resolve a dead subject.
  let assert Ok(pid) = session.document_owner(sess, topic)
  process.kill(pid)

  let session.Joined(_, _, _, _) =
    session.join_sequenced(sess, topic, "c2", "{}", 2000)
  session.sequence_number(sess, topic) |> should.equal(before + 1)
}

/// Reading must not be able to allocate. `session.exists` is reachable from REST
/// paths that do not require the document to exist, so routing it through
/// get-or-start would let any `GET` for an unknown id spawn an actor.
pub fn reading_an_unknown_document_starts_no_actor_test() {
  let backend = memory_store.new()
  let sess = session.start_with_backend(backend)

  session.exists(sess, "document:t:never-created") |> should.be_false
  session.clients(sess, "document:t:never-created") |> should.equal([])
  session.roster(sess, "document:t:never-created") |> should.equal([])
  session.sequence_number(sess, "document:t:never-created") |> should.equal(0)
  session.since(sess, "document:t:never-created", 0) |> should.equal([])
  session.summary(sess, "document:t:never-created") |> should.equal(#("", 0))

  session.cached_documents(sess) |> should.equal(0)
}

/// The registry's ETS table belongs to the owner, so it dies with it. That is
/// what the `RestForOne` pairing is for: restarting the factory after the owner
/// takes every now-unreachable document actor down, rather than leaving them
/// holding state nothing can find. The ordering is positional and easy to break
/// silently, so pin it.
pub fn owner_restart_takes_document_actors_with_it_test() {
  let backend = memory_store.new()
  let sess = session.start_with_backend(backend)
  let topic = "document:t:owner-restart"

  let session.Joined(_, _, _, _) =
    session.join_sequenced(sess, topic, "c1", "{}", 1000)
  let before = session.sequence_number(sess, topic)
  let assert Ok(doc_pid) = session.document_owner(sess, topic)

  let assert Ok(owner_pid) = session.owner(sess)
  process.kill(owner_pid)
  let assert Ok(_) = await_restart(sess, owner_pid, 100)

  // No orphan: the document actor went down with the table that pointed at it.
  process.is_alive(doc_pid) |> should.be_false
  session.cached_documents(sess) |> should.equal(0)

  // And the document still works, rebuilt from storage.
  session.sequence_number(sess, topic) |> should.equal(before)
  let session.Joined(_, _, _, _) =
    session.join_sequenced(sess, topic, "c2", "{}", 2000)
}

@external(erlang, "floodgate_ffi", "now_ms")
fn now_ms() -> Int

/// Every submit handler must write before it acks.
///
/// `Submit` and `SubmitSummary` used to reply first, unlike their
/// closure-carrying siblings `SubmitMessage` and `SubmitSummaryMessages`. The
/// caller wakes on the reply, so it could read storage back before the actor's
/// write had run — and a crash in that window would have acked a sequence number
/// that was never persisted, leaving it free to be handed to a different op on
/// rehydration.
///
/// Reading the backend *directly* here is the point: going through
/// `session.since` would queue behind the actor and pass either way.
///
/// Of the two tests below, only the summary one reliably *detects* a regression
/// — verified by reverting the fix. `Submit`'s single write almost always lands
/// before the caller wakes, so it wins the race even when the order is wrong;
/// `SubmitSummary`'s three writes are late enough to lose. This one therefore
/// documents the contract rather than guarding it. Both are deterministic in the
/// correct order, so neither is flaky.
pub fn submit_is_durable_before_it_acks_test() {
  let backend = memory_store.new()
  let s = session.start_with_backend(backend)
  let topic = "document:t:durable-ack"
  session.join(s, topic, "c1") |> should.be_false

  let assert session.Assigned(sn, _) =
    session.submit(s, topic, "c1", 1, 0, "DURABLE")
  store.get_ops(backend, topic)
  |> list.key_find(sn)
  |> should.equal(Ok("DURABLE"))
}

pub fn submit_summary_is_durable_before_it_acks_test() {
  let backend = memory_store.new()
  let s = session.start_with_backend(backend)
  let topic = "document:t:durable-summary-ack"
  session.join(s, topic, "c1") |> should.be_false

  let assert session.SummaryAssigned(summary_sn, response_sn, _) =
    session.submit_summary(
      s,
      topic,
      "c1",
      1,
      0,
      "summary-op",
      "summary-ack",
      Some("handle-1"),
    )
  let stored = store.get_ops(backend, topic)
  stored |> list.key_find(summary_sn) |> should.equal(Ok("summary-op"))
  stored |> list.key_find(response_sn) |> should.equal(Ok("summary-ack"))
  // The summary pointer is written last of the three, so observing the ack must
  // mean it landed too.
  store.get_summary(backend, topic) |> should.equal(#("handle-1", summary_sn))
}
