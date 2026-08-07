//// Per-document session registry — shared sequencing + op history across all
//// sockets on a `document:*` topic (beryl assigns are per-socket). Analogue of
//// levee's Elixir Session GenServer: SN assignment + delta catch-up history.
////
//// There is **one actor per document**, not one for all of them. Previously a
//// single actor sequenced every document through one mailbox, which made it
//// both a throughput bottleneck (a slow `create_initialized` — it runs the
//// initial-summary build inside the mailbox, hence its 10 s timeout — stalled
//// every other document) and a single crash domain (one crash discarded
//// `client_states` for every document at once, nacking every connected client
//// until it rejoined). Now a crash costs one document's roster.
////
//// Three collaborators, all private to this module's public API:
////
//// - **`floodgate/doc_state`** — the `Doc` record and the storage-only logic
////   that rebuilds it. Shared by the actor and by the read-only fallback below.
//// - **`floodgate/doc_registry`** — topic → actor, in ETS. Read directly by the
////   calling process, so resolving a document costs no message hop.
//// - **the owner actor** (`OwnerMsg`) — starts document actors and inserts their
////   rows. Serialized, so get-or-start is atomic. It sits on the cold path only.
////
//// Everything in the public API still takes `(Session, topic, ...)` exactly as
//// before, so no caller changed. The document actor's `Msg` also kept its
//// `topic` field even though each actor now serves one topic: the handlers use
//// it directly as the storage key, and keeping it meant the sequencing logic
//// moved across unmodified.
////
//// Several read-only operations no longer involve a process at all. `since` and
//// `summary` always read storage (they never touched the in-memory `Doc`, even
//// before), and `exists`/`clients`/`roster` are answerable from the registry
//// plus storage. That matters because `exists` is reachable from unauthenticated
//// REST paths — routing it through get-or-start would let any `GET` on an
//// unknown document spawn an actor.

import exception
import floodgate/doc_registry
import floodgate/doc_state.{type Doc, Doc}
import floodgate/memory_store
import floodgate/store
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import spillway/sequencing

/// A handle onto a document session.
///
/// This holds the registry owner's registered *name*, not any `Subject`, so a
/// supervised restart is transparent to every holder. Capturing a Subject
/// instead — which is what this did before gap 1.1 — meant a restarted actor was
/// unreachable by the already-registered channel, so a crash took the whole
/// service down permanently rather than for the length of a restart.
///
/// The same name doubles as the ETS table name for the document registry; see
/// `doc_registry.from_name` for why that is the right atom to reuse.
pub opaque type Session {
  Session(name: process.Name(OwnerMsg), storage: store.Backend)
}

/// Resolve the current registry owner. Called per request rather than cached, so
/// the handle survives a restart.
fn owner_subject(s: Session) -> Subject(OwnerMsg) {
  process.named_subject(s.name)
}

fn registry(s: Session) -> doc_registry.Registry(Msg) {
  doc_registry.from_name(s.name)
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
  /// Self-scheduled: stop if nobody is connected and nothing has touched this
  /// document within the idle window. See `idle`.
  Sweep
}

/// Messages to the registry owner. Only ever sent on the cold path — an
/// established document is resolved straight from ETS.
pub opaque type OwnerMsg {
  EnsureStarted(topic: String, reply: Subject(Result(Subject(Msg), Nil)))
  ChildDown(process.Down)
}

/// What a document actor needs to run: its topic, the shared storage backend,
/// the registry it must remove itself from on shutdown, and the idle window.
type DocArgument =
  #(String, store.Backend, doc_registry.Registry(Msg), Int)

type DocFactory =
  process.Name(factory_supervisor.Message(DocArgument, Subject(Msg)))

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

/// A document actor's state. `None` means nothing is cached yet, which is the
/// exact analogue of a topic being absent from the old single actor's `docs`
/// dict — including for the `existing` flag, which must distinguish "we have
/// this in memory" from "storage has it".
type DocState {
  DocState(self: Subject(Msg), doc: Option(Doc))
}

/// Allocate a fresh name for a session's registry owner.
pub fn new_name() -> process.Name(OwnerMsg) {
  process.new_name("floodgate_session")
}

/// A handle onto the session registered at `name`, which need not be running
/// yet — this is what lets the handle be built before the supervisor starts the
/// actor, and stay valid across restarts.
pub fn from_name(
  name: process.Name(OwnerMsg),
  storage: store.Backend,
) -> Session {
  Session(name, storage)
}

/// Start the registry owner under `name`.
///
/// `store.open` is a no-op for both backends — tables and backing actors are
/// created when the `Backend` value is constructed — so the storage lifecycle
/// sits outside this actor's crash domain and a restart cannot disturb it.
fn start_owner(
  name: process.Name(OwnerMsg),
  storage: store.Backend,
  factory: DocFactory,
) -> Result(actor.Started(Subject(OwnerMsg)), actor.StartError) {
  store.open(storage)
  let registry = doc_registry.from_name(name)
  // Read once, at start, and passed to every document actor: the sweep cadence
  // and the window it enforces must agree, and re-reading per sweep would let
  // them disagree.
  let idle_ms = idle_document_ms()
  actor.new_with_initialiser(1000, fn(self) {
    // The table belongs to this process, so it dies with it. That is what the
    // RestForOne pairing in `child_spec` is for: the factory restarts after the
    // owner, taking every now-unreachable document actor down with it.
    doc_registry.open(registry)
    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select_monitors(ChildDown)
    actor.initialised(OwnerState(
      registry: registry,
      storage: storage,
      factory: factory,
      idle_ms: idle_ms,
      monitors: dict.new(),
    ))
    |> actor.selecting(selector)
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle_owner)
  |> actor.named(name)
  |> actor.start
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

/// Whether this document actor should stop: nothing cached, or nobody connected
/// and untouched for a full idle window.
///
/// Safe because stopping is only a cache drop — `doc_state.rehydrate` rebuilds
/// sequence state and summary from storage when the document is next touched,
/// and the condition guarantees there are no `client_states` or roster entries
/// to lose. It is the same code path a crash already exercises.
fn idle(state: DocState, idle_ms: Int) -> Bool {
  case state.doc {
    None -> True
    Some(d) ->
      dict.is_empty(d.presence)
      && d.last_touched_ms <= doc_state.now_ms() - idle_ms
  }
}

/// Supervisable child specification for a session.
///
/// This is a `RestForOne` pair — the registry owner, then the factory that
/// starts document actors — and the order is load-bearing. The owner owns the
/// registry's ETS table, so if it dies the table dies with it and every running
/// document actor becomes unreachable; restarting the factory after it takes
/// those actors down rather than leaving them holding state nobody can find.
///
/// Per-document state is rebuilt lazily from persisted ops and summaries, so a
/// restart recovers each document's sequence state on next touch. Connected
/// clients' `client_states` do not survive, so their next `submitOp` is nacked
/// as an unknown client until they rejoin — the same contract levee has when its
/// per-document session restarts.
pub fn child_spec(
  name: process.Name(OwnerMsg),
  storage: store.Backend,
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  // Allocated here rather than by the caller because it is created once per
  // session and never dynamically — the ChildSpecification holds this closure,
  // so a supervised restart reuses the same name rather than minting another.
  let factory = new_factory_name()
  static_supervisor.new(static_supervisor.RestForOne)
  |> static_supervisor.add(
    supervision.worker(fn() { start_owner(name, storage, factory) }),
  )
  |> static_supervisor.add(document_factory(factory))
  |> static_supervisor.supervised
}

fn new_factory_name() -> DocFactory {
  process.new_name("floodgate_documents")
}

/// The factory the owner starts document actors from.
///
/// `Temporary` is deliberate: a restarted child would get a fresh `Subject` that
/// the registry row could not know about. Letting it stay dead is both simpler
/// and better — the owner drops the row and the next lookup starts a new actor
/// that rehydrates from storage, which is exactly the documented restart
/// contract, now scoped to one document.
fn document_factory(
  factory: DocFactory,
) -> supervision.ChildSpecification(
  factory_supervisor.Supervisor(DocArgument, Subject(Msg)),
) {
  factory_supervisor.worker_child(start_document)
  |> factory_supervisor.restart_strategy(supervision.Temporary)
  |> factory_supervisor.named(factory)
  |> factory_supervisor.supervised
}

/// Start an *unsupervised* session over a fresh, ephemeral in-memory backend.
/// For tests; a runtime should supervise via `child_spec`.
pub fn start() -> Session {
  start_with_backend(memory_store.new())
}

/// Start an *unsupervised* session over the supplied backend. For tests; a
/// runtime should supervise via `child_spec`.
pub fn start_with_backend(storage: store.Backend) -> Session {
  let name = new_name()
  let factory = new_factory_name()
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.RestForOne)
    |> static_supervisor.add(
      supervision.worker(fn() { start_owner(name, storage, factory) }),
    )
    |> static_supervisor.add(document_factory(factory))
    |> static_supervisor.start
  from_name(name, storage)
}

pub fn storage(session: Session) -> store.Backend {
  session.storage
}

/// The pid currently registered under the session's name, if the registry owner
/// is running. For supervision tests and diagnostics.
pub fn owner(s: Session) -> Result(process.Pid, Nil) {
  process.subject_owner(owner_subject(s))
}

/// The pid of the actor currently serving `topic`, if one is running. `Error`
/// means the document is not in memory, not that it does not exist. For
/// supervision tests and diagnostics.
pub fn document_owner(s: Session, topic: String) -> Result(process.Pid, Nil) {
  case doc_registry.lookup(registry(s), topic) {
    Ok(subject) -> process.subject_owner(subject)
    Error(Nil) -> Error(Nil)
  }
}

// ── Routing ────────────────────────────────────────────────────────────────
//
// Two ways to reach a document, and which one an operation uses is decided by a
// mechanical test on the old single-actor code: did the handler continue with a
// *modified* state?
//
// - Mutating handlers use `call_doc`/`send_doc_starting`, which start an actor
//   if there isn't one.
// - Non-mutating handlers use `send_doc` or answer from storage directly, so
//   they never bring a document into memory. Reading must not be able to
//   allocate, or any `GET` on an unknown document would spawn an actor.

/// Resolve the actor for `topic`, starting one if there isn't one.
///
/// The ETS read is the fast path and happens right here in the calling process.
/// Only a miss costs a message, and only to the owner, which serializes starts
/// so two callers racing on the same cold document cannot produce two actors.
fn resolve(s: Session, topic: String) -> Subject(Msg) {
  case doc_registry.lookup(registry(s), topic) {
    Ok(subject) -> subject
    Error(Nil) -> start_document_actor(s, topic)
  }
}

fn start_document_actor(s: Session, topic: String) -> Subject(Msg) {
  let assert Ok(subject) =
    process.call(owner_subject(s), 1000, EnsureStarted(topic, _))
  subject
}

/// Call a document actor, tolerating a registry row that has just gone stale.
///
/// A row can outlive its actor for a moment: an actor deletes its own row as it
/// stops, and the owner's monitor is only a backstop, so a caller can read a row
/// microseconds before the actor goes away. `process.call` panics on a dead
/// callee — it monitors, so it fails fast rather than after the timeout — and
/// panicking here would take down a channel process for what is a routine race.
/// Retry once against a freshly started actor instead.
fn call_doc(
  s: Session,
  topic: String,
  timeout: Int,
  make: fn(Subject(reply)) -> Msg,
) -> reply {
  case
    exception.rescue(fn() { process.call(resolve(s, topic), timeout, make) })
  {
    Ok(value) -> value
    Error(_) -> {
      // Drop the row we just failed against so the owner starts a fresh actor
      // rather than handing back the same corpse.
      doc_registry.delete(registry(s), topic)
      process.call(start_document_actor(s, topic), timeout, make)
    }
  }
}

/// Fire-and-forget to a document that is already in memory, dropping the
/// message if it is not. Only for messages whose effect on a document nobody has
/// loaded would be nil anyway.
fn send_doc(s: Session, topic: String, message: Msg) -> Nil {
  case doc_registry.lookup(registry(s), topic) {
    Ok(subject) -> process.send(subject, message)
    Error(Nil) -> Nil
  }
}

/// Fire-and-forget, starting the document actor if needed. For messages that
/// write to storage, which must not be dropped.
fn send_doc_starting(s: Session, topic: String, message: Msg) -> Nil {
  process.send(resolve(s, topic), message)
}

pub fn create(s: Session, topic: String) -> Bool {
  call_doc(s, topic, 1000, Create(topic, _))
}

pub fn create_initialized(
  s: Session,
  topic: String,
  build: fn() -> Result(Option(#(String, Int)), Nil),
) -> CreateInitializedResult {
  call_doc(s, topic, 10_000, CreateInitialized(topic, build, _))
}

pub fn join(s: Session, topic: String, c: String) -> Bool {
  call_doc(s, topic, 1000, Join(topic, c, _))
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
  call_doc(s, topic, 1000, Connect(
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
  call_doc(s, topic, 1000, JoinPresence(topic, client_id, mode, _))
}

pub fn join_sequenced(
  s: Session,
  topic: String,
  client_id: String,
  data: String,
  timestamp: Int,
) -> JoinResult {
  call_doc(s, topic, 1000, JoinSequenced(topic, client_id, data, timestamp, _))
}

pub fn submit(
  s: Session,
  t: String,
  c: String,
  csn: Int,
  rsn: Int,
  contents: String,
) -> SubmitResult {
  call_doc(s, t, 1000, Submit(t, c, csn, rsn, contents, _))
}

pub fn submit_message(
  s: Session,
  topic: String,
  client_id: String,
  csn: Int,
  rsn: Int,
  build: fn(Int, Int) -> String,
) -> SubmitMessageResult {
  call_doc(s, topic, 1000, SubmitMessage(topic, client_id, csn, rsn, build, _))
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
  call_doc(s, topic, 1000, SubmitSummary(
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
  call_doc(s, topic, 1000, SubmitSummaryMessages(
    topic,
    client_id,
    csn,
    rsn,
    build,
    _,
  ))
}

pub fn leave(s: Session, topic: String, client_id: String) -> Nil {
  send_doc(s, topic, Leave(topic, client_id))
}

pub fn leave_presence(s: Session, topic: String, client_id: String) -> Nil {
  send_doc(s, topic, LeavePresence(topic, client_id))
}

pub fn leave_sequenced(
  s: Session,
  topic: String,
  client_id: String,
  timestamp: Int,
) -> LeaveResult {
  call_doc(s, topic, 1000, LeaveSequenced(topic, client_id, timestamp, _))
}

/// Ops after `sn`.
///
/// The handler reads storage rather than the in-memory `Doc`, so this looks like
/// it could skip the actor entirely — but it cannot when one exists. The submit
/// handlers reply *before* writing (`Submit` sends `Assigned` and only then
/// calls `store.put_op`), so going straight to storage can observe a gap the
/// shared mailbox used to close: a caller that has already been told an op was
/// assigned could read back a history without it.
///
/// With no actor there is nothing in flight to miss, so the storage read is
/// exact — and that is the path REST delta requests for cold documents take.
pub fn since(s: Session, t: String, sn: Int) -> List(#(Int, String)) {
  case doc_registry.lookup(registry(s), t) {
    Ok(subject) -> process.call(subject, 1000, Since(t, sn, _))
    Error(Nil) -> store.get_ops(s.storage, t) |> list.filter(fn(o) { o.0 > sn })
  }
}

pub fn clients(s: Session, t: String) -> List(String) {
  case doc_registry.lookup(registry(s), t) {
    Ok(subject) -> process.call(subject, 1000, Clients(t, _))
    // A document with no actor has no presence: `doc_state.rehydrate` starts
    // with an empty roster, so the old code's answer here was `[]` too.
    Error(Nil) -> []
  }
}

pub fn roster(s: Session, t: String) -> List(#(String, String)) {
  case doc_registry.lookup(registry(s), t) {
    Ok(subject) -> process.call(subject, 1000, Roster(t, _))
    Error(Nil) -> []
  }
}

/// Whether the document exists, in memory or in storage.
///
/// Deliberately allocation-free — this is reachable from REST paths that do not
/// require a document to exist, so it must not be able to spawn an actor.
pub fn exists(s: Session, t: String) -> Bool {
  case doc_registry.lookup(registry(s), t) {
    Ok(_) -> True
    Error(Nil) -> doc_state.stored_document_exists(s.storage, t)
  }
}

pub fn sequence_number(s: Session, t: String) -> Int {
  case doc_registry.lookup(registry(s), t) {
    Ok(subject) -> process.call(subject, 1000, SequenceNumber(t, _))
    // Same rebuild the actor would do on its first touch, without keeping it.
    Error(Nil) -> doc_state.rehydrate(s.storage, t).seq.sequence_number
  }
}

pub fn set_summary(s: Session, t: String, handle: String, sn: Int) {
  send_doc_starting(s, t, SetSummary(t, handle, sn))
}

/// Advance a client's reference sequence number without sequencing an op, so
/// an idle client still lets the minimum sequence number move. Fire-and-forget,
/// mirroring levee's `Session.update_client_rsn` cast.
pub fn update_client_rsn(s: Session, t: String, client_id: String, rsn: Int) {
  send_doc(s, t, UpdateClientRsn(t, client_id, rsn))
}

pub fn initialize_summary(s: Session, t: String, handle: String, sn: Int) {
  call_doc(s, t, 1000, InitializeSummary(t, handle, sn, _))
}

/// The latest summary. Ordered behind the document's actor for the same reason
/// as `since`: `SubmitSummary` acks before it calls `store.put_summary`, so a
/// direct storage read can return the previous summary to a caller that has
/// already been told the new one was accepted.
pub fn summary(s: Session, t: String) -> #(String, Int) {
  case doc_registry.lookup(registry(s), t) {
    Ok(subject) -> process.call(subject, 1000, GetSummary(t, _))
    Error(Nil) -> store.get_summary(s.storage, t)
  }
}

/// How many documents are currently held in memory. Documents are a cache over
/// storage, so this is bounded by the idle timers rather than by the number of
/// documents the server has ever seen. For tests and diagnostics.
///
/// Now a direct ETS read of the registry's size rather than a process call,
/// since one live actor is exactly one cached document.
pub fn cached_documents(s: Session) -> Int {
  doc_registry.size(registry(s))
}

// ── The registry owner ─────────────────────────────────────────────────────

type OwnerState {
  OwnerState(
    registry: doc_registry.Registry(Msg),
    storage: store.Backend,
    factory: DocFactory,
    idle_ms: Int,
    /// Monitor → the topic it was taken for, so a `DOWN` can find the row to
    /// clean up.
    monitors: dict.Dict(process.Monitor, String),
  )
}

fn handle_owner(
  state: OwnerState,
  message: OwnerMsg,
) -> actor.Next(OwnerState, OwnerMsg) {
  case message {
    EnsureStarted(topic, reply) ->
      // Re-check under serialization: two callers can both miss the ETS read and
      // both land here, and the second must get the first one's actor rather
      // than starting a duplicate. This is why starts go through one process.
      case doc_registry.lookup(state.registry, topic) {
        Ok(subject) -> {
          process.send(reply, Ok(subject))
          actor.continue(state)
        }
        Error(Nil) -> start_child(state, topic, reply)
      }
    ChildDown(down) ->
      case down {
        process.ProcessDown(monitor:, pid:, ..) ->
          case dict.get(state.monitors, monitor) {
            Ok(topic) -> {
              // Only clear the row if it still points at the process that died.
              // A document that stopped and was immediately restarted has a live
              // actor under the same topic, and deleting its row here would
              // orphan it.
              case doc_registry.lookup(state.registry, topic) {
                Ok(current) ->
                  case process.subject_owner(current) == Ok(pid) {
                    True -> doc_registry.delete(state.registry, topic)
                    False -> Nil
                  }
                Error(Nil) -> Nil
              }
              actor.continue(
                OwnerState(
                  ..state,
                  monitors: dict.delete(state.monitors, monitor),
                ),
              )
            }
            Error(Nil) -> actor.continue(state)
          }
        process.PortDown(..) -> actor.continue(state)
      }
  }
}

fn start_child(
  state: OwnerState,
  topic: String,
  reply: Subject(Result(Subject(Msg), Nil)),
) -> actor.Next(OwnerState, OwnerMsg) {
  let argument = #(topic, state.storage, state.registry, state.idle_ms)
  case
    factory_supervisor.start_child(
      factory_supervisor.get_by_name(state.factory),
      argument,
    )
  {
    Ok(started) -> {
      doc_registry.insert(state.registry, topic, started.data)
      let monitor = process.monitor(started.pid)
      process.send(reply, Ok(started.data))
      actor.continue(
        OwnerState(
          ..state,
          monitors: dict.insert(state.monitors, monitor, topic),
        ),
      )
    }
    Error(_) -> {
      process.send(reply, Error(Nil))
      actor.continue(state)
    }
  }
}

// ── The document actor ─────────────────────────────────────────────────────

/// Start the actor for one document. The factory's template, so this is only
/// ever called by the owner via `factory_supervisor.start_child`.
fn start_document(
  argument: DocArgument,
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  let #(topic, storage, registry, idle_ms) = argument
  actor.new_with_initialiser(1000, fn(self) {
    schedule_sweep(self, idle_ms)
    actor.initialised(DocState(self:, doc: None))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(fn(state, message) {
    handle(topic, storage, registry, idle_ms, state, message)
  })
  |> actor.start
}

/// This document's in-memory state, rebuilding it from storage if it has none.
///
/// The returned value carries a fresh `last_touched_ms`. Every handler that
/// mutates the document reads it through here and writes the result back, so
/// that one line is what keeps the idle timer's clock current — no per-handler
/// bookkeeping. Read-only handlers do not write back, so a document nobody is
/// changing ages out even while it is being read; that is harmless, because
/// stopping is just a cache drop and this rebuilds it.
fn doc(storage: store.Backend, topic: String, state: DocState) -> Doc {
  case state.doc {
    Some(d) -> Doc(..d, last_touched_ms: doc_state.now_ms())
    None -> doc_state.rehydrate(storage, topic)
  }
}

/// The `existing` flag every join-shaped reply carries: is this document already
/// known? Holding a cached `Doc` is the in-memory half — the same test the old
/// single actor made against its `docs` dict.
fn already_exists(
  storage: store.Backend,
  topic: String,
  state: DocState,
) -> Bool {
  case state.doc {
    Some(_) -> True
    None -> doc_state.stored_document_exists(storage, topic)
  }
}

fn cache(state: DocState, d: Doc) -> actor.Next(DocState, Msg) {
  actor.continue(DocState(..state, doc: Some(d)))
}

fn handle(
  topic: String,
  storage: store.Backend,
  registry: doc_registry.Registry(Msg),
  idle_ms: Int,
  st: DocState,
  m: Msg,
) -> actor.Next(DocState, Msg) {
  case m {
    Create(t, reply) -> {
      let existing = already_exists(storage, t, st)
      store.put_document(storage, t)
      process.send(reply, existing)
      cache(st, doc(storage, t, st))
    }
    CreateInitialized(t, build, reply) -> {
      let existing = already_exists(storage, t, st)
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
              cache(
                st,
                Doc(
                  seq: seq,
                  history: [],
                  summary: summary_state,
                  presence: dict.new(),
                  last_touched_ms: doc_state.now_ms(),
                ),
              )
            }
          }
      }
    }
    Connect(t, c, mode, client, join_data, timestamp, reply) -> {
      let existing = already_exists(storage, t, st)
      store.put_document(storage, t)
      let d = doc(storage, t, st)
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
              doc_state.initial_messages(doc_state.remember(d, #(sn, message))),
              handle,
              summary_sn,
              sn,
              Some(#(sn, message)),
            ),
          )
          cache(
            st,
            Doc(
              ..d,
              seq: seq,
              history: doc_state.remember(d, #(sn, message)),
              presence: dict.insert(d.presence, c, client),
            ),
          )
        }
        _ -> {
          process.send(
            reply,
            Connected(
              existing,
              roster,
              doc_state.initial_messages(d.history),
              handle,
              summary_sn,
              d.seq.sequence_number,
              None,
            ),
          )
          cache(st, Doc(..d, presence: dict.insert(d.presence, c, client)))
        }
      }
    }
    Join(t, c, reply) -> {
      let existing = already_exists(storage, t, st)
      store.put_document(storage, t)
      let d = doc(storage, t, st)
      process.send(reply, existing)
      cache(
        st,
        Doc(
          ..d,
          seq: sequencing.client_join(d.seq, c, d.seq.sequence_number),
          presence: dict.insert(d.presence, c, minimal_client("write")),
        ),
      )
    }
    JoinPresence(t, c, mode, reply) -> {
      let existing = already_exists(storage, t, st)
      store.put_document(storage, t)
      let d = doc(storage, t, st)
      process.send(reply, existing)
      cache(
        st,
        Doc(..d, presence: dict.insert(d.presence, c, minimal_client(mode))),
      )
    }
    JoinSequenced(t, c, data, timestamp, reply) -> {
      let existing = already_exists(storage, t, st)
      store.put_document(storage, t)
      let d = doc(storage, t, st)
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
      cache(
        st,
        Doc(
          ..d,
          seq: seq,
          history: doc_state.remember(d, #(sn, message)),
          presence: dict.insert(d.presence, c, minimal_client("write")),
        ),
      )
    }
    Leave(t, c) -> {
      let d = doc(storage, t, st)
      cache(
        st,
        Doc(
          ..d,
          seq: sequencing.client_leave(d.seq, c),
          presence: dict.delete(d.presence, c),
        ),
      )
    }
    LeavePresence(t, c) -> {
      let d = doc(storage, t, st)
      cache(st, Doc(..d, presence: dict.delete(d.presence, c)))
    }
    LeaveSequenced(t, c, timestamp, reply) -> {
      let d = doc(storage, t, st)
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
      cache(
        st,
        Doc(
          ..d,
          seq: seq,
          history: doc_state.remember(d, #(sn, message)),
          presence: dict.delete(d.presence, c),
        ),
      )
    }
    Submit(t, c, csn, rsn, contents, reply) -> {
      let d = doc(storage, t, st)
      case sequencing.assign_sequence_number(d.seq, c, csn, rsn) {
        sequencing.SequenceOk(seq, sn, msn) -> {
          // Durable before acked, matching `SubmitMessage`. Replying first let
          // the caller wake and read storage before this write ran.
          store.put_op(storage, t, sn, contents)
          process.send(reply, Assigned(sn, msn))
          cache(
            st,
            Doc(..d, seq: seq, history: doc_state.remember(d, #(sn, contents))),
          )
        }
        sequencing.SequenceError(_) -> {
          process.send(reply, Rejected(d.seq.sequence_number))
          actor.continue(st)
        }
      }
    }
    SubmitMessage(t, c, csn, rsn, build, reply) -> {
      let d = doc(storage, t, st)
      case sequencing.assign_sequence_number(d.seq, c, csn, rsn) {
        sequencing.SequenceOk(seq, sn, msn) -> {
          let message = build(sn, msn)
          store.put_op(storage, t, sn, message)
          process.send(reply, MessageAssigned(sn, msn, message))
          cache(
            st,
            Doc(..d, seq: seq, history: doc_state.remember(d, #(sn, message))),
          )
        }
        sequencing.SequenceError(_) -> {
          process.send(reply, MessageRejected(d.seq.sequence_number))
          actor.continue(st)
        }
      }
    }
    SubmitSummary(t, c, csn, rsn, contents, response_contents, handle, reply) -> {
      let d = doc(storage, t, st)
      case sequencing.assign_sequence_number(d.seq, c, csn, rsn) {
        sequencing.SequenceOk(seq, summary_sn, msn) -> {
          let response_sn = summary_sn + 1
          let seq =
            sequencing.SequenceState(..seq, sequence_number: response_sn)
          // Durable before acked, matching `SubmitSummaryMessages`. The write
          // order among these three is itself load-bearing — ops, then the
          // summary pointer — so the ack goes after all of them, not between.
          store.put_op(storage, t, summary_sn, contents)
          store.put_op(storage, t, response_sn, response_contents)
          case handle {
            Some(handle) -> store.put_summary(storage, t, handle, summary_sn)
            _ -> Nil
          }
          process.send(reply, SummaryAssigned(summary_sn, response_sn, msn))
          cache(
            st,
            Doc(
              ..d,
              seq: seq,
              history: doc_state.remember_both(d, #(summary_sn, contents), #(
                response_sn,
                response_contents,
              )),
              summary: case handle {
                Some(handle) -> #(handle, summary_sn)
                _ -> d.summary
              },
            ),
          )
        }
        sequencing.SequenceError(_) -> {
          process.send(reply, SummaryRejected(d.seq.sequence_number))
          actor.continue(st)
        }
      }
    }
    SubmitSummaryMessages(t, c, csn, rsn, build, reply) -> {
      let d = doc(storage, t, st)
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
          cache(
            st,
            Doc(
              ..d,
              seq: seq,
              history: doc_state.remember_both(
                d,
                #(summary_sn, summary_message),
                #(response_sn, response_message),
              ),
              summary: case handle {
                Some(handle) -> #(handle, summary_sn)
                _ -> d.summary
              },
            ),
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
      process.send(reply, dict.keys(doc(storage, t, st).presence))
      actor.continue(st)
    }
    Roster(t, reply) -> {
      process.send(reply, dict.to_list(doc(storage, t, st).presence))
      actor.continue(st)
    }
    Exists(t, reply) -> {
      process.send(reply, already_exists(storage, t, st))
      actor.continue(st)
    }
    SequenceNumber(t, reply) -> {
      process.send(reply, doc(storage, t, st).seq.sequence_number)
      actor.continue(st)
    }
    InitializeSummary(t, handle, sn, reply) -> {
      store.put_summary(storage, t, handle, sn)
      let d = doc(storage, t, st)
      process.send(reply, Nil)
      cache(
        st,
        Doc(..d, seq: sequencing.from_checkpoint(sn, sn), summary: #(handle, sn)),
      )
    }
    SetSummary(t, handle, sn) -> {
      store.put_summary(storage, t, handle, sn)
      let d = doc(storage, t, st)
      cache(st, Doc(..d, summary: #(handle, sn)))
    }
    GetSummary(t, reply) -> {
      process.send(reply, store.get_summary(storage, t))
      actor.continue(st)
    }
    UpdateClientRsn(t, client_id, rsn) -> {
      let d = doc(storage, t, st)
      case sequencing.update_client_rsn(d.seq, client_id, rsn) {
        Error(_) -> actor.continue(st)
        Ok(seq) -> cache(st, Doc(..d, seq: seq))
      }
    }
    Sweep ->
      case idle(st, idle_ms) {
        // Deregister *before* stopping, so the common path never leaves a row
        // pointing at a dead process. The owner's monitor is only the backstop
        // for the path this cannot cover — a crash.
        True -> {
          doc_registry.delete(registry, topic)
          actor.stop()
        }
        False -> {
          schedule_sweep(st.self, idle_ms)
          actor.continue(st)
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

@external(erlang, "floodgate_ffi", "getenv")
fn getenv(name: String, default: String) -> String
