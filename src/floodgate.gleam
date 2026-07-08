//// Floodgate — Fluid Framework server on beryl: dewdrop/server codec, spillway
//// sequencing, beryl channels + pubsub fan-out + Mist. Official Fluid drivers
//// can connect. Gleam analogue of levee's DocumentChannel + Session + endpoint.

import beryl
import beryl/pubsub
import beryl/transport/mist as mist_transport
import dewdrop/server
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/uri
import mist
import floodgate/document_channel
import floodgate/git
import floodgate/session

pub fn start() -> Result(#(beryl.Channels, session.Session), beryl.StartError) {
  let ps = pubsub.start(pubsub.default_config())
  let config = beryl.config(server.server_codec()) |> beryl.with_pubsub(ps)
  case beryl.start(config) {
    Ok(channels) -> {
      let sess = session.start()
      let secret = getenv("FLOODGATE_JWT_SECRET", "")
      let _ =
        beryl.register(
          channels,
          "document:*",
          document_channel.new(channels, sess, secret),
        )
      Ok(#(channels, sess))
    }
    Error(e) -> Error(e)
  }
}

@external(erlang, "floodgate_ffi", "getenv")
fn getenv(name: String, default: String) -> String

pub fn serve(port: Int) -> Result(Nil, Nil) {
  case start() {
    Error(_) -> Error(Nil)
    Ok(#(channels, sess)) -> {
      let assert Ok(_) =
        mist_transport.handler(
          channels,
          mist_transport.default_config("/socket"),
          fn(req) { rest(sess, req) },
        )
        |> mist.new
        |> mist.port(port)
        |> mist.start
      process.sleep_forever()
      Ok(Nil)
    }
  }
}

// REST: document create (POST/PUT) + deltas catch-up.
fn rest(sess: session.Session, req: request.Request(mist.Connection)) {
  case req.method, request.path_segments(req) {
    http.Get, ["documents", tenant, doc, "deltas"] -> {
      let q = uri.parse_query(req.query |> option_unwrap) |> result_unwrap_list
      let from = case list.key_find(q, "from") {
        Ok(v) -> int.parse(v) |> result_unwrap(0)
        Error(_) -> 0
      }
      let ops = session.since(sess, "document:" <> tenant <> ":" <> doc, from)
      let body =
        json.preprocessed_array(
          list.map(ops, fn(o) {
            json.object([
              #("sequenceNumber", json.int(o.0)),
              #("contents", json.string(o.1)),
            ])
          }),
        )
        |> json.to_string
      response.new(200)
      |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
    }
    method, ["documents", tenant, doc]
      if method == http.Post || method == http.Put
    -> {
      session.join(sess, "document:" <> tenant <> ":" <> doc, "creator")
      let body =
        json.object([
          #("id", json.string(doc)),
          #("tenantId", json.string(tenant)),
        ])
        |> json.to_string
      response.new(201)
      |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
    }
    method, ["repos", tenant, "git", kind]
      if method == http.Post
      && { kind == "blobs" || kind == "trees" || kind == "commits" }
    -> {
      let body = read_body(req)
      let sha = git.create(tenant, body)
      let out =
        json.object([
          #("sha", json.string(sha)),
          #(
            "url",
            json.string("/repos/" <> tenant <> "/git/" <> kind <> "/" <> sha),
          ),
        ])
        |> json.to_string
      response.new(201)
      |> response.set_body(mist.Bytes(bytes_tree.from_string(out)))
    }
    http.Get, ["repos", tenant, "git", kind, sha]
      if kind == "blobs" || kind == "trees" || kind == "commits"
    -> {
      case git.fetch(tenant, sha) {
        Ok(data) ->
          response.new(200)
          |> response.set_body(mist.Bytes(bytes_tree.from_string(data)))
        Error(_) ->
          response.new(404)
          |> response.set_body(
            mist.Bytes(bytes_tree.from_string("{\"error\":\"not found\"}")),
          )
      }
    }
    _, _ -> response.new(404) |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

fn read_body(req: request.Request(mist.Connection)) -> String {
  case mist.read_body(req, 4_000_000) {
    Ok(r) -> bit_array.to_string(r.body) |> result_unwrap_str
    Error(_) -> ""
  }
}

fn result_unwrap_str(r: Result(String, a)) -> String {
  case r {
    Ok(s) -> s
    Error(_) -> ""
  }
}

fn option_unwrap(o: option.Option(String)) -> String {
  option.unwrap(o, "")
}

fn result_unwrap(r: Result(Int, a), d: Int) -> Int {
  case r {
    Ok(v) -> v
    Error(_) -> d
  }
}

fn result_unwrap_list(
  r: Result(List(#(String, String)), a),
) -> List(#(String, String)) {
  case r {
    Ok(v) -> v
    Error(_) -> []
  }
}

pub const topic_prefix = "document:"

pub fn main() {
  let _ = serve(3000)
}
