//// The coordinator's heartbeat sweep is what reclaims a socket that stopped
//// heartbeating — a process that died without a clean close, or a half-open
//// connection whose peer went away while TCP stayed up. Until floodgate
//// registered a closer the sweep could drop coordinator state but not close the
//// connection, so the socket process stayed alive pinging into the void with
//// its stale RSN pinning the document's MSN.
////
//// This exercises the whole chain: no heartbeats → sweep → channel terminate →
//// session roster reclaimed → registered closer invoked.

import beryl/transport
import beryl/wire/codec.{Join}
import floodgate
import floodgate/auth
import floodgate/memory_store
import floodgate/server_codec
import floodgate/session
import gleam/dynamic
import gleam/erlang/process
import gleam/option.{None, Some}
import gleeunit/should

const secret = "heartbeat-test-secret"

const tenant = "fluid"

/// Short enough to sweep inside a test — the check interval beryl derives is
/// `timeout / 2`, so eviction lands within ~300 ms of the last heartbeat.
const timeout_ms = "200"

pub fn socket_that_stops_heartbeating_is_evicted_and_closed_test() {
  let doc = "heartbeat-evict"
  let topic = "document:" <> tenant <> ":" <> doc
  let socket_id = "s-heartbeat"

  // Read at config time only, so restoring it immediately keeps every other
  // test on the 60 s default.
  setenv("FLOODGATE_HEARTBEAT_TIMEOUT_MS", timeout_ms)
  let assert Ok(#(channels, sess)) =
    floodgate.start_with_backend(tenant, secret, memory_store.new())
  setenv("FLOODGATE_HEARTBEAT_TIMEOUT_MS", "")

  let closed = process.new_subject()
  let sent = process.new_subject()
  transport.socket_connected_with_codec(
    channels: channels,
    socket_id: socket_id,
    send: fn(text) {
      process.send(sent, text)
      Ok(Nil)
    },
    send_binary: fn(_binary) { Ok(Nil) },
    codec: Some(server_codec.server_codec()),
    assigns: dynamic.nil(),
  )
  transport.register_closer(
    channels: channels,
    socket_id: socket_id,
    close: fn() { process.send(closed, Nil) },
  )

  // A Socket.IO join is the connect_document payload itself, so one frame puts
  // this client in the session roster.
  let token =
    auth.mint_token(tenant, doc, ["doc:read"], "user-1", secret, now(), 3600)
  transport.route_decoded(channels, socket_id, connect_frame(topic, doc, token))
  // Routing is a cast, so wait for the connect response before observing the
  // roster it was built from.
  let assert Ok(_connected) = process.receive(sent, 1000)
  session.clients(sess, topic) |> should.equal([socket_id])

  // Now go silent. No heartbeat ever arrives. The closer firing means the
  // coordinator has already run the channel's terminate, which is what returns
  // the client to the session.
  let assert Ok(Nil) = process.receive(closed, 2000)
  session.clients(sess, topic) |> should.equal([])
}

fn connect_frame(topic: String, doc: String, token: String) -> codec.Inbound {
  codec.inbound(
    None,
    None,
    topic,
    Join,
    dynamic.properties([
      #(dynamic.string("tenantId"), dynamic.string(tenant)),
      #(dynamic.string("id"), dynamic.string(doc)),
      #(dynamic.string("token"), dynamic.string(token)),
      #(dynamic.string("mode"), dynamic.string("read")),
    ]),
  )
}

@external(erlang, "floodgate_ffi", "now_seconds")
fn now() -> Int

@external(erlang, "floodgate_ffi", "setenv")
fn setenv(name: String, value: String) -> Nil
