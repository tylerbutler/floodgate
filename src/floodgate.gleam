//// Floodgate — Fluid Framework server on beryl: dewdrop/server codec, spillway
//// sequencing, beryl channels + pubsub fan-out + Mist. Official Fluid drivers
//// can connect. Gleam analogue of levee's DocumentChannel + Session + endpoint.

import beryl
import beryl/error as beryl_error
import beryl/pubsub
import beryl/supervisor as beryl_supervisor
import beryl/wire
import beryl_mist
import floodgate/auth
import floodgate/document_channel
import floodgate/git
import floodgate/initial_summary
import floodgate/memory_store
import floodgate/origin
import floodgate/session
import floodgate/shelf_store
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
import gleam/otp/static_supervisor
import gleam/result
import gleam/string
import gleam/uri
import mist
import signet/jwt

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

/// Resolve the explicit standalone runtime backend name. "ets" and "shelf" both
/// select the shelf-backed persistent store (`floodgate/shelf_store`); "ets" is
/// kept as a backward-compatible alias for the FLOODGATE_STORAGE_BACKEND value.
pub fn backend_from_name(
  name: String,
) -> Result(store.Backend, StorageBackendError) {
  case name {
    "ets" | "shelf" -> Ok(shelf_store.new(storage_data_dir()))
    "memory" -> Ok(memory_store.supervised())
    unsupported -> Error(UnsupportedStorageBackend(unsupported))
  }
}

/// Directory for the shelf DETS files, overridable via FLOODGATE_DATA_DIR.
fn storage_data_dir() -> String {
  getenv("FLOODGATE_DATA_DIR", "priv/floodgate_data")
}

/// Default maximum inbound WebSocket frame size (16 MiB).
const default_max_frame_bytes = 16_777_216

/// Maximum inbound WebSocket frame size, overridable via
/// FLOODGATE_MAX_FRAME_BYTES.
///
/// One value feeds all three places the limit is observable — beryl's enforced
/// `max_inbound_frame_bytes`, the `maxMessageSize` advertised in IConnected, and
/// the Engine.IO handshake's `maxPayload` — so they cannot drift. They had:
/// IConnected advertised 16 MiB while beryl enforced its own 1 MiB default and
/// the handshake advertised 1 MiB, and an oversize frame was dropped by the
/// transport with no protocol-level error.
pub fn max_frame_bytes() -> Int {
  positive_env("FLOODGATE_MAX_FRAME_BYTES", default_max_frame_bytes)
}

/// Origin policy for both socket endpoints, from FLOODGATE_ALLOWED_ORIGINS.
fn origin_policy() -> origin.OriginPolicy {
  origin.from_env(getenv("FLOODGATE_ALLOWED_ORIGINS", ""))
}

/// Read a positive integer from the environment, falling back to `default` when
/// unset, unparseable, or non-positive.
fn positive_env(name: String, default: Int) -> Int {
  case int.parse(getenv(name, "")) {
    Ok(value) if value > 0 -> value
    _ -> default
  }
}

/// Read a limit from the environment. beryl treats 0 as "unlimited" for the
/// connection and rate limits, so an explicit 0 must be preserved rather than
/// replaced by the default.
fn limit_env(name: String, default: Int) -> Int {
  case int.parse(getenv(name, "")) {
    Ok(value) if value >= 0 -> value
    _ -> default
  }
}

pub fn start(
  configured_tenant: String,
  jwt_secret: String,
) -> Result(#(beryl.Channels, session.Session), beryl_error.StartFailure) {
  start_with_backend(
    configured_tenant,
    jwt_secret,
    shelf_store.new(storage_data_dir()),
  )
}

/// Start a complete Floodgate socket runtime with the supplied storage backend.
pub fn start_with_backend(
  configured_tenant: String,
  jwt_secret: String,
  storage: store.Backend,
) -> Result(#(beryl.Channels, session.Session), beryl_error.StartFailure) {
  let ps = pubsub.start(pubsub.default_config())
  // Phoenix framing is the coordinator default so `levee-driver` sockets on
  // the stock beryl transport need no per-connection codec; the Socket.IO
  // transport overrides it per socket with the dewdrop/Routerlicious codec.
  //
  // The limits below must be applied before `beryl_supervisor.config`, which
  // reads them to decide whether to start the connection-limiter child.
  // Defaults are deliberately generous: the conformance suites open several
  // concurrent sockets from one address and burst ops during sync tests, so
  // these bound abuse without shaping normal collaboration. Set any to 0 to
  // disable that limit.
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_pubsub(ps)
    |> beryl.with_max_inbound_frame_bytes(max_frame_bytes())
    |> beryl.with_max_connections_per_ip(limit_env(
      "FLOODGATE_MAX_CONNECTIONS_PER_IP",
      256,
    ))
    |> beryl.with_max_connections(limit_env("FLOODGATE_MAX_CONNECTIONS", 4096))
    |> beryl.with_message_rate(
      per_second: limit_env("FLOODGATE_MESSAGE_RATE", 1000),
      burst: limit_env("FLOODGATE_MESSAGE_BURST", 2000),
    )
    |> beryl.with_join_rate(
      per_second: limit_env("FLOODGATE_JOIN_RATE", 100),
      burst: limit_env("FLOODGATE_JOIN_BURST", 200),
    )
  let supervised = beryl_supervisor.config(config)
  // The session actor owns the sequence state for every document, so it has to
  // be supervised — started outside the tree, a crash left every `process.call`
  // from every channel timing out with nothing to restart it, i.e. permanent
  // service death. Its name is allocated before the tree starts so the channel
  // below can be registered with a handle that stays valid across restarts.
  let session_name = session.new_name()
  let sess = session.from_name(session_name, storage)
  case
    static_supervisor.new(static_supervisor.OneForOne)
    // The backend's own processes come first: the session actor's `store.open`
    // and its lazy rehydration both call into storage, so storage has to be up
    // before it.
    |> store.supervise(storage)
    |> static_supervisor.add(beryl_supervisor.start(supervised))
    |> static_supervisor.add(session.child_spec(session_name, storage))
    |> static_supervisor.start()
  {
    Ok(_) -> {
      let channels = beryl_supervisor.channels(supervised)
      let _ =
        beryl.register(
          channels,
          "document:*",
          document_channel.new(channels, sess, configured_tenant, jwt_secret),
        )
      Ok(#(channels, sess))
    }
    Error(e) -> Error(beryl_error.from_actor_start_error(e))
  }
}

@external(erlang, "floodgate_ffi", "getenv")
fn getenv(name: String, default: String) -> String

/// Upgrade path for the Phoenix Channels endpoint. The phoenix js client used
/// by `levee-driver` is pointed at `<host>/socket` and appends `/websocket`.
const phoenix_socket_path = "/socket/websocket"

/// Phoenix endpoint transport config. beryl defaults to a same-origin policy,
/// which rejects browser clients served from another origin; FLOODGATE_ALLOWED_ORIGINS
/// takes a comma-separated allow-list, or `*` to disable origin checking.
fn phoenix_transport_config() -> beryl_mist.TransportConfig(Nil) {
  let config = beryl_mist.default_config(phoenix_socket_path)
  // beryl_mist's own default is already SameOrigin, so that case needs no call.
  case origin_policy() {
    origin.SameOrigin -> config
    origin.AllowAll -> beryl_mist.with_allow_all_origins(config)
    origin.AllowList(origins) ->
      beryl_mist.with_allowed_origins(config, origins)
  }
}

pub fn serve(port: Int) -> Result(Nil, Nil) {
  serve_with_backend(port, shelf_store.new(storage_data_dir()))
}

/// Serve the complete REST and socket surface with the supplied backend.
pub fn serve_with_backend(
  port: Int,
  storage: store.Backend,
) -> Result(Nil, Nil) {
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
            socketio_transport.handler(channels, origin_policy(), fn(req) {
              beryl_mist.upgrade(
                req,
                channels,
                phoenix_transport_config(),
                fn() { rest(sess, config, public_url, req) },
              )
            })
            |> mist.new
            |> mist.port(port)
            // Mist binds to localhost by default, which is unreachable from
            // outside a container. FLOODGATE_BIND overrides it; the Docker
            // image sets 0.0.0.0.
            |> mist.bind(getenv("FLOODGATE_BIND", "localhost"))
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
    // Unauthenticated readiness probe, byte-identical to levee's
    // `HealthController`, so container healthchecks and levee's integration
    // harness (`isServerRunning`) work unchanged against either server.
    // HEAD as well as GET: Phoenix answers HEAD for every GET route, and
    // container probes (`wget --spider`, most orchestrators) use HEAD.
    method, ["health"] if method == http.Get || method == http.Head ->
      health_body() |> json_response(200)
    http.Post, ["api", "tenants", tenant, "token-mint"] ->
      token_mint_response(config, req, tenant)
    http.Post, ["documents", tenant] -> {
      let body = read_body(req)
      case authorize_tenant_write(req, config, tenant) {
        Error(e) -> auth_error_response(e)
        Ok(_) -> {
          // Levee: `params["id"] || generate_document_id()`.
          let doc = case requested_document_id(body) {
            Some(id) -> id
            None -> generate_document_id()
          }
          create_document(sess, tenant, doc, public_url, body)
        }
      }
    }
    http.Get, ["documents", tenant, "session", doc] -> {
      case
        authorize_read(req, config, tenant, doc),
        session.exists(sess, topic(tenant, doc))
      {
        Error(e), _ -> auth_error_response(e)
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
        Error(e), _ -> auth_error_response(e)
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
        Error(e) -> auth_error_response(e)
        Ok(_) -> create_document(sess, tenant, doc, public_url, read_body(req))
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
        Error(e) -> auth_error_response(e)
        Ok(_) -> {
          let body = read_body(req)
          case git.create(storage, tenant, kind, body) {
            Error(_) -> bad_request()
            // Levee's GitController returns `{sha, url}` for a created blob but
            // the *whole* object for a created tree or commit — same shape its
            // GET returns. Match that, or clients reading `tree`/`message` off
            // the create response break.
            Ok(sha) ->
              case kind {
                "blobs" ->
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
                _ ->
                  case git.fetch(storage, tenant, sha) {
                    Error(_) -> bad_request()
                    Ok(data) ->
                      case
                        git.object_response(
                          storage,
                          public_url,
                          tenant,
                          kind,
                          sha,
                          data,
                          False,
                        )
                      {
                        Error(_) -> bad_request()
                        Ok(object) ->
                          object |> json.to_string |> json_response(201)
                      }
                  }
              }
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
        Error(e), _ -> auth_error_response(e)
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
      // The mint credential is floodgate's own, with no levee counterpart, so
      // it keeps the opaque rejection rather than levee's auth-plug wording.
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

/// The `Authorization` header plus the tenant check both routes share, reported
/// with levee's distinctions: a wrong tenant is a 403 mismatch, a missing header
/// is a 401.
fn authorization_header(
  req: request.Request(mist.Connection),
  config: AuthConfig,
  tenant: String,
) -> Result(String, auth.AuthError) {
  case tenant == config.tenant, request.get_header(req, "authorization") {
    False, _ -> Error(auth.BadClaims(jwt.TenantMismatch(config.tenant, tenant)))
    _, Error(_) -> Error(auth.MissingAuthorization)
    True, Ok(authorization) -> Ok(authorization)
  }
}

/// Write authorization for `POST /documents/:tenant`, which has no document id
/// in its path. See `auth.verify_tenant_write_authorization`.
fn authorize_tenant_write(
  req: request.Request(mist.Connection),
  config: AuthConfig,
  tenant: String,
) {
  use authorization <- result.try(authorization_header(req, config, tenant))
  auth.verify_tenant_write_authorization(
    authorization,
    config.jwt_secret,
    tenant,
    now_seconds(),
  )
}

fn authorize_write(
  req: request.Request(mist.Connection),
  config: AuthConfig,
  tenant: String,
  doc: String,
) {
  case tenant == config.tenant, request.get_header(req, "authorization") {
    False, _ -> Error(auth.BadClaims(jwt.TenantMismatch(config.tenant, tenant)))
    _, Error(_) -> Error(auth.MissingAuthorization)
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
    False, _ -> Error(auth.BadClaims(jwt.TenantMismatch(config.tenant, tenant)))
    _, Error(_) -> Error(auth.MissingAuthorization)
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
    False, _ -> Error(auth.BadClaims(jwt.TenantMismatch(config.tenant, tenant)))
    _, Error(_) -> Error(auth.MissingAuthorization)
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
    False, _ -> Error(auth.BadClaims(jwt.TenantMismatch(config.tenant, tenant)))
    _, Error(_) -> Error(auth.MissingAuthorization)
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
    Error(e) -> auth_error_response(e)
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
    Error(e) -> auth_error_response(e)
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
    Error(e) -> auth_error_response(e)
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
        Error(e), _ -> auth_error_response(e)
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
        Error(e), _ -> auth_error_response(e)
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
    Error(e), _ -> auth_error_response(e)
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
  public_url: String,
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
      create_response(doc, tenant, public_url, enable_discovery(body))
      |> json.to_string
      |> json_response(201)
  }
}

/// Levee's `DocumentController.create/2` responds with the bare document id —
/// `json(document_id)`, a JSON string — which is what `levee-driver`'s
/// `restWrapper.post<string>` consumes, and only wraps it in an object when the
/// caller asked for discovery.
pub fn create_response(
  doc: String,
  tenant: String,
  public_url: String,
  enable_discovery: Bool,
) -> json.Json {
  case enable_discovery {
    False -> json.string(doc)
    True ->
      json.object([
        #("id", json.string(doc)),
        #("session", session_info_json(tenant, public_url)),
      ])
  }
}

fn session_info_json(tenant: String, public_url: String) -> json.Json {
  json.object([
    #("ordererUrl", json.string(public_url)),
    #("historianUrl", json.string(public_url <> "/repos/" <> tenant)),
    #("deltaStreamUrl", json.string(public_url)),
    #("isSessionAlive", json.bool(True)),
    #("isSessionActive", json.bool(True)),
  ])
}

/// Whether a create request asked for the discovery-shaped response.
pub fn enable_discovery(body: String) -> Bool {
  case
    json.parse(
      body,
      decode.optionally_at(["enableDiscovery"], False, decode.bool),
    )
  {
    Ok(value) -> value
    Error(_) -> False
  }
}

/// Body of `GET /health`. Kept public so the wire shape is pinned by a test
/// rather than only by a live server.
pub fn health_body() -> String {
  json.object([#("status", json.string("ok"))]) |> json.to_string
}

/// The document id a `POST /documents/:tenant` body asks for, if any. Levee's
/// `DocumentController.create/2` does `params["id"] || generate_document_id()`;
/// an absent or empty id means "generate one".
pub fn requested_document_id(body: String) -> option.Option(String) {
  case json.parse(body, decode.optionally_at(["id"], "", decode.string)) {
    Ok("") | Error(_) -> None
    Ok(id) -> Some(id)
  }
}

/// Every rejection is 401, which is the Routerlicious contract the official
/// driver is held to (`floodgate-routerlicious.test.ts`, gated for release by
/// `floodgate-readiness.json`) and a deliberate divergence from levee.
///
/// Levee's `Plugs.Auth.error_response/1` — and `signet`'s own
/// `jwt.error_to_http_code` — answer 403 for a token that authenticates but is
/// not entitled (wrong tenant/document, missing scope). Floodgate keeps 401
/// there because the two statuses are not interchangeable to a Fluid client:
/// 401 prompts a token refresh and retry, 403 is fatal. See ADR-009.
pub fn auth_error_status(_error: auth.AuthError) -> Int {
  401
}

/// Rejection message, matching levee's wording closely enough that clients
/// keying off the text behave identically against either server.
pub fn auth_error_message(error: auth.AuthError) -> String {
  case error {
    auth.MissingAuthorization -> "Missing Authorization header"
    auth.BadFormat ->
      "Invalid Authorization header format. Expected: Bearer <token>"
    auth.BadSignature -> "Invalid token signature"
    auth.BadClaims(e) -> jwt.format_error(e)
  }
}

fn auth_error_response(error: auth.AuthError) {
  json.object([#("error", json.string(auth_error_message(error)))])
  |> json.to_string
  |> json_response(auth_error_status(error))
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

/// Default listen port when neither `PORT` nor `FLOODGATE_PORT` is set.
pub const default_port = 3000

/// Resolve the listen port, preferring `PORT` (the Docker/PaaS convention
/// levee already honours) over `FLOODGATE_PORT`, which stays available for
/// running floodgate alongside a levee server on one host.
pub fn resolve_port(port: String, floodgate_port: String) -> Int {
  case int.parse(port), int.parse(floodgate_port) {
    Ok(p), _ -> p
    _, Ok(p) -> p
    _, _ -> default_port
  }
}

pub fn main() {
  let backend_name = getenv("FLOODGATE_STORAGE_BACKEND", "ets")
  let assert Ok(storage) = backend_from_name(backend_name)
  let port = resolve_port(getenv("PORT", ""), getenv("FLOODGATE_PORT", ""))
  let assert Ok(Nil) = serve_with_backend(port, storage)
}
