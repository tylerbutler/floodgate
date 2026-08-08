//// Fluid document channel — connect_document join, submitOp shared sequencing
//// + op fan-out (with contents), nack, submitSignal fan-out, requestOps delta
//// catch-up. Gleam analogue of levee's DocumentChannel.

import beryl.{type RegisteredChannel}
import beryl/channel.{type Channel, JoinError, JoinOk, NoReply, Push}
import beryl/socket.{type Socket}
import dewdrop/events
import floodgate/auth
import floodgate/connect_document
import floodgate/git
import floodgate/session.{type Session}
import floodgate/session_logic
import floodgate/signals
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

pub type DocAssigns {
  DocAssigns(
    client_id: String,
    mode: String,
    topic: String,
    scopes: List(String),
    connected: Bool,
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
  sess: Session,
  registration: Registration,
) -> Channel(DocAssigns, DocInfo) {
  channel.new(fn(t, p, s) { join(channels, sess, t, p, s) })
  |> channel.with_handle_in(fn(e, p, s) {
    handle_in(channels, sess, registration, e, p, s)
  })
  |> channel.with_handle_info(fn(info, s) {
    case info {
      SignalPush(payload) -> Push(events.signal, payload, s)
    }
  })
  |> channel.with_terminate(fn(_reason, s) { on_leave(channels, sess, s) })
}

/// Two wire protocols enter this channel differently. Socket.IO carries the
/// whole `connect_document` payload as the join, so joining and connecting are
/// one step. A Phoenix `phx_join` carries only `{token}` — `mode` and the rest
/// of IConnect arrive later on the `connect_document` event — so the socket
/// joins first and connects in a second phase.
fn join(
  channels,
  sess: Session,
  topic,
  payload: Dynamic,
  sock: Socket(DocAssigns),
) {
  let cid = socket.id(sock)
  case is_connect_payload(payload) {
    True ->
      case connect_core(channels, sess, topic, payload, cid) {
        Error(error) -> join_error(error)
        Ok(#(response, assigns)) ->
          JoinOk(
            reply: Some(response),
            socket: socket.set_assigns(sock, assigns),
          )
      }
    False ->
      case authorize_topic_token(session.storage(sess), topic, payload) {
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

/// Assigns for a Phoenix socket that has joined but not yet connected.
fn pending_assigns(topic: String) -> DocAssigns {
  DocAssigns(
    client_id: "",
    mode: "",
    topic: topic,
    scopes: [],
    connected: False,
  )
}

fn join_error(error: ConnectError) {
  JoinError(json.object([#("reason", json.string(error.reason))]))
}

fn connect_error_json(error: ConnectError) -> json.Json {
  json.object([
    #("code", json.int(error.code)),
    #("message", json.string(error.message)),
  ])
}

/// Authorize, open the session, fan out the join, and build the connected
/// response. Shared by the Socket.IO join and the Phoenix `connect_document`.
fn connect_core(
  channels,
  sess: Session,
  topic: String,
  payload: Dynamic,
  cid: String,
) -> Result(#(json.Json, DocAssigns), ConnectError) {
  case authorize(session.storage(sess), topic, payload) {
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
        membership,
      ) =
        session.connect(
          sess,
          topic,
          cid,
          mode,
          json.to_string(client),
          client_join_data(cid, client),
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
      case mode {
        "write" -> {
          let assert Some(#(sn, message)) = membership
          // The joining client receives its own join op in initialMessages.
          // Excluding it from fan-out avoids an early duplicate before the
          // connect response has established its client ID.
          beryl.broadcast_from(
            channels,
            cid,
            topic,
            events.op,
            json.preprocessed_array([
              session.stored_message_json(#(sn, message)),
            ]),
          )
        }
        _ ->
          beryl.broadcast_from(
            channels,
            cid,
            topic,
            events.signal,
            presence_join(cid, client),
          )
      }
      Ok(#(
        connected_response(
          claims,
          cid,
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
          client_id: cid,
          mode: mode,
          topic: topic,
          scopes: types.scopes_to_strings(claims.scopes),
          connected: True,
        ),
      ))
    }
  }
}

fn on_leave(channels, sess: Session, sock: Socket(DocAssigns)) {
  let a = socket.get_assigns(sock)
  // A Phoenix socket that joined but never sent connect_document holds no
  // session membership, so there is nothing to tear down or announce.
  use <- bool.guard(when: !a.connected, return: Nil)
  case a.mode {
    "write" -> {
      let session.Left(sn, _, message) =
        session.leave_sequenced(
          sess,
          a.topic,
          a.client_id,
          now_seconds() * 1000,
        )
      beryl.broadcast(
        channels,
        a.topic,
        events.op,
        json.preprocessed_array([
          session.stored_message_json(#(sn, message)),
        ]),
      )
    }
    _ -> {
      session.leave_presence(sess, a.topic, a.client_id)
      beryl.broadcast(
        channels,
        a.topic,
        events.signal,
        presence_leave(a.client_id),
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
    Ok(parsed) -> dynamic_json(parsed)
    Error(_) -> value
  }
}

/// Expose the dynamic → JSON conversion the roster path uses, so tests can
/// assert on the exact bytes a client payload serializes to.
pub fn dynamic_to_json(value: Dynamic) -> json.Json {
  dynamic_json(value)
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
        Ok(_) -> Some(normalize_client_json(dynamic_json(client)))
        Error(_) -> None
      }
    Error(_) -> None
  }
}

fn client_json(mode: String, claims: TokenClaims) -> json.Json {
  normalize_client_json(raw_client_json(mode, claims))
}

fn raw_client_json(mode: String, claims: TokenClaims) -> json.Json {
  json.object([
    #("mode", json.string(mode)),
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

fn connection_mode(payload: Dynamic) -> String {
  case field(payload, "mode", "read") {
    "write" -> "write"
    _ -> "read"
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
  mode: String,
  existing: Bool,
  roster: List(#(String, String)),
  initial_ops: List(#(Int, String)),
  summary_handle: String,
  summary_sequence_number: Int,
  current_sequence_number: Int,
  max_message_size: Int,
) -> json.Json {
  json.object([
    #("claims", claims_json(claims)),
    #("clientId", json.string(client_id)),
    #("existing", json.bool(existing)),
    // Sourced from beryl's configured frame ceiling rather than hardcoded, so
    // what we advertise is what the transports actually enforce. This used to
    // claim 16 MiB while beryl's default enforced 1 MiB and the Engine.IO
    // handshake advertised 1 MiB — three numbers, one of them a fiction.
    #("maxMessageSize", json.int(max_message_size)),
    #("mode", json.string(mode)),
    #(
      "serviceConfiguration",
      json.object([
        #("blockSize", json.int(64 * 1024)),
        #("maxMessageSize", json.int(max_message_size)),
      ]),
    ),
    #("initialClients", initial_clients_json(roster)),
    #("initialMessages", ops_json(initial_ops)),
    // Always empty, matching levee. See the 0x4b2 note in `connect_core`.
    #("initialSignals", json.preprocessed_array([])),
    #("supportedVersions", json.array(["^0.1.0", "^1.0.0"], json.string)),
    #("version", json.string("1.0.0")),
    #("checkpointSequenceNumber", json.int(current_sequence_number)),
    #("summaryHandle", json.string(summary_handle)),
    #("summarySequenceNumber", json.int(summary_sequence_number)),
  ])
}

fn claims_json(claims: TokenClaims) -> json.Json {
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
    list.map(roster, fn(entry) {
      let #(client_id, serialized_client) = entry
      let assert Ok(client) = json.parse(serialized_client, decode.dynamic)
      json.object([
        #("clientId", json.string(client_id)),
        #("client", dynamic_json(client)),
      ])
    }),
  )
}

@external(erlang, "floodgate_ffi", "now_seconds")
fn now_seconds() -> Int

fn handle_in(
  channels,
  sess: Session,
  registration: Registration,
  event,
  payload: Dynamic,
  sock: Socket(DocAssigns),
) {
  let a = socket.get_assigns(sock)
  case event, a.connected {
    e, False if e == events.connect_document ->
      connect_phase_two(channels, sess, payload, sock, a)
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
      submit_op(channels, sess, payload, sock, a)
    e, True if e == events.submit_signal ->
      submit_signals(channels, sess, registration, payload, sock, a)
    "requestOps", True ->
      Push(
        events.op,
        ops_json(session.since(sess, a.topic, int_field(payload, "from", 0))),
        sock,
      )
    // Without this an idle levee-mode client never advances its reference
    // sequence number and the minimum sequence number stalls for the document.
    "noop", True -> {
      case field(payload, "clientId", "") == a.client_id {
        False -> Nil
        True ->
          session.update_client_rsn(
            sess,
            a.topic,
            a.client_id,
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
            session.sequence_number(sess, a.topic),
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
  channels,
  sess: Session,
  payload: Dynamic,
  sock: Socket(DocAssigns),
  a: DocAssigns,
) {
  case connect_core(channels, sess, a.topic, payload, socket.id(sock)) {
    Ok(#(response, assigns)) ->
      Push(
        events.connect_document_success,
        response,
        socket.set_assigns(sock, assigns),
      )
    Error(error) ->
      Push(events.connect_document_error, connect_error_json(error), sock)
  }
}

fn submit_op(channels, sess: Session, payload, sock, a: DocAssigns) {
  case a.mode {
    "write" -> submit_writable_ops(channels, sess, payload, sock, a)
    _ ->
      Push(
        events.nack,
        json.preprocessed_array([
          nack_json(None, 0, 403, "Read-only clients cannot submit operations"),
        ]),
        sock,
      )
  }
}

fn submit_writable_ops(channels, sess, payload, sock, a: DocAssigns) {
  case field(payload, "clientId", "") == a.client_id, submitted_ops(payload) {
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
              case list.contains(a.scopes, "summary:write") {
                True -> submit_summary_op(channels, sess, op, a, nacks)
                False -> [
                  nack_json(
                    Some(op),
                    session.sequence_number(sess, a.topic),
                    403,
                    "Summary scope required",
                  ),
                  ..nacks
                ]
              }
            _ ->
              case
                session.submit_message(
                  sess,
                  a.topic,
                  a.client_id,
                  op.client_sequence_number,
                  op.reference_sequence_number,
                  fn(sn, msn) {
                    sequenced_op_json(a.client_id, op, sn, msn)
                    |> json.to_string
                  },
                )
              {
                session.MessageAssigned(sn, _, message) -> {
                  beryl.broadcast(
                    channels,
                    a.topic,
                    events.op,
                    json.preprocessed_array([
                      session.stored_message_json(#(sn, message)),
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
  channels,
  sess: Session,
  op: SubmittedOp,
  a: DocAssigns,
  nacks,
) {
  case
    session.submit_summary_messages(
      sess,
      a.topic,
      a.client_id,
      op.client_sequence_number,
      op.reference_sequence_number,
      fn(summary_sn, response_sn, msn) {
        let outcome = case summarize_contents(op.contents) {
          Error(reason) -> #(None, reason)
          Ok(contents) ->
            case persist_summary(session.storage(sess), a.topic, contents) {
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
          sequenced_op_json(a.client_id, op, summary_sn, msn)
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
      publish_summary_ref(sess, a.topic)
      beryl.broadcast(
        channels,
        a.topic,
        events.op,
        json.preprocessed_array([
          session.stored_message_json(#(summary_sn, summary_message)),
          session.stored_message_json(#(response_sn, response_message)),
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

fn summarize_contents_decoder() {
  use handle <- decode.field("handle", decode.string)
  use message <- decode.field("message", decode.string)
  use parents <- decode.field("parents", decode.list(decode.string))
  use head <- decode.field("head", decode.string)
  decode.success(SummarizeContents(handle, message, parents, head))
}

/// Point `refs/heads/<document_id>` at whatever summary commit the session
/// currently holds. A no-op when there is none.
fn publish_summary_ref(sess: Session, topic: String) -> Nil {
  case topic_ids(topic), session.summary(sess, topic) {
    Ok(#(tenant, document_id)), #(handle, _sn) if handle != "" ->
      git.publish_summary_ref(
        session.storage(sess),
        tenant,
        document_id,
        handle,
      )
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
  channels,
  sess: Session,
  registration: Registration,
  payload: Dynamic,
  sock,
  a: DocAssigns,
) {
  case
    field(payload, "clientId", "") == a.client_id,
    submitted_signals(payload)
  {
    True, Ok(signals) -> {
      list.each(signals, fn(signal) {
        relay_signal(channels, sess, registration, a, signal)
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
  channels,
  sess: Session,
  registration: Registration,
  a: DocAssigns,
  signal: signals.NormalizedSignal,
) -> Nil {
  let message =
    json.object([
      #("clientId", json.string(a.client_id)),
      #("content", dynamic_json(signal.content)),
    ])

  case targeted(signal), registered_channel(registration) {
    // Untargeted, or no registration handle to push through: broadcast, which
    // is what this did unconditionally before targeting was honoured.
    False, _ | _, None ->
      beryl.broadcast(channels, a.topic, events.signal, message)
    True, Some(registered) ->
      session_logic.determine_signal_recipients(
        a.client_id,
        signal.targeted_clients,
        signal.ignored_clients,
        signal.target_client_id,
        session.clients(sess, a.topic),
      )
      // The Fluid client id *is* the beryl socket id — `join` assigns
      // `socket.id(sock)` as the client id — so a recipient addresses a socket
      // directly, with no mapping to maintain.
      |> list.each(fn(recipient) {
        beryl.send_info(registered, recipient, a.topic, SignalPush(message))
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

fn submitted_ops(payload: Dynamic) {
  let decoder = {
    use batches <- decode.field(
      "messageBatches",
      decode.list(decode.list(submitted_op_decoder())),
    )
    decode.success(list.flatten(batches))
  }
  decode.run(payload, decoder)
}

fn submitted_op_decoder() {
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

fn optional_dynamic_field(name: String, next) {
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
    list.map(_, fn(content) { signals.untargeted(dynamic.string(content)) }),
  )
  |> result.replace_error(Nil)
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
    #("contents", dynamic_json(op.contents)),
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
  |> list.map(fn(field) { #(field.0, dynamic_json(field.1)) })
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
        #("contents", dynamic_json(op.contents)),
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
    Some(value) -> list.append(fields, [#(name, dynamic_json(value))])
    None -> fields
  }
}

fn dynamic_json(value: Dynamic) -> json.Json {
  case decode.run(value, decode.optional(decode.dynamic)) {
    Ok(None) -> json.null()
    _ -> non_null_dynamic_json(value)
  }
}

fn non_null_dynamic_json(value: Dynamic) -> json.Json {
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
                      json.preprocessed_array(list.map(values, dynamic_json))
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
                            #(entry.0, dynamic_json(entry.1))
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

fn ops_json(ops: List(#(Int, String))) -> json.Json {
  json.preprocessed_array(list.map(ops, session.stored_message_json))
}

fn field(v: Dynamic, k: String, d: String) -> String {
  case decode.run(v, decode.field(k, decode.string, decode.success)) {
    Ok(x) -> x
    Error(_) -> d
  }
}

fn int_field(v: Dynamic, k: String, d: Int) -> Int {
  case decode.run(v, decode.field(k, decode.int, decode.success)) {
    Ok(x) -> x
    Error(_) -> d
  }
}
