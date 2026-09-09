//// Fluid document channel — connect_document join, submitOp shared sequencing
//// + op fan-out (with contents), nack, submitSignal fan-out, requestOps delta
//// catch-up. Gleam analogue of levee's DocumentChannel.

import beryl
import beryl/channel
import beryl/presence
import beryl/socket
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
import gleam/pair
import gleam/result
import gleam/string
import signet/types.{type TokenClaims}
import silt/object
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
    presence_joined: Bool,
    /// The token's verified user id, and the presence key derived from it.
    ///
    /// Deliberately not read back off the session roster: `connect_core` prefers
    /// the peer's *own* supplied `IClient` when it sent one, so the roster value
    /// is client-controlled and a socket could claim another user's presence.
    user_id: String,
  )
}

type ChannelState {
  ChannelState(assigns: DocAssigns, target_id: Int)
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

/// Server-originated messages delivered to one joined document channel.
pub type DocInfo {
  SignalPush(payload: json.Json)
  /// Any other server-originated event for one socket. The presence worker uses
  /// it for `presence_state` and `presence_error`, which are per-socket frames
  /// with no reply channel to ride on.
  EventPush(event: String, payload: json.Json)
}

type Target {
  Target(id: Int, sender: channel.Sender(DocInfo))
}

type RegistrationState {
  RegistrationState(
    sockets: Option(beryl.Sockets),
    next_id: Int,
    targets: dict.Dict(String, Target),
  )
}

/// Registry for targeted channel sends and presence-diff fan-out.
pub opaque type Registration {
  Registration(Subject(RegistrationMsg))
}

type RegistrationMsg {
  SetSockets(beryl.Sockets)
  RegisterTarget(
    socket_id: String,
    topic: String,
    sender: channel.Sender(DocInfo),
    reply: Subject(Int),
  )
  UnregisterTarget(socket_id: String, topic: String, id: Int)
  GetTarget(
    socket_id: String,
    topic: String,
    reply: Subject(Option(channel.Sender(DocInfo))),
  )
  BroadcastPresence(presence.Diff)
}

/// Allocate the runtime registry before building the Beryl child spec.
pub fn new_registration() -> Registration {
  let assert Ok(started) =
    actor.new(RegistrationState(None, 0, dict.new()))
    |> actor.on_message(fn(state, message) {
      case message {
        SetSockets(sockets) ->
          actor.continue(RegistrationState(..state, sockets: Some(sockets)))
        RegisterTarget(socket_id, topic, sender, reply) -> {
          let id = state.next_id + 1
          process.send(reply, id)
          actor.continue(
            RegistrationState(
              ..state,
              next_id: id,
              targets: dict.insert(
                state.targets,
                target_key(socket_id, topic),
                Target(id, sender),
              ),
            ),
          )
        }
        UnregisterTarget(socket_id, topic, id) -> {
          let key = target_key(socket_id, topic)
          let targets = case dict.get(state.targets, key) {
            Ok(Target(id: registered_id, ..)) if registered_id == id ->
              dict.delete(state.targets, key)
            _ -> state.targets
          }
          actor.continue(RegistrationState(..state, targets: targets))
        }
        GetTarget(socket_id, topic, reply) -> {
          let sender =
            dict.get(state.targets, target_key(socket_id, topic))
            |> result.map(fn(target) { target.sender })
            |> option.from_result
          process.send(reply, sender)
          actor.continue(state)
        }
        BroadcastPresence(diff) -> {
          case state.sockets {
            None -> Nil
            Some(sockets) ->
              presence.diff_topics(diff)
              |> list.each(fn(topic) {
                beryl.broadcast_presence_diff(sockets, topic, diff)
              })
          }
          actor.continue(state)
        }
      }
    })
    |> actor.start
  Registration(started.data)
}

/// Attach the Beryl runtime after `channel.child_spec` constructs it.
pub fn set_sockets(registration: Registration, sockets: beryl.Sockets) -> Nil {
  let Registration(subject) = registration
  process.send(subject, SetSockets(sockets))
}

/// Queue a presence diff for every local socket subscribed to its topics.
pub fn broadcast_presence_diff(
  registration: Registration,
  diff: presence.Diff,
) -> Nil {
  let Registration(subject) = registration
  process.send(subject, BroadcastPresence(diff))
}

fn register_target(
  registration: Registration,
  socket_id: String,
  topic: String,
  sender: channel.Sender(DocInfo),
) -> Int {
  let Registration(subject) = registration
  process.call(subject, 1000, fn(reply) {
    RegisterTarget(socket_id, topic, sender, reply)
  })
}

fn unregister_target(
  registration: Registration,
  socket_id: String,
  topic: String,
  id: Int,
) -> Nil {
  let Registration(subject) = registration
  process.send(subject, UnregisterTarget(socket_id, topic, id))
}

fn target(
  registration: Registration,
  socket_id: String,
  topic: String,
) -> Option(channel.Sender(DocInfo)) {
  let Registration(subject) = registration
  process.call(subject, 1000, fn(reply) { GetTarget(socket_id, topic, reply) })
}

fn target_key(socket_id: String, topic: String) -> String {
  socket_id <> "\n" <> topic
}

pub fn new(
  document_session: Session,
  registration: Registration,
  presence: Subject(presence_worker.Msg),
  max_frame_bytes: Int,
) -> channel.Handler {
  channel.handler("document:*:*", fn(context) {
    case
      join(
        document_session,
        context.topic,
        context.payload,
        context.socket_id,
        max_frame_bytes,
      )
    {
      Error(error) -> join_error(error)
      Ok(PreparedJoin(reply, assigns, actions)) -> {
        let target_id =
          register_target(
            registration,
            context.socket_id,
            context.topic,
            context.self,
          )
        let accepted =
          channel.accept(ChannelState(assigns, target_id))
          |> channel.on_message(fn(state, message) {
            handle_in(
              document_session,
              registration,
              presence,
              message.event,
              message.payload,
              context.socket_id,
              state.assigns,
              max_frame_bytes,
            )
            |> apply_result(state, message.reply)
          })
          |> channel.on_info(fn(state, info) {
            case info {
              SignalPush(payload) ->
                channel.next(state, [channel.push(events.signal, payload)])
              EventPush(event, payload) ->
                channel.next(state, [channel.push(event, payload)])
            }
          })
          |> channel.on_terminate(fn(state, _reason) {
            unregister_target(
              registration,
              context.socket_id,
              context.topic,
              state.target_id,
            )
            on_leave(document_session, presence, state.assigns)
          })
          |> channel.with_actions(actions)
        case reply {
          Some(payload) -> channel.with_reply(accepted, payload)
          None -> accepted
        }
      }
    }
  })
}

/// Push one server-originated event to one socket, out of band. This is the
/// callback `floodgate.start_with_backend` hands the presence worker; the worker
/// cannot access this module's typed channel-sender registry directly.
pub fn push_event(
  registration: Registration,
  socket_id: String,
  topic: String,
  event: String,
  payload: json.Json,
) -> Nil {
  case target(registration, socket_id, topic) {
    None -> Nil
    Some(sender) -> channel.notify(sender, EventPush(event, payload))
  }
}

type PreparedJoin {
  PreparedJoin(
    reply: Option(json.Json),
    assigns: DocAssigns,
    actions: List(channel.Action(channel.Active)),
  )
}

type Connected {
  Connected(
    response: json.Json,
    assigns: DocAssigns,
    actions: List(channel.Action(channel.Active)),
  )
}

/// Two wire protocols enter this channel differently. Socket.IO carries the
/// whole `connect_document` payload as the join, so joining and connecting are
/// one step. A Phoenix `phx_join` carries only `{token}` — `mode` and the rest
/// of IConnect arrive later on the `connect_document` event — so the socket
/// joins first and connects in a second phase.
fn join(
  document_session: Session,
  topic: String,
  payload: Dynamic,
  client_id: String,
  max_frame_bytes: Int,
) -> Result(PreparedJoin, ConnectError) {
  case is_connect_payload(payload) {
    True ->
      connect_core(document_session, topic, payload, client_id, max_frame_bytes)
      |> result.map(fn(result) {
        let Connected(response, assigns, actions) = result
        PreparedJoin(Some(response), assigns, actions)
      })
    False ->
      case
        authorize_topic_token(session.storage(document_session), topic, payload)
      {
        Error(error) -> Error(error)
        Ok(_claims) -> Ok(PreparedJoin(None, pending_assigns(topic), []))
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
    presence_joined: False,
    user_id: "",
  )
}

fn join_error(error: ConnectError) -> channel.JoinResult(state, info) {
  channel.reject(json.object([#("reason", json.string(error.reason))]))
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
  document_session: Session,
  topic: String,
  payload: Dynamic,
  client_id: String,
  max_frame_bytes: Int,
) -> Result(Connected, ConnectError) {
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
      let actions = case recovery {
        [] -> []
        recovery -> [
          channel.broadcast_from(
            events.op,
            recovery
              |> list.map(session.stored_message_to_json)
              |> json.preprocessed_array,
          ),
        ]
      }
      let actions = case membership {
        // The joining client receives its own join op in initialMessages.
        // Excluding it from fan-out avoids an early duplicate before the
        // connect response has established its client ID.
        session.Writer(sn, message) ->
          list.append(actions, [
            channel.broadcast_from(
              events.op,
              json.preprocessed_array([
                session.stored_message_to_json(#(sn, message)),
              ]),
            ),
          ])
        session.Reader -> actions
      }
      // Routerlicious announces *every* connection with a room join signal, not
      // just a read-only one: an audience that is fed only by signals — Fluid
      // 1.4.0's is, and it always loads in write mode — never learns about a
      // writer otherwise. Clients that also track the quorum ignore the join
      // signal for a write client, so the extra signal cannot double-count.
      //
      // The joining socket cannot be broadcast to yet (beryl subscribes it once
      // this returns), so its own join rides along in `initialSignals`.
      let join_signal = presence_join(client_id, client)
      let actions =
        list.append(actions, [
          channel.broadcast_from(events.signal, join_signal),
        ])
      Ok(Connected(
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
          max_frame_bytes,
          [join_signal],
        ),
        DocAssigns(
          client_id: client_id,
          mode: mode,
          topic: topic,
          scopes: types.scopes_to_strings(claims.scopes),
          connected: True,
          presence_joined: False,
          user_id: claims.user.id,
        ),
        actions,
      ))
    }
  }
}

fn on_leave(
  document_session: Session,
  presence: Subject(presence_worker.Msg),
  assigns: DocAssigns,
) -> List(channel.Action(channel.Closing)) {
  // Before the `connected` guard: this is the one funnel every termination
  // reaches — a Socket.IO close, a Phoenix close, a heartbeat-sweep eviction, or
  // an explicit `phx_leave` — and it is what makes a dropped socket stop being
  // present without anyone waiting out a TTL. A no-op for a socket that never
  // tracked, so it is safe to run unconditionally.
  presence_worker.cleanup(presence, assigns.client_id)
  // A Phoenix socket that joined but never sent connect_document holds no
  // session membership, so there is nothing to tear down or announce.
  use <- bool.guard(when: !assigns.connected, return: [])
  let actions = case assigns.mode {
    session.Write -> {
      let session.Left(sn, _, message) =
        session.leave_sequenced(
          document_session,
          assigns.topic,
          assigns.client_id,
          now_seconds() * 1000,
        )
      [
        channel.broadcast(
          events.op,
          json.preprocessed_array([
            session.stored_message_to_json(#(sn, message)),
          ]),
        ),
      ]
    }
    session.Read -> {
      session.leave_presence(document_session, assigns.topic, assigns.client_id)
      []
    }
  }
  // The mirror of the unconditional join signal in `connect_core`: routerlicious
  // announces every disconnect to the room, so an audience built from signals
  // alone still drops a writer that left.
  list.append(actions, [
    channel.broadcast(events.signal, presence_leave(assigns.client_id)),
  ])
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
  initial_signals: List(json.Json),
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
    // Read clients do not receive a sequenced join op, so their own join signal
    // must be present before the loader can transition to connected.
    #("initialSignals", json.preprocessed_array(initial_signals)),
    // Capability negotiation is one-directional: a client that has never heard
    // of a feature ignores the key, and one that has opts in per document by
    // sending its own command (`joinPresence`). Watershed's gate is strict —
    // present *and* boolean `true` — so a stringified "true" here would read as
    // unsupported and silently downgrade every client to heartbeat presence.
    #(
      "supportedFeatures",
      json.object([
        #(presence_worker.feature_presence_v1, json.bool(True)),
        #("submit_signals_v2", json.bool(True)),
      ]),
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

type ChannelResult {
  NoReply(DocAssigns)
  Push(event: String, payload: json.Json, assigns: DocAssigns)
  Actions(assigns: DocAssigns, actions: List(channel.Action(channel.Active)))
}

fn apply_result(
  result: ChannelResult,
  state: ChannelState,
  reply: Option(socket.ReplyRef),
) -> channel.Next(ChannelState) {
  let reply_actions = [channel.reply_ok(reply, json.object([]))]
  case result {
    NoReply(assigns) ->
      channel.next(ChannelState(..state, assigns: assigns), reply_actions)
    Push(event, payload, assigns) ->
      channel.next(ChannelState(..state, assigns: assigns), [
        channel.push(event, payload),
        ..reply_actions
      ])
    Actions(assigns, actions) ->
      channel.next(
        ChannelState(..state, assigns: assigns),
        list.append(actions, reply_actions),
      )
  }
}

fn handle_in(
  document_session: Session,
  registration: Registration,
  presence: Subject(presence_worker.Msg),
  event: String,
  payload: Dynamic,
  socket_id: String,
  assigns: DocAssigns,
  max_frame_bytes: Int,
) -> ChannelResult {
  case event, assigns.connected {
    e, False if e == events.connect_document ->
      connect_phase_two(
        document_session,
        payload,
        socket_id,
        assigns,
        max_frame_bytes,
      )
    // Presence must never be attributable to an unauthenticated socket: before
    // connect there is no verified user id to key it by.
    e, False if e == presence_worker.event_join ->
      Push(presence_worker.event_error, unauthenticated_presence(), assigns)
    e, False if e == presence_worker.event_update ->
      Push(presence_worker.event_error, unauthenticated_presence(), assigns)
    // Everything below needs session membership, which only connect
    // establishes. Mirrors levee's `connected` assign guard.
    e, False if e == events.submit_op ->
      Push(
        events.nack,
        json.preprocessed_array([
          nack_json(None, 0, 400, "Client not connected"),
        ]),
        assigns,
      )
    _, False -> NoReply(assigns)
    e, True if e == events.submit_op ->
      submit_op(document_session, payload, assigns)
    e, True if e == events.submit_signal ->
      submit_signals(document_session, registration, payload, assigns)
    e, True if e == presence_worker.event_join ->
      case presence_meta(payload, assigns.client_id) {
        Error(frame) -> Push(presence_worker.event_error, frame, assigns)
        Ok(meta) -> {
          presence_worker.join(
            presence,
            assigns.client_id,
            assigns.topic,
            assigns.user_id,
            meta,
          )
          NoReply(DocAssigns(..assigns, presence_joined: True))
        }
      }
    e, True if e == presence_worker.event_update ->
      case assigns.presence_joined, presence_meta(payload, assigns.client_id) {
        False, _ ->
          Push(
            presence_worker.event_error,
            presence_worker.error(
              "not_joined",
              "this connection has no presence to update",
            ),
            assigns,
          )
        _, Error(frame) -> Push(presence_worker.event_error, frame, assigns)
        True, Ok(meta) -> {
          presence_worker.update(
            presence,
            assigns.client_id,
            assigns.topic,
            meta,
          )
          NoReply(assigns)
        }
      }
    // No rejection path at all, deliberately asymmetric with update: a duplicate
    // leave, or one racing the socket's own cleanup, is a no-op rather than an
    // error. The payload is ignored.
    e, True if e == presence_worker.event_leave -> {
      presence_worker.leave(presence, assigns.client_id)
      NoReply(DocAssigns(..assigns, presence_joined: False))
    }
    "requestOps", True ->
      Push(
        events.op,
        ops_to_json(session.since(
          document_session,
          assigns.topic,
          int_field(payload, "from", 0),
        )),
        assigns,
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
      NoReply(assigns)
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
        assigns,
      )
    _, True -> NoReply(assigns)
  }
}

/// Phoenix path only: IConnect arrives as an event after the join, and the
/// driver listens for a pushed result rather than a reply.
fn connect_phase_two(
  document_session: Session,
  payload: Dynamic,
  socket_id: String,
  assigns: DocAssigns,
  max_frame_bytes: Int,
) -> ChannelResult {
  case
    connect_core(
      document_session,
      assigns.topic,
      payload,
      socket_id,
      max_frame_bytes,
    )
  {
    Ok(Connected(response, connected_assigns, broadcasts)) ->
      Actions(
        connected_assigns,
        list.append(broadcasts, [
          channel.push(events.connect_document_success, response),
        ]),
      )
    Error(error) ->
      Push(events.connect_document_error, connect_error_to_json(error), assigns)
  }
}

fn submit_op(
  document_session: Session,
  payload: Dynamic,
  assigns: DocAssigns,
) -> ChannelResult {
  case assigns.mode {
    session.Write -> submit_writable_ops(document_session, payload, assigns)
    session.Read ->
      Push(
        events.nack,
        json.preprocessed_array([
          nack_json(None, 0, 403, "Read-only clients cannot submit operations"),
        ]),
        assigns,
      )
  }
}

fn submit_writable_ops(
  document_session: Session,
  payload: Dynamic,
  assigns: DocAssigns,
) -> ChannelResult {
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
        assigns,
      )
    _, Error(_) ->
      Push(
        events.nack,
        json.preprocessed_array([
          nack_json(None, 0, 400, "Malformed submitOp payload"),
        ]),
        assigns,
      )
    True, Ok(ops) -> {
      let #(nacks, broadcasts) =
        list.fold(ops, #([], []), fn(acc, op) {
          let #(nacks, broadcasts) = acc
          case op.kind {
            "summarize" ->
              case list.contains(assigns.scopes, "summary:write") {
                True ->
                  submit_summary_op(
                    document_session,
                    op,
                    assigns,
                    nacks,
                    broadcasts,
                  )
                False -> #(
                  [
                    nack_json(
                      Some(op),
                      session.sequence_number(document_session, assigns.topic),
                      403,
                      "Summary scope required",
                    ),
                    ..nacks
                  ],
                  broadcasts,
                )
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
                  #(nacks, [
                    channel.broadcast(
                      events.op,
                      json.preprocessed_array([
                        session.stored_message_to_json(#(sn, message)),
                      ]),
                    ),
                    ..broadcasts
                  ])
                }
                session.MessageRejected(current_sn) -> #(
                  [
                    nack_json(
                      Some(op),
                      current_sn,
                      400,
                      "Invalid client or reference sequence number",
                    ),
                    ..nacks
                  ],
                  broadcasts,
                )
              }
          }
        })

      let broadcasts = list.reverse(broadcasts)
      let actions = case nacks {
        [] -> broadcasts
        _ ->
          list.append(broadcasts, [
            channel.push(
              events.nack,
              json.preprocessed_array(list.reverse(nacks)),
            ),
          ])
      }
      Actions(assigns, actions)
    }
  }
}

fn submit_summary_op(
  document_session: Session,
  op: SubmittedOp,
  assigns: DocAssigns,
  nacks: List(json.Json),
  broadcasts: List(channel.Action(channel.Active)),
) -> #(List(json.Json), List(channel.Action(channel.Active))) {
  case
    session.submit_summary_messages(
      document_session,
      assigns.topic,
      assigns.client_id,
      op.client_sequence_number,
      op.reference_sequence_number,
      fn(summary_sn, response_sn, msn, _roster, current_summary) {
        let outcome = case summarize_contents(op.contents) {
          Error(reason) -> #(None, reason)
          Ok(contents) -> {
            let history = session.since(document_session, assigns.topic, 0)
            case
              persist_summary(
                session.storage(document_session),
                assigns.topic,
                contents,
                current_summary,
                op.reference_sequence_number,
                protocol_minimum_sequence_number(
                  history,
                  op.reference_sequence_number,
                ),
                history,
              )
            {
              Ok(commit_sha) -> #(Some(commit_sha), "")
              Error(reason) -> #(None, reason)
            }
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
      #(nacks, [
        channel.broadcast(
          events.op,
          json.preprocessed_array([
            session.stored_message_to_json(#(summary_sn, summary_message)),
            session.stored_message_to_json(#(response_sn, response_message)),
          ]),
        ),
        ..broadcasts
      ])
    }
    session.SummaryMessagesRejected(current_sn) -> #(
      [
        nack_json(
          Some(op),
          current_sn,
          400,
          "Invalid client or reference sequence number",
        ),
        ..nacks
      ],
      broadcasts,
    )
  }
}

fn summarize_contents(contents: Dynamic) -> Result(SummarizeContents, String) {
  case decode.run(contents, decode.dict(decode.string, decode.dynamic)) {
    Error(_) -> {
      use serialized <- result.try(
        decode.run(contents, decode.string)
        |> result.replace_error("Summary contents must be an object"),
      )
      use parsed <- result.try(
        json.parse(serialized, decode.dynamic)
        |> result.replace_error("Summary contents must be an object"),
      )
      summarize_contents(parsed)
    }
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

/// Store the summary's commit object and return its sha.
///
/// The document actor publishes the pointer and ref after storing the proposal
/// and its response.
fn persist_summary(
  storage: store.Backend,
  topic: String,
  contents: SummarizeContents,
  current_summary: #(String, Int),
  reference_sequence_number: Int,
  minimum_sequence_number: Int,
  history: List(#(Int, String)),
) -> Result(String, String) {
  let expected_parents = case current_summary.0 {
    "" -> []
    head -> [head]
  }
  use Nil <- result.try(
    case
      contents.parents == expected_parents,
      contents.head == current_summary.0
    {
      False, _ -> Error("Summary parent is not the published head")
      _, False -> Error("Summary head is not the published head")
      True, True -> Ok(Nil)
    },
  )
  case git.fetch(storage, topic, contents.handle) {
    Error(_) -> Error("Summary tree does not exist")
    Ok(body) -> {
      use _ <- result.try(
        object.decode_tree(body)
        |> result.replace_error("Summary handle is not a tree"),
      )
      use tree <- result.try(summary_tree_handle(
        storage,
        topic,
        contents,
        reference_sequence_number,
        minimum_sequence_number,
        history,
      ))
      let author =
        json.object([
          #("name", json.string("Floodgate")),
          #("email", json.string("server@floodgate.local")),
          #("date", json.string(int.to_string(now_seconds()))),
        ])
      let commit =
        json.object([
          #("tree", json.string(tree)),
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

fn summary_tree_handle(
  storage: store.Backend,
  topic: String,
  contents: SummarizeContents,
  reference_sequence_number: Int,
  minimum_sequence_number: Int,
  history: List(#(Int, String)),
) -> Result(String, String) {
  case contents.parents {
    [] -> Ok(contents.handle)
    [parent, ..] -> {
      use parent_body <- result.try(
        git.fetch_commit(storage, topic, parent)
        |> result.replace_error("Parent summary commit does not exist"),
      )
      use parent_tree <- result.try(
        json.parse(
          parent_body,
          decode.field("tree", decode.string, decode.success),
        )
        |> result.replace_error("Parent summary commit is invalid"),
      )
      use tree_body <- result.try(
        git.fetch(storage, topic, parent_tree)
        |> result.replace_error("Parent summary tree does not exist"),
      )
      use entries <- result.try(
        json.parse(
          tree_body,
          decode.field(
            "tree",
            decode.list(summary_tree_entry_decoder()),
            decode.success,
          ),
        )
        |> result.replace_error("Parent summary tree is invalid"),
      )
      case
        list.find_map(entries, fn(entry) {
          case entry {
            #(".protocol", _, "tree", sha) -> Ok(sha)
            _ -> Error(Nil)
          }
        })
      {
        Error(_) -> Ok(contents.handle)
        Ok(protocol_sha) -> {
          use protocol_sha <- result.try(update_protocol_tree(
            storage,
            topic,
            protocol_sha,
            reference_sequence_number,
            minimum_sequence_number,
            history,
          ))
          json.object([
            #(
              "tree",
              json.preprocessed_array([
                summary_tree_entry(".app", contents.handle),
                summary_tree_entry(".protocol", protocol_sha),
              ]),
            ),
          ])
          |> json.to_string
          |> git.create(storage, topic, "trees", _)
          |> result.replace_error("Could not store combined summary tree")
        }
      }
    }
  }
}

fn summary_tree_entry_decoder() -> decode.Decoder(
  #(String, String, String, String),
) {
  use path <- decode.field("path", decode.string)
  use mode <- decode.field("mode", decode.string)
  use kind <- decode.field("type", decode.string)
  use sha <- decode.field("sha", decode.string)
  decode.success(#(path, mode, kind, sha))
}

fn summary_tree_entry(path: String, sha: String) -> json.Json {
  json.object([
    #("path", json.string(path)),
    #("mode", json.string("040000")),
    #("type", json.string("tree")),
    #("sha", json.string(sha)),
  ])
}

fn update_protocol_tree(
  storage: store.Backend,
  topic: String,
  protocol_sha: String,
  reference_sequence_number: Int,
  minimum_sequence_number: Int,
  history: List(#(Int, String)),
) -> Result(String, String) {
  use protocol_body <- result.try(
    git.fetch(storage, topic, protocol_sha)
    |> result.replace_error("Parent protocol tree does not exist"),
  )
  use entries <- result.try(
    json.parse(
      protocol_body,
      decode.field(
        "tree",
        decode.list(summary_tree_entry_decoder()),
        decode.success,
      ),
    )
    |> result.replace_error("Parent protocol tree is invalid"),
  )
  let attributes =
    json.object([
      #("minimumSequenceNumber", json.int(minimum_sequence_number)),
      #("sequenceNumber", json.int(reference_sequence_number)),
    ])
    |> json.to_string
  let blob =
    json.object([
      #("content", json.string(attributes)),
      #("encoding", json.string("utf-8")),
    ])
    |> json.to_string
  use attributes_sha <- result.try(
    git.create(storage, topic, "blobs", blob)
    |> result.replace_error("Could not store protocol attributes"),
  )
  let members =
    json.to_string(quorum_members(history, reference_sequence_number))
    |> protocol_blob_body
  use members_sha <- result.try(
    git.create(storage, topic, "blobs", members)
    |> result.replace_error("Could not store protocol members"),
  )
  let entries =
    list.map(entries, fn(entry) {
      case entry {
        #("attributes", mode, kind, _) ->
          git_tree_entry(#("attributes", mode, kind, attributes_sha))
        #("quorumMembers", mode, kind, _) ->
          git_tree_entry(#("quorumMembers", mode, kind, members_sha))
        _ -> git_tree_entry(entry)
      }
    })
  json.object([#("tree", json.preprocessed_array(entries))])
  |> json.to_string
  |> git.create(storage, topic, "trees", _)
  |> result.replace_error("Could not store updated protocol tree")
}

fn git_tree_entry(entry: #(String, String, String, String)) -> json.Json {
  let #(path, mode, kind, sha) = entry
  json.object([
    #("path", json.string(path)),
    #("mode", json.string(mode)),
    #("type", json.string(kind)),
    #("sha", json.string(sha)),
  ])
}

fn protocol_blob_body(content: String) -> String {
  json.object([
    #("content", json.string(content)),
    #("encoding", json.string("utf-8")),
  ])
  |> json.to_string
}

/// The minimum sequence number a summary's `.protocol/attributes` records.
///
/// Scribe snapshots the protocol state *as of the summary's reference sequence
/// number*: it replays pending ops up to that point and reads the handler back,
/// so the attributes carry the MSN of the last op at or before the reference,
/// paired with the reference itself. The document's MSN when the summarize op
/// was sequenced is a later, higher value — writing that one gives a container
/// loading the summary a starting MSN ahead of the very ops it then reads, and
/// the client rejects the first of them with "Invalid MinimumSequenceNumber
/// from service - document may have been restored to previous state".
pub fn protocol_minimum_sequence_number(
  history: List(#(Int, String)),
  reference_sequence_number: Int,
) -> Int {
  history
  |> list.fold(#(0, 0), fn(latest, op) {
    let #(seen, _) = latest
    case op.0 <= reference_sequence_number && op.0 >= seen {
      False -> latest
      True ->
        case message_minimum_sequence_number(op.1) {
          Ok(value) -> #(op.0, value)
          Error(Nil) -> latest
        }
    }
  })
  |> pair.second
}

fn message_minimum_sequence_number(message: String) -> Result(Int, Nil) {
  json.parse(
    message,
    decode.field("minimumSequenceNumber", decode.int, decode.success),
  )
  |> result.replace_error(Nil)
}

fn quorum_members(
  history: List(#(Int, String)),
  reference_sequence_number: Int,
) -> json.Json {
  history
  |> list.filter(fn(op) { op.0 <= reference_sequence_number })
  |> list.fold(dict.new(), fn(members, op) {
    case membership_change(op) {
      Ok(MemberJoined(client_id, client, sequence_number)) ->
        dict.insert(members, client_id, #(client, sequence_number))
      Ok(MemberLeft(client_id)) -> dict.delete(members, client_id)
      Error(_) -> members
    }
  })
  |> dict.to_list
  |> list.map(fn(member) {
    let #(client_id, #(client, sequence_number)) = member
    json.preprocessed_array([
      json.string(client_id),
      json.object([
        #("client", dynamic_to_json(client)),
        #("sequenceNumber", json.int(sequence_number)),
      ]),
    ])
  })
  |> json.preprocessed_array
}

type MembershipChange {
  MemberJoined(client_id: String, client: Dynamic, sequence_number: Int)
  MemberLeft(client_id: String)
}

fn membership_change(op: #(Int, String)) -> Result(MembershipChange, Nil) {
  use event <- result.try(
    json.parse(op.1, {
      use kind <- decode.field("type", decode.string)
      use data <- decode.field("data", decode.string)
      decode.success(#(kind, data))
    })
    |> result.replace_error(Nil),
  )
  case event {
    #("join", data) ->
      json.parse(data, {
        use client_id <- decode.field("clientId", decode.string)
        use client <- decode.field("detail", decode.dynamic)
        decode.success(MemberJoined(client_id, client, op.0))
      })
      |> result.replace_error(Nil)
    #("leave", data) ->
      json.parse(data, decode.string)
      |> result.map(MemberLeft)
      |> result.replace_error(Nil)
    _ -> Error(Nil)
  }
}

fn submit_signals(
  document_session: Session,
  registration: Registration,
  payload: Dynamic,
  assigns: DocAssigns,
) -> ChannelResult {
  case
    field(payload, "clientId", "") == assigns.client_id,
    submitted_signals(payload)
  {
    True, Ok(signals) -> {
      signals
      |> list.each(fn(signal) {
        relay_signal(document_session, registration, assigns, signal)
      })
      NoReply(assigns)
    }
    _, _ -> NoReply(assigns)
  }
}

/// Deliver one signal to the clients its targeting fields name.
///
/// Every signal uses the same per-channel notification path so mixed targeted
/// and untargeted batches retain their submitted order.
///
/// Recipients come from `spillway/session_logic.determine_signal_recipients`,
/// which is the same function levee's `Bridge.determine_signal_recipients` calls
/// — levee's behaviour is the reference here, so the shared implementation is
/// the one to use rather than `signals.get_signal_recipients`, which does not
/// intersect the targeted list with the known clients.
fn relay_signal(
  document_session: Session,
  registration: Registration,
  assigns: DocAssigns,
  signal: signals.NormalizedSignal,
) -> Nil {
  let message_fields = [
    #("clientId", json.string(assigns.client_id)),
    #("content", dynamic_to_json(signal.content)),
  ]
  let message_fields = case signal.target_client_id {
    Some(target) -> [#("targetClientId", json.string(target)), ..message_fields]
    None -> message_fields
  }
  let message = json.object(message_fields)

  let recipients = case targeted(signal) {
    False -> session.clients(document_session, assigns.topic)
    True ->
      case signal.target_client_id {
        Some(target) if target == assigns.client_id -> [target]
        _ ->
          session_logic.determine_signal_recipients(
            assigns.client_id,
            signal.targeted_clients,
            signal.ignored_clients,
            signal.target_client_id,
            session.clients(document_session, assigns.topic),
          )
      }
  }
  recipients
  |> list.each(fn(recipient) {
    case target(registration, recipient, assigns.topic) {
      Some(sender) -> channel.notify(sender, SignalPush(message))
      None -> Nil
    }
  })
}

/// Whether a signal names recipients at all. `determine_signal_recipients`
/// treats all-absent as "broadcast to everyone but the sender", while Fluid
/// signals are also delivered back to their sender.
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

/// Signal payloads arrive in three shapes. Floodgate's Socket.IO clients send
/// `{signals: [...]}`, `levee-driver` sends
/// `{contentBatches: [[{content, targetClientId?}]]}`, and any driver that
/// predates the `submit_signals_v2` feature — Fluid 1.4.0, 2.0.0-internal.5.4.2
/// and 2.0.9 among them — sends a *batch of contents* per entry, i.e.
/// `[["<json string>"]]`.
///
/// Routerlicious' nexus lambda makes the same split: an entry that is an array
/// is a v1 content batch whose items relay verbatim, anything else is a single
/// `ISentSignalMessage`. Entries that are objects go through spillway's v1/v2
/// normalization — the same path levee's `Bridge.normalize_signal_batch` takes —
/// rather than a third ad-hoc parser.
///
/// Normalized signals keep their targeting fields, which `relay_signal` honours.
fn submitted_signals(
  payload: Dynamic,
) -> Result(List(signals.NormalizedSignal), Nil) {
  let field = fn(name) {
    use raw <- decode.field(name, decode.dynamic)
    decode.success(raw)
  }
  case decode.run(payload, field("contentBatches")) {
    Ok(raw) -> Ok(normalize_submitted(raw))
    Error(_) ->
      decode.run(payload, field("signals"))
      |> result.map(normalize_submitted)
      |> result.replace_error(Nil)
  }
}

fn normalize_submitted(raw: Dynamic) -> List(signals.NormalizedSignal) {
  case decode.run(raw, decode.list(decode.dynamic)) {
    Ok(entries) -> list.flat_map(entries, normalize_submitted_entry)
    Error(_) -> normalize_submitted_entry(raw)
  }
}

fn normalize_submitted_entry(entry: Dynamic) -> List(signals.NormalizedSignal) {
  case decode.run(entry, decode.list(decode.dynamic)) {
    Ok(contents) -> list.map(contents, normalize_submitted_content)
    Error(_) -> [normalize_submitted_content(entry)]
  }
}

fn normalize_submitted_content(content: Dynamic) -> signals.NormalizedSignal {
  case decode.run(content, decode.dict(decode.string, decode.dynamic)) {
    Ok(fields) -> signals.normalize_signal(fields)
    // A pre-v2 driver's content is an opaque payload — in practice the JSON
    // string the container stringified — and relays exactly as it arrived.
    Error(_) ->
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
