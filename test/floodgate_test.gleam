import exception
import floodgate
import floodgate/auth
import floodgate/doc_state
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
import summary_fixture

pub fn main() -> Nil {
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

/// `GET /deltas/{tenant}/{doc}` must pick the same dialect Undertow's
/// `IsRouterliciousDeltaFetch` does: bare array for Routerlicious (Basic
/// auth, or `fetchReason` present, or both), Levee's `{"value": [...]}`
/// envelope otherwise. See `is_routerlicious_delta_fetch`'s doc comment for
/// the full rationale.
pub fn is_routerlicious_delta_fetch_matches_undertow_dialect_test() {
  // Levee: bearer auth, no fetchReason -> not Routerlicious (gets the envelope).
  floodgate.is_routerlicious_delta_fetch(Some("Bearer test-token"), [])
  |> should.be_false

  // Historical Routerlicious: Basic auth, no fetchReason -> bare array.
  floodgate.is_routerlicious_delta_fetch(Some("Basic dXNlcjpqd3Q="), [])
  |> should.be_true

  // Modern Routerlicious: Basic auth + fetchReason -> bare array.
  floodgate.is_routerlicious_delta_fetch(Some("Basic dXNlcjpqd3Q="), [
    #("fetchReason", "PostDocumentOpen_fetch"),
  ])
  |> should.be_true

  // fetchReason alone, even over bearer auth, is still a Routerlicious
  // marker -> bare array.
  floodgate.is_routerlicious_delta_fetch(Some("Bearer test-token"), [
    #("fetchReason", "PostDocumentOpen_fetch"),
  ])
  |> should.be_true

  // No Authorization header at all (should not happen post-`authorize_read`,
  // but the helper must not crash) -> defaults to the Levee envelope.
  floodgate.is_routerlicious_delta_fetch(None, [])
  |> should.be_false

  // The scheme check is case-insensitive, matching how ASP.NET Core /
  // Routerlicious drivers may format the header.
  floodgate.is_routerlicious_delta_fetch(Some("BASIC dXNlcjpqd3Q="), [])
  |> should.be_true
}

// ─────────────────────────────────────────────────────────────────────────────
// Tenant admin API — response shapes must match the Lustre UI's decoders in
// admin/src/floodgate_admin/api.gleam exactly.
// ─────────────────────────────────────────────────────────────────────────────

/// `{id, name}` — `api.gleam`'s `tenant_decoder`. No secrets, ever.
pub fn tenant_info_to_json_matches_admin_ui_decoder_shape_test() {
  floodgate.tenant_info_to_json(store.TenantInfo(id: "t-1", name: "Acme"))
  |> json.to_string
  |> should.equal("{\"id\":\"t-1\",\"name\":\"Acme\"}")
}

/// `{id, name, secret1, secret2}` — `api.gleam`'s
/// `tenant_with_secrets_decoder`, used by both create and show.
pub fn tenant_with_secrets_to_json_matches_admin_ui_decoder_shape_test() {
  floodgate.tenant_with_secrets_to_json(store.TenantWithSecrets(
    id: "t-1",
    name: "Acme",
    secret1: "s1",
    secret2: "s2",
  ))
  |> json.to_string
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

pub fn standalone_storage_backend_selection_test() {
  let assert Ok(_) = floodgate.backend_from_name("ets")
  let assert Ok(_) = floodgate.backend_from_name("shelf")
  let assert Ok(_) = floodgate.backend_from_name("memory")
  floodgate.backend_from_name("postgres")
  |> should.equal(Error(floodgate.UnsupportedStorageBackend("postgres")))
}

pub fn session_sequences_per_document_test() {
  let document_session = session.start()
  session.join(document_session, "document:t:seqbasic", "c1") |> should.be_false
  session.join(document_session, "document:t:seqbasic", "c2") |> should.be_true
  let assert session.Assigned(1, _) =
    session.submit(document_session, "document:t:seqbasic", "c1", 1, 0, "a")
  let assert session.Assigned(2, _) =
    session.submit(document_session, "document:t:seqbasic", "c1", 2, 0, "b")
}

pub fn session_create_marks_document_existing_without_audience_client_test() {
  let document_session = session.start()
  session.create(document_session, "document:t:created") |> should.be_false
  session.clients(document_session, "document:t:created") |> should.equal([])
  session.join(document_session, "document:t:created", "c1") |> should.be_true
  session.clients(document_session, "document:t:created")
  |> should.equal(["c1"])
}

pub fn supervised_session_restarts_and_rehydrates_test() {
  let topic = "document:fluid:supervised-restart"
  // The backend outlives the session actor, which is what makes a restart
  // recoverable: `docs` is in-memory only and rebuilt from persisted ops.
  let backend = memory_store.new()
  let assert Ok(#(_channels, document_session)) =
    floodgate.start_with_backend("fluid", "test-jwt-secret", backend)

  session.create(document_session, topic) |> should.be_false
  let session.Joined(_, _, _, _) =
    session.join_sequenced(document_session, topic, "c1", "{}", 1000)
  let before = session.sequence_number(document_session, topic)
  before |> should.not_equal(0)

  // Kill it the way a real crash would, and confirm the supervisor brings it
  // back under the same registered name.
  let assert Ok(pid) = session.owner(document_session)
  process.kill(pid)
  let assert Ok(restarted_pid) = await_restart(document_session, pid, 100)
  { restarted_pid == pid } |> should.be_false

  // The handle still resolves — it holds the name, not the dead Subject — and
  // the sequence state comes back from storage rather than restarting at 0.
  session.exists(document_session, topic) |> should.be_true
  session.sequence_number(document_session, topic) |> should.equal(before)
}

pub fn document_crash_closes_unmatched_durable_joins_test() {
  let topic = "document:fluid:membership-recovery"
  let backend = memory_store.new()
  let document_session = session.start_with_backend(backend)
  let assert session.Joined(_, 1, _, join_c1) =
    session.join_sequenced(
      document_session,
      topic,
      "c1",
      "{\"clientId\":\"c1\"}",
      1000,
    )
  let assert session.Joined(_, 2, _, join_c2) =
    session.join_sequenced(
      document_session,
      topic,
      "c2",
      "{\"clientId\":\"c2\"}",
      2000,
    )

  let assert Ok(pid) = session.document_owner(document_session, topic)
  process.kill(pid)

  let assert session.Connected(
    True,
    [],
    initial_ops,
    "",
    0,
    5,
    recovery,
    session.Writer(join_c3_sn, join_c3_message),
  ) =
    session.connect(
      document_session,
      topic,
      "c3",
      session.Write,
      "{\"mode\":\"write\"}",
      "{\"clientId\":\"c3\"}",
      3000,
    )
  let join_c3 = #(join_c3_sn, join_c3_message)

  recovery |> list.map(fn(op) { op.0 }) |> should.equal([3, 4])
  let assert [#(_, leave_c1), #(_, leave_c2)] = recovery
  leave_c1 |> string.contains("\"type\":\"leave\"") |> should.be_true
  leave_c1 |> string.contains("\\\"c1\\\"") |> should.be_true
  leave_c2 |> string.contains("\\\"c2\\\"") |> should.be_true
  initial_ops
  |> should.equal([
    #(1, join_c1),
    #(2, join_c2),
    ..list.append(recovery, [join_c3])
  ])
  session.clients(document_session, topic) |> should.equal(["c3"])
  session.since(document_session, topic, 0) |> should.equal(initial_ops)

  let assert Ok(restarted_pid) = session.document_owner(document_session, topic)
  process.kill(restarted_pid)
  let assert session.Connected(
    _,
    _,
    _,
    _,
    _,
    7,
    second_recovery,
    session.Writer(_, _),
  ) =
    session.connect(
      document_session,
      topic,
      "c4",
      session.Write,
      "{\"mode\":\"write\"}",
      "{\"clientId\":\"c4\"}",
      4000,
    )
  list.length(second_recovery) |> should.equal(1)
  let assert [#(6, leave_c3)] = second_recovery
  leave_c3 |> string.contains("\\\"c3\\\"") |> should.be_true
}

pub fn read_connect_repairs_unmatched_durable_joins_test() {
  let topic = "document:fluid:read-membership-recovery"
  let document_session = session.start()
  let assert session.Joined(_, 1, _, join_writer) =
    session.join_sequenced(
      document_session,
      topic,
      "writer",
      "{\"clientId\":\"writer\"}",
      1000,
    )
  let assert Ok(pid) = session.document_owner(document_session, topic)
  process.kill(pid)

  let assert session.Connected(
    True,
    [],
    initial_ops,
    "",
    0,
    2,
    [#(2, leave_writer)],
    session.Reader,
  ) =
    session.connect(
      document_session,
      topic,
      "reader",
      session.Read,
      "{\"mode\":\"read\"}",
      "{}",
      2000,
    )
  leave_writer |> string.contains("\\\"writer\\\"") |> should.be_true
  initial_ops |> should.equal([#(1, join_writer), #(2, leave_writer)])
  session.clients(document_session, topic) |> should.equal(["reader"])
}

pub fn missing_summary_ref_is_restored_only_under_document_ownership_test() {
  let backend = memory_store.new()
  let tenant = "ref-repair"
  let doc = "doc"
  let topic = "document:" <> tenant <> ":" <> doc

  // The state a crash between `put_summary` and the ref write leaves behind.
  let tree = summary_fixture.tree(backend, topic, "repair")
  let sha = summary_fixture.commit(backend, topic, tree, [], "repair")
  let assert Ok(Nil) = store.put_summary(backend, topic, sha, 5)
  git.get_ref(backend, tenant, git.summary_ref(doc)) |> should.equal(Error(Nil))

  let document_session = session.start_with_backend(backend)
  session.sequence_number(document_session, topic) |> should.equal(5)
  git.get_ref(backend, tenant, git.summary_ref(doc)) |> should.equal(Error(Nil))
  session.join(document_session, topic, "reader") |> should.be_true
  git.get_ref(backend, tenant, git.summary_ref(doc))
  |> should.equal(Ok(sha))
}

/// A ref that merely lags is safe — a client discovering an older snapshot just
/// replays more ops — and clients may move refs through the Historian API, so the
/// repair must only fill in a missing ref, never overwrite one.
pub fn storage_only_rehydrate_does_not_write_an_existing_ref_test() {
  let backend = memory_store.new()
  let tenant = "ref-keep"
  let doc = "doc"
  let topic = "document:" <> tenant <> ":" <> doc

  let assert Ok(Nil) =
    git.put_ref(backend, tenant, git.summary_ref(doc), "client-chosen-sha")
  let tree = summary_fixture.tree(backend, topic, "read-only")
  let sha = summary_fixture.commit(backend, topic, tree, [], "read-only")
  let assert Ok(Nil) = store.put_summary(backend, topic, sha, 5)

  let document_session = session.start_with_backend(backend)
  session.sequence_number(document_session, topic) |> should.equal(5)
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
  let document_session = session.start()
  session.join(document_session, topic, "c1") |> should.be_false

  submit_ops(document_session, topic, 1, 1005)

  let session.Connected(_, _, initial_ops, _, _, _, _, _) =
    session.connect(document_session, topic, "c2", session.Read, "{}", "{}", 0)

  list.length(initial_ops) |> should.equal(1000)
  // The newest 1000 of 1005, oldest first: sequence numbers 6 through 1005.
  let assert [oldest, ..] = initial_ops
  oldest.0 |> should.equal(6)
  let assert Ok(newest) = list.last(initial_ops)
  newest.0 |> should.equal(1005)
}

fn submit_ops(
  document_session: session.Session,
  topic: String,
  csn: Int,
  through: Int,
) -> Nil {
  case csn > through {
    True -> Nil
    False -> {
      let assert session.Assigned(_, _) =
        session.submit(
          document_session,
          topic,
          "c1",
          csn,
          0,
          "op-" <> int.to_string(csn),
        )
      submit_ops(document_session, topic, csn + 1, through)
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
  let document_session = session.start_with_backend(backend)
  setenv("FLOODGATE_DOC_IDLE_MS", "")

  let session.Joined(_, _, _, _) =
    session.join_sequenced(document_session, topic, "c1", "{}", 1000)
  let before = session.sequence_number(document_session, topic)
  session.cached_documents(document_session) |> should.equal(1)

  // A document with a connected client is never evicted, however idle.
  process.sleep(250)
  session.cached_documents(document_session) |> should.equal(1)

  let session.Left(_, _, _) =
    session.leave_sequenced(document_session, topic, "c1", 2000)
  process.sleep(250)
  session.cached_documents(document_session) |> should.equal(0)

  // Evicting it lost nothing: the numbering comes back from persisted ops.
  session.sequence_number(document_session, topic) |> should.equal(before + 1)
}

@external(erlang, "floodgate_ffi", "setenv")
fn setenv(name: String, value: String) -> Nil

/// Poll until the session's name resolves to a pid other than `dead`.
fn await_restart(
  document_session: session.Session,
  dead: process.Pid,
  attempts: Int,
) -> Result(process.Pid, Nil) {
  case attempts <= 0 {
    True -> Error(Nil)
    False ->
      case session.owner(document_session) {
        Ok(pid) if pid != dead -> Ok(pid)
        _ -> {
          process.sleep(10)
          await_restart(document_session, dead, attempts - 1)
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
  let document_session = session.start_with_backend(backend)
  let tree = summary_fixture.tree(backend, topic, "checkpoint")
  let sha = summary_fixture.commit(backend, topic, tree, [], "checkpoint")

  session.create_initialized(document_session, topic, fn() {
    Ok(Some(#(sha, 7)))
  })
  |> should.equal(session.Created)
  session.summary(document_session, topic)
  |> should.equal(Ok(#(sha, 7)))
  session.sequence_number(document_session, topic) |> should.equal(7)

  let restarted = session.start_with_backend(backend)
  session.summary(restarted, topic) |> should.equal(Ok(#(sha, 7)))
  session.sequence_number(restarted, topic) |> should.equal(7)
  let assert session.Joined(True, 8, 7, _) =
    session.join_sequenced(restarted, topic, "c1", "{}", 1000)
}

pub fn duplicate_initialized_document_preserves_existing_state_test() {
  let topic = "document:t:duplicate-initialized"
  let document_session = session.start()

  session.create_initialized(document_session, topic, fn() {
    Ok(Some(#("original-summary", 4)))
  })
  |> should.equal(session.Created)
  session.create_initialized(document_session, topic, fn() { Error(Nil) })
  |> should.equal(session.AlreadyExists)

  session.summary(document_session, topic)
  |> should.equal(Ok(#("original-summary", 4)))
  session.sequence_number(document_session, topic) |> should.equal(4)
}

pub fn session_rejects_future_reference_sequence_number_test() {
  let document_session = session.start()
  session.join(document_session, "document:t:reject-future", "c1")
  session.submit(document_session, "document:t:reject-future", "c1", 1, 10, "a")
  |> should.equal(session.Rejected(0))
}

pub fn session_leave_removes_client_test() {
  let document_session = session.start()
  session.join(document_session, "document:t:leave", "c1")
  session.clients(document_session, "document:t:leave") |> should.equal(["c1"])
  session.leave(document_session, "document:t:leave", "c1")
  session.clients(document_session, "document:t:leave") |> should.equal([])
}

pub fn read_presence_does_not_pin_write_minimum_sequence_number_test() {
  let topic = "document:t:read-presence"
  let document_session = session.start()
  let assert session.Joined(False, 1, 0, _) =
    session.join_sequenced(document_session, topic, "writer", "{}", 1000)
  session.join_presence(document_session, topic, "reader", session.Read)
  |> should.be_true
  let roster =
    session.roster(document_session, topic)
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  let assert [#("reader", reader), #("writer", writer)] = roster
  reader |> string.contains("\"mode\":\"read\"") |> should.be_true
  writer |> string.contains("\"mode\":\"write\"") |> should.be_true

  let assert session.MessageAssigned(2, 1, _) =
    session.submit_message(document_session, topic, "writer", 1, 1, fn(_, _) {
      "first"
    })
  let assert session.MessageAssigned(3, 2, _) =
    session.submit_message(document_session, topic, "writer", 2, 2, fn(_, _) {
      "second"
    })
}

/// The write join is part of the atomic connect snapshot and is durably ordered
/// before the client can submit its first application operation.
pub fn connect_returns_an_atomic_document_snapshot_test() {
  let topic = "document:t:connect-snapshot"
  let document_session = session.start()
  session.create_initialized(document_session, topic, fn() {
    Ok(Some(#("summary-4", 4)))
  })

  let assert session.Connected(
    True,
    [],
    [#(5, join_message)],
    "summary-4",
    4,
    5,
    [],
    session.Writer(5, membership_message),
  ) =
    session.connect(
      document_session,
      topic,
      "writer",
      session.Write,
      "{\"mode\":\"write\"}",
      "{}",
      1000,
    )
  membership_message |> should.equal(join_message)

  let assert session.MessageAssigned(6, 5, "app-op") =
    session.submit_message(document_session, topic, "writer", 1, 5, fn(_, _) {
      "app-op"
    })
  let assert session.Connected(
    True,
    [#("writer", "{\"mode\":\"write\"}")],
    initial_ops,
    "summary-4",
    4,
    6,
    [],
    session.Reader,
  ) =
    session.connect(
      document_session,
      topic,
      "reader",
      session.Read,
      "{\"mode\":\"read\"}",
      "{}",
      2000,
    )
  initial_ops |> should.equal([#(5, join_message), #(6, "app-op")])
}

pub fn sequenced_join_and_leave_are_persisted_as_protocol_ops_test() {
  let topic = "document:t:protocol-membership"
  let document_session = session.start()
  let join_data = "{\"clientId\":\"c1\",\"detail\":{\"mode\":\"write\"}}"
  let assert session.Joined(False, 1, 0, join_message) =
    session.join_sequenced(document_session, topic, "c1", join_data, 1000)
  join_message |> string.contains("\"type\":\"join\"") |> should.be_true

  let assert session.Left(2, 0, leave_message) =
    session.leave_sequenced(document_session, topic, "c1", 2000)
  leave_message |> string.contains("\"type\":\"leave\"") |> should.be_true
  session.since(document_session, topic, 0)
  |> should.equal([#(1, join_message), #(2, leave_message)])
}

pub fn reconnect_starts_from_current_sequence_checkpoint_test() {
  let topic = "document:t:reconnect-checkpoint"
  let document_session = session.start()
  session.join(document_session, topic, "c1")
  let assert session.Assigned(1, _) =
    session.submit(document_session, topic, "c1", 1, 0, "before-disconnect")
  session.leave(document_session, topic, "c1")
  session.clients(document_session, topic) |> should.equal([])

  session.join(document_session, topic, "c2")
  let assert session.Assigned(2, 1) =
    session.submit(document_session, topic, "c2", 1, 0, "after-reconnect")
}

pub fn since_returns_history_after_sn_test() {
  let document_session = session.start()
  session.join(document_session, "document:t:since", "c1")
  let assert session.Assigned(1, _) =
    session.submit(document_session, "document:t:since", "c1", 1, 0, "a")
  let assert session.Assigned(2, _) =
    session.submit(document_session, "document:t:since", "c1", 2, 0, "b")
  session.since(document_session, "document:t:since", 1)
  |> should.equal([#(2, "b")])
}

pub fn submit_message_persists_the_built_message_test() {
  let topic = "document:t:atomic-message"
  let document_session = session.start()
  session.join(document_session, topic, "c1")

  let assert session.MessageAssigned(1, 0, message) =
    session.submit_message(document_session, topic, "c1", 1, 0, fn(sn, msn) {
      "message-" <> int.to_string(sn) <> "-" <> int.to_string(msn)
    })
  message |> should.equal("message-1-0")
  session.since(document_session, topic, 0) |> should.equal([#(1, message)])
}

pub fn summary_stores_latest_handle_test() {
  let document_session = session.start()
  session.set_summary(document_session, "document:t:d2", "sha-abc", 5)
  session.summary(document_session, "document:t:d2")
  |> should.equal(Ok(#("sha-abc", 5)))
}

pub fn sequenced_summary_advances_past_response_and_stores_context_test() {
  let topic = "document:t:sequenced-summary"
  let document_session = session.start()
  session.join(document_session, topic, "c1")
  let assert session.SummaryAssigned(1, 2, _) =
    session.submit_summary(
      document_session,
      topic,
      "c1",
      1,
      0,
      "summary",
      "ack",
      Some("summary-handle"),
    )
  session.summary(document_session, topic)
  |> should.equal(Ok(#("summary-handle", 1)))
  session.sequence_number(document_session, topic) |> should.equal(2)
  let assert session.Assigned(3, _) =
    session.submit(document_session, topic, "c1", 2, 2, "after-summary")
}

pub fn summary_nack_does_not_replace_latest_summary_test() {
  let topic = "document:t:nacked-summary"
  let document_session = session.start()
  session.join(document_session, topic, "c1")
  session.set_summary(document_session, topic, "existing-handle", 0)
  let assert session.SummaryAssigned(1, 2, _) =
    session.submit_summary(
      document_session,
      topic,
      "c1",
      1,
      0,
      "invalid-summary",
      "nack",
      None,
    )
  session.summary(document_session, topic)
  |> should.equal(Ok(#("existing-handle", 0)))
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
  // Historian objects are tenant-scoped, so drivers can safely reuse a
  // content-addressed object hash across documents.
  git.fetch(storage, store.topic("t", "other"), sha)
  |> should.equal(Ok(body))
  git.fetch(storage, store.topic("other-tenant", "doc"), sha)
  |> should.equal(Error(Nil))
}

pub fn git_ref_roundtrip_test() {
  let storage = memory_store.new()
  store.open(storage)
  git.create_ref(storage, "t", "heads/main", "commit-sha")
  |> should.equal(Ok(True))
  git.create_ref(storage, "t", "heads/main", "replacement")
  |> should.equal(Ok(False))
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
  let document_session = session.start_with_backend(backend)

  process.spawn_unlinked(fn() {
    session.create_initialized(document_session, "document:t:slow", fn() {
      process.sleep(600)
      Ok(Some(#("slow-summary", 1)))
    })
  })
  // Let the slow build take its actor's mailbox before racing it.
  process.sleep(50)

  // The slow build is genuinely mid-flight: its actor is up and holding its own
  // mailbox. Without this the timing assertion below would also pass if the
  // spawn had failed and nothing slow were running at all.
  let assert Ok(_) = session.document_owner(document_session, "document:t:slow")

  let started = now_ms()
  let session.Joined(_, _, _, _) =
    session.join_sequenced(
      document_session,
      "document:t:fast",
      "c1",
      "{}",
      1000,
    )
  let elapsed = now_ms() - started

  // Generous enough not to be flaky, tight enough to fail outright if the two
  // documents still share a mailbox — that would put this at ~550 ms.
  { elapsed < 300 } |> should.be_true

  // And the slow build really did take its 600 ms and then commit, so the join
  // above overlapped it rather than following it.
  process.sleep(700)
  session.summary(document_session, "document:t:slow")
  |> should.equal(Ok(#("slow-summary", 1)))
}

/// A crash now costs one document's roster instead of every document's. Under
/// the old single actor, killing the sequencer discarded `client_states` for
/// everything on the node at once.
pub fn document_crash_does_not_disturb_other_documents_test() {
  let backend = memory_store.new()
  let document_session = session.start_with_backend(backend)
  let victim = "document:t:crash-victim"
  let bystander = "document:t:crash-bystander"

  let session.Joined(_, _, _, _) =
    session.join_sequenced(document_session, victim, "c1", "{}", 1000)
  let session.Joined(_, _, _, _) =
    session.join_sequenced(document_session, bystander, "c2", "{}", 1000)
  let victim_sn = session.sequence_number(document_session, victim)

  let assert Ok(pid) = session.document_owner(document_session, victim)
  process.kill(pid)
  process.sleep(50)

  // The bystander kept its in-memory roster — it was never touched.
  session.clients(document_session, bystander) |> should.equal(["c2"])

  // The victim rehydrates from storage on next touch: numbering survives, the
  // roster does not. That is the documented restart contract, now scoped to one
  // document rather than all of them.
  session.sequence_number(document_session, victim) |> should.equal(victim_sn)
  session.clients(document_session, victim) |> should.equal([])
}

/// The failure mode the ETS registry introduces: a row can outlive its actor for
/// a moment, so a caller can resolve a subject that is already dead. `call_doc`
/// has to turn that into a retry rather than a panic that takes the caller — a
/// channel process, in production — down with it.
pub fn call_against_a_dead_document_actor_recovers_test() {
  let backend = memory_store.new()
  let document_session = session.start_with_backend(backend)
  let topic = "document:t:stale-row"

  let session.Joined(_, _, _, _) =
    session.join_sequenced(document_session, topic, "c1", "{}", 1000)
  let before = session.sequence_number(document_session, topic)

  // Kill it and call straight away, without giving the owner's monitor time to
  // clear the row — so the call really does resolve a dead subject.
  let assert Ok(pid) = session.document_owner(document_session, topic)
  process.kill(pid)

  let session.Joined(_, _, _, _) =
    session.join_sequenced(document_session, topic, "c2", "{}", 2000)
  session.sequence_number(document_session, topic) |> should.equal(before + 1)
}

/// Reading must not be able to allocate. `session.exists` is reachable from REST
/// paths that do not require the document to exist, so routing it through
/// get-or-start would let any `GET` for an unknown id spawn an actor.
pub fn reading_an_unknown_document_starts_no_actor_test() {
  let backend = memory_store.new()
  let document_session = session.start_with_backend(backend)

  session.exists(document_session, "document:t:never-created")
  |> should.be_false
  session.clients(document_session, "document:t:never-created")
  |> should.equal([])
  session.roster(document_session, "document:t:never-created")
  |> should.equal([])
  session.sequence_number(document_session, "document:t:never-created")
  |> should.equal(0)
  session.since(document_session, "document:t:never-created", 0)
  |> should.equal([])
  session.summary(document_session, "document:t:never-created")
  |> should.equal(Error(Nil))

  session.cached_documents(document_session) |> should.equal(0)
}

/// The registry's ETS table belongs to the owner, so it dies with it. That is
/// what the `RestForOne` pairing is for: restarting the factory after the owner
/// takes every now-unreachable document actor down, rather than leaving them
/// holding state nothing can find. The ordering is positional and easy to break
/// silently, so pin it.
pub fn owner_restart_takes_document_actors_with_it_test() {
  let backend = memory_store.new()
  let document_session = session.start_with_backend(backend)
  let topic = "document:t:owner-restart"

  let session.Joined(_, _, _, _) =
    session.join_sequenced(document_session, topic, "c1", "{}", 1000)
  let before = session.sequence_number(document_session, topic)
  let assert Ok(doc_pid) = session.document_owner(document_session, topic)

  let assert Ok(owner_pid) = session.owner(document_session)
  process.kill(owner_pid)
  let assert Ok(_) = await_restart(document_session, owner_pid, 100)

  // No orphan: the document actor went down with the table that pointed at it.
  process.is_alive(doc_pid) |> should.be_false
  session.cached_documents(document_session) |> should.equal(0)

  // And the document still works, rebuilt from storage.
  session.sequence_number(document_session, topic) |> should.equal(before)
  let session.Joined(_, _, _, _) =
    session.join_sequenced(document_session, topic, "c2", "{}", 2000)
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
  let document_session = session.start_with_backend(backend)
  let topic = "document:t:durable-ack"
  session.join(document_session, topic, "c1") |> should.be_false

  let assert session.Assigned(sn, _) =
    session.submit(document_session, topic, "c1", 1, 0, "DURABLE")
  store.get_ops(backend, topic)
  |> list.key_find(sn)
  |> should.equal(Ok("DURABLE"))
}

pub fn submit_summary_is_durable_before_it_acks_test() {
  let backend = memory_store.new()
  let document_session = session.start_with_backend(backend)
  let topic = "document:t:durable-summary-ack"
  session.join(document_session, topic, "c1") |> should.be_false

  let assert session.SummaryAssigned(summary_sn, response_sn, _) =
    session.submit_summary(
      document_session,
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
  store.get_summary(backend, topic)
  |> should.equal(Ok(#("handle-1", summary_sn)))
}

pub fn summary_publication_writes_ref_before_reply_test() {
  let backend = memory_store.new()
  let events = process.new_subject()
  let recording =
    store.Backend(
      ..backend,
      put_op: fn(topic, sn, body) {
        let result = backend.put_op(topic, sn, body)
        process.send(events, case sn {
          1 -> "proposal"
          _ -> "response"
        })
        result
      },
      put_summary: fn(topic, sha, sn) {
        let result = backend.put_summary(topic, sha, sn)
        process.send(events, "pointer")
        result
      },
      put_ref: fn(tenant, ref, sha) {
        let result = backend.put_ref(tenant, ref, sha)
        process.send(events, "ref")
        result
      },
    )
  let document_session = session.start_with_backend(recording)
  let topic = store.topic("publish-order", "doc")
  session.join(document_session, topic, "writer") |> should.be_false
  let assert session.SummaryMessagesAssigned(1, 2, _, _, _) =
    session.submit_summary_messages(
      document_session,
      topic,
      "writer",
      1,
      0,
      fn(sn, _, _, _, current) {
        let tree = summary_fixture.tree(recording, topic, "snapshot")
        let commit =
          summary_fixture.commit(recording, topic, tree, [], "summary")
        process.send(events, "objects")
        #(
          summary_fixture.proposal(sn, 0, tree, current.0),
          summary_fixture.ack(sn, commit),
          Some(commit),
        )
      },
    )
  process.send(events, "reply")
  collect_write_events(events)
  |> should.equal(["objects", "proposal", "response", "pointer", "ref", "reply"])
  let assert Ok(#(sha, 1)) = session.summary(document_session, topic)
  git.get_ref(backend, "publish-order", "heads/doc") |> should.equal(Ok(sha))
}

fn collect_write_events(events: process.Subject(String)) -> List(String) {
  let assert Ok(event) = process.receive(events, 1000)
  case event {
    "reply" -> ["reply"]
    _ -> [event, ..collect_write_events(events)]
  }
}

pub fn initialized_summary_is_published_before_created_test() {
  let backend = memory_store.new()
  let document_session = session.start_with_backend(backend)
  let topic = store.topic("initial-publish", "doc:branch")
  let assert session.Created =
    session.create_initialized(document_session, topic, fn() {
      let tree = summary_fixture.tree(backend, topic, "initial")
      let sha = summary_fixture.commit(backend, topic, tree, [], "initial")
      Ok(Some(#(sha, 10)))
    })
  let assert Ok(#(sha, 10)) = session.summary(document_session, topic)
  git.get_ref(backend, "initial-publish", "heads/doc:branch")
  |> should.equal(Ok(sha))
  let assert Ok(Nil) =
    store.delete_ref(backend, "initial-publish", "refs/heads/doc:branch")
  session.published_summary(document_session, topic)
  |> should.equal(Ok(Some(#(sha, 10))))
  git.get_ref(backend, "initial-publish", "heads/doc:branch")
  |> should.equal(Ok(sha))
}

pub fn timed_out_call_does_not_replace_a_live_publisher_test() {
  let backend = memory_store.new()
  let entered = process.new_subject()
  let finished = process.new_subject()
  let blocked =
    store.Backend(..backend, put_ref: fn(tenant, ref, sha) {
      let release = process.new_subject()
      process.send(entered, release)
      let assert Ok(Nil) = process.receive(release, 5000)
      backend.put_ref(tenant, ref, sha)
    })
  let document_session = session.start_with_backend(blocked)
  let topic = store.topic("blocked-publication", "doc")
  session.join(document_session, topic, "writer") |> should.be_false
  let assert Ok(owner) = session.document_owner(document_session, topic)
  let _ =
    process.spawn_unlinked(fn() {
      let result =
        exception.rescue(fn() {
          session.submit_summary_messages(
            document_session,
            topic,
            "writer",
            1,
            0,
            fn(sn, _, _, _, current) {
              let tree = summary_fixture.tree(backend, topic, "blocked")
              let sha =
                summary_fixture.commit(backend, topic, tree, [], "blocked")
              #(
                summary_fixture.proposal(sn, 0, tree, current.0),
                summary_fixture.ack(sn, sha),
                Some(sha),
              )
            },
          )
        })
      process.send(finished, result)
    })
  let assert Ok(release) = process.receive(entered, 1000)
  let independent = store.topic("blocked-publication", "independent")
  session.join(document_session, independent, "other") |> should.be_false
  let assert session.Assigned(1, _) =
    session.submit(document_session, independent, "other", 1, 0, "unblocked")
  // This call times out while the publisher is blocked, not after it died.
  let result =
    exception.rescue(fn() { session.join(document_session, topic, "late") })
  process.send(release, Nil)
  let assert Error(_) = result
  session.document_owner(document_session, topic) |> should.equal(Ok(owner))
  let assert Ok(_) = process.receive(finished, 2000)
  store.get_ops(backend, topic) |> list.length |> should.equal(2)
}

pub fn summary_recovery_uses_complete_durable_ack_evidence_test() {
  assert_summary_recovery(memory_store.new())
}

pub fn assert_summary_recovery(backend: store.Backend) -> Nil {
  list.each(["objects", "proposal", "nack"], fn(kind) {
    let topic = store.topic("unpublished-prefix", kind)
    let tree = summary_fixture.tree(backend, topic, kind)
    let sha = summary_fixture.commit(backend, topic, tree, [], kind)
    case kind {
      "objects" -> Nil
      _ -> {
        let assert Ok(Nil) =
          store.put_op(
            backend,
            topic,
            1,
            summary_fixture.proposal(1, 0, tree, ""),
          )
        Nil
      }
    }
    case kind {
      "nack" -> {
        let assert Ok(Nil) =
          store.put_op(
            backend,
            topic,
            2,
            string.replace(
              summary_fixture.ack(1, sha),
              "summaryAck",
              "summaryNack",
            ),
          )
        Nil
      }
      _ -> Nil
    }
    let document_session = session.start_with_backend(backend)
    let _ = session.join(document_session, topic, "reader")
    session.summary(document_session, topic) |> should.equal(Error(Nil))
  })
  list.each(
    [
      "objects", "proposal", "nack", "ack", "older-pointer", "newer-pointer",
      "initial", "malformed", "client-authored", "unmatched", "missing-commit",
      "wrong-sequence", "old-ack", "string-contents",
    ],
    fn(kind) {
      let topic = store.topic("recover-matrix", kind)
      let tree = summary_fixture.tree(backend, topic, kind)
      let root = summary_fixture.commit(backend, topic, tree, [], "root")
      let proposed =
        summary_fixture.commit(backend, topic, tree, [root], "child")
      let latest =
        summary_fixture.commit(backend, topic, tree, [proposed], "latest")
      let assert Ok(Nil) = store.put_summary(backend, topic, root, 2)
      case kind {
        "objects" | "initial" -> Nil
        _ -> {
          let proposal = summary_fixture.proposal(5, 3, tree, root)
          let proposal = case kind {
            "string-contents" -> summary_fixture.stringify_contents(proposal)
            _ -> proposal
          }
          let assert Ok(Nil) = store.put_op(backend, topic, 5, proposal)
          Nil
        }
      }
      let ack = summary_fixture.ack(5, proposed)
      case kind {
        "objects" | "proposal" | "initial" -> Nil
        _ -> {
          let response = case kind {
            "nack" -> string.replace(ack, "summaryAck", "summaryNack")
            "malformed" -> "{\"type\":\"summaryAck\"}"
            "client-authored" ->
              string.replace(
                ack,
                "\"clientId\":null",
                "\"clientId\":\"client\"",
              )
            "unmatched" -> summary_fixture.ack(4, proposed)
            "missing-commit" -> summary_fixture.ack(5, "missing")
            "wrong-sequence" ->
              string.replace(
                ack,
                "\"sequenceNumber\":6",
                "\"sequenceNumber\":7",
              )
            "string-contents" -> summary_fixture.stringify_contents(ack)
            _ -> ack
          }
          let assert Ok(Nil) = store.put_op(backend, topic, 6, response)
          Nil
        }
      }
      case kind {
        "newer-pointer" -> {
          let assert Ok(Nil) = store.put_summary(backend, topic, latest, 10)
          Nil
        }
        "old-ack" -> {
          let _ =
            list.index_map(list.repeat(Nil, 1004), fn(_, index) {
              let assert Ok(Nil) = store.put_op(backend, topic, index + 7, "{}")
              Nil
            })
          Nil
        }
        _ -> Nil
      }
      let expected = case kind {
        "ack" | "older-pointer" | "old-ack" | "string-contents" -> #(
          proposed,
          5,
        )
        "newer-pointer" -> #(latest, 10)
        _ -> #(root, 2)
      }
      let before = store.get_ops(backend, topic)
      let document_session = session.start_with_backend(backend)
      session.join(document_session, topic, "reader") |> should.be_true
      session.summary(document_session, topic) |> should.equal(Ok(expected))
      store.get_ops(backend, topic) |> should.equal(before)
      let again = session.start_with_backend(backend)
      session.join(again, topic, "reader") |> should.be_true
      session.summary(again, topic) |> should.equal(Ok(expected))
      store.get_ops(backend, topic) |> should.equal(before)
    },
  )
}

pub fn acknowledged_summary_without_pointer_recovers_without_writing_during_reads_test() {
  let backend = memory_store.new()
  let topic = store.topic("recover-no-pointer", "doc")
  let tree = summary_fixture.tree(backend, topic, "first")
  let sha = summary_fixture.commit(backend, topic, tree, [], "first")
  let assert Ok(Nil) =
    store.put_op(backend, topic, 5, summary_fixture.proposal(5, 0, tree, ""))
  let assert Ok(Nil) =
    store.put_op(backend, topic, 6, summary_fixture.ack(5, sha))
  doc_state.rehydrate(backend, topic).summary |> should.equal(#(sha, 5))
  store.get_summary(backend, topic) |> should.equal(Error(Nil))
  let document_session = session.start_with_backend(backend)
  session.join(document_session, topic, "reader") |> should.be_true
  session.summary(document_session, topic) |> should.equal(Ok(#(sha, 5)))
  session.sequence_number(document_session, topic) |> should.equal(6)
  store.get_ops(backend, topic) |> list.length |> should.equal(2)
}

pub fn recovery_rejects_damaged_or_conflicting_publication_test() {
  let backend = memory_store.new()
  let topic = store.topic("corrupt-publication", "doc")
  let assert Ok(Nil) = store.put_summary(backend, topic, "missing", 5)
  let assert Error(git.CorruptPublication(_)) =
    doc_state.recover(backend, topic)
  let tree = summary_fixture.tree(backend, topic, "snapshot")
  let stored = summary_fixture.commit(backend, topic, tree, [], "stored")
  let competing = summary_fixture.commit(backend, topic, tree, [], "competing")
  let assert Ok(Nil) = store.put_summary(backend, topic, stored, 5)
  let assert Ok(Nil) =
    store.put_op(backend, topic, 5, summary_fixture.proposal(5, 0, tree, ""))
  let assert Ok(Nil) =
    store.put_op(backend, topic, 6, summary_fixture.ack(5, competing))
  let assert Error(git.CorruptPublication(_)) =
    doc_state.recover(backend, topic)
}

pub fn historian_reads_reconcile_refs_without_creating_documents_test() {
  assert_ref_reconciliation(memory_store.new())
}

pub fn assert_ref_reconciliation(backend: store.Backend) -> Nil {
  let topic = store.topic("ref-read", "doc")
  let tree = summary_fixture.tree(backend, topic, "head")
  let head = summary_fixture.commit(backend, topic, tree, [], "head")
  let assert Ok(Nil) = store.put_summary(backend, topic, head, 5)
  let document_session = session.start_with_backend(backend)
  list.each(["missing", "older", "ahead"], fn(ref) {
    case ref {
      "missing" -> Nil
      _ -> {
        let assert Ok(Nil) = git.put_ref(backend, "ref-read", "heads/doc", ref)
        Nil
      }
    }
    session.published_summary(document_session, topic)
    |> should.equal(Ok(Some(#(head, 5))))
    git.get_ref(backend, "ref-read", "heads/doc") |> should.equal(Ok(head))
  })
  let empty = store.topic("ref-read", "empty")
  let cached = session.cached_documents(document_session)
  session.published_summary(document_session, empty) |> should.equal(Ok(None))
  session.cached_documents(document_session) |> should.equal(cached)
  let assert Ok(Nil) = git.put_ref(backend, "ref-read", "heads/empty", head)
  session.published_summary(document_session, empty) |> should.equal(Ok(None))
  git.get_ref(backend, "ref-read", "heads/empty") |> should.equal(Error(Nil))
  session.exists(document_session, empty) |> should.be_false
  store.list_refs(backend, "ref-read")
  |> should.equal([#("refs/heads/doc", head)])
  store.delete_ref(backend, "ref-read", "refs/heads/empty")
  |> should.equal(Ok(Nil))
  session.write_ref(
    document_session,
    "ref-read",
    "doc",
    "heads/doc",
    head,
    True,
  )
  |> should.equal(session.RefReserved)
  session.write_ref(
    document_session,
    "ref-read",
    "other",
    "refs/heads/doc",
    head,
    False,
  )
  |> should.equal(session.RefReserved)
  session.write_ref(
    document_session,
    "ref-read",
    "doc",
    "heads/generic",
    head,
    True,
  )
  |> should.equal(session.RefWritten)
  let generic = store.topic("ref-read", "generic")
  session.exists(document_session, generic) |> should.be_false
  session.create_initialized(document_session, generic, fn() { Ok(None) })
  |> should.equal(session.Created)
  git.get_ref(backend, "ref-read", "heads/generic")
  |> should.equal(Error(Nil))
  session.write_ref(
    document_session,
    "ref-read",
    "doc",
    "heads/generic",
    head,
    False,
  )
  |> should.equal(session.RefReserved)
}

pub fn failed_ref_repair_surfaces_error_and_retries_test() {
  let backend = memory_store.new()
  let topic = store.topic("ref-failure", "doc")
  let tree = summary_fixture.tree(backend, topic, "head")
  let head = summary_fixture.commit(backend, topic, tree, [], "head")
  let assert Ok(Nil) = store.put_summary(backend, topic, head, 5)
  let failing = store.Backend(..backend, put_ref: fn(_, _, _) { Error(Nil) })
  session.published_summary(session.start_with_backend(failing), topic)
  |> should.equal(Error(git.StorageUnavailable))
  session.published_summary(session.start_with_backend(backend), topic)
  |> should.equal(Ok(Some(#(head, 5))))
  let unreadable =
    store.Backend(
      ..backend,
      get_ref: fn(_, _) { panic as "Ref storage is unavailable" },
      create_ref: fn(_, _, _) { panic as "Ref storage is unavailable" },
    )
  session.published_summary(session.start_with_backend(unreadable), topic)
  |> should.equal(Error(git.StorageUnavailable))
  session.write_ref(
    session.start_with_backend(unreadable),
    "ref-failure",
    "doc",
    "heads/other",
    head,
    True,
  )
  |> should.equal(session.RefUnavailable)
  let stray = store.topic("ref-failure", "stray")
  let assert Ok(Nil) = git.put_ref(backend, "ref-failure", "heads/stray", head)
  let undeletable =
    store.Backend(..backend, delete_ref: fn(_, _) { Error(Nil) })
  session.published_summary(session.start_with_backend(undeletable), stray)
  |> should.equal(Error(git.StorageUnavailable))
  session.published_summary(session.start_with_backend(backend), stray)
  |> should.equal(Ok(None))
  git.get_ref(backend, "ref-failure", "heads/stray")
  |> should.equal(Error(Nil))
}

pub fn published_commit_ownership_and_legacy_adoption_test() {
  assert_commit_ownership(memory_store.new())
}

pub fn publication_failures_preserve_the_durable_prefix_test() {
  assert_publication_failure_prefixes(memory_store.new())
}

pub fn assert_publication_failure_prefixes(backend: store.Backend) -> Nil {
  list.each(["object", "proposal", "response", "pointer", "ref"], fn(stage) {
    let topic = store.topic("failure-prefix", stage)
    let tree = summary_fixture.tree(backend, topic, stage)
    let commits = process.new_subject()
    let failing =
      store.Backend(
        ..backend,
        put_object: fn(namespace, sha, body) {
          case stage {
            "object" -> Error(Nil)
            _ -> backend.put_object(namespace, sha, body)
          }
        },
        put_op: fn(topic, sn, body) {
          case stage, sn {
            "proposal", 1 | "response", 2 -> Error(Nil)
            _, _ -> backend.put_op(topic, sn, body)
          }
        },
        put_summary: fn(topic, sha, sn) {
          case stage {
            "pointer" -> Error(Nil)
            _ -> backend.put_summary(topic, sha, sn)
          }
        },
        put_ref: fn(tenant, ref, sha) {
          case stage {
            "ref" -> Error(Nil)
            _ -> backend.put_ref(tenant, ref, sha)
          }
        },
      )
    let publishing = session.start_with_backend(failing)
    session.join(publishing, topic, "writer") |> should.be_false
    let assert Ok(owner) = session.document_owner(publishing, topic)
    let result =
      exception.rescue(fn() {
        session.submit_summary_messages(
          publishing,
          topic,
          "writer",
          1,
          0,
          fn(sn, _, _, _, current) {
            let sha = summary_fixture.commit(failing, topic, tree, [], stage)
            process.send(commits, sha)
            #(
              summary_fixture.proposal(sn, 0, tree, current.0),
              summary_fixture.ack(sn, sha),
              Some(sha),
            )
          },
        )
      })
    let assert Error(_) = result
    process.is_alive(owner) |> should.be_false
    let commit = case stage {
      "object" -> ""
      _ -> {
        let assert Ok(sha) = process.receive(commits, 1000)
        sha
      }
    }
    let durable = store.get_ops(backend, topic)
    let count = case stage {
      "object" | "proposal" -> 0
      "response" -> 1
      _ -> 2
    }
    list.length(durable) |> should.equal(count)
    let expected = case stage {
      "pointer" | "ref" -> Some(#(commit, 1))
      _ -> None
    }
    // Shelf's one-file cap closes the failed document before recovery.
    let assert Ok(Nil) =
      store.put_document(
        backend,
        store.topic("failure-prefix", "evict-" <> stage),
      )
    let recovered = session.start_with_backend(backend)
    session.published_summary(recovered, topic) |> should.equal(Ok(expected))
    session.published_summary(recovered, topic) |> should.equal(Ok(expected))
    store.get_ops(backend, topic) |> should.equal(durable)
    session.sequence_number(recovered, topic) |> should.equal(count)
    session.join(recovered, topic, "after") |> should.be_true
    let assert session.Assigned(next, _) =
      session.submit(recovered, topic, "after", 1, count, "next")
    next |> should.equal(count + 1)
  })
}

pub fn assert_commit_ownership(backend: store.Backend) -> Nil {
  let tenant = "commit-ownership"
  let a = store.topic(tenant, "a")
  let b = store.topic(tenant, "b")
  let tree = summary_fixture.tree(backend, a, "shared")
  let staged = summary_fixture.commit(backend, a, tree, [], "staged")
  store.get_object(backend, a, staged) |> should.not_equal(Error(Nil))
  store.get_object(backend, b, staged) |> should.equal(Error(Nil))
  git.fetch(backend, b, tree) |> should.not_equal(Error(Nil))
  let staged_session = session.start_with_backend(backend)
  session.published_summary(staged_session, a) |> should.equal(Ok(None))
  session.exists(staged_session, a) |> should.be_false
  session.create_initialized(staged_session, a, fn() { Ok(None) })
  |> should.equal(session.Created)
  let legacy =
    store.Backend(..backend, put_object: fn(_, sha, body) {
      backend.put_object(tenant, sha, body)
    })
  let root = summary_fixture.commit(legacy, a, tree, [], "legacy-root")
  let head = summary_fixture.commit(legacy, a, tree, [root], "legacy-head")
  let orphan = summary_fixture.commit(legacy, a, tree, [], "legacy-orphan")
  let assert Ok(Nil) = store.put_summary(backend, a, head, 5)
  let document_session = session.start_with_backend(backend)
  session.published_summary(document_session, a)
  |> should.equal(Ok(Some(#(head, 5))))
  store.get_object(backend, a, head)
  |> should.equal(store.get_object(backend, tenant, head))
  store.get_object(backend, a, root)
  |> should.equal(store.get_object(backend, tenant, root))
  store.get_object(backend, a, orphan) |> should.equal(Error(Nil))
  session.published_summary(document_session, b) |> should.equal(Ok(None))
  store.get_object(backend, b, head) |> should.equal(Error(Nil))
  summary_fixture.commit(backend, b, tree, [], "staged")
  |> should.equal(staged)
  git.fetch_commit(backend, b, staged)
  |> should.equal(git.fetch_commit(backend, a, staged))
  git.published_history_response(
    backend,
    "http://localhost",
    tenant,
    a,
    head,
    Some(staged),
    10,
  )
  |> should.equal(Ok(None))
  let assert Ok(Some(history)) =
    git.published_history_response(
      backend,
      "http://localhost",
      tenant,
      a,
      head,
      Some(root),
      10,
    )
  list.length(history) |> should.equal(1)
  let damaged =
    store.Backend(..backend, get_object: fn(namespace, sha) {
      case namespace == a && sha == root {
        True -> Error(Nil)
        False -> backend.get_object(namespace, sha)
      }
    })
  let assert Error(git.CorruptPublication(_)) =
    git.published_history_response(
      damaged,
      "http://localhost",
      tenant,
      a,
      head,
      None,
      1,
    )

  let initial = store.topic(tenant, "legacy-initial")
  let assert Ok(Nil) = store.put_summary(backend, initial, root, 0)
  session.published_summary(document_session, initial)
  |> should.equal(Ok(Some(#(root, 0))))
  git.fetch_commit(backend, initial, root)
  |> should.equal(store.get_object(backend, tenant, root))

  let acknowledged = store.topic(tenant, "legacy-ack")
  let proposal = summary_fixture.proposal(5, 0, tree, root)
  let ack = summary_fixture.ack(5, head)
  let assert Ok(Nil) = store.put_op(backend, acknowledged, 5, proposal)
  let assert Ok(Nil) = store.put_op(backend, acknowledged, 6, ack)
  session.published_summary(document_session, acknowledged)
  |> should.equal(Ok(Some(#(head, 5))))
  store.get_ops(backend, acknowledged)
  |> should.equal([#(5, proposal), #(6, ack)])
  git.fetch_commit(backend, acknowledged, root)
  |> should.equal(store.get_object(backend, tenant, root))

  let partial = store.topic(tenant, "legacy-partial")
  let assert Ok(Nil) = store.put_summary(backend, partial, head, 5)
  let failing =
    store.Backend(..backend, put_object: fn(namespace, sha, body) {
      case namespace == partial && sha == root {
        True -> Error(Nil)
        False -> backend.put_object(namespace, sha, body)
      }
    })
  session.published_summary(session.start_with_backend(failing), partial)
  |> should.equal(Error(git.StorageUnavailable))
  git.fetch_commit(backend, partial, head)
  |> should.equal(store.get_object(backend, tenant, head))
  git.fetch_commit(backend, partial, root) |> should.equal(Error(Nil))
  git.get_ref(backend, tenant, "heads/legacy-partial")
  |> should.equal(Error(Nil))
  session.published_summary(document_session, partial)
  |> should.equal(Ok(Some(#(head, 5))))
  git.fetch_commit(backend, partial, root)
  |> should.equal(store.get_object(backend, tenant, root))
}
