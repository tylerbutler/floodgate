//// Floodgate's beryl codec customization for Routerlicious event shapes.

import beryl/wire/codec.{type Codec, TextFrame}
import dewdrop/events
import dewdrop/server
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import windsock

pub fn server_codec() -> Codec {
  let base = server.server_codec()
  // beryl's `Codec` is now opaque, so we rebuild it via `codec.new` with the
  // base's own encoders, overriding only `encode_push`. `new` resets every
  // *optional* part of the codec, so each one has to be carried across
  // deliberately — dewdrop's close encoder was being dropped here, which is why
  // floodgate never emitted `42["close"]` on a graceful channel termination even
  // though dewdrop defines the frame and the coordinator asks for it.
  codec.new(
    decode_text: codec.decode_text(base),
    encode_reply: codec.encode_reply(base),
    encode_push: encode_push,
    encode_heartbeat_reply: codec.encode_heartbeat_reply(base),
  )
  |> preserve_optional_parts(base)
}

/// Re-apply the optional parts of `base` to a rebuilt codec.
///
/// Written against every optional field rather than only the ones dewdrop
/// currently sets, so adding one upstream cannot silently go missing here again.
/// The durable fix is a `with_push_encoder` in beryl, which would remove the need
/// to rebuild at all.
fn preserve_optional_parts(rebuilt: Codec, base: Codec) -> Codec {
  let rebuilt = case codec.topicless_events(base) {
    True -> codec.with_topicless_events(rebuilt)
    False -> rebuilt
  }
  let rebuilt = case codec.encode_close(base) {
    Some(encode_close) -> codec.with_close_encoder(rebuilt, encode_close)
    None -> rebuilt
  }
  let rebuilt = case codec.decode_binary(base) {
    Some(decode_binary) -> codec.with_binary_decoder(rebuilt, decode_binary)
    None -> rebuilt
  }
  case codec.encode_error(base) {
    Some(encode_error) -> codec.with_error_encoder(rebuilt, encode_error)
    None -> rebuilt
  }
}

fn encode_push(
  topic: String,
  event: String,
  payload: json.Json,
) -> codec.Frame {
  case event {
    e if e == events.op || e == events.nack ->
      TextFrame(
        windsock.encode(event, [
          json.string(document_id(topic)),
          payload,
        ]),
      )
    _ -> TextFrame(windsock.encode(event, [payload]))
  }
}

fn document_id(topic: String) -> String {
  case string.split(topic, ":") {
    ["document", _, document_id] -> document_id
    _ -> topic
  }
}
