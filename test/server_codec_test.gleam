import beryl/wire/codec
import dewdrop/server
import floodgate/server_codec
import gleam/dynamic
import gleam/json
import gleam/option.{None, Some}
import gleeunit/should
import spillway/socketio

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

/// Overriding `encode_push` means rebuilding the codec with `codec.new`, which
/// resets every optional part. dewdrop's close encoder was being dropped that
/// way, so the coordinator found none and floodgate stayed silent on graceful
/// channel termination instead of emitting `42["close"]`.
pub fn server_codec_preserves_dewdrops_close_encoder_test() {
  let base = server.server_codec()
  let configured = server_codec.server_codec()

  // Only meaningful while dewdrop actually sets one.
  let assert Some(base_encode_close) = codec.encode_close(base)
  let assert Some(encode_close) = codec.encode_close(configured)

  let assert codec.TextFrame(frame) =
    encode_close(None, "document:tenant-a:doc-1")
  let assert codec.TextFrame(base_frame) =
    base_encode_close(None, "document:tenant-a:doc-1")
  frame |> should.equal(base_frame)
}

/// The topicless-events flag has the same failure mode; it was already being
/// carried across, and this keeps it that way.
pub fn server_codec_preserves_topicless_events_test() {
  codec.topicless_events(server_codec.server_codec()) |> should.be_true
}
