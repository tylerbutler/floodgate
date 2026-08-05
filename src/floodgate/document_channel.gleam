//// Fluid document channel — connect_document join, submitOp shared sequencing
//// + op fan-out (with contents), nack, submitSignal fan-out, requestOps delta
//// catch-up. Gleam analogue of levee's DocumentChannel.

import beryl
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
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
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

pub fn new(
  channels: beryl.Channels,
  sess: Session,
  configured_tenant: String,
  secret: String,
) -> Channel(DocAssigns, info) {
  channel.new(fn(t, p, s) {
    join(channels, sess, configured_tenant, secret, t, p, s)
  })
  |> channel.with_handle_in(fn(e, p, s) {
    handle_in(channels, sess, configured_tenant, secret, e, p, s)
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
  configured_tenant: String,
  secret: String,
  topic,
  payload: Dynamic,
  sock: Socket(DocAssigns),
) {
  let cid = socket.id(sock)
  case is_connect_payload(payload) {
    True ->
      case
        connect_core(
          channels,
          sess,
          configured_tenant,
          secret,
          topic,
          payload,
          cid,
        )
      {
        Error(error) -> join_error(error)
        Ok(#(response, assigns)) ->
          JoinOk(
            reply: Some(response),
            socket: socket.set_assigns(sock, assigns),
          )
      }
    False ->
      case authorize_topic_token(configured_tenant, secret, topic, payload) {
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
  configured_tenant: String,
  secret: String,
  topic: String,
  payload: Dynamic,
  cid: String,
) -> Result(#(json.Json, DocAssigns), ConnectError) {
  case authorize(configured_tenant, secret, topic, payload) {
    Error(error) -> Error(error)
    Ok(claims) -> {
      let mode = connection_mode(payload)
      let client = client_json(mode, claims)
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
          client_join_data(cid, mode, claims),
          now_seconds() * 1000,
        )
      let initial_signals = case mode {
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
          // Fluid Presence relies on the self join signal after the connection
          // has a client ID. Returning it as an initial signal preserves that
          // ordering while the sequenced join op is fanned out to peers.
          [presence_join(cid, mode, claims)]
        }
        _ -> {
          beryl.broadcast_from(
            channels,
            cid,
            topic,
            events.signal,
            presence_join(cid, mode, claims),
          )
          [presence_join(cid, mode, claims)]
        }
      }
      Ok(#(
        connected_response(
          claims,
          cid,
          mode,
          existing,
          roster,
          initial_ops,
          initial_signals,
          summary_handle,
          summary_sequence_number,
          current_sequence_number,
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

fn presence_join(
  client_id: String,
  mode: String,
  claims: TokenClaims,
) -> json.Json {
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
            #("client", client_json(mode, claims)),
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

fn client_join_data(
  client_id: String,
  mode: String,
  claims: TokenClaims,
) -> String {
  json.object([
    #("clientId", json.string(client_id)),
    #("detail", client_json(mode, claims)),
  ])
  |> json.to_string
}

fn client_json(mode: String, claims: TokenClaims) -> json.Json {
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

/// Verify the topic names a document under this tenant and that the payload
/// carries a token granting read access to it. Shared by both join paths; the
/// Phoenix path stops here because `mode` is not known until connect.
fn authorize_topic_token(
  configured_tenant: String,
  secret: String,
  topic: String,
  payload: Dynamic,
) -> Result(TokenClaims, ConnectError) {
  case string.split(topic, ":") {
    ["document", tenant, doc] if tenant == configured_tenant ->
      case
        auth.verify(
          field(payload, "token", ""),
          secret,
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
            False -> Error(unauthorized(403, "Token lacks document read scope"))
            True -> Ok(claims)
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
  configured_tenant: String,
  secret: String,
  topic: String,
  payload: Dynamic,
) -> Result(TokenClaims, ConnectError) {
  use claims <- result.try(authorize_topic_token(
    configured_tenant,
    secret,
    topic,
    payload,
  ))
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
  initial_signals: List(json.Json),
  summary_handle: String,
  summary_sequence_number: Int,
  current_sequence_number: Int,
) -> json.Json {
  json.object([
    #("claims", claims_json(claims)),
    #("clientId", json.string(client_id)),
    #("existing", json.bool(existing)),
    #("maxMessageSize", json.int(16 * 1024 * 1024)),
    #("mode", json.string(mode)),
    #(
      "serviceConfiguration",
      json.object([
        #("blockSize", json.int(64 * 1024)),
        #("maxMessageSize", json.int(16 * 1024 * 1024)),
      ]),
    ),
    #("initialClients", initial_clients_json(roster)),
    #("initialMessages", ops_json(initial_ops)),
    #("initialSignals", json.preprocessed_array(initial_signals)),
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
  configured_tenant: String,
  secret: String,
  event,
  payload: Dynamic,
  sock: Socket(DocAssigns),
) {
  let a = socket.get_assigns(sock)
  case event, a.connected {
    e, False if e == events.connect_document ->
      connect_phase_two(
        channels,
        sess,
        configured_tenant,
        secret,
        payload,
        sock,
        a,
      )
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
      submit_signals(channels, payload, sock, a)
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
  configured_tenant: String,
  secret: String,
  payload: Dynamic,
  sock: Socket(DocAssigns),
  a: DocAssigns,
) {
  case
    connect_core(
      channels,
      sess,
      configured_tenant,
      secret,
      a.topic,
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

fn persist_summary(
  storage: store.Backend,
  topic: String,
  contents: SummarizeContents,
) -> Result(String, String) {
  case topic_ids(topic) {
    Error(reason) -> Error(reason)
    Ok(#(tenant, document_id)) ->
      case git.fetch(storage, tenant, contents.handle) {
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
          case git.create(storage, tenant, "commits", commit) {
            Error(_) -> Error("Could not store summary commit")
            Ok(commit_sha) -> {
              git.put_ref(
                storage,
                tenant,
                "refs/heads/" <> document_id,
                commit_sha,
              )
              Ok(commit_sha)
            }
          }
        }
      }
  }
}

fn topic_ids(topic: String) -> Result(#(String, String), String) {
  case string.split(topic, ":") {
    ["document", tenant, document_id] -> Ok(#(tenant, document_id))
    _ -> Error("Invalid document topic")
  }
}

fn submit_signals(channels, payload: Dynamic, sock, a: DocAssigns) {
  case
    field(payload, "clientId", "") == a.client_id,
    submitted_signals(payload)
  {
    True, Ok(contents) -> {
      list.each(contents, fn(content) {
        beryl.broadcast(
          channels,
          a.topic,
          events.signal,
          json.object([
            #("clientId", json.string(a.client_id)),
            #("content", content),
          ]),
        )
      })
      NoReply(sock)
    }
    _, _ -> NoReply(sock)
  }
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
/// Targeting fields are parsed but not yet honoured: floodgate has no
/// per-socket push, so every signal is broadcast to the topic.
fn submitted_signals(payload: Dynamic) -> Result(List(json.Json), Nil) {
  let batches_decoder = {
    use batches <- decode.field("contentBatches", decode.list(decode.dynamic))
    decode.success(batches)
  }
  case decode.run(payload, batches_decoder) {
    Ok(batches) ->
      Ok(
        list.flat_map(batches, fn(batch) {
          signals.normalize_signal_batch(batch)
          |> list.map(fn(signal) { dynamic_json(signal.content) })
        }),
      )
    Error(_) -> legacy_submitted_signals(payload)
  }
}

fn legacy_submitted_signals(payload: Dynamic) -> Result(List(json.Json), Nil) {
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
  |> result.map(list.map(_, json.string))
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
