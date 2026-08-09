//// Two-phase Phoenix connect (ADR-008): a `levee-driver` socket joins with
//// only a token, then connects with the full IConnect payload and receives a
//// pushed `connect_document_success`. Drives the real coordinator with Phoenix
//// V2 frames, so these cover the codec inversion as well as the channel.

import beryl
import beryl/coordinator
import floodgate
import floodgate/auth
import floodgate/document_channel
import floodgate/memory_store
import floodgate/session
import floodgate/store
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

const secret = "phoenix-test-secret"

const tenant = "fluid"

fn token_for(doc: String, scopes: List(String)) -> String {
  auth.mint_token(tenant, doc, scopes, "user-1", secret, now(), 3600)
}

@external(erlang, "floodgate_ffi", "now_seconds")
fn now() -> Int

/// Start a runtime and attach a socket that captures outbound frames.
fn start_socket(
  socket_id: String,
) -> #(beryl.Channels, session.Session, process.Subject(String)) {
  let assert Ok(#(channels, sess)) =
    floodgate.start_with_backend(tenant, secret, memory_store.new())
  let sent = process.new_subject()
  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      socket_id,
      fn(text) {
        process.send(sent, text)
        Ok(Nil)
      },
      fn(_binary) { Ok(Nil) },
      // No per-socket codec: inherit the configured Phoenix framing, exactly
      // as beryl's stock mist transport does at /socket/websocket.
      None,
      dynamic.nil(),
    ),
  )
  #(channels, sess, sent)
}

fn route(channels: beryl.Channels, socket_id: String, frame: String) -> Nil {
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    socket_id,
    frame,
  )
}

fn phoenix_join(doc: String, token: String) -> String {
  "[\"1\",\"1\",\"document:"
  <> tenant
  <> ":"
  <> doc
  <> "\",\"phx_join\",{\"token\":\""
  <> token
  <> "\"}]"
}

fn phoenix_event(doc: String, event: String, payload: String) -> String {
  "[\"1\",\"2\",\"document:"
  <> tenant
  <> ":"
  <> doc
  <> "\",\""
  <> event
  <> "\","
  <> payload
  <> "]"
}

fn connect_payload(doc: String, token: String, mode: String) -> String {
  "{\"tenantId\":\""
  <> tenant
  <> "\",\"id\":\""
  <> doc
  <> "\",\"token\":\""
  <> token
  <> "\",\"mode\":\""
  <> mode
  <> "\",\"client\":{},\"versions\":[\"^0.4.0\"]}"
}

// A Phoenix join replies ok and does not connect: no connected response is
// pushed until the client sends connect_document.
pub fn phoenix_join_replies_ok_without_connecting_test() {
  let doc = "phx-join"
  let #(channels, _sess, sent) = start_socket("s-join")
  route(channels, "s-join", phoenix_join(doc, token_for(doc, ["doc:read"])))

  let assert Ok(reply) = process.receive(sent, 1000)
  reply |> string.contains("phx_reply") |> should.be_true
  reply |> string.contains("\"status\":\"ok\"") |> should.be_true
  reply |> string.contains("clientId") |> should.be_false
}

// Phase two: connect_document produces a pushed connect_document_success
// (not a phx_reply), which is what levee-driver listens for.
pub fn connect_document_pushes_success_test() {
  let doc = "phx-connect"
  let token = token_for(doc, ["doc:read", "doc:write"])
  let #(channels, _sess, sent) = start_socket("s-connect")

  route(channels, "s-connect", phoenix_join(doc, token))
  let assert Ok(_join_reply) = process.receive(sent, 1000)

  route(
    channels,
    "s-connect",
    phoenix_event(doc, "connect_document", connect_payload(doc, token, "write")),
  )
  let assert Ok(push) = process.receive(sent, 1000)
  push |> string.contains("connect_document_success") |> should.be_true
  push |> string.contains("\"clientId\":\"s-connect\"") |> should.be_true
  push |> string.contains("\"mode\":\"write\"") |> should.be_true
}

// A bad token is rejected at join time — floodgate is stricter than levee,
// which only parses the topic at join.
pub fn phoenix_join_rejects_bad_token_test() {
  let doc = "phx-bad-token"
  let #(channels, _sess, sent) = start_socket("s-bad")
  route(channels, "s-bad", phoenix_join(doc, "not-a-token"))

  let assert Ok(reply) = process.receive(sent, 1000)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("unauthorized") |> should.be_true
}

// A topic outside the configured tenant never reaches the session.
pub fn phoenix_join_rejects_foreign_tenant_test() {
  let doc = "phx-foreign"
  let #(channels, _sess, sent) = start_socket("s-foreign")
  route(
    channels,
    "s-foreign",
    "[\"1\",\"1\",\"document:other:"
      <> doc
      <> "\",\"phx_join\",{\"token\":\"x\"}]",
  )

  let assert Ok(reply) = process.receive(sent, 1000)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("invalid_topic") |> should.be_true
}

// Events that need session membership are refused until connect runs.
pub fn submit_op_before_connect_is_nacked_test() {
  let doc = "phx-early-op"
  let token = token_for(doc, ["doc:read", "doc:write"])
  let #(channels, _sess, sent) = start_socket("s-early")

  route(channels, "s-early", phoenix_join(doc, token))
  let assert Ok(_join_reply) = process.receive(sent, 1000)

  route(
    channels,
    "s-early",
    phoenix_event(
      doc,
      "submitOp",
      "{\"clientId\":\"s-early\",\"messageBatches\":[[]]}",
    ),
  )
  let assert Ok(push) = process.receive(sent, 1000)
  push |> string.contains("nack") |> should.be_true
  push |> string.contains("Client not connected") |> should.be_true
}

// The Socket.IO path is unchanged: its join payload is the connect payload, so
// the connected response comes back in the join reply itself.
pub fn socketio_style_join_stays_single_phase_test() {
  let doc = "sio-join"
  let token = token_for(doc, ["doc:read", "doc:write"])
  let #(channels, _sess, sent) = start_socket("s-sio")

  route(
    channels,
    "s-sio",
    "[\"1\",\"1\",\"document:"
      <> tenant
      <> ":"
      <> doc
      <> "\",\"phx_join\","
      <> connect_payload(doc, token, "write")
      <> "]",
  )

  let assert Ok(reply) = process.receive(sent, 1000)
  reply |> string.contains("\"status\":\"ok\"") |> should.be_true
  reply |> string.contains("\"clientId\":\"s-sio\"") |> should.be_true
}

// levee-driver's signal shape reaches the topic; floodgate previously dropped
// contentBatches entirely, which broke presence.
pub fn content_batches_signals_are_broadcast_test() {
  let doc = "phx-signal"
  let token = token_for(doc, ["doc:read", "doc:write"])
  let #(channels, _sess, sent) = start_socket("s-signal")

  route(channels, "s-signal", phoenix_join(doc, token))
  let assert Ok(_join_reply) = process.receive(sent, 1000)
  route(
    channels,
    "s-signal",
    phoenix_event(doc, "connect_document", connect_payload(doc, token, "write")),
  )
  let assert Ok(_connected) = process.receive(sent, 1000)

  route(
    channels,
    "s-signal",
    phoenix_event(
      doc,
      "submitSignal",
      "{\"clientId\":\"s-signal\",\"contentBatches\":[[{\"content\":\"ping\"}]]}",
    ),
  )
  let assert Ok(signal) = process.receive(sent, 1000)
  signal |> string.contains("\"signal\"") |> should.be_true
  signal |> string.contains("ping") |> should.be_true
}

/// A signal carrying `targetClientId` must reach only that client.
///
/// `spillway/session_logic.determine_signal_recipients` — the same function
/// levee's `Bridge.determine_signal_recipients` calls — was fully implemented and
/// entirely unused here: floodgate parsed the targeting fields and then
/// broadcast to the whole topic anyway, because it had no handle to push to a
/// single socket with. This is the divergence from levee that ADR-008 recorded as
/// deferred.
pub fn targeted_signal_reaches_only_its_target_test() {
  let doc = "phx-signal-target"
  let token = token_for(doc, ["doc:read", "doc:write"])
  let assert Ok(#(channels, _sess)) =
    floodgate.start_with_backend(tenant, secret, memory_store.new())

  let sender = attach(channels, "s-tgt-sender")
  let target = attach(channels, "s-tgt-target")
  let bystander = attach(channels, "s-tgt-bystander")
  connect(channels, doc, token, "s-tgt-sender")
  connect(channels, doc, token, "s-tgt-target")
  connect(channels, doc, token, "s-tgt-bystander")

  // Joins fan out to peers; clear that traffic before observing the signal.
  drain(sender)
  drain(target)
  drain(bystander)

  route(
    channels,
    "s-tgt-sender",
    phoenix_event(
      doc,
      "submitSignal",
      "{\"clientId\":\"s-tgt-sender\",\"contentBatches\":[[{\"content\":\"psst\","
        <> "\"targetClientId\":\"s-tgt-target\"}]]}",
    ),
  )

  let assert Ok(signal) = process.receive(target, 1000)
  signal |> string.contains("\"signal\"") |> should.be_true
  signal |> string.contains("psst") |> should.be_true
  // The client id is the beryl socket id, which is what makes addressing a
  // recipient possible at all.
  signal |> string.contains("s-tgt-sender") |> should.be_true

  process.receive(bystander, 200) |> should.equal(Error(Nil))
  // Nor does the sender receive its own signal back.
  process.receive(sender, 200) |> should.equal(Error(Nil))
}

/// An untargeted signal still goes to the whole topic, via the cheaper broadcast
/// path rather than one message per recipient.
pub fn untargeted_signal_still_reaches_every_peer_test() {
  let doc = "phx-signal-broadcast"
  let token = token_for(doc, ["doc:read", "doc:write"])
  let assert Ok(#(channels, _sess)) =
    floodgate.start_with_backend(tenant, secret, memory_store.new())

  let sender = attach(channels, "s-bc-sender")
  let first = attach(channels, "s-bc-first")
  let second = attach(channels, "s-bc-second")
  connect(channels, doc, token, "s-bc-sender")
  connect(channels, doc, token, "s-bc-first")
  connect(channels, doc, token, "s-bc-second")
  drain(sender)
  drain(first)
  drain(second)

  route(
    channels,
    "s-bc-sender",
    phoenix_event(
      doc,
      "submitSignal",
      "{\"clientId\":\"s-bc-sender\",\"contentBatches\":[[{\"content\":\"hello\"}]]}",
    ),
  )

  let assert Ok(to_first) = process.receive(first, 1000)
  to_first |> string.contains("hello") |> should.be_true
  let assert Ok(to_second) = process.receive(second, 1000)
  to_second |> string.contains("hello") |> should.be_true
}

pub fn recovered_membership_is_broadcast_before_the_new_join_test() {
  let doc = "phx-membership-recovery"
  let topic = store.topic(tenant, doc)
  let token = token_for(doc, ["doc:read", "doc:write"])
  let assert Ok(#(channels, sess)) =
    floodgate.start_with_backend(tenant, secret, memory_store.new())

  let old = attach(channels, "s-old")
  let fresh = attach(channels, "s-fresh")
  connect(channels, doc, token, "s-old")
  drain(old)
  drain(fresh)

  let assert Ok(pid) = session.document_owner(sess, topic)
  process.kill(pid)

  route(channels, "s-fresh", phoenix_join(doc, token))
  let assert Ok(_join_reply) = process.receive(fresh, 1000)
  route(
    channels,
    "s-fresh",
    phoenix_event(doc, "connect_document", connect_payload(doc, token, "write")),
  )

  let assert Ok(recovery) = process.receive(old, 1000)
  recovery |> string.contains("leave") |> should.be_true
  recovery |> string.contains("s-old") |> should.be_true

  let assert Ok(new_join) = process.receive(old, 1000)
  new_join |> string.contains("join") |> should.be_true
  new_join |> string.contains("s-fresh") |> should.be_true

  let assert Ok(connected) = process.receive(fresh, 1000)
  connected |> string.contains("connect_document_success") |> should.be_true
  connected |> string.contains("leave") |> should.be_true
  // `broadcast_from` excludes the fresh socket because the same operations are
  // already in its atomic connect snapshot.
  process.receive(fresh, 200) |> should.equal(Error(Nil))
}

/// Attach a frame-capturing socket to an existing runtime, so several clients
/// can share one coordinator and one document.
fn attach(
  channels: beryl.Channels,
  socket_id: String,
) -> process.Subject(String) {
  let sent = process.new_subject()
  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      socket_id,
      fn(text) {
        process.send(sent, text)
        Ok(Nil)
      },
      fn(_binary) { Ok(Nil) },
      None,
      dynamic.nil(),
    ),
  )
  sent
}

/// Both phases of a Phoenix connect.
fn connect(
  channels: beryl.Channels,
  doc: String,
  token: String,
  socket_id: String,
) -> Nil {
  route(channels, socket_id, phoenix_join(doc, token))
  route(
    channels,
    socket_id,
    phoenix_event(doc, "connect_document", connect_payload(doc, token, "write")),
  )
}

/// Discard already-queued frames, so a later `receive` observes only what the
/// assertion is about.
fn drain(sent: process.Subject(String)) -> Nil {
  case process.receive(sent, 200) {
    Ok(_) -> drain(sent)
    Error(Nil) -> Nil
  }
}

// noop advances the client's reference sequence number so the minimum
// sequence number can move for an otherwise idle client.
pub fn noop_advances_minimum_sequence_number_test() {
  let topic = "document:fluid:noop-msn"
  let sess = session.start_with_backend(memory_store.new())
  let assert session.Connected(_, _, _, _, _, _, [], Some(_)) =
    session.connect(sess, topic, "c1", "write", "{}", "{}", 0)

  let assert session.MessageAssigned(_, msn_before, _) =
    session.submit_message(sess, topic, "c1", 1, 0, fn(sn, msn) {
      "op-" <> string_of(sn) <> "-" <> string_of(msn)
    })

  session.update_client_rsn(sess, topic, "c1", 2)

  // The follow-up op still references 0, so any advance in the minimum
  // sequence number can only have come from the noop.
  let assert session.MessageAssigned(_, msn_after, _) =
    session.submit_message(sess, topic, "c1", 2, 0, fn(sn, msn) {
      "op-" <> string_of(sn) <> "-" <> string_of(msn)
    })
  msn_before |> should.equal(0)
  msn_after |> should.equal(2)
}

@external(erlang, "erlang", "integer_to_binary")
fn string_of(value: Int) -> String

/// `@fluidframework/container-loader`'s audience asserts that a client it
/// already holds and the one carried by that client's sequenced join op
/// serialize to the identical string (assert 0x4b2, "new client has different
/// payload from existing one"). `initialClients` is rebuilt from the roster,
/// which stores each client as a string and so round-trips through an Erlang
/// map — and maps do not preserve key order — while the join op's payload is
/// built directly. Normalizing every client payload through the same
/// round-trip is what makes the two agree, so that normalization has to be
/// idempotent.
pub fn client_payload_survives_roster_round_trip_test() {
  let client =
    document_channel.normalize_client_json(
      json.object([
        #("mode", json.string("write")),
        #(
          "details",
          json.object([
            #("capabilities", json.object([#("interactive", json.bool(True))])),
          ]),
        ),
        #("permission", json.preprocessed_array([])),
        #("scopes", json.array(["doc:read", "doc:write"], json.string)),
        #(
          "user",
          json.object([
            #("id", json.string("u1")),
            #("name", json.string("User One")),
          ]),
        ),
      ]),
    )

  // Storing the client and rebuilding it — what initialClients does — must not
  // change a single byte.
  document_channel.normalize_client_json(client)
  |> json.to_string
  |> should.equal(json.to_string(client))
}

/// Levee's `Session.client_join/2` stores `connect_msg["client"]` verbatim and
/// serves it back in both `initialClients` and the sequenced join op. The Fluid
/// container adds its *own* `IClient` to the audience from the object it sent,
/// so a server that rebuilds the record from `mode` + token claims hands the
/// audience two different payloads for one client id and trips assert 0x4b2
/// ("new client has different payload from existing one"). Fields the server
/// does not model — `details.environment` above all — are exactly what differ.
pub fn client_payload_echoes_the_clients_own_record_test() {
  let supplied =
    "{\"mode\":\"write\",\"details\":{\"capabilities\":{\"interactive\":true},"
    <> "\"environment\":\"loaderVersion:2.81.1\"},\"permission\":[],"
    <> "\"scopes\":[\"doc:read\"],\"user\":{\"id\":\"u1\"}}"
  let assert Ok(payload) =
    json.parse("{\"client\":" <> supplied <> "}", decode.dynamic)
  let assert Ok(sent) = json.parse(supplied, decode.dynamic)

  let assert Some(echoed) = document_channel.supplied_client_json(payload)
  json.to_string(echoed)
  |> should.equal(
    json.to_string(
      document_channel.normalize_client_json(document_channel.dynamic_to_json(
        sent,
      )),
    ),
  )
  // The field the server has no model for is the one that must survive.
  json.to_string(echoed) |> string.contains("environment") |> should.be_true
}

/// A Phoenix `phx_join` carries only a token, so there is nothing to echo and
/// the server-built record remains the fallback.
pub fn supplied_client_json_absent_when_not_sent_test() {
  let assert Ok(payload) = json.parse("{\"mode\":\"write\"}", decode.dynamic)
  document_channel.supplied_client_json(payload) |> should.equal(None)
}

// ─────────────────────────────────────────────────────────────────────────────
// Dynamic multi-tenancy — a tenant registered *after* the runtime has already
// started, with its own server-generated secrets, joins and connects exactly
// like the tenant seeded from FLOODGATE_TENANT_ID/FLOODGATE_JWT_SECRET. No
// restart is needed: `document_channel.authorize_topic_token` resolves the
// topic's tenant against `session.storage(sess)` on every join, so a tenant
// created between two requests is visible on the very next one.
// ─────────────────────────────────────────────────────────────────────────────

fn join_frame(topic: String, token: String) -> String {
  "[\"1\",\"1\",\""
  <> topic
  <> "\",\"phx_join\",{\"token\":\""
  <> token
  <> "\"}]"
}

fn event_frame(topic: String, event: String, payload: String) -> String {
  "[\"1\",\"2\",\"" <> topic <> "\",\"" <> event <> "\"," <> payload <> "]"
}

fn tenant_scoped_connect_payload(
  tenant_id: String,
  doc: String,
  token: String,
  mode: String,
) -> String {
  "{\"tenantId\":\""
  <> tenant_id
  <> "\",\"id\":\""
  <> doc
  <> "\",\"token\":\""
  <> token
  <> "\",\"mode\":\""
  <> mode
  <> "\",\"client\":{},\"versions\":[\"^0.4.0\"]}"
}

pub fn phoenix_join_accepts_dynamically_registered_tenant_test() {
  let doc = "phx-dynamic-tenant"
  let assert Ok(#(channels, sess)) =
    floodgate.start_with_backend(tenant, secret, memory_store.new())
  let acme = store.create_tenant(session.storage(sess), "Acme Co")
  let topic = "document:" <> acme.id <> ":" <> doc
  let token =
    auth.mint_token(
      acme.id,
      doc,
      ["doc:read", "doc:write"],
      "user-1",
      acme.secret1,
      now(),
      3600,
    )
  let sent = attach(channels, "s-dyn")

  route(channels, "s-dyn", join_frame(topic, token))
  let assert Ok(join_reply) = process.receive(sent, 1000)
  join_reply |> string.contains("\"status\":\"ok\"") |> should.be_true

  route(
    channels,
    "s-dyn",
    event_frame(
      topic,
      "connect_document",
      tenant_scoped_connect_payload(acme.id, doc, token, "write"),
    ),
  )
  let assert Ok(push) = process.receive(sent, 1000)
  push |> string.contains("connect_document_success") |> should.be_true
}

/// A token that authenticates fine for the tenant it was minted for is
/// rejected outright against a *different*, also-registered tenant, because
/// verification is scoped to the secrets of the tenant named in the topic —
/// never the token's own claimed tenant.
pub fn phoenix_join_rejects_cross_tenant_token_test() {
  let doc = "phx-cross-tenant"
  let assert Ok(#(channels, sess)) =
    floodgate.start_with_backend(tenant, secret, memory_store.new())
  let storage = session.storage(sess)
  let acme = store.create_tenant(storage, "Acme Co")
  let widgets = store.create_tenant(storage, "Widgets Inc")
  let token =
    auth.mint_token(
      acme.id,
      doc,
      ["doc:read", "doc:write"],
      "user-1",
      acme.secret1,
      now(),
      3600,
    )
  let sent = attach(channels, "s-xtenant")

  route(
    channels,
    "s-xtenant",
    join_frame("document:" <> widgets.id <> ":" <> doc, token),
  )

  let assert Ok(reply) = process.receive(sent, 1000)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("unauthorized") |> should.be_true
}

/// Both secret slots verify; rotating one leaves the other's tokens valid and
/// invalidates only tokens signed with the slot that changed.
pub fn phoenix_join_honours_secret_rotation_test() {
  let doc = "phx-rotation"
  let assert Ok(#(channels, sess)) =
    floodgate.start_with_backend(tenant, secret, memory_store.new())
  let storage = session.storage(sess)
  let rotating = store.create_tenant(storage, "Rotating Co")
  let topic = "document:" <> rotating.id <> ":" <> doc
  let old_secret1 = rotating.secret1

  let token_secret2 =
    auth.mint_token(
      rotating.id,
      doc,
      ["doc:read"],
      "user-1",
      rotating.secret2,
      now(),
      3600,
    )
  let sent_before = attach(channels, "s-rot-before")
  route(channels, "s-rot-before", join_frame(topic, token_secret2))
  let assert Ok(reply_before) = process.receive(sent_before, 1000)
  reply_before |> string.contains("\"status\":\"ok\"") |> should.be_true

  let assert Ok(_) =
    store.regenerate_tenant_secret(storage, rotating.id, store.Slot1)

  // The old secret1 no longer verifies anything.
  let stale_token =
    auth.mint_token(
      rotating.id,
      doc,
      ["doc:read"],
      "user-1",
      old_secret1,
      now(),
      3600,
    )
  let sent_stale = attach(channels, "s-rot-stale")
  route(channels, "s-rot-stale", join_frame(topic, stale_token))
  let assert Ok(reply_stale) = process.receive(sent_stale, 1000)
  reply_stale |> string.contains("\"status\":\"error\"") |> should.be_true

  // secret2 was never touched by the rotation, so it still verifies.
  let sent_after = attach(channels, "s-rot-after")
  route(channels, "s-rot-after", join_frame(topic, token_secret2))
  let assert Ok(reply_after) = process.receive(sent_after, 1000)
  reply_after |> string.contains("\"status\":\"ok\"") |> should.be_true
}
