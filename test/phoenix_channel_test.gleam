//// Two-phase Phoenix connect (ADR-008): a `levee-driver` socket joins with
//// only a token, then connects with the full IConnect payload and receives a
//// pushed `connect_document_success`. Drives the real coordinator with Phoenix
//// V2 frames, so these cover the codec inversion as well as the channel.

import beryl
import beryl/coordinator
import floodgate
import floodgate/auth
import floodgate/memory_store
import floodgate/session
import gleam/dynamic
import gleam/erlang/process
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

// noop advances the client's reference sequence number so the minimum
// sequence number can move for an otherwise idle client.
pub fn noop_advances_minimum_sequence_number_test() {
  let topic = "document:fluid:noop-msn"
  let sess = session.start_with_backend(memory_store.new())
  let assert session.Connected(_, _, _, _, _, _, Some(_)) =
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
