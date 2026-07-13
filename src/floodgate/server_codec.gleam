//// Floodgate's beryl codec customization for Routerlicious event shapes.

import beryl/wire/codec.{type Codec, Codec, TextFrame}
import dewdrop/events
import dewdrop/server
import gleam/json
import gleam/string
import windsock

pub fn server_codec() -> Codec {
  let base = server.server_codec()
  Codec(..base, encode_push: encode_push)
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
