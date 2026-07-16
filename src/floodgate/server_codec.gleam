//// Floodgate's beryl codec customization for Routerlicious event shapes.

import beryl/wire/codec.{type Codec, TextFrame}
import dewdrop/events
import dewdrop/server
import gleam/json
import gleam/string
import windsock

pub fn server_codec() -> Codec {
  let base = server.server_codec()
  // beryl's `Codec` is now opaque, so we rebuild it via `codec.new` with the
  // base's own encoders, overriding only `encode_push`. `new` resets the
  // topicless-events flag, so re-apply the base's setting to preserve it.
  let rebuilt =
    codec.new(
      decode_text: codec.decode_text(base),
      encode_reply: codec.encode_reply(base),
      encode_push: encode_push,
      encode_heartbeat_reply: codec.encode_heartbeat_reply(base),
    )
  case codec.topicless_events(base) {
    True -> codec.with_topicless_events(rebuilt)
    False -> rebuilt
  }
}

fn encode_push(topic: String, event: String, payload: json.Json) {
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
