//// Mist transport for the Engine.IO/Socket.IO framing expected by the
//// official Routerlicious driver.

import beryl.{type Channels}
import beryl/coordinator.{type Message as CoordinatorMessage}
import beryl/wire/codec.{type Inbound, Event, Heartbeat, Inbound, Join}
import dewdrop/events
import floodgate/socketio
import gleam/bit_array
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

const max_payload = 1_000_000

type ConnectionState {
  ConnectionState(
    socket_id: String,
    coordinator: Subject(CoordinatorMessage),
    send_subject: Subject(SendRequest),
    topic: String,
  )
}

type SendRequest {
  SendText(String)
  SendBinary(BitArray)
  SendPing
}

/// Build a combined `/socket.io/` WebSocket and HTTP request handler.
pub fn handler(
  channels: Channels,
  http_fallback: fn(Request(Connection)) -> Response(ResponseData),
) -> fn(Request(Connection)) -> Response(ResponseData) {
  fn(request) {
    case is_socketio_websocket_request(request) {
      True -> upgrade(request, channels)
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
) -> Response(ResponseData) {
  mist.websocket(
    request: request,
    handler: on_message,
    on_init: fn(connection) {
      on_init(connection, beryl.coordinator_subject(channels))
    },
    on_close: on_close,
  )
}

fn on_init(
  connection: WebsocketConnection,
  coordinator: Subject(CoordinatorMessage),
) -> #(ConnectionState, Option(process.Selector(SendRequest))) {
  let socket_id = generate_socket_id()
  let send_subject = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(send_subject)

  let send_text = fn(text: String) -> Result(Nil, Nil) {
    process.send(send_subject, SendText(text))
    Ok(Nil)
  }
  let send_binary = fn(data: BitArray) -> Result(Nil, Nil) {
    process.send(send_subject, SendBinary(data))
    Ok(Nil)
  }

  process.send(
    coordinator,
    coordinator.SocketConnected(
      socket_id,
      send_text,
      send_binary,
      None,
      dynamic.nil(),
    ),
  )

  let _ =
    mist.send_text_frame(
      connection,
      socketio.encode_open(
        socket_id,
        ping_interval_ms,
        ping_timeout_ms,
        max_payload,
      ),
    )
  schedule_ping(send_subject)

  #(ConnectionState(socket_id, coordinator, send_subject, ""), Some(selector))
}

fn on_message(
  state: ConnectionState,
  message: mist.WebsocketMessage(SendRequest),
  connection: WebsocketConnection,
) -> mist.Next(ConnectionState, SendRequest) {
  case message {
    mist.Text(text) -> handle_text(state, text, connection)
    mist.Binary(data) -> {
      coordinator.route_binary(state.coordinator, state.socket_id, data)
      mist.continue(state)
    }
    mist.Closed | mist.Shutdown -> mist.stop()
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

fn handle_text(
  state: ConnectionState,
  text: String,
  connection: WebsocketConnection,
) -> mist.Next(ConnectionState, SendRequest) {
  case socketio.classify(text) {
    socketio.EnginePing -> {
      coordinator.route_decoded(
        state.coordinator,
        state.socket_id,
        Inbound(None, None, "", Heartbeat, dynamic.nil()),
      )
      mist.continue(state)
    }
    socketio.EnginePong -> {
      coordinator.route_decoded(
        state.coordinator,
        state.socket_id,
        Inbound(None, None, "", Heartbeat, dynamic.nil()),
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
      coordinator.route_decoded(state.coordinator, state.socket_id, inbound)
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
        _ -> Ok(#(Inbound(None, None, topic, Join, payload), topic))
      }
    }
    e, [client_id, messages, ..]
      if e == events.submit_op && current_topic != ""
    ->
      Ok(#(
        Inbound(
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
        Inbound(
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
        Inbound(None, None, current_topic, Event(event), payload),
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
  process.send(
    state.coordinator,
    coordinator.SocketDisconnected(state.socket_id),
  )
}

fn schedule_ping(subject: Subject(SendRequest)) -> Nil {
  let _ = process.send_after(subject, ping_interval_ms, SendPing)
  Nil
}

fn generate_socket_id() -> String {
  crypto.strong_random_bytes(16)
  |> bit_array.base16_encode()
}
