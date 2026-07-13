//// Floodgate — Fluid Framework server on beryl: dewdrop/server codec, spillway
//// sequencing, beryl channels + pubsub fan-out + Mist. Official Fluid drivers
//// can connect. Gleam analogue of levee's DocumentChannel + Session + endpoint.

import beryl
import beryl/pubsub
import floodgate/auth
import floodgate/document_channel
import floodgate/git
import floodgate/initial_summary
import floodgate/memory_store
import floodgate/server_codec
import floodgate/session
import floodgate/socketio_transport
import floodgate/store
import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mist

type AuthConfig {
  AuthConfig(
    tenant: String,
    jwt_secret: String,
    token_mint_secret: option.Option(String),
    token_mint_user_id: String,
    token_mint_user_name: String,
  )
}

type TokenMintRequest {
  TokenMintRequest(document_id: String, tenant_id: option.Option(String))
}

pub type StorageBackendError {
  UnsupportedStorageBackend(String)
}

/// Resolve the explicit standalone runtime backend name.
pub fn backend_from_name(
  name: String,
) -> Result(store.Backend, StorageBackendError) {
  case name {
    "ets" -> Ok(store.ets())
    "memory" -> Ok(memory_store.new())
    unsupported -> Error(UnsupportedStorageBackend(unsupported))
  }
}

pub fn start(
  configured_tenant: String,
  jwt_secret: String,
) -> Result(#(beryl.Channels, session.Session), beryl.StartError) {
  start_with_backend(configured_tenant, jwt_secret, store.ets())
}

/// Start a complete Floodgate socket runtime with the supplied storage backend.
pub fn start_with_backend(
  configured_tenant: String,
  jwt_secret: String,
  storage: store.Backend,
) -> Result(#(beryl.Channels, session.Session), beryl.StartError) {
  let ps = pubsub.start(pubsub.default_config())
  let config =
    beryl.config(server_codec.server_codec()) |> beryl.with_pubsub(ps)
  case beryl.start(config) {
    Ok(channels) -> {
      let sess = session.start_with_backend(storage)
      let _ =
        beryl.register(
          channels,
          "document:*",
          document_channel.new(channels, sess, configured_tenant, jwt_secret),
        )
      Ok(#(channels, sess))
    }
    Error(e) -> Error(e)
  }
}

@external(erlang, "floodgate_ffi", "getenv")
fn getenv(name: String, default: String) -> String

pub fn serve(port: Int) -> Result(Nil, Nil) {
  serve_with_backend(port, store.ets())
}

/// Serve the complete REST and socket surface with the supplied backend.
pub fn serve_with_backend(port: Int, storage: store.Backend) -> Result(Nil, Nil) {
  let configured_tenant = getenv("FLOODGATE_TENANT_ID", "fluid")
  let jwt_secret = getenv("FLOODGATE_JWT_SECRET", "")
  case jwt_secret {
    "" -> Error(Nil)
    _ -> {
      let token_mint_secret = case getenv("FLOODGATE_TOKEN_MINT_SECRET", "") {
        "" -> None
        secret -> Some(secret)
      }
      let config =
        AuthConfig(
          configured_tenant,
          jwt_secret,
          token_mint_secret,
          getenv("FLOODGATE_TOKEN_MINT_USER_ID", "floodgate-token-mint"),
          getenv("FLOODGATE_TOKEN_MINT_USER_NAME", "Floodgate Token Mint"),
        )
      let public_url =
        getenv(
          "FLOODGATE_PUBLIC_URL",
          "http://localhost:" <> int.to_string(port),
        )
      case start_with_backend(configured_tenant, jwt_secret, storage) {
        Error(_) -> Error(Nil)
        Ok(#(channels, sess)) -> {
          let assert Ok(_) =
            socketio_transport.handler(channels, fn(req) {
              rest(sess, config, public_url, req)
            })
            |> mist.new
            |> mist.port(port)
            |> mist.start
          process.sleep_forever()
          Ok(Nil)
        }
      }
    }
  }
}

// REST: document lifecycle + deltas catch-up + git object storage.
fn rest(
  sess: session.Session,
  config: AuthConfig,
  public_url: String,
  req: request.Request(mist.Connection),
) {
  let req = normalize_restless_request(req)
  let storage = session.storage(sess)
  case req.method, request.path_segments(req) {
    http.Post, ["api", "tenants", tenant, "token-mint"] ->
      token_mint_response(config, req, tenant)
    http.Post, ["documents", tenant] -> {
      case authorize_write(req, config, tenant, "") {
        Error(_) -> unauthorized()
        Ok(_) -> {
          let doc = generate_document_id()
          create_document(sess, tenant, doc, read_body(req))
        }
      }
    }
    http.Get, ["documents", tenant, "session", doc] -> {
      case
        authorize_read(req, config, tenant, doc),
        session.exists(sess, topic(tenant, doc))
      {
        Error(_), _ -> unauthorized()
        _, False -> not_found()
        Ok(_), True ->
          json.object([
            #("ordererUrl", json.string(public_url)),
            #("historianUrl", json.string(public_url <> "/repos/" <> tenant)),
            #("deltaStreamUrl", json.string(public_url)),
            #("isSessionAlive", json.bool(True)),
            #("isSessionActive", json.bool(True)),
          ])
          |> json.to_string
          |> json_response(200)
      }
    }
    http.Get, ["documents", tenant, doc, "deltas"] ->
      deltas_response(sess, config, req, tenant, doc, False)
    http.Get, ["deltas", tenant, doc] ->
      deltas_response(sess, config, req, tenant, doc, True)
    http.Get, ["documents", tenant, doc] -> {
      case
        authorize_read(req, config, tenant, doc),
        session.exists(sess, topic(tenant, doc))
      {
        Error(_), _ -> unauthorized()
        _, False -> not_found()
        Ok(_), True ->
          json.object([
            #("id", json.string(doc)),
            #("tenantId", json.string(tenant)),
            #(
              "sequenceNumber",
              json.int(session.sequence_number(sess, topic(tenant, doc))),
            ),
          ])
          |> json.to_string
          |> json_response(200)
      }
    }
    method, ["documents", tenant, doc]
      if method == http.Post || method == http.Put
    -> {
      case authorize_write(req, config, tenant, doc) {
        Error(_) -> unauthorized()
        Ok(_) -> create_document(sess, tenant, doc, read_body(req))
      }
    }
    http.Get, ["repos", tenant, "commits"] ->
      commits_response(storage, config, public_url, req, tenant)
    http.Get, ["repos", tenant, "git", "refs"] ->
      refs_response(storage, config, public_url, req, tenant)
    http.Post, ["repos", tenant, "git", "refs"] ->
      create_ref_response(storage, config, public_url, req, tenant)
    method, ["repos", tenant, "git", "refs", ..ref_parts]
      if method == http.Get || method == http.Patch
    -> ref_response(storage, config, public_url, req, tenant, ref_parts, method)
    method, ["repos", tenant, "git", kind]
      if method == http.Post
      && { kind == "blobs" || kind == "trees" || kind == "commits" }
    -> {
      case authorize_storage_write(req, config, tenant) {
        Error(_) -> unauthorized()
        Ok(_) -> {
          let body = read_body(req)
          case git.create(storage, tenant, kind, body) {
            Error(_) -> bad_request()
            Ok(sha) ->
              json.object([
                #("sha", json.string(sha)),
                #(
                  "url",
                  json.string(
                    public_url
                    <> "/repos/"
                    <> tenant
                    <> "/git/"
                    <> kind
                    <> "/"
                    <> sha,
                  ),
                ),
              ])
              |> json.to_string
              |> json_response(201)
          }
        }
      }
    }
    http.Get, ["repos", tenant, "git", kind, sha]
      if kind == "blobs" || kind == "trees" || kind == "commits"
    -> {
      case
        authorize_storage_read(req, config, tenant),
        git.fetch(storage, tenant, sha)
      {
        Error(_), _ -> unauthorized()
        _, Error(_) -> not_found()
        Ok(_), Ok(data) -> {
          let query =
            uri.parse_query(req.query |> option_unwrap) |> result_unwrap_list
          let recursive = case list.key_find(query, "recursive") {
            Ok("1") -> True
            _ -> False
          }
          case
            git.object_response(
              storage,
              public_url,
              tenant,
              kind,
              sha,
              data,
              recursive,
            )
          {
            Ok(object) -> object |> json.to_string |> json_response(200)
            Error(_) -> bad_request()
          }
        }
      }
    }
    _, _ -> response.new(404) |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

fn token_mint_response(
  config: AuthConfig,
  req: request.Request(mist.Connection),
  tenant: String,
) {
  case
    tenant == config.tenant,
    config.token_mint_secret,
    request.get_header(req, "authorization")
  {
    False, _, _ -> unauthorized()
    _, None, _ -> not_found()
    _, _, Error(_) -> unauthorized()
    True, Some(mint_secret), Ok(authorization) ->
      case auth.verify_token_mint_authorization(authorization, mint_secret) {
        Error(_) -> unauthorized()
        Ok(Nil) ->
          case decode_token_mint_request(read_body(req)) {
            Error(_) -> bad_request()
            Ok(mint_request) ->
              case mint_request.tenant_id {
                Some(body_tenant) if body_tenant != tenant -> unauthorized()
                _ -> {
                  let expires_in = 3600
                  let token =
                    auth.mint_token(
                      tenant,
                      mint_request.document_id,
                      [
                        "doc:read",
                        "doc:write",
                        "summary:read",
                        "summary:write",
                      ],
                      config.token_mint_user_id,
                      config.jwt_secret,
                      now_seconds(),
                      expires_in,
                    )
                  json.object([
                    #("jwt", json.string(token)),
                    #("expiresIn", json.int(expires_in)),
                    #(
                      "user",
                      json.object([
                        #("id", json.string(config.token_mint_user_id)),
                        #("name", json.string(config.token_mint_user_name)),
                      ]),
                    ),
                  ])
                  |> json.to_string
                  |> json_response(200)
                }
              }
          }
      }
  }
}

fn decode_token_mint_request(body: String) -> Result(TokenMintRequest, Nil) {
  let decoder = {
    use document_id <- decode.field("documentId", decode.string)
    use tenant_id <- decode.optional_field(
      "tenantId",
      None,
      decode.optional(decode.string),
    )
    decode.success(TokenMintRequest(document_id, tenant_id))
  }
  json.parse(body, decoder) |> result.replace_error(Nil)
}

fn authorize_write(
  req: request.Request(mist.Connection),
  config: AuthConfig,
  tenant: String,
  doc: String,
) {
  case tenant == config.tenant, request.get_header(req, "authorization") {
    False, _ | _, Error(_) -> Error(auth.BadFormat)
    True, Ok(authorization) ->
      auth.verify_write_authorization(
        authorization,
        config.jwt_secret,
        tenant,
        doc,
        now_seconds(),
      )
  }
}

fn authorize_read(
  req: request.Request(mist.Connection),
  config: AuthConfig,
  tenant: String,
  doc: String,
) {
  case tenant == config.tenant, request.get_header(req, "authorization") {
    False, _ | _, Error(_) -> Error(auth.BadFormat)
    True, Ok(authorization) ->
      auth.verify_read_authorization(
        authorization,
        config.jwt_secret,
        tenant,
        doc,
        now_seconds(),
      )
  }
}

fn authorize_storage_read(
  req: request.Request(mist.Connection),
  config: AuthConfig,
  tenant: String,
) {
  case tenant == config.tenant, request.get_header(req, "authorization") {
    False, _ | _, Error(_) -> Error(auth.BadFormat)
    True, Ok(authorization) ->
      auth.verify_storage_read_authorization(
        authorization,
        config.jwt_secret,
        tenant,
        now_seconds(),
      )
  }
}

fn authorize_storage_write(
  req: request.Request(mist.Connection),
  config: AuthConfig,
  tenant: String,
) {
  case tenant == config.tenant, request.get_header(req, "authorization") {
    False, _ | _, Error(_) -> Error(auth.BadFormat)
    True, Ok(authorization) ->
      auth.verify_storage_write_authorization(
        authorization,
        config.jwt_secret,
        tenant,
        now_seconds(),
      )
  }
}

fn commits_response(
  storage: store.Backend,
  config: AuthConfig,
  public_url: String,
  req: request.Request(mist.Connection),
  tenant: String,
) {
  case authorize_storage_read(req, config, tenant) {
    Error(_) -> unauthorized()
    Ok(_) -> {
      let query =
        uri.parse_query(req.query |> option_unwrap) |> result_unwrap_list
      let count = case list.key_find(query, "count") {
        Error(_) -> Ok(1)
        Ok(value) ->
          case int.parse(value) {
            Ok(count) if count > 0 -> Ok(count)
            _ -> Error(Nil)
          }
      }
      case list.key_find(query, "sha"), count {
        Error(_), _ | _, Error(_) -> bad_request()
        Ok(requested), Ok(count) -> {
          let sha = case
            git.get_ref(storage, tenant, "refs/heads/" <> requested)
          {
            Ok(ref_sha) -> ref_sha
            Error(_) -> requested
          }
          git.commit_history_response(storage, public_url, tenant, sha, count)
          |> json.preprocessed_array
          |> json.to_string
          |> json_response(200)
        }
      }
    }
  }
}

fn refs_response(
  storage: store.Backend,
  config: AuthConfig,
  public_url: String,
  req: request.Request(mist.Connection),
  tenant: String,
) {
  case authorize_storage_read(req, config, tenant) {
    Error(_) -> unauthorized()
    Ok(_) ->
      git.list_refs(storage, tenant)
      |> list.map(fn(ref) { git.ref_response(public_url, tenant, ref.0, ref.1) })
      |> json.preprocessed_array
      |> json.to_string
      |> json_response(200)
  }
}

fn create_ref_response(
  storage: store.Backend,
  config: AuthConfig,
  public_url: String,
  req: request.Request(mist.Connection),
  tenant: String,
) {
  case authorize_storage_write(req, config, tenant) {
    Error(_) -> unauthorized()
    Ok(_) ->
      case git.decode_ref(read_body(req)) {
        Error(_) -> bad_request()
        Ok(ref) -> {
          case git.create_ref(storage, tenant, ref.0, ref.1) {
            False -> conflict()
            True ->
              git.ref_response(public_url, tenant, ref.0, ref.1)
              |> json.to_string
              |> json_response(201)
          }
        }
      }
  }
}

fn ref_response(
  storage: store.Backend,
  config: AuthConfig,
  public_url: String,
  req: request.Request(mist.Connection),
  tenant: String,
  ref_parts: List(String),
  method: http.Method,
) {
  let ref = "refs/" <> string.join(ref_parts, "/")
  case method {
    http.Get ->
      case
        authorize_storage_read(req, config, tenant),
        git.get_ref(storage, tenant, ref)
      {
        Error(_), _ -> unauthorized()
        _, Error(_) -> not_found()
        Ok(_), Ok(sha) ->
          git.ref_response(public_url, tenant, ref, sha)
          |> json.to_string
          |> json_response(200)
      }
    http.Patch ->
      case
        authorize_storage_write(req, config, tenant),
        decode_sha(read_body(req))
      {
        Error(_), _ -> unauthorized()
        _, Error(_) -> bad_request()
        Ok(_), Ok(sha) -> {
          git.put_ref(storage, tenant, ref, sha)
          git.ref_response(public_url, tenant, ref, sha)
          |> json.to_string
          |> json_response(200)
        }
      }
    _ -> not_found()
  }
}

fn decode_sha(body: String) -> Result(String, Nil) {
  json.parse(body, decode.field("sha", decode.string, decode.success))
  |> result.replace_error(Nil)
}

fn deltas_response(
  sess: session.Session,
  config: AuthConfig,
  req: request.Request(mist.Connection),
  tenant: String,
  doc: String,
  envelope: Bool,
) {
  case
    authorize_read(req, config, tenant, doc),
    session.exists(sess, topic(tenant, doc))
  {
    Error(_), _ -> unauthorized()
    _, False -> not_found()
    Ok(_), True -> {
      let query =
        uri.parse_query(req.query |> option_unwrap) |> result_unwrap_list
      let from = case list.key_find(query, "from") {
        Ok(value) -> int.parse(value) |> result_unwrap(-1)
        Error(_) -> -1
      }
      let to = case list.key_find(query, "to") {
        Ok(value) ->
          int.parse(value) |> result_unwrap(9_223_372_036_854_775_807)
        Error(_) -> 9_223_372_036_854_775_807
      }
      let ops =
        session.since(sess, topic(tenant, doc), from)
        |> list.filter(fn(op) { op.0 <= to })
        |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
        |> list.take(2000)
      let messages =
        json.preprocessed_array(list.map(ops, session.stored_message_json))
      let body = case envelope {
        True -> json.object([#("value", messages)])
        False -> messages
      }
      body |> json.to_string |> json_response(200)
    }
  }
}

fn create_document(
  sess: session.Session,
  tenant: String,
  doc: String,
  body: String,
) {
  let document_topic = topic(tenant, doc)
  case
    session.create_initialized(sess, document_topic, fn() {
      initial_summary.persist(
        session.storage(sess),
        tenant,
        doc,
        body,
        now_seconds(),
      )
    })
  {
    session.AlreadyExists -> conflict()
    session.InvalidInitialSummary -> bad_request()
    session.Created ->
      json.object([
        #("id", json.string(doc)),
        #("tenantId", json.string(tenant)),
      ])
      |> json.to_string
      |> json_response(201)
  }
}

fn unauthorized() {
  json.object([#("error", json.string("unauthorized"))])
  |> json.to_string
  |> json_response(401)
}

fn not_found() {
  json.object([#("error", json.string("not found"))])
  |> json.to_string
  |> json_response(404)
}

fn bad_request() {
  json.object([#("error", json.string("bad request"))])
  |> json.to_string
  |> json_response(400)
}

fn conflict() {
  json.object([#("error", json.string("conflict"))])
  |> json.to_string
  |> json_response(409)
}

fn json_response(body: String, status: Int) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn generate_document_id() -> String {
  crypto.strong_random_bytes(16)
  |> bit_array.base16_encode
}

fn topic(tenant: String, doc: String) -> String {
  "document:" <> tenant <> ":" <> doc
}

@external(erlang, "floodgate_ffi", "now_seconds")
fn now_seconds() -> Int

fn read_body(req: request.Request(mist.Connection)) -> String {
  case request.get_header(req, "x-floodgate-restless-body") {
    Ok(body) -> body
    Error(_) -> read_raw_body(req)
  }
}

fn normalize_restless_request(req: request.Request(mist.Connection)) {
  case request.get_header(req, "content-type") {
    Ok(content_type) -> {
      case string.contains(content_type, ";restless") {
        False -> req
        True -> {
          let fields =
            read_raw_body(req) |> uri.parse_query |> result_unwrap_list
          let method = case list.key_find(fields, "method") {
            Ok(value) -> http.parse_method(value) |> result.unwrap(req.method)
            Error(_) -> req.method
          }
          let req =
            fields
            |> list.filter_map(fn(field) {
              case field {
                #("header", value) -> Ok(value)
                _ -> Error(Nil)
              }
            })
            |> list.fold(
              request.Request(..req, method: method),
              fn(req, header) {
                case string.split_once(header, ": ") {
                  Ok(#(name, value)) ->
                    request.set_header(req, string.lowercase(name), value)
                  Error(_) -> req
                }
              },
            )
          case list.key_find(fields, "body") {
            Ok(body) ->
              request.set_header(req, "x-floodgate-restless-body", body)
            Error(_) -> req
          }
        }
      }
    }
    Error(_) -> req
  }
}

fn read_raw_body(req: request.Request(mist.Connection)) -> String {
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
  let backend_name = getenv("FLOODGATE_STORAGE_BACKEND", "ets")
  let assert Ok(storage) = backend_from_name(backend_name)
  let assert Ok(Nil) = serve_with_backend(3000, storage)
}
