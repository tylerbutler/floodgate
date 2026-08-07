//// Mist transport for the Engine.IO/Socket.IO framing expected by the
//// official Routerlicious driver.
////
//// This is floodgate's own transport rather than beryl_mist's, so the guards
//// beryl_mist applies to the Phoenix endpoint have to be applied here too or the
//// two endpoints diverge. It now mirrors beryl_mist on four counts: the origin
//// (CSWSH) policy, the per-IP/node connection ceiling, the per-socket message
//// rate limit, and — importantly — registering a closer so the coordinator can
//// actively evict a stale socket instead of leaving a zombie connection whose
//// frames are silently dropped.

import beryl.{type Channels, type ConnectionPermit}
import beryl/transport.{type RateLimiter}
import beryl/wire/codec.{type Inbound, Event, Heartbeat, Join}
import dewdrop/events
import floodgate/origin
import floodgate/server_codec
import floodgate/socketio
import gleam/bit_array
import gleam/bool
import gleam/bytes_tree
import gleam/crypto
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mist.{type Connection, type ResponseData, type WebsocketConnection}

const ping_interval_ms = 25_000

const ping_timeout_ms = 20_000

type ConnectionState {
  ConnectionState(
    socket_id: String,
    channels: Channels,
    send_subject: Subject(SendRequest),
    topic: String,
    connection_permit: Option(ConnectionPermit),
    message_limiter: Option(RateLimiter),
    max_frame_bytes: Int,
  )
}

type SendRequest {
  SendText(String)
  SendBinary(BitArray)
  SendPing
  Close
}

/// Build a combined `/socket.io/` WebSocket and HTTP request handler.
///
/// The frame ceiling is read from the beryl config via
/// `beryl.max_inbound_frame_bytes`, which is the single authority for all three
/// places the limit is observable: enforced here per frame (beryl only *exposes*
/// the value — enforcement is each transport's job), advertised in the Engine.IO
/// handshake as `maxPayload`, and advertised by the channel as IConnected's
/// `maxMessageSize`.
pub fn handler(
  channels: Channels,
  origin_policy: origin.OriginPolicy,
  http_fallback: fn(Request(Connection)) -> Response(ResponseData),
) -> fn(Request(Connection)) -> Response(ResponseData) {
  fn(request) {
    case is_socketio_websocket_request(request) {
      True -> upgrade(request, channels, origin_policy)
      False -> http_fallback(request)
    }
  }
}

fn is_socketio_websocket_request(request: Request(Connection)) -> Bool {
  case request.path_segments(request), request.get_header(request, "upgrade") {
    ["socket.io"], Ok(upgrade) -> string.lowercase(upgrade) == "websocket"
    _, _ -> False
  }
}

fn upgrade(
  request: Request(Connection),
  channels: Channels,
  origin_policy: origin.OriginPolicy,
) -> Response(ResponseData) {
  // Reject cross-site browser upgrades before the handshake. Non-browser
  // clients — the official Fluid drivers and the conformance suites — send no
  // `Origin` and stay admitted under the default policy.
  use <- bool.lazy_guard(
    when: !origin.allowed(
      origin_policy,
      origin: request.get_header(request, "origin"),
      host: request.get_header(request, "host"),
    ),
    return: fn() { empty_response(403) },
  )

  case beryl.acquire_connection_slot(channels, request_ip(request)) {
    Error(Nil) -> empty_response(429)
    Ok(permit) ->
      // The permit is bound to the connection process in `on_init` so the
      // limiter's monitor reclaims it on abnormal death, and released in
      // `on_close`. A handshake that never reaches `on_init` would leak the
      // slot; that window is the same one beryl_mist has, and the request has
      // already been screened as a websocket upgrade by this point.
      mist.websocket(
        request: request,
        handler: on_message,
        on_init: fn(connection) { on_init(connection, channels, permit) },
        on_close: on_close,
      )
  }
}

fn empty_response(status: Int) -> Response(ResponseData) {
  response.new(status)
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}

/// The real socket peer address. Deliberately not read from `X-Forwarded-For`:
/// a client sets that freely and could otherwise spoof its way past the per-IP
/// ceiling. Behind a trusted proxy every connection shares the proxy address,
/// so enforce per-client limits at the proxy instead.
fn request_ip(request: Request(Connection)) -> String {
  case mist.get_connection_info(request.body) {
    Ok(info) -> mist.ip_address_to_string(info.ip_address)
    Error(Nil) -> "unknown"
  }
}

fn on_init(
  connection: WebsocketConnection,
  channels: Channels,
  permit: ConnectionPermit,
) -> #(ConnectionState, Option(process.Selector(SendRequest))) {
  let max_frame_bytes = beryl.max_inbound_frame_bytes(channels)
  let socket_id = generate_socket_id()
  let send_subject = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(send_subject)

  // Bind before anything can fail, so the slot is reclaimed even if this
  // process dies without running `on_close`.
  beryl.bind_connection_slot(permit)

  let send_text = fn(text: String) -> Result(Nil, Nil) {
    process.send(send_subject, SendText(text))
    Ok(Nil)
  }
  let send_binary = fn(data: BitArray) -> Result(Nil, Nil) {
    process.send(send_subject, SendBinary(data))
    Ok(Nil)
  }

  transport.socket_connected_with_codec(
    channels: channels,
    socket_id: socket_id,
    send: send_text,
    send_binary: send_binary,
    codec: Some(server_codec.server_codec()),
    assigns: dynamic.nil(),
  )

  // Without this the coordinator can drop its own state for a stale socket but
  // cannot close the underlying connection, leaving this process alive and
  // pinging into the void — and its stale RSN pinning the document's MSN.
  transport.register_closer(
    channels: channels,
    socket_id: socket_id,
    close: fn() { process.send(send_subject, Close) },
  )

  let _ =
    mist.send_text_frame(
      connection,
      socketio.encode_open(
        socket_id,
        ping_interval_ms,
        ping_timeout_ms,
        max_frame_bytes,
      ),
    )
  schedule_ping(send_subject)

  #(
    ConnectionState(
      socket_id: socket_id,
      channels: channels,
      send_subject: send_subject,
      topic: "",
      connection_permit: Some(permit),
      message_limiter: transport.new_message_limiter(channels),
      max_frame_bytes: max_frame_bytes,
    ),
    Some(selector),
  )
}

fn on_message(
  state: ConnectionState,
  message: mist.WebsocketMessage(SendRequest),
  connection: WebsocketConnection,
) -> mist.Next(ConnectionState, SendRequest) {
  case message {
    mist.Text(text) ->
      case frame_too_large(state.max_frame_bytes, string.byte_size(text)) {
        True -> mist.stop()
        False ->
          case take_token(state) {
            #(state, False) -> mist.continue(state)
            #(state, True) -> handle_text(state, text, connection)
          }
      }
    mist.Binary(data) ->
      case frame_too_large(state.max_frame_bytes, bit_array.byte_size(data)) {
        True -> mist.stop()
        False ->
          case take_token(state) {
            #(state, False) -> mist.continue(state)
            #(state, True) -> {
              transport.route_binary(state.channels, state.socket_id, data)
              mist.continue(state)
            }
          }
      }
    mist.Closed | mist.Shutdown -> mist.stop()
    // Coordinator-initiated eviction via the registered closer.
    mist.Custom(Close) -> mist.stop()
    mist.Custom(SendText(text)) -> send_text(connection, state, text)
    mist.Custom(SendBinary(data)) -> {
      mist.send_binary_frame(connection, data)
      |> result.replace(mist.continue(state))
      |> result.unwrap(mist.continue(state))
    }
    mist.Custom(SendPing) -> {
      schedule_ping(state.send_subject)
      send_text(connection, state, socketio.engine_ping())
    }
  }
}

/// Whether an inbound frame breaches the configured ceiling. A cap of 0 (or
/// less) disables the check, matching beryl's convention. Mirrors beryl_mist so
/// both endpoints reject at the same size and in the same way — a close rather
/// than a protocol error, since at frame level there is no reliable client or
/// topic context to address a nack to, and WebSocket close is the native signal.
fn frame_too_large(max_bytes: Int, actual_bytes: Int) -> Bool {
  max_bytes > 0 && actual_bytes > max_bytes
}

/// Take a token from this socket's inbound message budget. Over-budget frames
/// are dropped rather than closing the socket, matching how the coordinator
/// treats frames from a socket it has already stopped tracking.
fn take_token(state: ConnectionState) -> #(ConnectionState, Bool) {
  case state.message_limiter {
    None -> #(state, True)
    Some(limiter) -> {
      let #(limiter, allowed) = transport.take_token(limiter)
      #(ConnectionState(..state, message_limiter: Some(limiter)), allowed)
    }
  }
}

fn handle_text(
  state: ConnectionState,
  text: String,
  connection: WebsocketConnection,
) -> mist.Next(ConnectionState, SendRequest) {
  case socketio.classify(text) {
    socketio.EnginePing -> {
      transport.route_decoded(
        state.channels,
        state.socket_id,
        codec.inbound(None, None, "", Heartbeat, dynamic.nil()),
      )
      mist.continue(state)
    }
    socketio.EnginePong -> {
      transport.route_decoded(
        state.channels,
        state.socket_id,
        codec.inbound(None, None, "", Heartbeat, dynamic.nil()),
      )
      mist.continue(state)
    }
    socketio.SocketConnect ->
      send_text(connection, state, socketio.encode_connect_ack(state.socket_id))
    socketio.FluidEvent(event, args) -> handle_fluid_event(state, event, args)
    socketio.Unrecognized(_) -> mist.continue(state)
  }
}

fn handle_fluid_event(
  state: ConnectionState,
  event: String,
  args: List(dynamic.Dynamic),
) -> mist.Next(ConnectionState, SendRequest) {
  case inbound_event(state.topic, event, args) {
    Error(Nil) -> mist.continue(state)
    Ok(#(inbound, topic)) -> {
      transport.route_decoded(state.channels, state.socket_id, inbound)
      mist.continue(ConnectionState(..state, topic: topic))
    }
  }
}

fn inbound_event(
  current_topic: String,
  event: String,
  args: List(dynamic.Dynamic),
) -> Result(#(Inbound, String), Nil) {
  case event, args {
    e, [payload, ..] if e == events.connect_document -> {
      let topic = topic_from_connect(payload)
      case topic {
        "" -> Error(Nil)
        _ -> Ok(#(codec.inbound(None, None, topic, Join, payload), topic))
      }
    }
    e, [client_id, messages, ..]
      if e == events.submit_op && current_topic != ""
    ->
      Ok(#(
        codec.inbound(
          None,
          None,
          current_topic,
          Event(event),
          dynamic.properties([
            #(dynamic.string("clientId"), client_id),
            #(dynamic.string("messageBatches"), messages),
          ]),
        ),
        current_topic,
      ))
    e, [client_id, signals, ..]
      if e == events.submit_signal && current_topic != ""
    ->
      Ok(#(
        codec.inbound(
          None,
          None,
          current_topic,
          Event(event),
          dynamic.properties([
            #(dynamic.string("clientId"), client_id),
            #(dynamic.string("signals"), signals),
          ]),
        ),
        current_topic,
      ))
    _, [payload, ..] if current_topic != "" ->
      Ok(#(
        codec.inbound(None, None, current_topic, Event(event), payload),
        current_topic,
      ))
    _, _ -> Error(Nil)
  }
}

fn topic_from_connect(payload: dynamic.Dynamic) -> String {
  let tenant = string_field(payload, "tenantId")
  let document_id = string_field(payload, "id")
  case tenant, document_id {
    "", _ -> ""
    _, "" -> ""
    _, _ -> "document:" <> tenant <> ":" <> document_id
  }
}

fn string_field(value: dynamic.Dynamic, key: String) -> String {
  case decode.run(value, decode.field(key, decode.string, decode.success)) {
    Ok(found) -> found
    Error(_) -> ""
  }
}

fn send_text(
  connection: WebsocketConnection,
  state: ConnectionState,
  text: String,
) -> mist.Next(ConnectionState, SendRequest) {
  mist.send_text_frame(connection, text)
  |> result.replace(mist.continue(state))
  |> result.unwrap(mist.continue(state))
}

fn on_close(state: ConnectionState) -> Nil {
  transport.socket_disconnected(state.channels, state.socket_id)
  case state.connection_permit {
    Some(permit) -> beryl.release_connection_slot(permit)
    None -> Nil
  }
}

fn schedule_ping(subject: Subject(SendRequest)) -> Nil {
  let _ = process.send_after(subject, ping_interval_ms, SendPing)
  Nil
}

fn generate_socket_id() -> String {
  crypto.strong_random_bytes(16)
  |> bit_array.base16_encode()
}
