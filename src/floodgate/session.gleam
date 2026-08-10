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
//// until it rejoined). Now a crash only resets one document's live client
//// states; the first later connection closes any unmatched durable joins.
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
//// Read-only operations never *start* a document actor, and most involve no
//// process at all. `since` and `summary` read storage directly; `exists`,
//// `clients` and `roster` answer from the registry plus storage; only
//// `sequence_number` consults an actor when one exists, and then just to avoid
//// re-deriving a checkpoint it already holds. That matters because `exists` is
//// reachable from unauthenticated REST paths — routing reads through
//// get-or-start would let any `GET` on an unknown document spawn an actor.
////
//// The storage reads are only correct because every submit handler writes before
//// it acks (`2e59238`) and both backends' writes are synchronous. Reverse either
//// and a caller could be told an op was assigned, then fail to read it back.

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
fn owner_subject(session: Session) -> Subject(OwnerMsg) {
  process.named_subject(session.name)
}

fn registry(session: Session) -> doc_registry.Registry(Subject(Msg)) {
  doc_registry.from_name(session.name)
}

/// How a client asked to connect. Writers join the sequencing quorum with a
/// durable join op; readers only appear in presence. The wire carries this as
/// the IConnect `mode` string — see `mode_to_string`.
pub type Mode {
  Read
  Write
}

/// The wire encoding of a `Mode`, as IConnect/IClient's `mode` field spells it.
pub fn mode_to_string(mode: Mode) -> String {
  case mode {
    Read -> "read"
    Write -> "write"
  }
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
    mode: Mode,
    client: String,
    join_data: String,
    timestamp: Int,
    reply: Subject(ConnectionResult),
  )
  Join(topic: String, client_id: String, reply: Subject(Bool))
  JoinPresence(
    topic: String,
    client_id: String,
    mode: Mode,
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
  Clients(topic: String, reply: Subject(List(String)))
  Roster(topic: String, reply: Subject(List(#(String, String))))
  Exists(topic: String, reply: Subject(Bool))
  SequenceNumber(topic: String, reply: Subject(Int))
  InitializeSummary(topic: String, handle: String, sn: Int, reply: Subject(Nil))
  SetSummary(topic: String, handle: String, sn: Int, reply: Subject(Nil))
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
  #(String, store.Backend, doc_registry.Registry(Subject(Msg)), Int)

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

/// How the session admitted the connecting client. A writer's join is
/// sequenced as a durable op, which every writer has and no reader does — so
/// the op rides on the variant instead of an `Option` that would let a
/// writer-without-join-op be represented.
pub type Membership {
  Writer(sequence_number: Int, message: String)
  Reader
}

pub type ConnectionResult {
  Connected(
    existing: Bool,
    roster: List(#(String, String)),
    initial_ops: List(#(Int, String)),
    summary_handle: String,
    summary_sequence_number: Int,
    current_sequence_number: Int,
    recovery: List(#(Int, String)),
    membership: Membership,
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
  /// Replaying the full durable log is needed only before the first connection
  /// handled by this actor. Other messages may populate `doc` first.
  DocState(self: Subject(Msg), doc: Option(Doc), membership_reconciled: Bool)
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
/// `store.open` is a no-op for both backends. Their lifecycle is started before
/// this actor by `store.supervise`, so a session restart cannot disturb it.
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
    Some(document) ->
      dict.is_empty(document.presence)
      && document.last_touched_ms <= doc_state.now_ms() - idle_ms
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
pub fn owner(session: Session) -> Result(process.Pid, Nil) {
  process.subject_owner(owner_subject(session))
}

/// The pid of the actor currently serving `topic`, if one is running. `Error`
/// means the document is not in memory, not that it does not exist. For
/// supervision tests and diagnostics.
pub fn document_owner(
  session: Session,
  topic: String,
) -> Result(process.Pid, Nil) {
  case doc_registry.lookup(registry(session), topic) {
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
// - Mutating handlers use `call_doc`, which starts an actor if there isn't one.
// - Non-mutating handlers use `send_doc` or answer from storage directly, so
//   they never bring a document into memory. Reading must not be able to
//   allocate, or any `GET` on an unknown document would spawn an actor.

/// Resolve the actor for `topic`, starting one if there isn't one.
///
/// The ETS read is the fast path and happens right here in the calling process.
/// Only a miss costs a message, and only to the owner, which serializes starts
/// so two callers racing on the same cold document cannot produce two actors.
fn resolve(session: Session, topic: String) -> Subject(Msg) {
  case doc_registry.lookup(registry(session), topic) {
    Ok(subject) -> subject
    Error(Nil) -> start_document_actor(session, topic)
  }
}

fn start_document_actor(session: Session, topic: String) -> Subject(Msg) {
  let assert Ok(subject) =
    process.call(owner_subject(session), 1000, EnsureStarted(topic, _))
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
  session: Session,
  topic: String,
  timeout: Int,
  make: fn(Subject(reply)) -> Msg,
) -> reply {
  case
    exception.rescue(fn() {
      process.call(resolve(session, topic), timeout, make)
    })
  {
    Ok(value) -> value
    Error(_) -> {
      // Drop the row we just failed against so the owner starts a fresh actor
      // rather than handing back the same corpse.
      doc_registry.delete(registry(session), topic)
      process.call(start_document_actor(session, topic), timeout, make)
    }
  }
}

/// Fire-and-forget to a document that is already in memory, dropping the
/// message if it is not. Only for messages whose effect on a document nobody has
/// loaded would be nil anyway.
fn send_doc(session: Session, topic: String, message: Msg) -> Nil {
  case doc_registry.lookup(registry(session), topic) {
    Ok(subject) -> process.send(subject, message)
    Error(Nil) -> Nil
  }
}

pub fn create(session: Session, topic: String) -> Bool {
  call_doc(session, topic, 1000, Create(topic, _))
}

pub fn create_initialized(
  session: Session,
  topic: String,
  build: fn() -> Result(Option(#(String, Int)), Nil),
) -> CreateInitializedResult {
  call_doc(session, topic, 10_000, CreateInitialized(topic, build, _))
}

pub fn join(session: Session, topic: String, client_id: String) -> Bool {
  call_doc(session, topic, 1000, Join(topic, client_id, _))
}

pub fn connect(
  session: Session,
  topic: String,
  client_id: String,
  mode: Mode,
  client: String,
  join_data: String,
  timestamp: Int,
) -> ConnectionResult {
  call_doc(session, topic, 1000, Connect(
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
  session: Session,
  topic: String,
  client_id: String,
  mode: Mode,
) -> Bool {
  call_doc(session, topic, 1000, JoinPresence(topic, client_id, mode, _))
}

pub fn join_sequenced(
  session: Session,
  topic: String,
  client_id: String,
  data: String,
  timestamp: Int,
) -> JoinResult {
  call_doc(session, topic, 1000, JoinSequenced(
    topic,
    client_id,
    data,
    timestamp,
    _,
  ))
}

pub fn submit(
  session: Session,
  topic: String,
  client_id: String,
  csn: Int,
  rsn: Int,
  contents: String,
) -> SubmitResult {
  call_doc(session, topic, 1000, Submit(topic, client_id, csn, rsn, contents, _))
}

pub fn submit_message(
  session: Session,
  topic: String,
  client_id: String,
  csn: Int,
  rsn: Int,
  build: fn(Int, Int) -> String,
) -> SubmitMessageResult {
  call_doc(session, topic, 1000, SubmitMessage(
    topic,
    client_id,
    csn,
    rsn,
    build,
    _,
  ))
}

pub fn submit_summary(
  session: Session,
  topic: String,
  client_id: String,
  csn: Int,
  rsn: Int,
  contents: String,
  response_contents: String,
  handle: Option(String),
) -> SubmitSummaryResult {
  call_doc(session, topic, 1000, SubmitSummary(
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
  session: Session,
  topic: String,
  client_id: String,
  csn: Int,
  rsn: Int,
  build: fn(Int, Int, Int) -> #(String, String, Option(String)),
) -> SubmitSummaryMessagesResult {
  call_doc(session, topic, 1000, SubmitSummaryMessages(
    topic,
    client_id,
    csn,
    rsn,
    build,
    _,
  ))
}

pub fn leave(session: Session, topic: String, client_id: String) -> Nil {
  send_doc(session, topic, Leave(topic, client_id))
}

pub fn leave_presence(
  session: Session,
  topic: String,
  client_id: String,
) -> Nil {
  send_doc(session, topic, LeavePresence(topic, client_id))
}

pub fn leave_sequenced(
  session: Session,
  topic: String,
  client_id: String,
  timestamp: Int,
) -> LeaveResult {
  call_doc(session, topic, 1000, LeaveSequenced(topic, client_id, timestamp, _))
}

/// Ops after `sn`, straight from storage — no process involved, hot or cold.
///
/// Safe because every submit handler now writes before it acks, and both
/// backends' writes are synchronous (`memory_store` blocks on a `process.call`,
/// `shelf_store` inserts into ETS/DETS inline). So anything a caller has been
/// told was assigned is already readable here. This briefly routed through the
/// document's actor instead, to close the window the two mis-ordered handlers
/// left open before `2e59238`; fixing the order removed the reason.
pub fn since(session: Session, topic: String, sn: Int) -> List(#(Int, String)) {
  store.get_ops(session.storage, topic) |> list.filter(fn(op) { op.0 > sn })
}

pub fn clients(session: Session, topic: String) -> List(String) {
  case doc_registry.lookup(registry(session), topic) {
    Ok(subject) -> process.call(subject, 1000, Clients(topic, _))
    // A document with no actor has no presence: `doc_state.rehydrate` starts
    // with an empty roster, so the old code's answer here was `[]` too.
    Error(Nil) -> []
  }
}

pub fn roster(session: Session, topic: String) -> List(#(String, String)) {
  case doc_registry.lookup(registry(session), topic) {
    Ok(subject) -> process.call(subject, 1000, Roster(topic, _))
    Error(Nil) -> []
  }
}

/// Whether the document exists, in memory or in storage.
///
/// Deliberately allocation-free — this is reachable from REST paths that do not
/// require a document to exist, so it must not be able to spawn an actor.
pub fn exists(session: Session, topic: String) -> Bool {
  case doc_registry.lookup(registry(session), topic) {
    Ok(_) -> True
    Error(Nil) -> doc_state.stored_document_exists(session.storage, topic)
  }
}

pub fn sequence_number(session: Session, topic: String) -> Int {
  case doc_registry.lookup(registry(session), topic) {
    Ok(subject) -> process.call(subject, 1000, SequenceNumber(topic, _))
    // Same rebuild the actor would do on its first touch, without keeping it.
    Error(Nil) ->
      doc_state.rehydrate(session.storage, topic).seq.sequence_number
  }
}

/// Set the stored summary pointer.
///
/// Synchronous, like `initialize_summary` and unlike the other `process.send`
/// messages, because it is the only fire-and-forget message with a *durable*
/// effect. While it was async, `summary` could not read storage directly — the
/// read raced the write it had just asked for.
pub fn set_summary(
  session: Session,
  topic: String,
  handle: String,
  sn: Int,
) -> Nil {
  call_doc(session, topic, 1000, SetSummary(topic, handle, sn, _))
}

/// Advance a client's reference sequence number without sequencing an op, so
/// an idle client still lets the minimum sequence number move. Fire-and-forget,
/// mirroring levee's `Session.update_client_rsn` cast.
pub fn update_client_rsn(
  session: Session,
  topic: String,
  client_id: String,
  rsn: Int,
) -> Nil {
  send_doc(session, topic, UpdateClientRsn(topic, client_id, rsn))
}

pub fn initialize_summary(
  session: Session,
  topic: String,
  handle: String,
  sn: Int,
) -> Nil {
  call_doc(session, topic, 1000, InitializeSummary(topic, handle, sn, _))
}

/// The latest summary, straight from storage — same reasoning as `since`. The
/// summary pointer is the last of `SubmitSummary`'s three writes and the ack
/// follows all of them, so observing the ack means this read sees it.
/// `Error(Nil)` when the document has never been summarized.
pub fn summary(session: Session, topic: String) -> Result(#(String, Int), Nil) {
  store.get_summary(session.storage, topic)
}

/// How many documents are currently held in memory. Documents are a cache over
/// storage, so this is bounded by the idle timers rather than by the number of
/// documents the server has ever seen. For tests and diagnostics.
///
/// Now a direct ETS read of the registry's size rather than a process call,
/// since one live actor is exactly one cached document.
pub fn cached_documents(session: Session) -> Int {
  doc_registry.size(registry(session))
}

// ── The registry owner ─────────────────────────────────────────────────────

type OwnerState {
  OwnerState(
    registry: doc_registry.Registry(Subject(Msg)),
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
    actor.initialised(DocState(self:, doc: None, membership_reconciled: False))
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
    Some(document) -> Doc(..document, last_touched_ms: doc_state.now_ms())
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

fn cache(state: DocState, document: Doc) -> actor.Next(DocState, Msg) {
  actor.continue(DocState(..state, doc: Some(document)))
}

fn reconcile_membership(
  storage: store.Backend,
  topic: String,
  document: Doc,
) -> #(Doc, List(#(Int, String))) {
  let unmatched =
    store.get_ops(storage, topic)
    |> doc_state.unmatched_clients
    |> list.filter(fn(client_id) { !dict.has_key(document.presence, client_id) })
  let #(reconciled, newest_first) =
    list.fold(unmatched, #(document, []), fn(acc, client_id) {
      let #(next, op) =
        sequence_leave(storage, topic, acc.0, client_id, now_seconds() * 1000)
      #(next, [op, ..acc.1])
    })
  #(reconciled, list.reverse(newest_first))
}

fn sequence_leave(
  storage: store.Backend,
  topic: String,
  document: Doc,
  client_id: String,
  timestamp: Int,
) -> #(Doc, #(Int, String)) {
  let sn = document.seq.sequence_number + 1
  let left = sequencing.client_leave(document.seq, client_id)
  let seq = sequencing.SequenceState(..left, sequence_number: sn)
  let data = json.string(client_id) |> json.to_string
  let message =
    system_message("leave", data, sn, seq.minimum_sequence_number, timestamp)
  persist_op(storage, topic, sn, message)
  #(
    Doc(
      ..document,
      seq: seq,
      history: doc_state.remember(document, #(sn, message)),
      presence: dict.delete(document.presence, client_id),
    ),
    #(sn, message),
  )
}

fn handle(
  topic: String,
  storage: store.Backend,
  registry: doc_registry.Registry(Subject(Msg)),
  idle_ms: Int,
  state: DocState,
  message: Msg,
) -> actor.Next(DocState, Msg) {
  case message {
    Create(topic, reply) -> {
      let existing = already_exists(storage, topic, state)
      persist_document(storage, topic)
      process.send(reply, existing)
      cache(state, doc(storage, topic, state))
    }
    CreateInitialized(topic, build, reply) -> {
      let existing = already_exists(storage, topic, state)
      case existing {
        True -> {
          process.send(reply, AlreadyExists)
          actor.continue(state)
        }
        False ->
          case build() {
            Error(Nil) -> {
              process.send(reply, InvalidInitialSummary)
              actor.continue(state)
            }
            Ok(summary) -> {
              persist_document(storage, topic)
              let #(seq, summary_state) = case summary {
                Some(#(handle, sn)) -> {
                  persist_summary(storage, topic, handle, sn)
                  #(sequencing.from_checkpoint(sn, sn), #(handle, sn))
                }
                None -> #(sequencing.new(), #("", 0))
              }
              process.send(reply, Created)
              cache(
                state,
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
    Connect(topic, client_id, mode, client, join_data, timestamp, reply) -> {
      let existing = already_exists(storage, topic, state)
      persist_document(storage, topic)
      let document = doc(storage, topic, state)
      let #(document, recovery) = case state.membership_reconciled {
        True -> #(document, [])
        False -> reconcile_membership(storage, topic, document)
      }
      let roster = dict.to_list(document.presence)
      let #(handle, summary_sn) = document.summary
      case mode {
        Write -> {
          let sn = document.seq.sequence_number + 1
          let joined =
            sequencing.client_join(
              document.seq,
              client_id,
              document.seq.sequence_number,
            )
          let seq = sequencing.SequenceState(..joined, sequence_number: sn)
          let message =
            system_message(
              "join",
              join_data,
              sn,
              seq.minimum_sequence_number,
              timestamp,
            )
          persist_op(storage, topic, sn, message)
          process.send(
            reply,
            Connected(
              existing,
              roster,
              doc_state.initial_messages(
                doc_state.remember(document, #(sn, message)),
              ),
              handle,
              summary_sn,
              sn,
              recovery,
              Writer(sn, message),
            ),
          )
          cache(
            DocState(..state, membership_reconciled: True),
            Doc(
              ..document,
              seq: seq,
              history: doc_state.remember(document, #(sn, message)),
              presence: dict.insert(document.presence, client_id, client),
            ),
          )
        }
        Read -> {
          process.send(
            reply,
            Connected(
              existing,
              roster,
              doc_state.initial_messages(document.history),
              handle,
              summary_sn,
              document.seq.sequence_number,
              recovery,
              Reader,
            ),
          )
          cache(
            DocState(..state, membership_reconciled: True),
            Doc(
              ..document,
              presence: dict.insert(document.presence, client_id, client),
            ),
          )
        }
      }
    }
    Join(topic, client_id, reply) -> {
      let existing = already_exists(storage, topic, state)
      persist_document(storage, topic)
      let document = doc(storage, topic, state)
      process.send(reply, existing)
      cache(
        state,
        Doc(
          ..document,
          seq: sequencing.client_join(
            document.seq,
            client_id,
            document.seq.sequence_number,
          ),
          presence: dict.insert(
            document.presence,
            client_id,
            minimal_client(Write),
          ),
        ),
      )
    }
    JoinPresence(topic, client_id, mode, reply) -> {
      let existing = already_exists(storage, topic, state)
      persist_document(storage, topic)
      let document = doc(storage, topic, state)
      process.send(reply, existing)
      cache(
        state,
        Doc(
          ..document,
          presence: dict.insert(
            document.presence,
            client_id,
            minimal_client(mode),
          ),
        ),
      )
    }
    JoinSequenced(topic, client_id, data, timestamp, reply) -> {
      let existing = already_exists(storage, topic, state)
      persist_document(storage, topic)
      let document = doc(storage, topic, state)
      let sn = document.seq.sequence_number + 1
      let joined =
        sequencing.client_join(
          document.seq,
          client_id,
          document.seq.sequence_number,
        )
      let seq = sequencing.SequenceState(..joined, sequence_number: sn)
      let message =
        system_message("join", data, sn, seq.minimum_sequence_number, timestamp)
      persist_op(storage, topic, sn, message)
      process.send(
        reply,
        Joined(existing, sn, seq.minimum_sequence_number, message),
      )
      cache(
        state,
        Doc(
          ..document,
          seq: seq,
          history: doc_state.remember(document, #(sn, message)),
          presence: dict.insert(
            document.presence,
            client_id,
            minimal_client(Write),
          ),
        ),
      )
    }
    Leave(topic, client_id) -> {
      let document = doc(storage, topic, state)
      cache(
        state,
        Doc(
          ..document,
          seq: sequencing.client_leave(document.seq, client_id),
          presence: dict.delete(document.presence, client_id),
        ),
      )
    }
    LeavePresence(topic, client_id) -> {
      let document = doc(storage, topic, state)
      cache(
        state,
        Doc(..document, presence: dict.delete(document.presence, client_id)),
      )
    }
    LeaveSequenced(topic, client_id, timestamp, reply) -> {
      let document = doc(storage, topic, state)
      let #(document, #(sn, message)) =
        sequence_leave(storage, topic, document, client_id, timestamp)
      process.send(
        reply,
        Left(sn, document.seq.minimum_sequence_number, message),
      )
      cache(state, document)
    }
    Submit(topic, client_id, csn, rsn, contents, reply) -> {
      let document = doc(storage, topic, state)
      case
        sequencing.assign_sequence_number(document.seq, client_id, csn, rsn)
      {
        sequencing.SequenceOk(seq, sn, msn) -> {
          // Durable before acked, matching `SubmitMessage`. Replying first let
          // the caller wake and read storage before this write ran.
          persist_op(storage, topic, sn, contents)
          process.send(reply, Assigned(sn, msn))
          cache(
            state,
            Doc(
              ..document,
              seq: seq,
              history: doc_state.remember(document, #(sn, contents)),
            ),
          )
        }
        sequencing.SequenceError(_) -> {
          process.send(reply, Rejected(document.seq.sequence_number))
          actor.continue(state)
        }
      }
    }
    SubmitMessage(topic, client_id, csn, rsn, build, reply) -> {
      let document = doc(storage, topic, state)
      case
        sequencing.assign_sequence_number(document.seq, client_id, csn, rsn)
      {
        sequencing.SequenceOk(seq, sn, msn) -> {
          let message = build(sn, msn)
          persist_op(storage, topic, sn, message)
          process.send(reply, MessageAssigned(sn, msn, message))
          cache(
            state,
            Doc(
              ..document,
              seq: seq,
              history: doc_state.remember(document, #(sn, message)),
            ),
          )
        }
        sequencing.SequenceError(_) -> {
          process.send(reply, MessageRejected(document.seq.sequence_number))
          actor.continue(state)
        }
      }
    }
    SubmitSummary(
      topic,
      client_id,
      csn,
      rsn,
      contents,
      response_contents,
      handle,
      reply,
    ) -> {
      let document = doc(storage, topic, state)
      case
        sequencing.assign_sequence_number(document.seq, client_id, csn, rsn)
      {
        sequencing.SequenceOk(seq, summary_sn, msn) -> {
          let response_sn = summary_sn + 1
          let seq =
            sequencing.SequenceState(..seq, sequence_number: response_sn)
          // Durable before acked, matching `SubmitSummaryMessages`. The write
          // order among these three is itself load-bearing — ops, then the
          // summary pointer — so the ack goes after all of them, not between.
          persist_op(storage, topic, summary_sn, contents)
          persist_op(storage, topic, response_sn, response_contents)
          case handle {
            Some(handle) -> persist_summary(storage, topic, handle, summary_sn)
            None -> Nil
          }
          process.send(reply, SummaryAssigned(summary_sn, response_sn, msn))
          cache(
            state,
            Doc(
              ..document,
              seq: seq,
              history: doc_state.remember_both(
                document,
                #(summary_sn, contents),
                #(response_sn, response_contents),
              ),
              summary: case handle {
                Some(handle) -> #(handle, summary_sn)
                None -> document.summary
              },
            ),
          )
        }
        sequencing.SequenceError(_) -> {
          process.send(reply, SummaryRejected(document.seq.sequence_number))
          actor.continue(state)
        }
      }
    }
    SubmitSummaryMessages(topic, client_id, csn, rsn, build, reply) -> {
      let document = doc(storage, topic, state)
      case
        sequencing.assign_sequence_number(document.seq, client_id, csn, rsn)
      {
        sequencing.SequenceOk(seq, summary_sn, msn) -> {
          let response_sn = summary_sn + 1
          let seq =
            sequencing.SequenceState(..seq, sequence_number: response_sn)
          let #(summary_message, response_message, handle) =
            build(summary_sn, response_sn, msn)
          persist_op(storage, topic, summary_sn, summary_message)
          persist_op(storage, topic, response_sn, response_message)
          case handle {
            Some(handle) -> persist_summary(storage, topic, handle, summary_sn)
            None -> Nil
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
            state,
            Doc(
              ..document,
              seq: seq,
              history: doc_state.remember_both(
                document,
                #(summary_sn, summary_message),
                #(response_sn, response_message),
              ),
              summary: case handle {
                Some(handle) -> #(handle, summary_sn)
                None -> document.summary
              },
            ),
          )
        }
        sequencing.SequenceError(_) -> {
          process.send(
            reply,
            SummaryMessagesRejected(document.seq.sequence_number),
          )
          actor.continue(state)
        }
      }
    }
    Clients(topic, reply) -> {
      process.send(reply, dict.keys(doc(storage, topic, state).presence))
      actor.continue(state)
    }
    Roster(topic, reply) -> {
      process.send(reply, dict.to_list(doc(storage, topic, state).presence))
      actor.continue(state)
    }
    Exists(topic, reply) -> {
      process.send(reply, already_exists(storage, topic, state))
      actor.continue(state)
    }
    SequenceNumber(topic, reply) -> {
      process.send(reply, doc(storage, topic, state).seq.sequence_number)
      actor.continue(state)
    }
    InitializeSummary(topic, handle, sn, reply) -> {
      persist_summary(storage, topic, handle, sn)
      let document = doc(storage, topic, state)
      process.send(reply, Nil)
      cache(
        state,
        Doc(..document, seq: sequencing.from_checkpoint(sn, sn), summary: #(
          handle,
          sn,
        )),
      )
    }
    SetSummary(topic, handle, sn, reply) -> {
      persist_summary(storage, topic, handle, sn)
      let document = doc(storage, topic, state)
      process.send(reply, Nil)
      cache(state, Doc(..document, summary: #(handle, sn)))
    }
    UpdateClientRsn(topic, client_id, rsn) -> {
      let document = doc(storage, topic, state)
      case sequencing.update_client_rsn(document.seq, client_id, rsn) {
        Error(_) -> actor.continue(state)
        Ok(seq) -> cache(state, Doc(..document, seq: seq))
      }
    }
    Sweep ->
      case idle(state, idle_ms) {
        // Deregister *before* stopping, so the common path never leaves a row
        // pointing at a dead process. The owner's monitor is only the backstop
        // for the path this cannot cover — a crash.
        True -> {
          doc_registry.delete(registry, topic)
          actor.stop()
        }
        False -> {
          schedule_sweep(state.self, idle_ms)
          actor.continue(state)
        }
      }
  }
}

fn minimal_client(mode: Mode) -> String {
  json.object([#("mode", json.string(mode_to_string(mode)))])
  |> json.to_string
}

/// Durability before ack: every submit/join handler writes before it replies,
/// so a failed storage write must crash this supervised actor — a restart
/// rehydrates from what actually reached storage — rather than let an
/// unpersisted op be acked.
fn persist_op(
  storage: store.Backend,
  topic: String,
  sequence_number: Int,
  contents: String,
) -> Nil {
  let assert Ok(Nil) = store.put_op(storage, topic, sequence_number, contents)
  Nil
}

/// See `persist_op`.
fn persist_document(storage: store.Backend, topic: String) -> Nil {
  let assert Ok(Nil) = store.put_document(storage, topic)
  Nil
}

/// See `persist_op`.
fn persist_summary(
  storage: store.Backend,
  topic: String,
  handle: String,
  sequence_number: Int,
) -> Nil {
  let assert Ok(Nil) =
    store.put_summary(storage, topic, handle, sequence_number)
  Nil
}

pub fn stored_message_to_json(op: #(Int, String)) -> json.Json {
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

@external(erlang, "floodgate_ffi", "now_seconds")
fn now_seconds() -> Int
