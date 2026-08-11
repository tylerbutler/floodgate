//// Fluid document channel — connect_document join, submitOp shared sequencing
//// + op fan-out (with contents), nack, submitSignal fan-out, requestOps delta
//// catch-up. Gleam analogue of levee's DocumentChannel.

import beryl.{type RegisteredChannel}
import beryl/channel.{type Channel, JoinError, JoinOk, NoReply, Push}
import beryl/socket.{type Socket}
import dewdrop/events
import floodgate/auth
import floodgate/git
import floodgate/presence_worker
import floodgate/session.{type Session}
import floodgate/store
import gleam/bool
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import signet/types.{type TokenClaims}
import spillway/connect_document
import spillway/session_logic
import spillway/signals

pub type DocAssigns {
  DocAssigns(
    client_id: String,
    mode: session.Mode,
    topic: String,
    scopes: List(String),
    connected: Bool,
    /// The token's verified user id, and the presence key derived from it.
    ///
    /// Deliberately not read back off the session roster: `connect_core` prefers
    /// the peer's *own* supplied `IClient` when it sent one, so the roster value
    /// is client-controlled and a socket could claim another user's presence.
    user_id: String,
  )
}

/// A failed connect. `reason` is the Socket.IO join-error string; `code` and
/// `message` are the Routerlicious-style pair the Phoenix path pushes as
/// `connect_document_error`.
pub type ConnectError {
  ConnectError(reason: String, code: Int, message: String)
}

fn unauthorized(code: Int, message: String) -> ConnectError {
  ConnectError(reason: "unauthorized", code: code, message: message)
}

type SubmittedOp {
  SubmittedOp(
    client_sequence_number: Int,
    reference_sequence_number: Int,
    kind: String,
    contents: Dynamic,
    metadata: option.Option(Dynamic),
    server_metadata: option.Option(Dynamic),
    traces: option.Option(Dynamic),
    compression: option.Option(Dynamic),
  )
}

type SummarizeContents {
  SummarizeContents(
    handle: String,
    message: String,
    parents: List(String),
    head: String,
  )
}

/// Server-originated messages delivered to a single socket's channel context via
/// `beryl.send_info`. Signals with targeting cannot go out as a topic broadcast,
/// so they arrive here instead and are pushed from `handle_info`.
pub type DocInfo {
  SignalPush(payload: json.Json)
  /// Any other server-originated event for one socket. The presence worker uses
  /// it for `presence_state` and `presence_error`, which are per-socket frames
  /// with no reply channel to ride on.
  EventPush(event: String, payload: json.Json)
}

/// Holds the `RegisteredChannel` handle `beryl.send_info` needs.
///
/// The handle only exists *after* `beryl.register` returns, and `register` takes
/// the channel this module builds — so it cannot be passed in at construction.
/// It also cannot live in `session`, because `RegisteredChannel` is opaque and
/// parameterized on `DocAssigns`/`DocInfo`, and `document_channel` already
/// depends on `session`. Hence a holder in this module, written once at startup
/// and read on each targeted signal.
pub opaque type Registration {
  Registration(Subject(RegistrationMsg))
}

type RegistrationMsg {
  Set(RegisteredChannel(DocAssigns, DocInfo))
  Get(Subject(Option(RegisteredChannel(DocAssigns, DocInfo))))
}

/// Allocate an empty holder. Call before `beryl.register`.
pub fn new_registration() -> Registration {
  let assert Ok(started) =
    actor.new(None)
    |> actor.on_message(fn(state, message) {
      case message {
        Set(registered) -> actor.continue(Some(registered))
        Get(reply) -> {
          process.send(reply, state)
          actor.continue(state)
        }
      }
    })
    |> actor.start
  Registration(started.data)
}

/// Record the handle `beryl.register` returned.
pub fn set_registration(
  registration: Registration,
  registered: RegisteredChannel(DocAssigns, DocInfo),
) -> Nil {
  let Registration(subject) = registration
  process.send(subject, Set(registered))
}

fn registered_channel(
  registration: Registration,
) -> Option(RegisteredChannel(DocAssigns, DocInfo)) {
  let Registration(subject) = registration
  process.call(subject, 1000, Get)
}

pub fn new(
  channels: beryl.Channels,
  document_session: Session,
  registration: Registration,
  presence: Subject(presence_worker.Msg),
) -> Channel(DocAssigns, DocInfo) {
  channel.new(fn(topic, payload, sock) {
    join(channels, document_session, topic, payload, sock)
  })
  |> channel.with_handle_in(fn(event, payload, sock) {
    handle_in(
      channels,
      document_session,
      registration,
      presence,
      event,
      payload,
      sock,
    )
  })
  |> channel.with_handle_info(fn(info, sock) {
    case info {
      SignalPush(payload) -> Push(events.signal, payload, sock)
      EventPush(event, payload) -> Push(event, payload, sock)
    }
  })
  |> channel.with_terminate(fn(_reason, sock) {
    on_leave(channels, document_session, presence, sock)
  })
}

/// Push one server-originated event to one socket, out of band. This is the
/// callback `floodgate.start_with_backend` hands the presence worker; the worker
/// cannot call `beryl.send_info` itself because it must not import this module.
pub fn push_event(
  registration: Registration,
  socket_id: String,
  topic: String,
  event: String,
  payload: json.Json,
) -> Nil {
  case registered_channel(registration) {
    None -> Nil
    Some(registered) ->
      beryl.send_info(registered, socket_id, topic, EventPush(event, payload))
  }
}

/// Two wire protocols enter this channel differently. Socket.IO carries the
/// whole `connect_document` payload as the join, so joining and connecting are
/// one step. A Phoenix `phx_join` carries only `{token}` — `mode` and the rest
/// of IConnect arrive later on the `connect_document` event — so the socket
/// joins first and connects in a second phase.
fn join(
  channels: beryl.Channels,
  document_session: Session,
  topic: String,
  payload: Dynamic,
  sock: Socket(DocAssigns),
) -> channel.JoinResult(DocAssigns) {
  let client_id = socket.id(sock)
  case is_connect_payload(payload) {
    True ->
      case connect_core(channels, document_session, topic, payload, client_id) {
        Error(error) -> join_error(error)
        Ok(#(response, assigns)) ->
          JoinOk(
            reply: Some(response),
            socket: socket.set_assigns(sock, assigns),
          )
      }
    False ->
      case
        authorize_topic_token(session.storage(document_session), topic, payload)
      {
        Error(error) -> join_error(error)
        Ok(_claims) ->
          JoinOk(
            reply: None,
            socket: socket.set_assigns(sock, pending_assigns(topic)),
          )
      }
  }
}

/// A Socket.IO join is a `connect_document` payload: it always carries the
/// tenant and document ids (the transport derives the topic from them). Phoenix
/// join params carry only the token.
fn is_connect_payload(payload: Dynamic) -> Bool {
  field(payload, "tenantId", "") != "" && field(payload, "id", "") != ""
}

/// Assigns for a Phoenix socket that has joined but not yet connected. `mode`
/// is never read before `connected` is set — every mode-dependent handler
/// guards on `connected` first — so the placeholder `Read` grants nothing.
fn pending_assigns(topic: String) -> DocAssigns {
  DocAssigns(
    client_id: "",
    mode: session.Read,
    topic: topic,
    scopes: [],
    connected: False,
    user_id: "",
  )
}

fn join_error(error: ConnectError) -> channel.JoinResult(DocAssigns) {
  JoinError(json.object([#("reason", json.string(error.reason))]))
}

fn connect_error_to_json(error: ConnectError) -> json.Json {
  json.object([
    #("code", json.int(error.code)),
    #("message", json.string(error.message)),
  ])
}

/// Authorize, open the session, fan out the join, and build the connected
/// response. Shared by the Socket.IO join and the Phoenix `connect_document`.
fn connect_core(
  channels: beryl.Channels,
  document_session: Session,
  topic: String,
  payload: Dynamic,
  client_id: String,
) -> Result(#(json.Json, DocAssigns), ConnectError) {
  case authorize(session.storage(document_session), topic, payload) {
    Error(error) -> Error(error)
    Ok(claims) -> {
      let mode = connection_mode(payload)
      // Echo the peer's own IClient when it sent one, so the audience sees a
      // single payload for this client id — see `supplied_client_json`.
      let client = case supplied_client_json(payload) {
        Some(supplied) -> supplied
        None -> client_json(mode, claims)
      }
      let session.Connected(
        existing,
        roster,
        initial_ops,
        summary_handle,
        summary_sequence_number,
        current_sequence_number,
        recovery,
        membership,
      ) =
        session.connect(
          document_session,
          topic,
          client_id,
          mode,
          json.to_string(client),
          client_join_data(client_id, client),
          now_seconds() * 1000,
        )
      // `initialSignals` is always empty, matching levee's
      // `build_connected_response`. This used to return the client's own
      // presence-join signal, which closed containers with assert 0x4b2: the
      // container-loader seeds its audience with the IClient object it *sent*
      // (original key order) and `Audience.addMember` demands byte-identity
      // with any later add for the same client id — but every payload this
      // server echoes has been through an Erlang map, which stores keys in
      // term order, so the self add could never match the seed. Peers are
      // unaffected: every copy *they* see is Erlang-map-ordered alike.
      case recovery {
        [] -> Nil
        recovery ->
          beryl.broadcast_from(
            channels,
            client_id,
            topic,
            events.op,
            recovery
              |> list.map(session.stored_message_to_json)
              |> json.preprocessed_array,
          )
      }
      case membership {
        // The joining client receives its own join op in initialMessages.
        // Excluding it from fan-out avoids an early duplicate before the
        // connect response has established its client ID.
        session.Writer(sn, message) ->
          beryl.broadcast_from(
            channels,
            client_id,
            topic,
            events.op,
            json.preprocessed_array([
              session.stored_message_to_json(#(sn, message)),
            ]),
          )
        session.Reader ->
          beryl.broadcast_from(
            channels,
            client_id,
            topic,
            events.signal,
            presence_join(client_id, client),
          )
      }
      Ok(#(
        connected_response(
          claims,
          client_id,
          mode,
          existing,
          roster,
          initial_ops,
          summary_handle,
          summary_sequence_number,
          current_sequence_number,
          beryl.max_inbound_frame_bytes(channels),
        ),
        DocAssigns(
          client_id: client_id,
          mode: mode,
          topic: topic,
          scopes: types.scopes_to_strings(claims.scopes),
          connected: True,
          user_id: claims.user.id,
        ),
      ))
    }
  }
}

fn on_leave(
  channels: beryl.Channels,
  document_session: Session,
  presence: Subject(presence_worker.Msg),
  sock: Socket(DocAssigns),
) -> Nil {
  let assigns = socket.get_assigns(sock)
  // Before the `connected` guard: this is the one funnel every termination
  // reaches — a Socket.IO close, a Phoenix close, a heartbeat-sweep eviction, or
  // an explicit `phx_leave` — and it is what makes a dropped socket stop being
  // present without anyone waiting out a TTL. A no-op for a socket that never
  // tracked, so it is safe to run unconditionally.
  presence_worker.cleanup(presence, assigns.client_id)
  // A Phoenix socket that joined but never sent connect_document holds no
  // session membership, so there is nothing to tear down or announce.
  use <- bool.guard(when: !assigns.connected, return: Nil)
  case assigns.mode {
    session.Write -> {
      let session.Left(sn, _, message) =
        session.leave_sequenced(
          document_session,
          assigns.topic,
          assigns.client_id,
          now_seconds() * 1000,
        )
      beryl.broadcast(
        channels,
        assigns.topic,
        events.op,
        json.preprocessed_array([
          session.stored_message_to_json(#(sn, message)),
        ]),
      )
    }
    session.Read -> {
      session.leave_presence(document_session, assigns.topic, assigns.client_id)
      beryl.broadcast(
        channels,
        assigns.topic,
        events.signal,
        presence_leave(assigns.client_id),
      )
    }
  }
}

fn presence_join(client_id: String, client: json.Json) -> json.Json {
  json.object([
    #("clientId", json.null()),
    #(
      "content",
      json.object([
        #("type", json.string("join")),
        #(
          "content",
          json.object([
            #("clientId", json.string(client_id)),
            #("client", client),
          ]),
        ),
      ])
        |> json.to_string
        |> json.string,
    ),
  ])
}

fn presence_leave(client_id: String) -> json.Json {
  json.object([
    #("clientId", json.null()),
    #(
      "content",
      json.object([
        #("type", json.string("leave")),
        #("content", json.string(client_id)),
      ])
        |> json.to_string
        |> json.string,
    ),
  ])
}

fn unauthenticated_presence() -> json.Json {
  presence_worker.error(
    "unauthenticated",
    "presence requires a completed document connection",
  )
}

/// Read a presence command's metadata and stamp the server's own session id on
/// it, or produce the `presence_error` frame that rejects it.
///
/// Two tiers, and the difference is the point. A server-owned name at the
/// command's *top level* is an attempt to claim another identity, so it is
/// rejected outright; the same name nested inside `meta` is merely smuggled and
/// is stripped. Metadata must be a JSON **object** because the Phoenix `metas`
/// shape puts `phx_ref` and `client_id` alongside the application's own fields,
/// and a scalar or array leaves nowhere to put them.
///
/// `client_id` is added here rather than by beryl: beryl stamps `phx_ref` on
/// every tracked meta but knows nothing of session ids, and watershed reads
/// `client_id` as `PresenceEntry.session_id` — omit it and every session in the
/// roster collapses to the empty string.
pub fn presence_meta(
  payload: Dynamic,
  client_id: String,
) -> Result(json.Json, json.Json) {
  let malformed =
    presence_worker.error(
      "invalid_meta",
      "presence metadata must be a JSON object",
    )
  case decode.run(payload, decode.dict(decode.string, decode.dynamic)) {
    Error(_) -> Error(malformed)
    Ok(fields) ->
      case
        list.any(dict.keys(fields), fn(name) {
          list.contains(presence_worker.reserved_meta_fields, name)
        })
      {
        True ->
          Error(presence_worker.error(
            "invalid_meta",
            "the server owns key, session, and ref; a client cannot set them",
          ))
        False ->
          case dict.get(fields, "meta") {
            Error(Nil) -> Error(malformed)
            Ok(meta) ->
              case
                decode.run(meta, decode.dict(decode.string, decode.dynamic))
              {
                Error(_) -> Error(malformed)
                Ok(meta_fields) ->
                  Ok(
                    json.object([
                      #("client_id", json.string(client_id)),
                      ..meta_fields
                      |> dict.drop(presence_worker.reserved_meta_fields)
                      |> dict.to_list
                      |> list.map(fn(field) {
                        #(field.0, dynamic_to_json(field.1))
                      })
                    ]),
                  )
              }
          }
      }
  }
}

fn client_join_data(client_id: String, client: json.Json) -> String {
  json.object([
    #("clientId", json.string(client_id)),
    #("detail", client),
  ])
  |> json.to_string
}

/// Re-encode a client payload through the same JSON → Erlang map → JSON
/// round-trip that `initialClients` performs when it rebuilds clients from the
/// stored roster.
///
/// `@fluidframework/container-loader`'s audience asserts that a client it
/// already holds and the one carried by that client's sequenced join op
/// serialize to the identical string (assert 0x4b2, "new client has different
/// payload from existing one"). A second client loading a document receives the
/// first in `initialClients` *and* replays its join op from `initialMessages`,
/// so both payloads reach the audience. Erlang maps do not preserve key order,
/// so the roster path reorders keys while a directly-built payload does not —
/// putting every client payload through this same round-trip is what keeps the
/// two byte-identical.
pub fn normalize_client_json(value: json.Json) -> json.Json {
  case json.parse(json.to_string(value), decode.dynamic) {
    Ok(parsed) -> dynamic_to_json(parsed)
    Error(_) -> value
  }
}

/// The `IClient` record the peer sent in its connect payload, if any.
///
/// Levee's `Session.client_join/2` stores `connect_msg["client"]` verbatim and
/// serves that back; the Fluid container meanwhile seeds its audience with the
/// very object it sent. Echoing it is therefore not a nicety — rebuilding the
/// record from `mode` and token claims drops fields the server does not model
/// (`details.environment`, extra `user` fields) and the audience then sees two
/// different payloads for one client id, tripping assert 0x4b2.
///
/// `None` for a Phoenix `phx_join`, which carries only a token.
pub fn supplied_client_json(payload: Dynamic) -> Option(json.Json) {
  case decode.run(payload, decode.at(["client"], decode.dynamic)) {
    Ok(client) ->
      case decode.run(client, decode.dict(decode.string, decode.dynamic)) {
        // Only an object is a usable IClient; anything else falls back to the
        // server-built record.
        Ok(_) -> Some(normalize_client_json(dynamic_to_json(client)))
        Error(_) -> None
      }
    Error(_) -> None
  }
}

fn client_json(mode: session.Mode, claims: TokenClaims) -> json.Json {
  normalize_client_json(raw_client_json(mode, claims))
}

fn raw_client_json(mode: session.Mode, claims: TokenClaims) -> json.Json {
  json.object([
    #("mode", json.string(session.mode_to_string(mode))),
    #(
      "details",
      json.object([
        #("capabilities", json.object([#("interactive", json.bool(True))])),
      ]),
    ),
    #("permission", json.preprocessed_array([])),
    #("scopes", json.array(types.scopes_to_strings(claims.scopes), json.string)),
    #(
      "user",
      json.object([
        #("id", json.string(claims.user.id)),
        #("name", json.string(user_name(claims))),
      ]),
    ),
  ])
}

fn user_name(claims: TokenClaims) -> String {
  case dict.get(claims.user.properties, "name") {
    Ok(name) ->
      decode.run(name, decode.string)
      |> result.unwrap(claims.user.id)
    Error(Nil) -> claims.user.id
  }
}

fn connection_mode(payload: Dynamic) -> session.Mode {
  case field(payload, "mode", "read") {
    "write" -> session.Write
    _ -> session.Read
  }
}

/// Verify the topic names a registered tenant's document and that the payload
/// carries a token granting read access to it, trying that tenant's active
/// secret slots. Shared by both join paths; the Phoenix path stops here
/// because `mode` is not known until connect.
fn authorize_topic_token(
  storage: store.Backend,
  topic: String,
  payload: Dynamic,
) -> Result(TokenClaims, ConnectError) {
  case string.split(topic, ":") {
    ["document", tenant, doc] ->
      case store.get_tenant_secrets(storage, tenant) {
        Error(Nil) ->
          Error(ConnectError(
            reason: "invalid_topic",
            code: 400,
            message: "Topic does not name a document in this tenant",
          ))
        Ok(#(secret1, secret2)) ->
          case
            auth.verify_any(
              field(payload, "token", ""),
              [secret1, secret2],
              tenant,
              doc,
              now_seconds(),
            )
          {
            Error(_) -> Error(unauthorized(401, "Invalid or expired token"))
            Ok(claims) ->
              case
                list.contains(
                  types.scopes_to_strings(claims.scopes),
                  connect_document.read_scope(),
                )
              {
                False ->
                  Error(unauthorized(403, "Token lacks document read scope"))
                True -> Ok(claims)
              }
          }
      }
    _ ->
      Error(ConnectError(
        reason: "invalid_topic",
        code: 400,
        message: "Topic does not name a document in this tenant",
      ))
  }
}

fn authorize(
  storage: store.Backend,
  topic: String,
  payload: Dynamic,
) -> Result(TokenClaims, ConnectError) {
  use claims <- result.try(authorize_topic_token(storage, topic, payload))
  case decode.run(payload, decode.dict(decode.string, decode.dynamic)) {
    Error(_) ->
      Error(ConnectError(
        reason: "unauthorized",
        code: 400,
        message: "Malformed connect_document payload",
      ))
    Ok(fields) ->
      case
        connect_document.validate_mode_scope(
          fields,
          types.scopes_to_strings(claims.scopes),
        )
      {
        Error(_) ->
          Error(unauthorized(403, "Write mode requires document write scope"))
        Ok(_) -> Ok(claims)
      }
  }
}

fn connected_response(
  claims: TokenClaims,
  client_id: String,
  mode: session.Mode,
  existing: Bool,
  roster: List(#(String, String)),
  initial_ops: List(#(Int, String)),
  summary_handle: String,
  summary_sequence_number: Int,
  current_sequence_number: Int,
  max_message_size: Int,
) -> json.Json {
  json.object([
    #("claims", claims_to_json(claims)),
    #("clientId", json.string(client_id)),
    #("existing", json.bool(existing)),
    // Sourced from beryl's configured frame ceiling rather than hardcoded, so
    // what we advertise is what the transports actually enforce. This used to
    // claim 16 MiB while beryl's default enforced 1 MiB and the Engine.IO
    // handshake advertised 1 MiB — three numbers, one of them a fiction.
    #("maxMessageSize", json.int(max_message_size)),
    #("mode", json.string(session.mode_to_string(mode))),
    #(
      "serviceConfiguration",
      json.object([
        #("blockSize", json.int(64 * 1024)),
        #("maxMessageSize", json.int(max_message_size)),
      ]),
    ),
    #("initialClients", initial_clients_json(roster)),
    #("initialMessages", ops_to_json(initial_ops)),
    // Always empty, matching levee. See the 0x4b2 note in `connect_core`.
    #("initialSignals", json.preprocessed_array([])),
    // Capability negotiation is one-directional: a client that has never heard
    // of a feature ignores the key, and one that has opts in per document by
    // sending its own command (`joinPresence`). Watershed's gate is strict —
    // present *and* boolean `true` — so a stringified "true" here would read as
    // unsupported and silently downgrade every client to heartbeat presence.
    #(
      "supportedFeatures",
      json.object([#(presence_worker.feature_presence_v1, json.bool(True))]),
    ),
    #("supportedVersions", json.array(["^0.1.0", "^1.0.0"], json.string)),
    #("version", json.string("1.0.0")),
    #("checkpointSequenceNumber", json.int(current_sequence_number)),
    #("summaryHandle", json.string(summary_handle)),
    #("summarySequenceNumber", json.int(summary_sequence_number)),
  ])
}

fn claims_to_json(claims: TokenClaims) -> json.Json {
  json.object([
    #("documentId", json.string(claims.document_id)),
    #("scopes", json.array(types.scopes_to_strings(claims.scopes), json.string)),
    #("tenantId", json.string(claims.tenant_id)),
    #("user", json.object([#("id", json.string(claims.user.id))])),
    #("iat", json.int(claims.issued_at)),
    #("exp", json.int(claims.expiration)),
    #("ver", json.string(claims.version)),
  ])
}

fn initial_clients_json(roster: List(#(String, String))) -> json.Json {
  json.preprocessed_array(
    list.filter_map(roster, fn(entry) {
      let #(client_id, serialized_client) = entry
      // Roster values are server-serialized JSON, so this parse only fails on
      // corrupt storage. Omitting that one client beats crashing the connect
      // for everyone else.
      case json.parse(serialized_client, decode.dynamic) {
        Error(_) -> Error(Nil)
        Ok(client) ->
          Ok(
            json.object([
              #("clientId", json.string(client_id)),
              #("client", dynamic_to_json(client)),
            ]),
          )
      }
    }),
  )
}

@external(erlang, "floodgate_ffi", "now_seconds")
fn now_seconds() -> Int

fn handle_in(
  channels: beryl.Channels,
  document_session: Session,
  registration: Registration,
  presence: Subject(presence_worker.Msg),
  event: String,
  payload: Dynamic,
  sock: Socket(DocAssigns),
) -> channel.HandleResult(DocAssigns) {
  let assigns = socket.get_assigns(sock)
  case event, assigns.connected {
    e, False if e == events.connect_document ->
      connect_phase_two(channels, document_session, payload, sock, assigns)
    // Presence must never be attributable to an unauthenticated socket: before
    // connect there is no verified user id to key it by.
    e, False if e == presence_worker.event_join ->
      Push(presence_worker.event_error, unauthenticated_presence(), sock)
    e, False if e == presence_worker.event_update ->
      Push(presence_worker.event_error, unauthenticated_presence(), sock)
    // Everything below needs session membership, which only connect
    // establishes. Mirrors levee's `connected` assign guard.
    e, False if e == events.submit_op ->
      Push(
        events.nack,
        json.preprocessed_array([
          nack_json(None, 0, 400, "Client not connected"),
        ]),
        sock,
      )
    _, False -> NoReply(sock)
    e, True if e == events.submit_op ->
      submit_op(channels, document_session, payload, sock, assigns)
    e, True if e == events.submit_signal ->
      submit_signals(
        channels,
        document_session,
        registration,
        payload,
        sock,
        assigns,
      )
    e, True if e == presence_worker.event_join ->
      case presence_meta(payload, assigns.client_id) {
        Error(frame) -> Push(presence_worker.event_error, frame, sock)
        Ok(meta) -> {
          presence_worker.join(
            presence,
            assigns.client_id,
            assigns.topic,
            assigns.user_id,
            meta,
          )
          NoReply(sock)
        }
      }
    e, True if e == presence_worker.event_update ->
      case presence_meta(payload, assigns.client_id) {
        Error(frame) -> Push(presence_worker.event_error, frame, sock)
        Ok(meta) -> {
          presence_worker.update(
            presence,
            assigns.client_id,
            assigns.topic,
            meta,
          )
          NoReply(sock)
        }
      }
    // No rejection path at all, deliberately asymmetric with update: a duplicate
    // leave, or one racing the socket's own cleanup, is a no-op rather than an
    // error. The payload is ignored.
    e, True if e == presence_worker.event_leave -> {
      presence_worker.leave(presence, assigns.client_id)
      NoReply(sock)
    }
    "requestOps", True ->
      Push(
        events.op,
        ops_to_json(session.since(
          document_session,
          assigns.topic,
          int_field(payload, "from", 0),
        )),
        sock,
      )
    // Without this an idle levee-mode client never advances its reference
    // sequence number and the minimum sequence number stalls for the document.
    "noop", True -> {
      case field(payload, "clientId", "") == assigns.client_id {
        False -> Nil
        True ->
          session.update_client_rsn(
            document_session,
            assigns.topic,
            assigns.client_id,
            int_field(payload, "referenceSequenceNumber", 0),
          )
      }
      NoReply(sock)
    }
    e, True if e == events.submit_summary ->
      Push(
        events.nack,
        json.preprocessed_array([
          nack_json(
            None,
            session.sequence_number(document_session, assigns.topic),
            400,
            "Submit summaries as sequenced summarize operations",
          ),
        ]),
        sock,
      )
    _, True -> NoReply(sock)
  }
}

/// Phoenix path only: IConnect arrives as an event after the join, and the
/// driver listens for a pushed result rather than a reply.
fn connect_phase_two(
  channels: beryl.Channels,
  document_session: Session,
  payload: Dynamic,
  sock: Socket(DocAssigns),
  assigns: DocAssigns,
) -> channel.HandleResult(DocAssigns) {
  case
    connect_core(
      channels,
      document_session,
      assigns.topic,
      payload,
      socket.id(sock),
    )
  {
    Ok(#(response, assigns)) ->
      Push(
        events.connect_document_success,
        response,
        socket.set_assigns(sock, assigns),
      )
    Error(error) ->
      Push(events.connect_document_error, connect_error_to_json(error), sock)
  }
}

fn submit_op(
  channels: beryl.Channels,
  document_session: Session,
  payload: Dynamic,
  sock: Socket(DocAssigns),
  assigns: DocAssigns,
) -> channel.HandleResult(DocAssigns) {
  case assigns.mode {
    session.Write ->
      submit_writable_ops(channels, document_session, payload, sock, assigns)
    session.Read ->
      Push(
        events.nack,
        json.preprocessed_array([
          nack_json(None, 0, 403, "Read-only clients cannot submit operations"),
        ]),
        sock,
      )
  }
}

fn submit_writable_ops(
  channels: beryl.Channels,
  document_session: Session,
  payload: Dynamic,
  sock: Socket(DocAssigns),
  assigns: DocAssigns,
) -> channel.HandleResult(DocAssigns) {
  case
    field(payload, "clientId", "") == assigns.client_id,
    submitted_ops(payload)
  {
    False, _ ->
      Push(
        events.nack,
        json.preprocessed_array([
          nack_json(None, 0, 400, "Client ID mismatch"),
        ]),
        sock,
      )
    _, Error(_) ->
      Push(
        events.nack,
        json.preprocessed_array([
          nack_json(None, 0, 400, "Malformed submitOp payload"),
        ]),
        sock,
      )
    True, Ok(ops) -> {
      let nacks =
        list.fold(ops, [], fn(nacks, op) {
          case op.kind {
            "summarize" ->
              case list.contains(assigns.scopes, "summary:write") {
                True ->
                  submit_summary_op(
                    channels,
                    document_session,
                    op,
                    assigns,
                    nacks,
                  )
                False -> [
                  nack_json(
                    Some(op),
                    session.sequence_number(document_session, assigns.topic),
                    403,
                    "Summary scope required",
                  ),
                  ..nacks
                ]
              }
            _ ->
              case
                session.submit_message(
                  document_session,
                  assigns.topic,
                  assigns.client_id,
                  op.client_sequence_number,
                  op.reference_sequence_number,
                  fn(sn, msn) {
                    sequenced_op_json(assigns.client_id, op, sn, msn)
                    |> json.to_string
                  },
                )
              {
                session.MessageAssigned(sn, _, message) -> {
                  beryl.broadcast(
                    channels,
                    assigns.topic,
                    events.op,
                    json.preprocessed_array([
                      session.stored_message_to_json(#(sn, message)),
                    ]),
                  )
                  nacks
                }
                session.MessageRejected(current_sn) -> [
                  nack_json(
                    Some(op),
                    current_sn,
                    400,
                    "Invalid client or reference sequence number",
                  ),
                  ..nacks
                ]
              }
          }
        })

      case nacks {
        [] -> NoReply(sock)
        _ ->
          Push(events.nack, json.preprocessed_array(list.reverse(nacks)), sock)
      }
    }
  }
}

fn submit_summary_op(
  channels: beryl.Channels,
  document_session: Session,
  op: SubmittedOp,
  assigns: DocAssigns,
  nacks: List(json.Json),
) -> List(json.Json) {
  case
    session.submit_summary_messages(
      document_session,
      assigns.topic,
      assigns.client_id,
      op.client_sequence_number,
      op.reference_sequence_number,
      fn(summary_sn, response_sn, msn) {
        let outcome = case summarize_contents(op.contents) {
          Error(reason) -> #(None, reason)
          Ok(contents) ->
            case
              persist_summary(
                session.storage(document_session),
                assigns.topic,
                contents,
              )
            {
              Ok(commit_sha) -> #(Some(commit_sha), "")
              Error(reason) -> #(None, reason)
            }
        }
        let response = case outcome.0 {
          Some(handle) ->
            summary_ack_json(handle, summary_sn, msn, now_seconds() * 1000)
          None ->
            summary_nack_json(
              summary_sn,
              response_sn,
              msn,
              outcome.1,
              now_seconds() * 1000,
            )
        }
        #(
          sequenced_op_json(assigns.client_id, op, summary_sn, msn)
            |> json.to_string,
          json.to_string(response),
          outcome.0,
        )
      },
    )
  {
    session.SummaryMessagesAssigned(
      summary_sn,
      response_sn,
      _,
      summary_message,
      response_message,
    ) -> {
      // Now that the ops and the session's summary pointer are committed, make
      // the ref match it. Reading the pointer back rather than reusing the sha
      // computed above is what makes the ref a projection of the authoritative
      // value: whatever the session accepted is what gets published.
      publish_summary_ref(document_session, assigns.topic)
      beryl.broadcast(
        channels,
        assigns.topic,
        events.op,
        json.preprocessed_array([
          session.stored_message_to_json(#(summary_sn, summary_message)),
          session.stored_message_to_json(#(response_sn, response_message)),
        ]),
      )
      nacks
    }
    session.SummaryMessagesRejected(current_sn) -> [
      nack_json(
        Some(op),
        current_sn,
        400,
        "Invalid client or reference sequence number",
      ),
      ..nacks
    ]
  }
}

fn summarize_contents(contents: Dynamic) -> Result(SummarizeContents, String) {
  case decode.run(contents, decode.dict(decode.string, decode.dynamic)) {
    Error(_) -> Error("Summary contents must be an object")
    Ok(fields) ->
      case session_logic.validate_summarize_contents(fields) {
        Error(reason) -> Error("Invalid summarize op: " <> reason)
        Ok(Nil) ->
          case decode.run(contents, summarize_contents_decoder()) {
            Ok(contents) -> Ok(contents)
            Error(_) -> Error("Summary contents have invalid field types")
          }
      }
  }
}

fn summarize_contents_decoder() -> decode.Decoder(SummarizeContents) {
  use handle <- decode.field("handle", decode.string)
  use message <- decode.field("message", decode.string)
  use parents <- decode.field("parents", decode.list(decode.string))
  use head <- decode.field("head", decode.string)
  decode.success(SummarizeContents(handle, message, parents, head))
}

/// Point `refs/heads/<document_id>` at whatever summary commit the session
/// currently holds. A no-op when there is none.
fn publish_summary_ref(document_session: Session, topic: String) -> Nil {
  case topic_ids(topic), session.summary(document_session, topic) {
    Ok(#(tenant, document_id)), Ok(#(handle, _sn)) if handle != "" -> {
      // Best-effort: a failed publish leaves a lagging ref, which
      // `doc_state.rehydrate` repairs on the document's next cold start.
      let _ =
        git.publish_summary_ref(
          session.storage(document_session),
          tenant,
          document_id,
          handle,
        )
      Nil
    }
    _, _ -> Nil
  }
}

/// Store the summary's commit object and return its sha.
///
/// Deliberately does *not* publish `refs/heads/<document_id>`: that happens in
/// `submit_summary_op` once the session has committed its own summary pointer, so
/// the ref can only ever lag, never lead. See `git.publish_summary_ref`.
fn persist_summary(
  storage: store.Backend,
  topic: String,
  contents: SummarizeContents,
) -> Result(String, String) {
  // Objects are keyed by topic, so the tenant/document split `topic_ids` used to
  // do here is no longer needed: a malformed topic simply misses, which is the
  // same "tree does not exist" answer it produced before.
  case git.fetch(storage, topic, contents.handle) {
    Error(_) -> Error("Summary tree does not exist")
    Ok(_) -> {
      let author =
        json.object([
          #("name", json.string("Floodgate")),
          #("email", json.string("server@floodgate.local")),
          #("date", json.string(int.to_string(now_seconds()))),
        ])
      let commit =
        json.object([
          #("tree", json.string(contents.handle)),
          #("parents", json.array(contents.parents, json.string)),
          #("message", json.string(contents.message)),
          #("author", author),
          #("committer", author),
        ])
        |> json.to_string
      // The commit is content-addressed, so an orphan left by a crash is
      // garbage rather than a wrong answer.
      git.create(storage, topic, "commits", commit)
      |> result.replace_error("Could not store summary commit")
    }
  }
}

fn topic_ids(topic: String) -> Result(#(String, String), String) {
  case string.split(topic, ":") {
    ["document", tenant, document_id] -> Ok(#(tenant, document_id))
    _ -> Error("Invalid document topic")
  }
}

fn submit_signals(
  channels: beryl.Channels,
  document_session: Session,
  registration: Registration,
  payload: Dynamic,
  sock: Socket(DocAssigns),
  assigns: DocAssigns,
) -> channel.HandleResult(DocAssigns) {
  case
    field(payload, "clientId", "") == assigns.client_id,
    submitted_signals(payload)
  {
    True, Ok(signals) -> {
      list.each(signals, fn(signal) {
        relay_signal(channels, document_session, registration, assigns, signal)
      })
      NoReply(sock)
    }
    _, _ -> NoReply(sock)
  }
}

/// Deliver one signal to the clients its targeting fields name.
///
/// An untargeted signal keeps the broadcast path: it is one coordinator message
/// rather than one per recipient, and it avoids the `session.clients` round-trip
/// needed to resolve a recipient list. Only a signal that actually carries
/// targeting pays for either.
///
/// Recipients come from `spillway/session_logic.determine_signal_recipients`,
/// which is the same function levee's `Bridge.determine_signal_recipients` calls
/// — levee's behaviour is the reference here, so the shared implementation is
/// the one to use rather than `signals.get_signal_recipients`, which does not
/// intersect the targeted list with the known clients.
fn relay_signal(
  channels: beryl.Channels,
  document_session: Session,
  registration: Registration,
  assigns: DocAssigns,
  signal: signals.NormalizedSignal,
) -> Nil {
  let message =
    json.object([
      #("clientId", json.string(assigns.client_id)),
      #("content", dynamic_to_json(signal.content)),
    ])

  case targeted(signal), registered_channel(registration) {
    // Untargeted, or no registration handle to push through: broadcast, which
    // is what this did unconditionally before targeting was honoured.
    False, _ | _, None ->
      beryl.broadcast(channels, assigns.topic, events.signal, message)
    True, Some(registered) ->
      session_logic.determine_signal_recipients(
        assigns.client_id,
        signal.targeted_clients,
        signal.ignored_clients,
        signal.target_client_id,
        session.clients(document_session, assigns.topic),
      )
      // The Fluid client id *is* the beryl socket id — `join` assigns
      // `socket.id(sock)` as the client id — so a recipient addresses a socket
      // directly, with no mapping to maintain.
      |> list.each(fn(recipient) {
        beryl.send_info(
          registered,
          recipient,
          assigns.topic,
          SignalPush(message),
        )
      })
  }
}

/// Whether a signal names recipients at all. `determine_signal_recipients`
/// treats all-absent as "broadcast to everyone but the sender", which the
/// broadcast path already does more cheaply.
fn targeted(signal: signals.NormalizedSignal) -> Bool {
  option.is_some(signal.targeted_clients)
  || option.is_some(signal.ignored_clients)
  || option.is_some(signal.target_client_id)
}

fn submitted_ops(
  payload: Dynamic,
) -> Result(List(SubmittedOp), List(decode.DecodeError)) {
  let decoder = {
    use batches <- decode.field(
      "messageBatches",
      decode.list(decode.list(submitted_op_decoder())),
    )
    decode.success(list.flatten(batches))
  }
  decode.run(payload, decoder)
}

fn submitted_op_decoder() -> decode.Decoder(SubmittedOp) {
  use csn <- decode.field("clientSequenceNumber", decode.int)
  use rsn <- decode.field("referenceSequenceNumber", decode.int)
  use kind <- decode.optional_field("type", "op", decode.string)
  use contents <- decode.optional_field(
    "contents",
    dynamic.nil(),
    decode.dynamic,
  )
  use metadata <- optional_dynamic_field("metadata")
  use server_metadata <- optional_dynamic_field("serverMetadata")
  use traces <- optional_dynamic_field("traces")
  use compression <- optional_dynamic_field("compression")
  decode.success(SubmittedOp(
    csn,
    rsn,
    kind,
    contents,
    metadata,
    server_metadata,
    traces,
    compression,
  ))
}

fn optional_dynamic_field(
  name: String,
  next: fn(Option(Dynamic)) -> decode.Decoder(final),
) -> decode.Decoder(final) {
  decode.optional_field(name, None, decode.optional(decode.dynamic), next)
}

/// Signal payloads arrive in two shapes: floodgate's Socket.IO clients send
/// `{signals: [...]}`, while `levee-driver` sends
/// `{contentBatches: [[{content, targetClientId?}]]}`. Batches go through
/// spillway's v1/v2 normalization — the same path levee's
/// `Bridge.normalize_signal_batch` takes — rather than a third ad-hoc parser.
///
/// Normalized signals keep their targeting fields, which `relay_signal` honours.
fn submitted_signals(
  payload: Dynamic,
) -> Result(List(signals.NormalizedSignal), Nil) {
  let batches_decoder = {
    use batches <- decode.field("contentBatches", decode.list(decode.dynamic))
    decode.success(batches)
  }
  case decode.run(payload, batches_decoder) {
    Ok(batches) -> Ok(list.flat_map(batches, signals.normalize_signal_batch))
    Error(_) -> legacy_submitted_signals(payload)
  }
}

/// The `{signals: ["...", ...]}` shape carries content strings only — no
/// targeting — so these normalize to untargeted signals and take the broadcast
/// path.
fn legacy_submitted_signals(
  payload: Dynamic,
) -> Result(List(signals.NormalizedSignal), Nil) {
  let signal_decoder = {
    use content <- decode.field("content", decode.string)
    decode.success(content)
  }
  let signals_decoder =
    decode.one_of(decode.list(signal_decoder), [
      decode.list(decode.list(decode.string))
      |> decode.map(list.flatten),
    ])
  let decoder = {
    use signals <- decode.field("signals", signals_decoder)
    decode.success(signals)
  }
  decode.run(payload, decoder)
  |> result.map(
    list.map(_, fn(content) { untargeted(dynamic.string(content)) }),
  )
  |> result.replace_error(Nil)
}

/// A signal carrying content and no targeting — the legacy
/// `{signals: ["...", ...]}` shape has nowhere to put targeting fields, so
/// those signals go to the whole topic.
fn untargeted(content: Dynamic) -> signals.NormalizedSignal {
  signals.NormalizedSignal(
    content: content,
    signal_type: None,
    client_connection_number: None,
    reference_sequence_number: None,
    target_client_id: None,
    targeted_clients: None,
    ignored_clients: None,
  )
}

fn sequenced_op_json(
  client_id: String,
  op: SubmittedOp,
  sequence_number: Int,
  minimum_sequence_number: Int,
) -> json.Json {
  let fields = [
    #("clientId", json.string(client_id)),
    #("sequenceNumber", json.int(sequence_number)),
    #("minimumSequenceNumber", json.int(minimum_sequence_number)),
    #("clientSequenceNumber", json.int(op.client_sequence_number)),
    #("referenceSequenceNumber", json.int(op.reference_sequence_number)),
    #("type", json.string(op.kind)),
    #("contents", dynamic_to_json(op.contents)),
    #("timestamp", json.int(now_seconds() * 1000)),
  ]
  fields
  |> add_optional_json("metadata", op.metadata)
  |> add_optional_json("serverMetadata", op.server_metadata)
  |> add_optional_json("traces", op.traces)
  |> add_optional_json("compression", op.compression)
  |> json.object
}

fn summary_ack_json(
  handle: String,
  summary_sn: Int,
  minimum_sequence_number: Int,
  timestamp: Int,
) -> json.Json {
  session_logic.build_summary_ack(
    handle,
    summary_sn,
    minimum_sequence_number,
    timestamp,
  )
  |> list.map(fn(field) { #(field.0, dynamic_to_json(field.1)) })
  |> json.object
}

fn summary_nack_json(
  summary_sn: Int,
  response_sn: Int,
  minimum_sequence_number: Int,
  reason: String,
  timestamp: Int,
) -> json.Json {
  json.object([
    #("clientId", json.null()),
    #("sequenceNumber", json.int(response_sn)),
    #("minimumSequenceNumber", json.int(minimum_sequence_number)),
    #("clientSequenceNumber", json.int(-1)),
    #("referenceSequenceNumber", json.int(summary_sn)),
    #("type", json.string("summaryNack")),
    #(
      "contents",
      json.object([
        #(
          "summaryProposal",
          json.object([#("summarySequenceNumber", json.int(summary_sn))]),
        ),
        #("code", json.int(400)),
        #("message", json.string(reason)),
      ]),
    ),
    #("metadata", json.null()),
    #("timestamp", json.int(timestamp)),
  ])
}

fn nack_json(
  operation: option.Option(SubmittedOp),
  sequence_number: Int,
  code: Int,
  message: String,
) -> json.Json {
  let operation_json = case operation {
    Some(op) -> {
      let fields = [
        #("clientSequenceNumber", json.int(op.client_sequence_number)),
        #("referenceSequenceNumber", json.int(op.reference_sequence_number)),
        #("type", json.string(op.kind)),
        #("contents", dynamic_to_json(op.contents)),
      ]
      fields
      |> add_optional_json("metadata", op.metadata)
      |> add_optional_json("serverMetadata", op.server_metadata)
      |> add_optional_json("traces", op.traces)
      |> add_optional_json("compression", op.compression)
      |> json.object
    }
    None -> json.null()
  }

  json.object([
    #("operation", operation_json),
    #("sequenceNumber", json.int(sequence_number)),
    #(
      "content",
      json.object([
        #("code", json.int(code)),
        #("type", json.string("BadRequestError")),
        #("message", json.string(message)),
      ]),
    ),
  ])
}

fn add_optional_json(
  fields: List(#(String, json.Json)),
  name: String,
  value: option.Option(Dynamic),
) -> List(#(String, json.Json)) {
  case value {
    Some(value) -> list.append(fields, [#(name, dynamic_to_json(value))])
    None -> fields
  }
}

/// The dynamic → JSON conversion the roster path uses. Public so tests can
/// assert on the exact bytes a client payload serializes to.
pub fn dynamic_to_json(value: Dynamic) -> json.Json {
  case decode.run(value, decode.optional(decode.dynamic)) {
    Ok(None) -> json.null()
    _ -> non_null_dynamic_to_json(value)
  }
}

fn non_null_dynamic_to_json(value: Dynamic) -> json.Json {
  case decode.run(value, decode.string) {
    Ok(value) -> json.string(value)
    Error(_) ->
      case decode.run(value, decode.bool) {
        Ok(value) -> json.bool(value)
        Error(_) ->
          case decode.run(value, decode.int) {
            Ok(value) -> json.int(value)
            Error(_) ->
              case decode.run(value, decode.float) {
                Ok(value) -> json.float(value)
                Error(_) ->
                  case decode.run(value, decode.list(decode.dynamic)) {
                    Ok(values) ->
                      json.preprocessed_array(list.map(values, dynamic_to_json))
                    Error(_) ->
                      case
                        decode.run(
                          value,
                          decode.dict(decode.string, decode.dynamic),
                        )
                      {
                        Ok(values) ->
                          values
                          |> dict.to_list
                          |> list.map(fn(entry) {
                            #(entry.0, dynamic_to_json(entry.1))
                          })
                          |> json.object
                        Error(_) -> json.null()
                      }
                  }
              }
          }
      }
  }
}

fn ops_to_json(ops: List(#(Int, String))) -> json.Json {
  json.preprocessed_array(list.map(ops, session.stored_message_to_json))
}

fn field(value: Dynamic, key: String, default: String) -> String {
  case decode.run(value, decode.field(key, decode.string, decode.success)) {
    Ok(found) -> found
    Error(_) -> default
  }
}

fn int_field(value: Dynamic, key: String, default: Int) -> Int {
  case decode.run(value, decode.field(key, decode.int, decode.success)) {
    Ok(found) -> found
    Error(_) -> default
  }
}
