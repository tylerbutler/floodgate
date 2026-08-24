//// Mist transport for the Engine.IO/Socket.IO framing expected by the
//// official Routerlicious driver.
////
//// Beryl's shared transport server owns admission, limits, runtime
//// registration, frame decoding, and runtime-triggered closes. This module
//// adds the Engine.IO opening packet, namespace connect acknowledgment, and
//// server ping timer required by Socket.IO.

import beryl.{type Sockets}
import beryl/transport
import beryl/transport/server
import dewdrop/server as fluid_codec
import floodgate/origin
import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mist.{type Connection, type ResponseData, type WebsocketConnection}
import spillway/socketio

const ping_interval_ms = 10_000

const ping_timeout_ms = 20_000

type ConnectionState {
  ConnectionState(
    runtime: server.ConnectionState,
    sid: String,
    ping_subject: Subject(server.SendRequest),
    last_inbound_ms: Int,
  )
}

/// Build a combined `/socket.io/` WebSocket and HTTP request handler.
pub fn handler(
  sockets: Sockets,
  origin_policy: origin.OriginPolicy,
  http_fallback: fn(Request(Connection)) -> Response(ResponseData),
) -> fn(Request(Connection)) -> Response(ResponseData) {
  let config = transport_config(origin_policy)
  server.handler(
    upgrade: fn(request, next) { upgrade(request, sockets, config, next) },
    http_fallback: http_fallback,
  )
}

fn transport_config(
  policy: origin.OriginPolicy,
) -> server.TransportConfig(Connection) {
  let config = server.default_config("/socket.io")
  case policy {
    origin.SameOrigin -> config
    origin.AllowAll -> server.with_allow_all_origins(config)
    origin.AllowList(origins) -> server.with_allowed_origins(config, origins)
  }
}

fn upgrade(
  request: Request(Connection),
  sockets: Sockets,
  config: server.TransportConfig(Connection),
  next: fn() -> Response(ResponseData),
) -> Response(ResponseData) {
  let telemetry = transport.telemetry(sockets, transport.Mist)
  server.upgrade(
    request: request,
    sockets: sockets,
    config: config,
    telemetry: telemetry,
    request_ip: request_ip,
    reject: empty_response,
    accept: fn(metadata, permit) {
      mist.websocket(
        request: request,
        handler: on_message,
        on_init: fn(connection) {
          on_init(connection, request, metadata, sockets, permit, telemetry)
        },
        on_close: on_close,
      )
    },
    next: next,
  )
}

fn empty_response(status: Int) -> Response(ResponseData) {
  response.new(status)
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}

fn request_ip(request: Request(Connection)) -> Result(String, Nil) {
  mist.get_connection_info(request.body)
  |> result.map(fn(info) { mist.ip_address_to_string(info.ip_address) })
}

fn on_init(
  connection: WebsocketConnection,
  request: Request(Connection),
  metadata: List(#(String, String)),
  sockets: Sockets,
  permit: transport.ConnectionPermit,
  telemetry: transport.Telemetry,
) -> #(ConnectionState, Option(process.Selector(server.SendRequest))) {
  let sid = generate_socket_id()
  let ping_subject = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(ping_subject)
  let #(runtime, selector) =
    server.init_connection(
      sockets: sockets,
      seed: server.connect_seed(request, metadata),
      connection_permit: permit,
      base_selector: selector,
      logger_name: "floodgate.socketio",
      telemetry: telemetry,
      codec: Some(fluid_codec.server_codec()),
    )
  let _ =
    mist.send_text_frame(
      connection,
      socketio.encode_open(
        sid,
        ping_interval_ms,
        ping_timeout_ms,
        transport.max_inbound_frame_bytes(sockets),
      ),
    )
  schedule_ping(ping_subject)
  #(
    ConnectionState(
      runtime: runtime,
      sid: sid,
      ping_subject: ping_subject,
      last_inbound_ms: now_ms(),
    ),
    Some(selector),
  )
}

fn on_message(
  state: ConnectionState,
  message: mist.WebsocketMessage(server.SendRequest),
  connection: WebsocketConnection,
) -> mist.Next(ConnectionState, server.SendRequest) {
  case message {
    mist.Text(text) -> {
      let state = ConnectionState(..state, last_inbound_ms: now_ms())
      case socket_ping_ack_id(text) {
        Some(id) ->
          handle_control_frame(connection, state, text, "43" <> id <> "[]")
        None ->
          case text == socketio.socket_connect_prefix {
            True ->
              handle_control_frame(
                connection,
                state,
                text,
                socketio.encode_connect_ack(state.sid),
              )
            False ->
              resume(state, server.handle_text_frame(state.runtime, text))
          }
      }
    }
    mist.Binary(data) ->
      resume(
        ConnectionState(..state, last_inbound_ms: now_ms()),
        server.handle_binary_frame(state.runtime, data),
      )
    mist.Closed | mist.Shutdown -> mist.stop()
    mist.Custom(server.Close) -> mist.stop()
    mist.Custom(server.SendBinary(data)) -> {
      let _send_result = mist.send_binary_frame(connection, data)
      mist.continue(state)
    }
    mist.Custom(server.SendText(text)) ->
      case text == socketio.engine_ping() {
        False -> send_text(connection, state, text)
        True ->
          case pong_overdue(state) {
            True -> mist.stop()
            False -> {
              schedule_ping(state.ping_subject)
              send_text(connection, state, text)
            }
          }
      }
  }
}

fn handle_control_frame(
  connection: WebsocketConnection,
  state: ConnectionState,
  frame: String,
  response: String,
) -> mist.Next(ConnectionState, server.SendRequest) {
  case server.handle_text_frame(state.runtime, frame) {
    server.Continue(runtime) ->
      send_text(
        connection,
        ConnectionState(..state, runtime: runtime),
        response,
      )
    server.Stop -> mist.stop()
  }
}

fn socket_ping_ack_id(text: String) -> Option(String) {
  case
    string.starts_with(text, "42"),
    string.contains(text, "[\"ping\""),
    string.split(string.drop_start(text, 2), "[")
  {
    True, True, [id, ..] if id != "" ->
      case int.parse(id) {
        Ok(_) -> Some(id)
        Error(_) -> None
      }
    _, _, _ -> None
  }
}

fn resume(
  state: ConnectionState,
  outcome: server.FrameDisposition,
) -> mist.Next(ConnectionState, server.SendRequest) {
  case outcome {
    server.Continue(runtime) ->
      mist.continue(ConnectionState(..state, runtime: runtime))
    server.Stop -> mist.stop()
  }
}

fn send_text(
  connection: WebsocketConnection,
  state: ConnectionState,
  text: String,
) -> mist.Next(ConnectionState, server.SendRequest) {
  mist.send_text_frame(connection, text)
  |> result.replace(mist.continue(state))
  |> result.unwrap(mist.continue(state))
}

fn on_close(state: ConnectionState) -> Nil {
  server.close_connection(state.runtime)
}

fn schedule_ping(subject: Subject(server.SendRequest)) -> Nil {
  let _ =
    process.send_after(
      subject,
      ping_interval_ms,
      server.SendText(socketio.engine_ping()),
    )
  Nil
}

fn pong_overdue(state: ConnectionState) -> Bool {
  now_ms() - state.last_inbound_ms > ping_interval_ms + ping_timeout_ms
}

fn generate_socket_id() -> String {
  crypto.strong_random_bytes(16)
  |> bit_array.base16_encode()
}

@external(erlang, "floodgate_ffi", "now_ms")
fn now_ms() -> Int
