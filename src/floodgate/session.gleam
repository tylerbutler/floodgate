//// Per-document session registry — shared sequencing + op history across all
//// sockets on a `document:*` topic (beryl assigns are per-socket). Analogue of
//// levee's Elixir Session GenServer: SN assignment + delta catch-up history.

import floodgate/git
import floodgate/memory_store
import floodgate/store
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/string
import spillway/sequencing
import spillway/session_logic

/// A handle onto the session actor.
///
/// This holds the actor's registered *name*, not its `Subject`, so a supervised
/// restart is transparent to every holder: `process.named_subject` re-resolves to
/// whatever process currently owns the name. Capturing the Subject instead —
/// which is what this did before — meant a restarted actor was unreachable by
/// the already-registered channel, so a crash took the whole service down
/// permanently rather than for the length of a restart.
pub opaque type Session {
  Session(name: process.Name(Msg), storage: store.Backend)
}

/// Resolve the current session actor. Called per request rather than cached, so
/// the handle survives a restart.
fn subject(s: Session) -> Subject(Msg) {
  process.named_subject(s.name)
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
  /// Self-scheduled: drop cached documents nobody is connected to. See
  /// `sweep_idle_documents`.
  Sweep
  CachedDocuments(reply: Subject(Int))
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
    /// Recent ops for `initialMessages`, **newest first** and capped at
    /// `max_history_size`, matching levee's `op_history`. Reversed at the two
    /// points it is handed out. It was previously oldest-first, uncapped, and
    /// extended with `list.append` — an unbounded per-document leak that also
    /// cost a full copy of the list on every op.
    history: List(#(Int, String)),
    summary: #(String, Int),
    presence: Dict(String, String),
    /// Monotonic ms of the last mutation, maintained by `doc/3` (see there) and
    /// read only by the idle sweep.
    last_touched_ms: Int,
  )
}

/// Ops retained per document for `initialMessages`. Levee uses the same figure
/// (`@max_history_size` in `Levee.Documents.Session`); clients that need more
/// history bootstrap from the summary and `requestOps`.
const max_history_size = 1000

type State {
  State(docs: Dict(String, Doc))
}

/// Prepend an op to a document's history and trim, via the same spillway helper
/// levee's `Bridge.add_to_history` calls.
fn remember(d: Doc, op: #(Int, String)) -> List(#(Int, String)) {
  session_logic.add_to_history(op, d.history, max_history_size)
}

/// Two ops in sequence order — a summarize and its ack, which are always
/// assigned and stored together.
fn remember_both(
  d: Doc,
  first: #(Int, String),
  second: #(Int, String),
) -> List(#(Int, String)) {
  session_logic.add_to_history(second, remember(d, first), max_history_size)
}

/// The history in the order clients expect: oldest first.
fn initial_messages(history: List(#(Int, String))) -> List(#(Int, String)) {
  list.reverse(history)
}

/// Allocate a fresh name for a session actor.
pub fn new_name() -> process.Name(Msg) {
  process.new_name("floodgate_session")
}

/// A handle onto the session actor registered at `name`, which need not be
/// running yet — this is what lets the handle be built before the supervisor
/// starts the actor, and stay valid across restarts.
pub fn from_name(name: process.Name(Msg), storage: store.Backend) -> Session {
  Session(name, storage)
}

/// Start the session actor under `name`.
///
/// `store.open` is a no-op for both backends — tables and backing actors are
/// created when the `Backend` value is constructed — so the storage lifecycle
/// sits outside this actor's crash domain and a restart cannot disturb it.
pub fn start_named(
  name: process.Name(Msg),
  storage: store.Backend,
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  store.open(storage)
  // Read once, at start, and carried for the actor's lifetime: the sweep cadence
  // and the window it enforces must agree, and re-reading per sweep would let
  // them disagree.
  let idle_ms = idle_document_ms()
  let started =
    actor.new(State(dict.new()))
    |> actor.on_message(fn(state, message) {
      handle(storage, name, idle_ms, state, message)
    })
    |> actor.named(name)
    |> actor.start
  case started {
    Ok(_) -> schedule_sweep(process.named_subject(name), idle_ms)
    Error(_) -> Nil
  }
  started
}

/// Documents with no connected clients are dropped after roughly this long,
/// overridable via FLOODGATE_DOC_IDLE_MS; `0` disables eviction.
///
/// Without it `docs` only ever grew: a server that had seen a million documents
/// held a million `Doc`s, each with up to `max_history_size` ops, whether or not
/// anyone was still using them.
fn idle_document_ms() -> Int {
  case int.parse(getenv("FLOODGATE_DOC_IDLE_MS", "")) {
    Ok(value) if value >= 0 -> value
    _ -> 300_000
  }
}

/// Sweeps run at half the idle window, so a document is dropped between one and
/// two windows after its last use — the same relationship beryl uses between its
/// heartbeat timeout and its check interval.
fn schedule_sweep(self: Subject(Msg), idle_ms: Int) -> Nil {
  case idle_ms {
    0 -> Nil
    _ -> {
      let _ = process.send_after(self, int.max(idle_ms / 2, 1), Sweep)
      Nil
    }
  }
}

/// Drop every cached document that has no connected client and has not been
/// touched within the idle window.
///
/// Safe because eviction is only a cache drop: `doc/3` rebuilds sequence state
/// and summary from storage on the next touch, and the condition guarantees
/// there are no `client_states` or roster entries to lose. It is the same code
/// path a supervised restart already exercises.
fn sweep_idle_documents(st: State, idle_ms: Int) -> State {
  let cutoff = now_ms() - idle_ms
  State(
    dict.filter(st.docs, fn(_topic, d) {
      !dict.is_empty(d.presence) || d.last_touched_ms > cutoff
    }),
  )
}

/// Supervisable child specification for the session actor.
///
/// In-memory state (`docs`) is rebuilt lazily by `doc/2` from persisted ops and
/// summaries, so a restart recovers each document's sequence state on next
/// touch. Connected clients' `client_states` do not survive, so their next
/// `submitOp` is nacked as an unknown client until they rejoin — which is the
/// same contract levee has when its per-document session restarts.
pub fn child_spec(
  name: process.Name(Msg),
  storage: store.Backend,
) -> supervision.ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start_named(name, storage) })
}

/// Start an *unsupervised* session over a fresh, ephemeral in-memory backend.
/// For tests; a runtime should supervise the actor via `child_spec`.
pub fn start() -> Session {
  start_with_backend(memory_store.new())
}

/// Start an *unsupervised* session over the supplied backend. For tests; a
/// runtime should supervise the actor via `child_spec`.
pub fn start_with_backend(storage: store.Backend) -> Session {
  let name = new_name()
  let assert Ok(_) = start_named(name, storage)
  from_name(name, storage)
}

pub fn storage(session: Session) -> store.Backend {
  session.storage
}

/// The pid currently registered under the session's name, if the actor is
/// running. For supervision tests and diagnostics.
pub fn owner(s: Session) -> Result(process.Pid, Nil) {
  process.subject_owner(subject(s))
}

pub fn create(s: Session, topic: String) -> Bool {
  process.call(subject(s), 1000, Create(topic, _))
}

pub fn create_initialized(
  s: Session,
  topic: String,
  build: fn() -> Result(Option(#(String, Int)), Nil),
) -> CreateInitializedResult {
  process.call(subject(s), 10_000, CreateInitialized(topic, build, _))
}

pub fn join(s: Session, topic: String, c: String) -> Bool {
  process.call(subject(s), 1000, Join(topic, c, _))
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
  process.call(subject(s), 1000, Connect(
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
  process.call(subject(s), 1000, JoinPresence(topic, client_id, mode, _))
}

pub fn join_sequenced(
  s: Session,
  topic: String,
  client_id: String,
  data: String,
  timestamp: Int,
) -> JoinResult {
  process.call(subject(s), 1000, JoinSequenced(
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
  process.call(subject(s), 1000, Submit(t, c, csn, rsn, contents, _))
}

pub fn submit_message(
  s: Session,
  topic: String,
  client_id: String,
  csn: Int,
  rsn: Int,
  build: fn(Int, Int) -> String,
) -> SubmitMessageResult {
  process.call(subject(s), 1000, SubmitMessage(
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
  process.call(subject(s), 1000, SubmitSummary(
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
  process.call(subject(s), 1000, SubmitSummaryMessages(
    topic,
    client_id,
    csn,
    rsn,
    build,
    _,
  ))
}

pub fn leave(s: Session, topic: String, client_id: String) -> Nil {
  process.send(subject(s), Leave(topic, client_id))
}

pub fn leave_presence(s: Session, topic: String, client_id: String) -> Nil {
  process.send(subject(s), LeavePresence(topic, client_id))
}

pub fn leave_sequenced(
  s: Session,
  topic: String,
  client_id: String,
  timestamp: Int,
) -> LeaveResult {
  process.call(subject(s), 1000, LeaveSequenced(topic, client_id, timestamp, _))
}

pub fn since(s: Session, t: String, sn: Int) -> List(#(Int, String)) {
  process.call(subject(s), 1000, Since(t, sn, _))
}

pub fn clients(s: Session, t: String) -> List(String) {
  process.call(subject(s), 1000, Clients(t, _))
}

pub fn roster(s: Session, t: String) -> List(#(String, String)) {
  process.call(subject(s), 1000, Roster(t, _))
}

pub fn exists(s: Session, t: String) -> Bool {
  process.call(subject(s), 1000, Exists(t, _))
}

pub fn sequence_number(s: Session, t: String) -> Int {
  process.call(subject(s), 1000, SequenceNumber(t, _))
}

pub fn set_summary(s: Session, t: String, handle: String, sn: Int) {
  process.send(subject(s), SetSummary(t, handle, sn))
}

/// Advance a client's reference sequence number without sequencing an op, so
/// an idle client still lets the minimum sequence number move. Fire-and-forget,
/// mirroring levee's `Session.update_client_rsn` cast.
pub fn update_client_rsn(s: Session, t: String, client_id: String, rsn: Int) {
  process.send(subject(s), UpdateClientRsn(t, client_id, rsn))
}

pub fn initialize_summary(s: Session, t: String, handle: String, sn: Int) {
  process.call(subject(s), 1000, InitializeSummary(t, handle, sn, _))
}

pub fn summary(s: Session, t: String) -> #(String, Int) {
  process.call(subject(s), 1000, GetSummary(t, _))
}

/// How many documents are currently held in memory. Documents are a cache over
/// storage, so this is bounded by the idle sweep rather than by the number of
/// documents the server has ever seen. For tests and diagnostics.
pub fn cached_documents(s: Session) -> Int {
  process.call(subject(s), 1000, CachedDocuments)
}

/// The in-memory state for a document, rehydrating it from storage on a miss.
///
/// The returned value carries a fresh `last_touched_ms`. Every handler that
/// mutates a document reads it through here and writes the result back, so that
/// one line is what keeps the idle sweep's clock current — no per-handler
/// bookkeeping. Read-only handlers do not write back, so a document nobody is
/// changing ages out even while it is being read; that is harmless, because
/// eviction is just a cache drop and this function rebuilds it.
fn doc(storage: store.Backend, st: State, t: String) -> Doc {
  case dict.get(st.docs, t) {
    Ok(d) -> Doc(..d, last_touched_ms: now_ms())
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
      // Repair the one crash prefix that is not benign. The summary pointer is
      // written before the ref that mirrors it, so a crash between the two can
      // leave a document whose summary exists but which `GET /commits?sha=<id>`
      // cannot resolve — making it unloadable. Restoring a *missing* ref here is
      // idempotent and only runs on a cache miss.
      restore_summary_ref(storage, t, handle)
      let checkpoint = case ssn > last_sn {
        True -> ssn
        False -> last_sn
      }
      Doc(
        seq: sequencing.from_checkpoint(checkpoint, ssn),
        // Newest first, and only as much as a live document would have kept.
        history: ops |> list.reverse |> list.take(max_history_size),
        summary: #(handle, ssn),
        presence: dict.new(),
        last_touched_ms: now_ms(),
      )
    }
  }
}

/// Put back a summary ref that a crash left unwritten. Never overwrites an
/// existing one — a ref that merely lags is safe and self-heals on the next
/// summary, and clients may move refs through the Historian API.
fn restore_summary_ref(
  storage: store.Backend,
  topic: String,
  handle: String,
) -> Nil {
  case handle, string.split(topic, ":") {
    "", _ -> Nil
    _, ["document", tenant, document_id] ->
      git.ensure_summary_ref(storage, tenant, document_id, handle)
    _, _ -> Nil
  }
}

fn handle(
  storage: store.Backend,
  name: process.Name(Msg),
  idle_ms: Int,
  st: State,
  m: Msg,
) -> actor.Next(State, Msg) {
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
                  Doc(
                    seq: seq,
                    history: [],
                    summary: summary_state,
                    presence: dict.new(),
                    last_touched_ms: now_ms(),
                  ),
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
              initial_messages(remember(d, #(sn, message))),
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
                history: remember(d, #(sn, message)),
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
              initial_messages(d.history),
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
            history: remember(d, #(sn, message)),
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
            history: remember(d, #(sn, message)),
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
              Doc(..d, seq: seq, history: remember(d, #(sn, contents))),
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
              Doc(..d, seq: seq, history: remember(d, #(sn, message))),
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
                ..d,
                seq: seq,
                history: remember_both(d, #(summary_sn, contents), #(
                  response_sn,
                  response_contents,
                )),
                summary: case handle {
                  Some(handle) -> #(handle, summary_sn)
                  _ -> d.summary
                },
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
                ..d,
                seq: seq,
                history: remember_both(d, #(summary_sn, summary_message), #(
                  response_sn,
                  response_message,
                )),
                summary: case handle {
                  Some(handle) -> #(handle, summary_sn)
                  _ -> d.summary
                },
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
    Sweep -> {
      schedule_sweep(process.named_subject(name), idle_ms)
      actor.continue(sweep_idle_documents(st, idle_ms))
    }
    CachedDocuments(reply) -> {
      process.send(reply, dict.size(st.docs))
      actor.continue(st)
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

@external(erlang, "floodgate_ffi", "now_ms")
fn now_ms() -> Int

@external(erlang, "floodgate_ffi", "getenv")
fn getenv(name: String, default: String) -> String

fn stored_document_exists(storage: store.Backend, topic: String) -> Bool {
  let #(summary_handle, _) = store.get_summary(storage, topic)
  store.has_document(storage, topic)
  || store.get_ops(storage, topic) != []
  || summary_handle != ""
}
