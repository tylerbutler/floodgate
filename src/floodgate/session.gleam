//// Per-document session registry — shared sequencing + op history across all
//// sockets on a `document:*` topic (beryl assigns are per-socket). Analogue of
//// levee's Elixir Session GenServer: SN assignment + delta catch-up history.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import floodgate/store
import spillway/sequencing

pub opaque type Session {
  Session(subject: Subject(Msg))
}

pub type Msg {
  Join(topic: String, client_id: String)
  Submit(
    topic: String,
    client_id: String,
    csn: Int,
    rsn: Int,
    contents: String,
    reply: Subject(SubmitResult),
  )
  Since(topic: String, sn: Int, reply: Subject(List(#(Int, String))))
  Clients(topic: String, reply: Subject(List(String)))
  SetSummary(topic: String, handle: String, sn: Int)
  GetSummary(topic: String, reply: Subject(#(String, Int)))
}

pub type SubmitResult {
  Assigned(sn: Int, msn: Int)
  Rejected
}

type Doc {
  Doc(
    seq: sequencing.SequenceState,
    history: List(#(Int, String)),
    summary: #(String, Int),
  )
}

type State {
  State(docs: Dict(String, Doc))
}

pub fn start() -> Session {
  store.open()
  let assert Ok(s) =
    actor.new(State(dict.new())) |> actor.on_message(handle) |> actor.start
  Session(s.data)
}

pub fn join(s: Session, topic: String, c: String) {
  process.send(s.subject, Join(topic, c))
}

pub fn submit(
  s: Session,
  t: String,
  c: String,
  csn: Int,
  rsn: Int,
  contents: String,
) -> SubmitResult {
  process.call(s.subject, 1000, Submit(t, c, csn, rsn, contents, _))
}

pub fn since(s: Session, t: String, sn: Int) -> List(#(Int, String)) {
  process.call(s.subject, 1000, Since(t, sn, _))
}

pub fn clients(s: Session, t: String) -> List(String) {
  process.call(s.subject, 1000, Clients(t, _))
}

pub fn set_summary(s: Session, t: String, handle: String, sn: Int) {
  process.send(s.subject, SetSummary(t, handle, sn))
}

pub fn summary(s: Session, t: String) -> #(String, Int) {
  process.call(s.subject, 1000, GetSummary(t, _))
}

fn doc(st: State, t: String) -> Doc {
  case dict.get(st.docs, t) {
    Ok(d) -> d
    Error(Nil) -> {
      // Rebuild durable state from ETS so a restarted server keeps numbering
      // after the last persisted op and serves the latest summary.
      let ops = store.get_ops(t)
      let last_sn =
        list.fold(ops, 0, fn(m, o) {
          case o.0 > m {
            True -> o.0
            False -> m
          }
        })
      let #(handle, ssn) = store.get_summary(t)
      Doc(sequencing.from_checkpoint(last_sn, ssn), ops, #(handle, ssn))
    }
  }
}

fn handle(st: State, m: Msg) -> actor.Next(State, Msg) {
  case m {
    Join(t, c) -> {
      let d = doc(st, t)
      actor.continue(
        State(dict.insert(
          st.docs,
          t,
          Doc(..d, seq: sequencing.client_join(d.seq, c, 0)),
        )),
      )
    }
    Submit(t, c, csn, rsn, contents, reply) -> {
      let d = doc(st, t)
      case sequencing.assign_sequence_number(d.seq, c, csn, rsn) {
        sequencing.SequenceOk(seq, sn, msn) -> {
          process.send(reply, Assigned(sn, msn))
          store.put_op(t, sn, contents)
          actor.continue(
            State(dict.insert(
              st.docs,
              t,
              Doc(
                ..d,
                seq: seq,
                history: list.append(d.history, [#(sn, contents)]),
              ),
            )),
          )
        }
        sequencing.SequenceError(_) -> {
          process.send(reply, Rejected)
          actor.continue(st)
        }
      }
    }
    Since(t, sn, reply) -> {
      process.send(reply, store.get_ops(t) |> list.filter(fn(o) { o.0 > sn }))
      actor.continue(st)
    }
    Clients(t, reply) -> {
      process.send(reply, dict.keys(doc(st, t).seq.client_states))
      actor.continue(st)
    }
    SetSummary(t, handle, sn) -> {
      store.put_summary(t, handle, sn)
      let d = doc(st, t)
      actor.continue(
        State(dict.insert(st.docs, t, Doc(..d, summary: #(handle, sn)))),
      )
    }
    GetSummary(t, reply) -> {
      process.send(reply, store.get_summary(t))
      actor.continue(st)
    }
  }
}
