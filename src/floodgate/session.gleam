//// Per-document session registry — shared sequencing + op history across all
//// sockets on a `document:*` topic (beryl assigns are per-socket). Analogue of
//// levee's Elixir Session GenServer: SN assignment + delta catch-up history.

import floodgate/memory_store
import floodgate/store
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import spillway/sequencing

pub opaque type Session {
  Session(subject: Subject(Msg), storage: store.Backend)
}

pub type Msg {
  Create(topic: String, reply: Subject(Bool))
  CreateInitialized(
    topic: String,
    build: fn() -> Result(Option(#(String, Int)), Nil),
    reply: Subject(CreateInitializedResult),
  )
  Connect(
    topic: String,
    client_id: String,
    mode: String,
    client: String,
    join_data: String,
    timestamp: Int,
    reply: Subject(ConnectionResult),
  )
  Join(topic: String, client_id: String, reply: Subject(Bool))
  JoinPresence(
    topic: String,
    client_id: String,
    mode: String,
    reply: Subject(Bool),
  )
  JoinSequenced(
    topic: String,
    client_id: String,
    data: String,
    timestamp: Int,
    reply: Subject(JoinResult),
  )
  Leave(topic: String, client_id: String)
  LeavePresence(topic: String, client_id: String)
  LeaveSequenced(
    topic: String,
    client_id: String,
    timestamp: Int,
    reply: Subject(LeaveResult),
  )
  Submit(
    topic: String,
    client_id: String,
    csn: Int,
    rsn: Int,
    contents: String,
    reply: Subject(SubmitResult),
  )
  SubmitMessage(
    topic: String,
    client_id: String,
    csn: Int,
    rsn: Int,
    build: fn(Int, Int) -> String,
    reply: Subject(SubmitMessageResult),
  )
  SubmitSummary(
    topic: String,
    client_id: String,
    csn: Int,
    rsn: Int,
    contents: String,
    response_contents: String,
    handle: Option(String),
    reply: Subject(SubmitSummaryResult),
  )
  SubmitSummaryMessages(
    topic: String,
    client_id: String,
    csn: Int,
    rsn: Int,
    build: fn(Int, Int, Int) -> #(String, String, Option(String)),
    reply: Subject(SubmitSummaryMessagesResult),
  )
  Since(topic: String, sn: Int, reply: Subject(List(#(Int, String))))
  Clients(topic: String, reply: Subject(List(String)))
  Roster(topic: String, reply: Subject(List(#(String, String))))
  Exists(topic: String, reply: Subject(Bool))
  SequenceNumber(topic: String, reply: Subject(Int))
  InitializeSummary(topic: String, handle: String, sn: Int, reply: Subject(Nil))
  SetSummary(topic: String, handle: String, sn: Int)
  GetSummary(topic: String, reply: Subject(#(String, Int)))
  UpdateClientRsn(topic: String, client_id: String, rsn: Int)
}

pub type SubmitResult {
  Assigned(sn: Int, msn: Int)
  Rejected(current_sn: Int)
}

pub type CreateInitializedResult {
  Created
  AlreadyExists
  InvalidInitialSummary
}

pub type SubmitMessageResult {
  MessageAssigned(sn: Int, msn: Int, message: String)
  MessageRejected(current_sn: Int)
}

pub type JoinResult {
  Joined(existing: Bool, sn: Int, msn: Int, message: String)
}

pub type ConnectionResult {
  Connected(
    existing: Bool,
    roster: List(#(String, String)),
    initial_ops: List(#(Int, String)),
    summary_handle: String,
    summary_sequence_number: Int,
    current_sequence_number: Int,
    membership: Option(#(Int, String)),
  )
}

pub type LeaveResult {
  Left(sn: Int, msn: Int, message: String)
}

pub type SubmitSummaryResult {
  SummaryAssigned(summary_sn: Int, response_sn: Int, msn: Int)
  SummaryRejected(current_sn: Int)
}

pub type SubmitSummaryMessagesResult {
  SummaryMessagesAssigned(
    summary_sn: Int,
    response_sn: Int,
    msn: Int,
    summary_message: String,
    response_message: String,
  )
  SummaryMessagesRejected(current_sn: Int)
}

type Doc {
  Doc(
    seq: sequencing.SequenceState,
    history: List(#(Int, String)),
    summary: #(String, Int),
    presence: Dict(String, String),
  )
}

type State {
  State(docs: Dict(String, Doc))
}

/// Start a session over a fresh, ephemeral in-memory backend. For a persistent
/// runtime, construct a `shelf_store` backend and use `start_with_backend`.
pub fn start() -> Session {
  start_with_backend(memory_store.new())
}

pub fn start_with_backend(storage: store.Backend) -> Session {
  store.open(storage)
  let assert Ok(s) =
    actor.new(State(dict.new()))
    |> actor.on_message(fn(state, message) { handle(storage, state, message) })
    |> actor.start
  Session(s.data, storage)
}

pub fn storage(session: Session) -> store.Backend {
  session.storage
}

pub fn create(s: Session, topic: String) -> Bool {
  process.call(s.subject, 1000, Create(topic, _))
}

pub fn create_initialized(
  s: Session,
  topic: String,
  build: fn() -> Result(Option(#(String, Int)), Nil),
) -> CreateInitializedResult {
  process.call(s.subject, 10_000, CreateInitialized(topic, build, _))
}

pub fn join(s: Session, topic: String, c: String) -> Bool {
  process.call(s.subject, 1000, Join(topic, c, _))
}

pub fn connect(
  s: Session,
  topic: String,
  client_id: String,
  mode: String,
  client: String,
  join_data: String,
  timestamp: Int,
) -> ConnectionResult {
  process.call(s.subject, 1000, Connect(
    topic,
    client_id,
    mode,
    client,
    join_data,
    timestamp,
    _,
  ))
}

pub fn join_presence(
  s: Session,
  topic: String,
  client_id: String,
  mode: String,
) -> Bool {
  process.call(s.subject, 1000, JoinPresence(topic, client_id, mode, _))
}

pub fn join_sequenced(
  s: Session,
  topic: String,
  client_id: String,
  data: String,
  timestamp: Int,
) -> JoinResult {
  process.call(s.subject, 1000, JoinSequenced(
    topic,
    client_id,
    data,
    timestamp,
    _,
  ))
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

pub fn submit_message(
  s: Session,
  topic: String,
  client_id: String,
  csn: Int,
  rsn: Int,
  build: fn(Int, Int) -> String,
) -> SubmitMessageResult {
  process.call(s.subject, 1000, SubmitMessage(
    topic,
    client_id,
    csn,
    rsn,
    build,
    _,
  ))
}

pub fn submit_summary(
  s: Session,
  topic: String,
  client_id: String,
  csn: Int,
  rsn: Int,
  contents: String,
  response_contents: String,
  handle: Option(String),
) -> SubmitSummaryResult {
  process.call(s.subject, 1000, SubmitSummary(
    topic,
    client_id,
    csn,
    rsn,
    contents,
    response_contents,
    handle,
    _,
  ))
}

pub fn submit_summary_messages(
  s: Session,
  topic: String,
  client_id: String,
  csn: Int,
  rsn: Int,
  build: fn(Int, Int, Int) -> #(String, String, Option(String)),
) -> SubmitSummaryMessagesResult {
  process.call(s.subject, 1000, SubmitSummaryMessages(
    topic,
    client_id,
    csn,
    rsn,
    build,
    _,
  ))
}

pub fn leave(s: Session, topic: String, client_id: String) -> Nil {
  process.send(s.subject, Leave(topic, client_id))
}

pub fn leave_presence(s: Session, topic: String, client_id: String) -> Nil {
  process.send(s.subject, LeavePresence(topic, client_id))
}

pub fn leave_sequenced(
  s: Session,
  topic: String,
  client_id: String,
  timestamp: Int,
) -> LeaveResult {
  process.call(s.subject, 1000, LeaveSequenced(topic, client_id, timestamp, _))
}

pub fn since(s: Session, t: String, sn: Int) -> List(#(Int, String)) {
  process.call(s.subject, 1000, Since(t, sn, _))
}

pub fn clients(s: Session, t: String) -> List(String) {
  process.call(s.subject, 1000, Clients(t, _))
}

pub fn roster(s: Session, t: String) -> List(#(String, String)) {
  process.call(s.subject, 1000, Roster(t, _))
}

pub fn exists(s: Session, t: String) -> Bool {
  process.call(s.subject, 1000, Exists(t, _))
}

pub fn sequence_number(s: Session, t: String) -> Int {
  process.call(s.subject, 1000, SequenceNumber(t, _))
}

pub fn set_summary(s: Session, t: String, handle: String, sn: Int) {
  process.send(s.subject, SetSummary(t, handle, sn))
}

/// Advance a client's reference sequence number without sequencing an op, so
/// an idle client still lets the minimum sequence number move. Fire-and-forget,
/// mirroring levee's `Session.update_client_rsn` cast.
pub fn update_client_rsn(s: Session, t: String, client_id: String, rsn: Int) {
  process.send(s.subject, UpdateClientRsn(t, client_id, rsn))
}

pub fn initialize_summary(s: Session, t: String, handle: String, sn: Int) {
  process.call(s.subject, 1000, InitializeSummary(t, handle, sn, _))
}

pub fn summary(s: Session, t: String) -> #(String, Int) {
  process.call(s.subject, 1000, GetSummary(t, _))
}

fn doc(storage: store.Backend, st: State, t: String) -> Doc {
  case dict.get(st.docs, t) {
    Ok(d) -> d
    Error(Nil) -> {
      // Rebuild durable state from ETS so a restarted server keeps numbering
      // after the last persisted op and serves the latest summary.
      let ops = store.get_ops(storage, t)
      let last_sn =
        list.fold(ops, 0, fn(m, o) {
          case o.0 > m {
            True -> o.0
            False -> m
          }
        })
      let #(handle, ssn) = store.get_summary(storage, t)
      let checkpoint = case ssn > last_sn {
        True -> ssn
        False -> last_sn
      }
      Doc(
        sequencing.from_checkpoint(checkpoint, ssn),
        ops,
        #(handle, ssn),
        dict.new(),
      )
    }
  }
}

fn handle(storage: store.Backend, st: State, m: Msg) -> actor.Next(State, Msg) {
  case m {
    Create(t, reply) -> {
      let existing = case dict.get(st.docs, t) {
        Ok(_) -> True
        Error(Nil) -> stored_document_exists(storage, t)
      }
      store.put_document(storage, t)
      process.send(reply, existing)
      actor.continue(State(dict.insert(st.docs, t, doc(storage, st, t))))
    }
    CreateInitialized(t, build, reply) -> {
      let existing = case dict.get(st.docs, t) {
        Ok(_) -> True
        Error(Nil) -> stored_document_exists(storage, t)
      }
      case existing {
        True -> {
          process.send(reply, AlreadyExists)
          actor.continue(st)
        }
        False ->
          case build() {
            Error(Nil) -> {
              process.send(reply, InvalidInitialSummary)
              actor.continue(st)
            }
            Ok(summary) -> {
              store.put_document(storage, t)
              let #(seq, summary_state) = case summary {
                Some(#(handle, sn)) -> {
                  store.put_summary(storage, t, handle, sn)
                  #(sequencing.from_checkpoint(sn, sn), #(handle, sn))
                }
                None -> #(sequencing.new(), #("", 0))
              }
              process.send(reply, Created)
              actor.continue(
                State(dict.insert(
                  st.docs,
                  t,
                  Doc(seq, [], summary_state, dict.new()),
                )),
              )
            }
          }
      }
    }
    Connect(t, c, mode, client, join_data, timestamp, reply) -> {
      let existing = case dict.get(st.docs, t) {
        Ok(_) -> True
        Error(Nil) -> stored_document_exists(storage, t)
      }
      store.put_document(storage, t)
      let d = doc(storage, st, t)
      let roster = dict.to_list(d.presence)
      let #(handle, summary_sn) = d.summary
      case mode {
        "write" -> {
          let sn = d.seq.sequence_number + 1
          let joined = sequencing.client_join(d.seq, c, d.seq.sequence_number)
          let seq = sequencing.SequenceState(..joined, sequence_number: sn)
          let message =
            system_message(
              "join",
              join_data,
              sn,
              seq.minimum_sequence_number,
              timestamp,
            )
          store.put_op(storage, t, sn, message)
          process.send(
            reply,
            Connected(
              existing,
              roster,
              list.append(d.history, [#(sn, message)]),
              handle,
              summary_sn,
              sn,
              Some(#(sn, message)),
            ),
          )
          actor.continue(
            State(dict.insert(
              st.docs,
              t,
              Doc(
                ..d,
                seq: seq,
                history: list.append(d.history, [#(sn, message)]),
                presence: dict.insert(d.presence, c, client),
              ),
            )),
          )
        }
        _ -> {
          process.send(
            reply,
            Connected(
              existing,
              roster,
              d.history,
              handle,
              summary_sn,
              d.seq.sequence_number,
              None,
            ),
          )
          actor.continue(
            State(dict.insert(
              st.docs,
              t,
              Doc(..d, presence: dict.insert(d.presence, c, client)),
            )),
          )
        }
      }
    }
    Join(t, c, reply) -> {
      let existing = case dict.get(st.docs, t) {
        Ok(_) -> True
        Error(Nil) -> stored_document_exists(storage, t)
      }
      store.put_document(storage, t)
      let d = doc(storage, st, t)
      process.send(reply, existing)
      actor.continue(
        State(dict.insert(
          st.docs,
          t,
          Doc(
            ..d,
            seq: sequencing.client_join(d.seq, c, d.seq.sequence_number),
            presence: dict.insert(d.presence, c, minimal_client("write")),
          ),
        )),
      )
    }
    JoinPresence(t, c, mode, reply) -> {
      let existing = case dict.get(st.docs, t) {
        Ok(_) -> True
        Error(Nil) -> stored_document_exists(storage, t)
      }
      store.put_document(storage, t)
      let d = doc(storage, st, t)
      process.send(reply, existing)
      actor.continue(
        State(dict.insert(
          st.docs,
          t,
          Doc(..d, presence: dict.insert(d.presence, c, minimal_client(mode))),
        )),
      )
    }
    JoinSequenced(t, c, data, timestamp, reply) -> {
      let existing = case dict.get(st.docs, t) {
        Ok(_) -> True
        Error(Nil) -> stored_document_exists(storage, t)
      }
      store.put_document(storage, t)
      let d = doc(storage, st, t)
      let sn = d.seq.sequence_number + 1
      let joined = sequencing.client_join(d.seq, c, d.seq.sequence_number)
      let seq = sequencing.SequenceState(..joined, sequence_number: sn)
      let message =
        system_message("join", data, sn, seq.minimum_sequence_number, timestamp)
      store.put_op(storage, t, sn, message)
      process.send(
        reply,
        Joined(existing, sn, seq.minimum_sequence_number, message),
      )
      actor.continue(
        State(dict.insert(
          st.docs,
          t,
          Doc(
            ..d,
            seq: seq,
            history: list.append(d.history, [#(sn, message)]),
            presence: dict.insert(d.presence, c, minimal_client("write")),
          ),
        )),
      )
    }
    Leave(t, c) -> {
      let d = doc(storage, st, t)
      actor.continue(
        State(dict.insert(
          st.docs,
          t,
          Doc(
            ..d,
            seq: sequencing.client_leave(d.seq, c),
            presence: dict.delete(d.presence, c),
          ),
        )),
      )
    }
    LeavePresence(t, c) -> {
      let d = doc(storage, st, t)
      actor.continue(
        State(dict.insert(
          st.docs,
          t,
          Doc(..d, presence: dict.delete(d.presence, c)),
        )),
      )
    }
    LeaveSequenced(t, c, timestamp, reply) -> {
      let d = doc(storage, st, t)
      let sn = d.seq.sequence_number + 1
      let left = sequencing.client_leave(d.seq, c)
      let seq = sequencing.SequenceState(..left, sequence_number: sn)
      let data = json.string(c) |> json.to_string
      let message =
        system_message(
          "leave",
          data,
          sn,
          seq.minimum_sequence_number,
          timestamp,
        )
      store.put_op(storage, t, sn, message)
      process.send(reply, Left(sn, seq.minimum_sequence_number, message))
      actor.continue(
        State(dict.insert(
          st.docs,
          t,
          Doc(
            ..d,
            seq: seq,
            history: list.append(d.history, [#(sn, message)]),
            presence: dict.delete(d.presence, c),
          ),
        )),
      )
    }
    Submit(t, c, csn, rsn, contents, reply) -> {
      let d = doc(storage, st, t)
      case sequencing.assign_sequence_number(d.seq, c, csn, rsn) {
        sequencing.SequenceOk(seq, sn, msn) -> {
          process.send(reply, Assigned(sn, msn))
          store.put_op(storage, t, sn, contents)
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
          process.send(reply, Rejected(d.seq.sequence_number))
          actor.continue(st)
        }
      }
    }
    SubmitMessage(t, c, csn, rsn, build, reply) -> {
      let d = doc(storage, st, t)
      case sequencing.assign_sequence_number(d.seq, c, csn, rsn) {
        sequencing.SequenceOk(seq, sn, msn) -> {
          let message = build(sn, msn)
          store.put_op(storage, t, sn, message)
          process.send(reply, MessageAssigned(sn, msn, message))
          actor.continue(
            State(dict.insert(
              st.docs,
              t,
              Doc(
                ..d,
                seq: seq,
                history: list.append(d.history, [#(sn, message)]),
              ),
            )),
          )
        }
        sequencing.SequenceError(_) -> {
          process.send(reply, MessageRejected(d.seq.sequence_number))
          actor.continue(st)
        }
      }
    }
    SubmitSummary(t, c, csn, rsn, contents, response_contents, handle, reply) -> {
      let d = doc(storage, st, t)
      case sequencing.assign_sequence_number(d.seq, c, csn, rsn) {
        sequencing.SequenceOk(seq, summary_sn, msn) -> {
          let response_sn = summary_sn + 1
          let seq =
            sequencing.SequenceState(..seq, sequence_number: response_sn)
          process.send(reply, SummaryAssigned(summary_sn, response_sn, msn))
          store.put_op(storage, t, summary_sn, contents)
          store.put_op(storage, t, response_sn, response_contents)
          case handle {
            Some(handle) -> store.put_summary(storage, t, handle, summary_sn)
            _ -> Nil
          }
          actor.continue(
            State(dict.insert(
              st.docs,
              t,
              Doc(
                seq,
                list.append(d.history, [
                  #(summary_sn, contents),
                  #(response_sn, response_contents),
                ]),
                case handle {
                  Some(handle) -> #(handle, summary_sn)
                  _ -> d.summary
                },
                d.presence,
              ),
            )),
          )
        }
        sequencing.SequenceError(_) -> {
          process.send(reply, SummaryRejected(d.seq.sequence_number))
          actor.continue(st)
        }
      }
    }
    SubmitSummaryMessages(t, c, csn, rsn, build, reply) -> {
      let d = doc(storage, st, t)
      case sequencing.assign_sequence_number(d.seq, c, csn, rsn) {
        sequencing.SequenceOk(seq, summary_sn, msn) -> {
          let response_sn = summary_sn + 1
          let seq =
            sequencing.SequenceState(..seq, sequence_number: response_sn)
          let #(summary_message, response_message, handle) =
            build(summary_sn, response_sn, msn)
          store.put_op(storage, t, summary_sn, summary_message)
          store.put_op(storage, t, response_sn, response_message)
          case handle {
            Some(handle) -> store.put_summary(storage, t, handle, summary_sn)
            _ -> Nil
          }
          process.send(
            reply,
            SummaryMessagesAssigned(
              summary_sn,
              response_sn,
              msn,
              summary_message,
              response_message,
            ),
          )
          actor.continue(
            State(dict.insert(
              st.docs,
              t,
              Doc(
                seq,
                list.append(d.history, [
                  #(summary_sn, summary_message),
                  #(response_sn, response_message),
                ]),
                case handle {
                  Some(handle) -> #(handle, summary_sn)
                  _ -> d.summary
                },
                d.presence,
              ),
            )),
          )
        }
        sequencing.SequenceError(_) -> {
          process.send(reply, SummaryMessagesRejected(d.seq.sequence_number))
          actor.continue(st)
        }
      }
    }
    Since(t, sn, reply) -> {
      process.send(
        reply,
        store.get_ops(storage, t) |> list.filter(fn(o) { o.0 > sn }),
      )
      actor.continue(st)
    }
    Clients(t, reply) -> {
      process.send(reply, dict.keys(doc(storage, st, t).presence))
      actor.continue(st)
    }
    Roster(t, reply) -> {
      process.send(reply, dict.to_list(doc(storage, st, t).presence))
      actor.continue(st)
    }
    Exists(t, reply) -> {
      let exists = case dict.get(st.docs, t) {
        Ok(_) -> True
        Error(Nil) -> stored_document_exists(storage, t)
      }
      process.send(reply, exists)
      actor.continue(st)
    }
    SequenceNumber(t, reply) -> {
      process.send(reply, doc(storage, st, t).seq.sequence_number)
      actor.continue(st)
    }
    InitializeSummary(t, handle, sn, reply) -> {
      store.put_summary(storage, t, handle, sn)
      let d = doc(storage, st, t)
      process.send(reply, Nil)
      actor.continue(
        State(dict.insert(
          st.docs,
          t,
          Doc(..d, seq: sequencing.from_checkpoint(sn, sn), summary: #(
            handle,
            sn,
          )),
        )),
      )
    }
    SetSummary(t, handle, sn) -> {
      store.put_summary(storage, t, handle, sn)
      let d = doc(storage, st, t)
      actor.continue(
        State(dict.insert(st.docs, t, Doc(..d, summary: #(handle, sn)))),
      )
    }
    GetSummary(t, reply) -> {
      process.send(reply, store.get_summary(storage, t))
      actor.continue(st)
    }
    UpdateClientRsn(t, client_id, rsn) -> {
      let d = doc(storage, st, t)
      case sequencing.update_client_rsn(d.seq, client_id, rsn) {
        Error(_) -> actor.continue(st)
        Ok(seq) ->
          actor.continue(State(dict.insert(st.docs, t, Doc(..d, seq: seq))))
      }
    }
  }
}

fn minimal_client(mode: String) -> String {
  json.object([#("mode", json.string(mode))]) |> json.to_string
}

pub fn stored_message_json(op: #(Int, String)) -> json.Json {
  case
    json.parse(op.1, decode.field("sequenceNumber", decode.int, decode.success))
  {
    Ok(_) -> raw_json(op.1)
    Error(_) ->
      json.object([
        #("sequenceNumber", json.int(op.0)),
        #("contents", json.string(op.1)),
      ])
  }
}

fn system_message(
  kind: String,
  data: String,
  sequence_number: Int,
  minimum_sequence_number: Int,
  timestamp: Int,
) -> String {
  json.object([
    #("clientId", json.null()),
    #("sequenceNumber", json.int(sequence_number)),
    #("minimumSequenceNumber", json.int(minimum_sequence_number)),
    #("clientSequenceNumber", json.int(-1)),
    #("referenceSequenceNumber", json.int(-1)),
    #("type", json.string(kind)),
    #("contents", json.null()),
    #("data", json.string(data)),
    #("timestamp", json.int(timestamp)),
  ])
  |> json.to_string
}

@external(erlang, "floodgate_ffi", "raw_json")
fn raw_json(value: String) -> json.Json

fn stored_document_exists(storage: store.Backend, topic: String) -> Bool {
  let #(summary_handle, _) = store.get_summary(storage, topic)
  store.has_document(storage, topic)
  || store.get_ops(storage, topic) != []
  || summary_handle != ""
}
