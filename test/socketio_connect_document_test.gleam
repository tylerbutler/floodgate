import beryl/wire/codec
import floodgate/connect_document
import floodgate/server_codec
import floodgate/socketio
import gleam/dict
import gleam/dynamic
import gleam/json
import gleeunit/should
import windsock

pub fn classify_engine_ping_test() {
  socketio.classify("2") |> should.equal(socketio.EnginePing)
}

pub fn classify_engine_pong_test() {
  socketio.classify("3") |> should.equal(socketio.EnginePong)
}

pub fn classify_socket_connect_test() {
  socketio.classify("40") |> should.equal(socketio.SocketConnect)
}

pub fn classify_fluid_event_test() {
  let assert socketio.FluidEvent("connect_document", [_payload]) =
    socketio.classify("42[\"connect_document\",{\"id\":\"doc\"}]")
}

pub fn classify_unrecognized_test() {
  let assert socketio.Unrecognized(_reason) = socketio.classify("garbage")
}

pub fn encode_open_contains_sid_and_prefix_test() {
  let packet = socketio.encode_open("abc123", 25_000, 20_000, 1_000_000)
  packet
  |> should.equal(
    "0{\"sid\":\"abc123\",\"upgrades\":[],\"pingInterval\":25000,\"pingTimeout\":20000,\"maxPayload\":1000000}",
  )
}

pub fn encode_connect_ack_test() {
  socketio.encode_connect_ack("abc123")
  |> should.equal("40{\"sid\":\"abc123\"}")
}

pub fn encode_pong_matches_windsock_test() {
  socketio.encode_pong() |> should.equal(windsock.pong)
}

pub fn encode_op_shape_test() {
  let assert socketio.FluidEvent("op", [decoded_doc_id, decoded_messages]) =
    socketio.classify(socketio.encode_op(
      json.string("doc-1"),
      json.preprocessed_array([]),
    ))
  decoded_doc_id |> should.equal(dynamic.string("doc-1"))
  decoded_messages |> should.equal(dynamic.list([]))
}

pub fn server_codec_encodes_routerlicious_op_arguments_test() {
  let configured = server_codec.server_codec()
  let assert codec.TextFrame(frame) =
    codec.encode_push(configured)(
      "document:tenant-a:doc-1",
      "op",
      json.preprocessed_array([]),
    )
  let assert socketio.FluidEvent("op", [decoded_doc_id, decoded_messages]) =
    socketio.classify(frame)
  decoded_doc_id |> should.equal(dynamic.string("doc-1"))
  decoded_messages |> should.equal(dynamic.list([]))
}

pub fn connect_document_parse_request_ok_test() {
  let payload =
    dict.from_list([
      #("tenantId", dynamic.string("tenant-a")),
      #("id", dynamic.string("doc-a")),
      #("token", dynamic.string("token-a")),
    ])

  let assert Ok(connect_document.ConnectRequest("tenant-a", "doc-a", "token-a")) =
    connect_document.parse_request(payload)
}

pub fn connect_document_parse_request_missing_field_test() {
  let payload =
    dict.from_list([
      #("tenantId", dynamic.string("tenant-a")),
      #("token", dynamic.string("token-a")),
    ])

  connect_document.parse_request(payload)
  |> should.equal(Error(connect_document.MissingField("id")))
}

pub fn connect_document_validate_mode_scope_write_with_scope_test() {
  let payload = dict.from_list([#("mode", dynamic.string("write"))])
  connect_document.validate_mode_scope(payload, ["doc:read", "doc:write"])
  |> should.equal(Ok(Nil))
}

pub fn connect_document_validate_mode_scope_write_without_scope_test() {
  let payload = dict.from_list([#("mode", dynamic.string("write"))])
  connect_document.validate_mode_scope(payload, ["doc:read"])
  |> should.equal(Error(connect_document.WriteModeWithoutWriteScope))
}

pub fn connect_document_validate_mode_scope_absent_mode_test() {
  let payload = dict.new()
  connect_document.validate_mode_scope(payload, [])
  |> should.equal(Ok(Nil))
}

pub fn connect_document_read_write_scope_strings_test() {
  connect_document.read_scope() |> should.equal("doc:read")
  connect_document.write_scope() |> should.equal("doc:write")
}
