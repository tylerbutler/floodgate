//// Floodgate — Fluid Framework server on beryl: dewdrop/server codec, spillway
//// sequencing, beryl channels + pubsub fan-out + Mist. Official Fluid drivers
//// can connect. Gleam analogue of levee's DocumentChannel + Session + endpoint.

import beryl
import beryl/error as beryl_error
import beryl/presence
import beryl/pubsub
import beryl/supervisor as beryl_supervisor
import beryl/wire
import beryl_mist
import floodgate/admin_auth
import floodgate/auth
import floodgate/document_channel
import floodgate/git
import floodgate/initial_summary
import floodgate/memory_store
import floodgate/oauth
import floodgate/oauth_state
import floodgate/origin
import floodgate/presence_worker
import floodgate/session
import floodgate/shelf_store
import floodgate/socketio_transport
import floodgate/static
import floodgate/store
import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process
import gleam/http
import gleam/http/cookie
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
import vestibule/auth as vestibule_auth
import vestibule/error as vestibule_error

/// Runtime configuration resolved once, in `serve_with_backend`, from every
/// `FLOODGATE_*`/`GITHUB_*` environment variable the REST surface needs.
/// `pub` so `admin_authorized`/`session_user`/`handle_successful_auth`/
/// `find_or_create_admin_user` — the testable decision points that take it —
/// can be exercised directly from `floodgate_test.gleam` with a fabricated
/// config, no real HTTP request or running server involved.
pub type AuthConfig {
  AuthConfig(
    storage: store.Backend,
    token_mint_secret: option.Option(String),
    token_mint_user_id: String,
    token_mint_user_name: String,
    admin_key: String,
    /// GitHub OAuth App credentials/callback for the admin session — see
    /// `floodgate/oauth.build_config` for how (and when) these are validated.
    github: oauth.GitHubConfig,
    /// The CSRF-state actor backing `/auth/github`'s two-phase flow.
    oauth_state: process.Subject(oauth_state.Msg),
    /// `FLOODGATE_ADMIN_GITHUB_USERS`, parsed — see
    /// `admin_auth.github_login_allowed` for the allow-list decision.
    admin_github_users: option.Option(List(String)),
    /// Admin session lifetime, from `FLOODGATE_ADMIN_SESSION_TTL_SECONDS`.
    admin_session_ttl_seconds: Int,
    /// Directory the shared `levee_admin` Lustre SPA's build output (and its
    /// `index.html`) is served from — `FLOODGATE_ADMIN_STATIC_DIR`.
    admin_static_dir: String,
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
    "ets" | "shelf" -> Ok(shelf_store.supervised(storage_data_dir()))
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
    shelf_store.supervised(storage_data_dir()),
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
    // The values beryl already defaults to, made explicit and overridable.
    // The sweep they drive is what reclaims a socket whose process died without
    // a clean close, or whose peer stopped answering pings while the TCP
    // connection stayed open — its stale RSN would otherwise pin the document's
    // MSN and block summarization for everyone else on it.
    |> beryl.with_heartbeat(
      interval_ms: positive_env("FLOODGATE_HEARTBEAT_INTERVAL_MS", 30_000),
      timeout_ms: positive_env("FLOODGATE_HEARTBEAT_TIMEOUT_MS", 60_000),
    )
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
  // `channels` is valid before the tree starts (it is a named handle), which is
  // what lets the `on_diff` callback below capture it while still building the
  // config that starts presence.
  let channels = beryl_supervisor.channels(supervised)
  // Server-backed presence (`presence_v1`).
  //
  // `diff_topics` has to be iterated rather than assuming one: `diff_joins` and
  // `diff_leaves` are per-topic in the pinned beryl, so a diff spanning two
  // documents would otherwise fan the wrong entries out to both.
  let presence_name = presence_worker.new_name()
  let supervised =
    supervised
    |> beryl_supervisor.with_presence(
      presence.default_config(presence_replica())
      |> presence_replication
      |> presence.with_on_diff(fn(diff) {
        presence.diff_topics(diff)
        |> list.each(fn(topic) {
          beryl.broadcast_presence_diff(channels, topic, diff)
        })
      }),
    )
  let assert Some(presence_handle) = beryl_supervisor.presence(supervised)
  // Sequence state lives in one actor per document, under the registry owner
  // and factory this child spec pairs. Supervising them matters because an
  // unsupervised registry owner left every `process.call` from every channel
  // timing out with nothing to restart it, i.e. permanent service death. The
  // owner's name is allocated before the tree starts so the channel below can be
  // registered with a handle that stays valid across restarts — and it doubles
  // as the name of the registry's ETS table.
  let session_name = session.new_name()
  let sess = session.from_name(session_name, storage)
  // The channel needs the handle `register` returns, to push a targeted
  // signal to one socket via `beryl.send_info` — but `register` takes the
  // channel, so the handle cannot exist at construction. The holder closes
  // that loop: built first, filled in immediately after. Discarding the
  // result here is what left signal targeting unimplementable.
  //
  // Built before the tree starts because the presence worker is *in* the tree
  // and its push callback closes over the holder.
  let registration = document_channel.new_registration()
  case
    static_supervisor.new(static_supervisor.OneForOne)
    // The backend's own processes come first: the session actor's `store.open`
    // and its lazy rehydration both call into storage, so storage has to be up
    // before it.
    |> store.supervise(storage)
    |> static_supervisor.add(beryl_supervisor.start(supervised))
    |> static_supervisor.add(session.child_spec(session_name, storage))
    |> static_supervisor.add(
      presence_worker.child_spec(
        presence_name,
        presence_handle,
        fn(socket_id, topic, event, payload) {
          document_channel.push_event(
            registration,
            socket_id,
            topic,
            event,
            payload,
          )
        },
      ),
    )
    |> static_supervisor.start()
  {
    Ok(_) -> {
      // Idempotent: creates the tenant if this is the first boot against
      // `storage` (or the memory backend, which never has one yet), leaves it
      // untouched if a previous boot (or the admin API) already registered it.
      // See `store.ensure_startup_tenant` for why this preserves existing
      // deployments across a persistent restart.
      store.ensure_startup_tenant(storage, configured_tenant, jwt_secret)
      let _ =
        beryl.register(
          channels,
          "document:*",
          document_channel.new(
            channels,
            sess,
            registration,
            presence_worker.from_name(presence_name),
          ),
        )
        |> result.map(document_channel.set_registration(registration, _))
      Ok(#(channels, sess))
    }
    Error(e) -> Error(beryl_error.from_actor_start_error(e))
  }
}

/// The replica id beryl's presence CRDT gossips under.
///
/// The node name, not a random per-boot id: beryl re-incarnates a *known*
/// replica on restart and prunes its previous incarnation's entries, whereas a
/// fresh id every boot would leave the old replica's sessions in every peer's
/// CRDT with no tombstone ever arriving to clear them.
fn presence_replica() -> String {
  node.self() |> node.name |> atom.to_string
}

/// Replicate presence across the cluster — but only when there *is* a cluster.
///
/// Gossip is peer-to-peer over a pg scope, so on an undistributed VM the only
/// peers it can ever reach are other Floodgate runtimes inside the same OS
/// process. Those are not cluster peers: they share this node's name, so they
/// share its replica id, and beryl's CRDT would merge their independent
/// documents into one another's state under a single identity. That is never
/// what a single-node deployment wants, and it is exactly what made two runtimes
/// in one test VM clobber each other's rosters.
///
/// Nothing is lost by leaving it off: `on_diff` fires for local track and
/// untrack whether or not PubSub is configured, so single-node presence is fully
/// live. A distributed node has a real name, distinct from its peers', and turns
/// replication on by having one.
fn presence_replication(config: presence.Config) -> presence.Config {
  case presence_replica() {
    "nonode@nohost" -> config
    _ ->
      presence.with_pubsub(
        config,
        pubsub.start(pubsub.config_with_scope("floodgate_presence")),
      )
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
  serve_with_backend(port, shelf_store.supervised(storage_data_dir()))
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
      let public_url =
        getenv(
          "FLOODGATE_PUBLIC_URL",
          "http://localhost:" <> int.to_string(port),
        )
      // The oauth-state actor is deliberately outside `start_with_backend`'s
      // supervision tree (see `floodgate/oauth_state`'s module doc): it is
      // ephemeral, request-scoped CSRF bookkeeping, not storage, and keeping
      // it separate means adding it never changes `start_with_backend`'s
      // return shape, which callers (including every existing test) already
      // destructure positionally.
      let oauth_state_name = oauth_state.new_name()
      let assert Ok(_) =
        static_supervisor.new(static_supervisor.OneForOne)
        |> static_supervisor.add(oauth_state.child_spec(oauth_state_name))
        |> static_supervisor.start()
      let config =
        AuthConfig(
          storage,
          token_mint_secret,
          getenv("FLOODGATE_TOKEN_MINT_USER_ID", "floodgate-token-mint"),
          getenv("FLOODGATE_TOKEN_MINT_USER_NAME", "Floodgate Token Mint"),
          getenv("FLOODGATE_ADMIN_KEY", ""),
          oauth.GitHubConfig(
            client_id: getenv("FLOODGATE_GITHUB_CLIENT_ID", ""),
            client_secret: getenv("FLOODGATE_GITHUB_CLIENT_SECRET", ""),
            // Falls back to the already-configured public URL rather than
            // requiring a third, usually-identical variable — see
            // FLOODGATE_GITHUB_REDIRECT_URI in the README if a deployment
            // fronts Floodgate at a different host for the OAuth callback.
            redirect_uri: case getenv("FLOODGATE_GITHUB_REDIRECT_URI", "") {
              "" -> public_url <> "/auth/github/callback"
              explicit -> explicit
            },
          ),
          process.named_subject(oauth_state_name),
          admin_auth.parse_allowlist(getenv("FLOODGATE_ADMIN_GITHUB_USERS", "")),
          positive_env(
            "FLOODGATE_ADMIN_SESSION_TTL_SECONDS",
            admin_auth.default_session_ttl_seconds,
          ),
          getenv("FLOODGATE_ADMIN_STATIC_DIR", "priv/static/admin"),
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
    // Static admin UI: the shared `server/levee_admin` Lustre SPA, served
    // from FLOODGATE_ADMIN_STATIC_DIR — see `floodgate/static` for the
    // file-serving + SPA-fallback contract.
    method, ["admin", ..path_parts]
      if method == http.Get || method == http.Head
    -> static.serve(config.admin_static_dir, path_parts)
    // GitHub OAuth for the admin session — see `floodgate/oauth`.
    http.Get, ["auth", "github"] -> oauth_begin_response(config, req)
    http.Get, ["auth", "github", "callback"] ->
      oauth_callback_response(config, public_url, req)
    // Auth API the admin UI expects (`server/levee_admin/src/levee_admin/api.gleam`):
    // a capability flag the login page uses to hide its dead password form
    // under Floodgate, and the session endpoints OAuth callback sessions use.
    http.Get, ["api", "auth", "config"] -> auth_config_response()
    http.Get, ["api", "auth", "me"] ->
      case session_user(req, config) {
        Error(_) -> session_unauthorized()
        Ok(user) -> me_response(user)
      }
    http.Post, ["api", "auth", "logout"] ->
      case session_token(req) {
        Error(_) -> session_unauthorized()
        Ok(token) ->
          case store.get_admin_session(config.storage, token) {
            Error(_) -> session_unauthorized()
            Ok(_) -> {
              store.delete_admin_session(config.storage, token)
              logout_response(public_url)
            }
          }
      }
    http.Post, ["api", "tenants", tenant, "token-mint"] ->
      token_mint_response(config, req, tenant)
    // Tenant management API: the minimum surface the Lustre admin UI needs
    // (`server/levee_admin/src/levee_admin/api.gleam`), gated by
    // FLOODGATE_ADMIN_KEY rather than the session auth levee uses — see
    // `authorize_admin`.
    http.Get, ["api", "tenants"] ->
      case authorize_admin(req, config) {
        Error(_) -> admin_unauthorized()
        Ok(_) -> tenants_list_response(storage)
      }
    http.Post, ["api", "tenants"] ->
      case authorize_admin(req, config) {
        Error(_) -> admin_unauthorized()
        Ok(_) -> tenant_create_response(storage, read_body(req))
      }
    method, ["api", "tenants", id]
      if method == http.Get || method == http.Delete
    ->
      case authorize_admin(req, config) {
        Error(_) -> admin_unauthorized()
        Ok(_) ->
          case method {
            http.Get -> tenant_show_response(storage, id)
            _ -> tenant_delete_response(storage, id)
          }
      }
    http.Post, ["api", "tenants", id, "secrets", slot] ->
      case authorize_admin(req, config) {
        Error(_) -> admin_unauthorized()
        Ok(_) -> tenant_regenerate_secret_response(storage, id, slot)
      }
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
        // The Historian routes are tenant-scoped, but objects are stored per
        // document — the document comes from the token the caller already had
        // to present. See `git.create`.
        Ok(claims) -> {
          let document_topic = topic(tenant, claims.document_id)
          let body = read_body(req)
          case git.create(storage, document_topic, kind, body) {
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
                  case git.fetch(storage, document_topic, sha) {
                    Error(_) -> bad_request()
                    Ok(data) ->
                      case
                        git.object_response(
                          storage,
                          public_url,
                          tenant,
                          document_topic,
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
      // Authorize *before* touching storage. The fetch used to be evaluated as
      // part of the case subject, so an unauthenticated request still did the
      // read; now the document is only opened once the caller has proved which
      // document its token is for.
      case authorize_storage_read(req, config, tenant) {
        Error(e) -> auth_error_response(e)
        Ok(claims) -> {
          let document_topic = topic(tenant, claims.document_id)
          case git.fetch(storage, document_topic, sha) {
            Error(_) -> not_found()
            Ok(data) -> {
              let query =
                uri.parse_query(req.query |> option_unwrap)
                |> result_unwrap_list
              let recursive = case list.key_find(query, "recursive") {
                Ok("1") -> True
                _ -> False
              }
              case
                git.object_response(
                  storage,
                  public_url,
                  tenant,
                  document_topic,
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
    store.get_tenant_secrets(config.storage, tenant),
    config.token_mint_secret,
    request.get_header(req, "authorization")
  {
    Error(Nil), _, _ -> unauthorized()
    _, None, _ -> not_found()
    _, _, Error(_) -> unauthorized()
    Ok(#(secret1, _secret2)), Some(mint_secret), Ok(authorization) ->
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
                      // Mint with the primary slot; verification tries both —
                      // see `authorize_topic_token`/the `authorize_*` REST
                      // helpers below.
                      secret1,
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

/// The `Authorization` header plus the tenant lookup every `authorize_*`
/// function below shares: an unregistered tenant is reported as
/// `auth.UnknownTenant` (401, same as every other rejection — see
/// `auth_error_status`), a missing header as `auth.MissingAuthorization`.
/// Returns both active secret slots alongside the header, so callers can
/// verify against either — see `auth.verify_any` and its `_any` siblings.
fn tenant_secrets_and_header(
  req: request.Request(mist.Connection),
  storage: store.Backend,
  tenant: String,
) -> Result(#(String, List(String)), auth.AuthError) {
  case
    store.get_tenant_secrets(storage, tenant),
    request.get_header(req, "authorization")
  {
    Error(Nil), _ -> Error(auth.UnknownTenant(tenant))
    _, Error(_) -> Error(auth.MissingAuthorization)
    Ok(#(secret1, secret2)), Ok(authorization) ->
      Ok(#(authorization, [secret1, secret2]))
  }
}

/// Write authorization for `POST /documents/:tenant`, which has no document id
/// in its path. See `auth.verify_tenant_write_authorization`.
fn authorize_tenant_write(
  req: request.Request(mist.Connection),
  config: AuthConfig,
  tenant: String,
) {
  use #(authorization, secrets) <- result.try(tenant_secrets_and_header(
    req,
    config.storage,
    tenant,
  ))
  auth.verify_tenant_write_authorization_any(
    authorization,
    secrets,
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
  use #(authorization, secrets) <- result.try(tenant_secrets_and_header(
    req,
    config.storage,
    tenant,
  ))
  auth.verify_write_authorization_any(
    authorization,
    secrets,
    tenant,
    doc,
    now_seconds(),
  )
}

fn authorize_read(
  req: request.Request(mist.Connection),
  config: AuthConfig,
  tenant: String,
  doc: String,
) {
  use #(authorization, secrets) <- result.try(tenant_secrets_and_header(
    req,
    config.storage,
    tenant,
  ))
  auth.verify_read_authorization_any(
    authorization,
    secrets,
    tenant,
    doc,
    now_seconds(),
  )
}

fn authorize_storage_read(
  req: request.Request(mist.Connection),
  config: AuthConfig,
  tenant: String,
) {
  use #(authorization, secrets) <- result.try(tenant_secrets_and_header(
    req,
    config.storage,
    tenant,
  ))
  auth.verify_storage_read_authorization_any(
    authorization,
    secrets,
    tenant,
    now_seconds(),
  )
}

fn authorize_storage_write(
  req: request.Request(mist.Connection),
  config: AuthConfig,
  tenant: String,
) {
  use #(authorization, secrets) <- result.try(tenant_secrets_and_header(
    req,
    config.storage,
    tenant,
  ))
  auth.verify_storage_write_authorization_any(
    authorization,
    secrets,
    tenant,
    now_seconds(),
  )
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
    Ok(claims) -> {
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
          // The ref lookup above stays tenant-scoped — refs are shared — but
          // the commit objects it points at live in the token's document.
          git.commit_history_response(
            storage,
            public_url,
            tenant,
            topic(tenant, claims.document_id),
            sha,
            count,
          )
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
        document_topic,
        body,
        now_seconds(),
      )
    })
  {
    session.AlreadyExists -> conflict()
    session.InvalidInitialSummary -> bad_request()
    session.Created -> {
      // The session has the summary pointer committed; publish the ref that
      // mirrors it. Deliberately after, not during `initial_summary.persist`, so
      // a crash can only leave the ref lagging rather than pointing at a summary
      // the session does not know it accepted.
      let #(handle, _sn) = session.summary(sess, document_topic)
      case handle {
        "" -> Nil
        _ -> git.publish_summary_ref(session.storage(sess), tenant, doc, handle)
      }
      create_response(doc, tenant, public_url, enable_discovery(body))
      |> json.to_string
      |> json_response(201)
    }
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
    auth.UnknownTenant(tenant) -> "Unknown tenant '" <> tenant <> "'"
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

// ─────────────────────────────────────────────────────────────────────────────
// Tenant management API
//
// The minimum surface the Lustre admin UI's `levee_admin/api.gleam` needs:
// GET/POST /api/tenants, GET/DELETE /api/tenants/:id,
// POST /api/tenants/:id/secrets/:slot. Response shapes match what its
// decoders expect exactly (`tenant_decoder`, `tenant_with_secrets_decoder`,
// `tenant_list_decoder`, `regenerate_response_decoder`,
// `delete_response_decoder`) — including that `GET /api/tenants/:id` returns
// both secrets, same as levee's `TenantAdminController.show/2`, while the list
// endpoint never does.
// ─────────────────────────────────────────────────────────────────────────────

/// Bearer + constant-time comparison against FLOODGATE_ADMIN_KEY, mirroring
/// levee's `Plugs.AdminAuth`. An unset or empty admin key rejects every
/// request, so the tenant management API is opt-in rather than exposed by
/// default on existing deployments.
fn authorize_admin(
  req: request.Request(mist.Connection),
  config: AuthConfig,
) -> Result(Nil, Nil) {
  case
    admin_credentials_authorized(
      request.get_header(req, "authorization"),
      list.key_find(request.get_cookies(req), admin_session_cookie_name),
      config.admin_key,
      config.storage,
      now_seconds(),
    )
  {
    True -> Ok(Nil)
    False -> Error(Nil)
  }
}

/// Authorize either the automation key, a bearer admin session, or the
/// HttpOnly admin-session cookie. Explicit credentials and clock keep this
/// decision directly testable without a live HTTP server.
pub fn admin_credentials_authorized(
  authorization: Result(String, Nil),
  session_cookie: Result(String, Nil),
  admin_key: String,
  storage: store.Backend,
  now: Int,
) -> Bool {
  let header_authorized = case authorization {
    Error(_) -> False
    Ok(value) ->
      case admin_key {
        "" -> admin_session_header_authorized(value, storage, now)
        key ->
          case auth.verify_admin_authorization(value, key) {
            Ok(_) -> True
            Error(_) -> admin_session_header_authorized(value, storage, now)
          }
      }
  }
  case header_authorized, session_cookie {
    True, _ -> True
    False, Ok(token) -> admin_session_token_authorized(token, storage, now)
    False, Error(_) -> False
  }
}

fn admin_session_header_authorized(
  authorization: String,
  storage: store.Backend,
  now: Int,
) -> Bool {
  case auth.extract_token(authorization) {
    Error(_) -> False
    Ok(token) -> admin_session_token_authorized(token, storage, now)
  }
}

fn admin_session_token_authorized(
  token: String,
  storage: store.Backend,
  now: Int,
) -> Bool {
  case store.get_admin_session(storage, token) {
    Error(_) -> False
    Ok(session) ->
      admin_auth.session_valid(session, now)
      && { store.get_admin_user(storage, session.user_id) |> result.is_ok }
  }
}

/// Shape of every admin API error, matching levee's
/// `%{error: %{code:, message:}}`.
fn admin_error(code: String, message: String, status: Int) {
  json.object([
    #(
      "error",
      json.object([
        #("code", json.string(code)),
        #("message", json.string(message)),
      ]),
    ),
  ])
  |> json.to_string
  |> json_response(status)
}

fn admin_unauthorized() {
  admin_error("unauthorized", "Invalid admin key", 401)
}

fn admin_not_found() {
  admin_error("not_found", "Tenant not found", 404)
}

// ─────────────────────────────────────────────────────────────────────────────
// Admin auth API — the session/OAuth surface the Lustre admin UI expects
// (`server/levee_admin/src/levee_admin/api.gleam`): GET /api/auth/config,
// GET /api/auth/me, POST /api/auth/logout, plus the GitHub OAuth entry and
// callback the login page's "Sign in with GitHub" button navigates to. See
// `floodgate/oauth`, `floodgate/oauth_state`, and `floodgate/admin_auth` for
// the OAuth exchange, CSRF-state, and user/session/allow-list logic this
// composes.
// ─────────────────────────────────────────────────────────────────────────────

/// The admin session cookie's name. Floodgate keeps this credential HttpOnly;
/// the shared SPA probes `/api/auth/me` and uses same-origin cookies when no
/// Levee bearer token exists.
const admin_session_cookie_name = "floodgate_admin_session"

/// `Result(user, Nil)` for a request carrying either a valid authorization
/// header (what the admin UI actually sends — see its `api.gleam`) or the
/// admin session cookie. The header takes precedence when both are present.
pub fn session_user(
  req: request.Request(mist.Connection),
  config: AuthConfig,
) -> Result(admin_auth.AdminUser, Nil) {
  use token <- result.try(session_token(req))
  use session <- result.try(
    store.get_admin_session(config.storage, token) |> result.replace_error(Nil),
  )
  case admin_auth.session_valid(session, now_seconds()) {
    False -> Error(Nil)
    True -> store.get_admin_user(config.storage, session.user_id)
  }
}

/// Extract the admin session id from a request: the authorization header
/// first, falling back to the admin session cookie.
fn session_token(req: request.Request(mist.Connection)) -> Result(String, Nil) {
  case request.get_header(req, "authorization") {
    Ok(authorization) ->
      auth.extract_token(authorization) |> result.replace_error(Nil)
    Error(_) ->
      list.key_find(request.get_cookies(req), admin_session_cookie_name)
  }
}

fn session_unauthorized() {
  admin_error("unauthorized", "Invalid or expired session", 401)
}

fn me_response(user: admin_auth.AdminUser) {
  json.object([#("user", admin_user_json(user))])
  |> json.to_string
  |> json_response(200)
}

/// Matches the admin UI's `user_decoder` (`id`, `email`, `display_name`,
/// `created_at`) exactly, plus `github_username`/`is_admin` for callers that
/// want them — extra JSON fields are simply ignored by that decoder.
/// Floodgate has no non-admin role (see `admin_auth.AdminUser`'s doc
/// comment), so `is_admin` is always `true`.
fn admin_user_json(user: admin_auth.AdminUser) -> json.Json {
  json.object([
    #("id", json.string(user.id)),
    #("email", json.string(user.email)),
    #("display_name", json.string(user.display_name)),
    #("github_username", json.string(user.github_username)),
    #("is_admin", json.bool(True)),
    #("created_at", json.int(user.created_at)),
  ])
}

fn logout_response(public_url: String) {
  json.object([#("message", json.string("logged out"))])
  |> json.to_string
  |> json_response(200)
  |> clear_admin_session_cookie(public_url)
}

/// Floodgate never implements password registration/login (no use for it —
/// GitHub OAuth is the only sign-in path), so this is a constant rather than
/// a real capability check. The admin UI's login page reads it to hide its
/// password form and "Register" link and present GitHub OAuth only, while
/// leaving Levee's own login page — which reports `true` — unchanged.
fn auth_config_response() {
  json.object([#("password_auth", json.bool(False))])
  |> json.to_string
  |> json_response(200)
}

fn oauth_begin_response(
  config: AuthConfig,
  req: request.Request(mist.Connection),
) {
  let _ = req
  case oauth.begin_auth(config.github, config.oauth_state, now_seconds()) {
    Ok(url) -> redirect_response(url)
    Error(oauth.ConfigMissing(_variable)) -> {
      oauth_error_response(
        500,
        "oauth_not_configured",
        "OAuth is not configured",
      )
    }
    Error(_err) -> {
      oauth_error_response(500, "oauth_error", "Failed to start authentication")
    }
  }
}

fn oauth_callback_response(
  config: AuthConfig,
  public_url: String,
  req: request.Request(mist.Connection),
) {
  let query = uri.parse_query(req.query |> option_unwrap) |> result_unwrap_list
  case list.key_find(query, "state") {
    Error(_) ->
      oauth_error_response(
        401,
        "state_invalid",
        "Authentication failed, please try again",
      )
    Ok(state) -> {
      let params = dict.from_list(query)
      case
        oauth.complete_auth(
          config.github,
          config.oauth_state,
          params,
          state,
          now_seconds(),
        )
      {
        Ok(auth_result) ->
          handle_successful_auth(config, public_url, auth_result)
        Error(oauth.StateInvalid) ->
          oauth_error_response(
            401,
            "state_invalid",
            "Authentication failed, please try again",
          )
        Error(oauth.ConfigMissing(_variable)) -> {
          oauth_error_response(
            500,
            "oauth_not_configured",
            "OAuth is not configured",
          )
        }
        Error(oauth.VestibuleError(vestibule_error.UserInfoFailed(_))) ->
          oauth_error_response(
            502,
            "provider_error",
            "Could not fetch profile from provider",
          )
        Error(oauth.VestibuleError(vestibule_error.ProviderError(
          code,
          description,
          _uri,
        ))) -> {
          let message = case description {
            "" -> code
            _ -> description
          }
          oauth_error_response(401, "oauth_failed", message)
        }
        Error(oauth.VestibuleError(_err)) -> {
          oauth_error_response(
            401,
            "auth_failed",
            "Authentication failed, please try again",
          )
        }
      }
    }
  }
}

/// Find-or-create the admin user for a successful GitHub login, apply the
/// allow-list decision (`admin_auth.github_login_allowed`), and —
/// if allowed — create a session and redirect to `/admin`. Denied logins
/// redirect back to `/admin` with an error indicator rather than creating any
/// session or user record. Public (and taking the resolved `Auth` value
/// rather than doing the exchange itself) so the find-or-create/allow-list
/// composition is directly testable without a real OAuth round trip.
pub fn handle_successful_auth(
  config: AuthConfig,
  public_url: String,
  auth_result: vestibule_auth.Auth,
) {
  let github_id = auth_result.uid
  let info = auth_result.info
  let github_username = option.unwrap(info.nickname, "")
  let display_name = case info.name {
    Some(name) -> name
    None -> github_username
  }
  let email = option.unwrap(info.email, "")
  let now = now_seconds()
  case
    find_or_create_admin_user(
      config,
      github_id,
      github_username,
      display_name,
      email,
      now,
    )
  {
    Error(Nil) -> redirect_response(admin_url_with_error("not_authorized"))
    Ok(user) -> {
      let session =
        admin_auth.new_admin_session(
          user.id,
          now,
          config.admin_session_ttl_seconds,
        )
      store.put_admin_session(config.storage, session)
      redirect_response("/admin")
      |> set_admin_session_cookie(public_url, session, config)
    }
  }
}

/// Look up (or, if allowed, create) the `AdminUser` for a GitHub identity —
/// the composition of `store.get_admin_user`/`put_admin_user` and
/// `admin_auth.github_login_allowed`/`new_admin_user` the OAuth callback
/// needs. `Error(Nil)` means the identity is not — and, with no admin yet and
/// no allow-list, cannot become — an admin.
pub fn find_or_create_admin_user(
  config: AuthConfig,
  github_id: String,
  github_username: String,
  display_name: String,
  email: String,
  now: Int,
) -> Result(admin_auth.AdminUser, Nil) {
  case store.get_admin_user(config.storage, github_id) {
    Ok(user) -> Ok(user)
    Error(Nil) -> {
      case
        admin_auth.github_login_allowed(
          github_username,
          config.admin_github_users,
          False,
          store.admin_user_count(config.storage) > 0,
        )
      {
        False -> Error(Nil)
        True -> {
          let user =
            admin_auth.new_admin_user(
              github_id,
              github_username,
              display_name,
              email,
              now,
            )
          store.put_admin_user(config.storage, user)
          Ok(user)
        }
      }
    }
  }
}

fn oauth_error_response(status: Int, code: String, message: String) {
  admin_error(code, message, status)
}

/// A relative, fixed `/admin`-only redirect target — deliberately never a
/// request- or cookie-supplied URL (see the module doc). Avoids the open-
/// redirect class of bug entirely, rather than needing to validate one.
fn admin_url_with_error(code: String) -> String {
  "/admin?error=" <> code
}

fn redirect_response(location: String) {
  response.new(302)
  |> response.set_header("location", location)
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}

/// The response's scheme, from `public_url` — determines whether the admin
/// session cookie gets the `Secure` attribute (see `cookie.defaults`).
fn public_url_scheme(public_url: String) -> http.Scheme {
  case uri.parse(public_url) {
    Ok(uri.Uri(scheme: Some("https"), ..)) -> http.Https
    _ -> http.Http
  }
}

/// Set the admin session cookie on a response: HttpOnly, SameSite=Lax always;
/// Secure when `public_url` is HTTPS; Path=/ (it authorizes both
/// `/api/auth/*` and `/api/tenants/*`); Max-Age matching the session's
/// remaining lifetime, so the browser expires it in step with the server.
fn set_admin_session_cookie(
  resp,
  public_url: String,
  session: admin_auth.AdminSession,
  config: AuthConfig,
) {
  let attrs =
    cookie.Attributes(
      ..cookie.defaults(public_url_scheme(public_url)),
      max_age: Some(config.admin_session_ttl_seconds),
    )
  response.set_cookie(resp, admin_session_cookie_name, session.id, attrs)
}

fn clear_admin_session_cookie(resp, public_url: String) {
  response.expire_cookie(
    resp,
    admin_session_cookie_name,
    cookie.defaults(public_url_scheme(public_url)),
  )
}

/// `{id, name}` — the list-endpoint shape, matching `api.gleam`'s
/// `tenant_decoder`. Never carries secrets.
pub fn tenant_info_json(tenant: store.TenantInfo) -> json.Json {
  json.object([
    #("id", json.string(tenant.id)),
    #("name", json.string(tenant.name)),
  ])
}

/// `{id, name, secret1, secret2}` — the create/show shape, matching
/// `api.gleam`'s `tenant_with_secrets_decoder`.
pub fn tenant_with_secrets_json(tenant: store.TenantWithSecrets) -> json.Json {
  json.object([
    #("id", json.string(tenant.id)),
    #("name", json.string(tenant.name)),
    #("secret1", json.string(tenant.secret1)),
    #("secret2", json.string(tenant.secret2)),
  ])
}

fn tenants_list_response(storage: store.Backend) {
  json.object([
    #(
      "tenants",
      json.preprocessed_array(list.map(
        store.list_tenants(storage),
        tenant_info_json,
      )),
    ),
  ])
  |> json.to_string
  |> json_response(200)
}

/// The `{"name": "..."}` request body `POST /api/tenants` sends.
pub fn decode_tenant_name(body: String) -> Result(String, Nil) {
  json.parse(body, decode.field("name", decode.string, decode.success))
  |> result.replace_error(Nil)
}

fn tenant_create_response(storage: store.Backend, body: String) {
  case decode_tenant_name(body) {
    Error(_) -> admin_error("missing_fields", "Required: name", 422)
    Ok(name) ->
      json.object([
        #(
          "tenant",
          tenant_with_secrets_json(store.create_tenant(storage, name)),
        ),
      ])
      |> json.to_string
      |> json_response(201)
  }
}

fn tenant_show_response(storage: store.Backend, id: String) {
  case store.get_tenant(storage, id), store.get_tenant_secrets(storage, id) {
    Ok(info), Ok(#(secret1, secret2)) ->
      json.object([
        #(
          "tenant",
          tenant_with_secrets_json(store.TenantWithSecrets(
            id: info.id,
            name: info.name,
            secret1: secret1,
            secret2: secret2,
          )),
        ),
      ])
      |> json.to_string
      |> json_response(200)
    _, _ -> admin_not_found()
  }
}

fn tenant_delete_response(storage: store.Backend, id: String) {
  case store.tenant_exists(storage, id) {
    False -> admin_not_found()
    True -> {
      // Deliberately narrow — see `store.unregister_tenant`: this does not
      // cascade to the tenant's documents, matching levee's
      // `unregister_tenant/1`.
      store.unregister_tenant(storage, id)
      json.object([#("message", json.string("Tenant unregistered"))])
      |> json.to_string
      |> json_response(200)
    }
  }
}

/// Parse a `POST /api/tenants/:id/secrets/:slot` path segment. Only `"1"` and
/// `"2"` are valid — anything else, including `"01"` or `"3"`, is rejected the
/// same way levee's `Integer.parse/1` guard rejects them.
pub fn parse_tenant_slot(slot: String) -> Result(store.TenantSlot, Nil) {
  case slot {
    "1" -> Ok(store.Slot1)
    "2" -> Ok(store.Slot2)
    _ -> Error(Nil)
  }
}

fn tenant_regenerate_secret_response(
  storage: store.Backend,
  id: String,
  slot: String,
) {
  case parse_tenant_slot(slot) {
    Error(_) -> admin_error("invalid_slot", "Slot must be 1 or 2", 400)
    Ok(slot) ->
      case store.regenerate_tenant_secret(storage, id, slot) {
        Error(_) -> admin_not_found()
        Ok(secret) ->
          json.object([#("secret", json.string(secret))])
          |> json.to_string
          |> json_response(200)
      }
  }
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
  store.topic(tenant, doc)
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

pub const topic_prefix = store.topic_prefix

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
