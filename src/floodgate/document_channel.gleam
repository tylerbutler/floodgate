//// Fluid document channel — connect_document join, submitOp shared sequencing
//// + op fan-out (with contents), nack, submitSignal fan-out, requestOps delta
//// catch-up. Gleam analogue of levee's DocumentChannel.

import beryl
import beryl/channel.{type Channel, JoinError, JoinOk, NoReply, Push}
import beryl/socket.{type Socket}
import dewdrop/events
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string
import floodgate/auth
import floodgate/session.{type Session}

pub type DocAssigns {
  DocAssigns(client_id: String, mode: String, topic: String)
}

pub fn new(
  channels: beryl.Channels,
  sess: Session,
  secret: String,
) -> Channel(DocAssigns, info) {
  channel.new(fn(t, p, s) { join(channels, sess, secret, t, p, s) })
  |> channel.with_handle_in(fn(e, p, s) { handle_in(channels, sess, e, p, s) })
  |> channel.with_terminate(fn(_reason, s) { on_leave(channels, s) })
}

fn join(
  channels,
  sess: Session,
  secret: String,
  topic,
  payload: Dynamic,
  sock: Socket(DocAssigns),
) {
  let cid = field(payload, "clientId", "anon")
  case authorize(secret, topic, payload) {
    Error(reason) -> JoinError(json.object([#("reason", json.string(reason))]))
    Ok(_) -> {
      let roster = session.clients(sess, topic)
      let #(sh, ssn) = session.summary(sess, topic)
      session.join(sess, topic, cid)
      beryl.broadcast(
        channels,
        topic,
        events.signal,
        presence(cid, "ClientJoin"),
      )
      JoinOk(
        reply: Some(
          json.object([
            #("status", json.string("ok")),
            #("submit_signals_v2", json.bool(True)),
            #("clients", json.array(roster, json.string)),
            #("summaryHandle", json.string(sh)),
            #("summarySequenceNumber", json.int(ssn)),
          ]),
        ),
        socket: socket.set_assigns(
          sock,
          DocAssigns(cid, field(payload, "mode", "write"), topic),
        ),
      )
    }
  }
}

fn on_leave(channels, sock: Socket(DocAssigns)) {
  let a = socket.get_assigns(sock)
  beryl.broadcast(
    channels,
    a.topic,
    events.signal,
    presence(a.client_id, "ClientLeave"),
  )
}

fn presence(client_id: String, kind: String) -> json.Json {
  json.object([
    #("clientId", json.string(client_id)),
    #("type", json.string(kind)),
  ])
}

fn authorize(
  secret: String,
  topic: String,
  payload: Dynamic,
) -> Result(Nil, String) {
  case secret {
    "" -> Ok(Nil)
    _ ->
      case string.split(topic, ":") {
        ["document", tenant, doc] ->
          case
            auth.verify(
              field(payload, "token", ""),
              secret,
              tenant,
              doc,
              now_seconds(),
            )
          {
            Ok(_) -> Ok(Nil)
            Error(_) -> Error("unauthorized")
          }
        _ -> Error("invalid_topic")
      }
  }
}

@external(erlang, "floodgate_ffi", "now_seconds")
fn now_seconds() -> Int

fn handle_in(
  channels,
  sess: Session,
  event,
  payload: Dynamic,
  sock: Socket(DocAssigns),
) {
  let a = socket.get_assigns(sock)
  case event {
    e if e == events.submit_op -> submit_op(channels, sess, payload, sock, a)
    e if e == events.submit_signal -> {
      beryl.broadcast(
        channels,
        a.topic,
        events.signal,
        json.object([#("clientId", json.string(a.client_id))]),
      )
      NoReply(sock)
    }
    "requestOps" ->
      Push(
        events.op,
        ops_json(session.since(sess, a.topic, int_field(payload, "from", 0))),
        sock,
      )
    e if e == events.submit_summary -> {
      let handle = field(payload, "handle", "")
      let sn = int_field(payload, "sequenceNumber", 0)
      session.set_summary(sess, a.topic, handle, sn)
      beryl.broadcast(
        channels,
        a.topic,
        events.summary_ack,
        json.object([
          #("handle", json.string(handle)),
          #("summarySequenceNumber", json.int(sn)),
        ]),
      )
      NoReply(sock)
    }
    _ -> NoReply(sock)
  }
}

fn submit_op(channels, sess: Session, payload, sock, a: DocAssigns) {
  let contents = field(payload, "contents", "")
  case
    session.submit(
      sess,
      a.topic,
      a.client_id,
      int_field(payload, "csn", 1),
      int_field(payload, "rsn", 0),
      contents,
    )
  {
    session.Assigned(sn, msn) -> {
      beryl.broadcast(
        channels,
        a.topic,
        events.op,
        json.object([
          #("clientId", json.string(a.client_id)),
          #("sequenceNumber", json.int(sn)),
          #("minimumSequenceNumber", json.int(msn)),
          #("contents", json.string(contents)),
        ]),
      )
      NoReply(sock)
    }
    session.Rejected -> {
      beryl.broadcast(
        channels,
        a.topic,
        events.nack,
        json.object([
          #("clientId", json.string(a.client_id)),
          #("code", json.int(400)),
        ]),
      )
      NoReply(sock)
    }
  }
}

fn ops_json(ops: List(#(Int, String))) -> json.Json {
  json.preprocessed_array(
    list.map(ops, fn(o) {
      json.object([
        #("sequenceNumber", json.int(o.0)),
        #("contents", json.string(o.1)),
      ])
    }),
  )
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
