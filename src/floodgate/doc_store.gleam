//// One DETS file per document.
////
//// `floodgate/shelf_store` used to keep every document's data in a handful of
//// server-wide tables — one `ops.dets` for the whole node, one `objects.dets`,
//// and so on. A document was a *row*. That had three costs: shelf mirrors each
//// table into ETS at open, so memory grew with all data ever written rather
//// than with active documents; a document could not be copied, archived, or
//// deleted on its own; and DETS' 2 GB per-file ceiling was shared by every
//// document on the server.
////
//// Here a document is a file. Everything document-scoped lives in one shelf
//// table per document — the marker, ops, the summary pointer, and git objects —
//// keyed by a tag so it is one file, one DETS handle, one ETS mirror. Data that
//// is *not* document-scoped (refs, tenants, admin users and sessions) stays in
//// `shelf_store`'s shared tables.
////
//// shelf gives the runtime model for free: each table is still ETS in front of
//// DETS in `WriteThrough` mode, so reads are memory-speed and every write is
//// durable immediately, exactly as before. The only new thing is *when* a table
//// is open.
////
//// ## Ownership
////
//// A shelf table's ETS mirror belongs to the process that opened it, so a table
//// opened by a REST handler would die with the request. Opens therefore go
//// through one supervised owner actor, which also serializes them — two
//// processes opening the same path concurrently would otherwise build two ETS
//// mirrors over one DETS file and diverge.
////
//// Resolution does *not* go through that actor. Open tables are published in a
//// public ETS table (`floodgate/doc_registry`, the same mechanism and the same
//// reasoning as topic → document-actor lookup) so a hit is resolved in the
//// calling process and costs no message hop. Only a miss pays the call.
////
//// If the owner dies, its ETS mirrors die with it and `doc_registry`'s table —
//// owned by the same process — goes too, so the restarted owner starts from an
//// empty cache and reopens from DETS. `WriteThrough` means nothing is lost.
////
//// ## Eviction
////
//// A table left open holds its document's whole contents in ETS, so a server
//// that had seen a million documents would hold a million documents' data —
//// the very thing the split is meant to fix. The owner therefore sweeps on the
//// same cadence and the same `FLOODGATE_DOC_IDLE_MS` window the document
//// actors use, closing tables untouched for a full window, and evicts the
//// least recently used when `FLOODGATE_MAX_OPEN_DOCUMENTS` open files would be
//// exceeded.
////
//// Closing is only ever a cache drop: `WriteThrough` already put every write on
//// disk, so the next touch reopens and sees exactly the same data. Eviction is
//// deliberately *not* tied to a document actor stopping — the read-only REST
//// paths open tables for documents that never get an actor, and one timer
//// covers both.
////
//// The eviction/use race is safe by construction rather than by locking. A
//// caller resolves a handle from ETS and may be evicted before it uses it; shelf
//// wraps every ETS call and returns `TableClosed` rather than crashing, so
//// `with_table` drops the stale row, reopens, and retries once.
////
//// ## File layout
////
//// `{data_dir}/documents/t{hex tenant}/d{hex document id}.dets`
////
//// Document ids are client-supplied and unbounded, so both components are
//// hex-encoded: reversible (`xxd -r -p` names the document), fixed alphabet,
//// filesystem-safe, no traversal, no case-folding surprise, and one code path
//// rather than a sanitise-or-hash conditional. The `t`/`d` prefixes keep an
//// empty tenant or document id from producing an empty or dotfile name.

import floodgate/doc_registry.{type Registry}
import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import shelf
import shelf/set.{type PSet}

/// A document's table. One key space, tagged by `key_*` below, so a document is
/// a single file rather than four.
pub type Table =
  PSet(#(String, String), String)

/// Key tags. The second key element is the tag's parameter — a sequence number
/// for an op, a sha for an object, empty where the tag is the whole key.
const key_marker = "d"

const key_op = "o"

const key_summary = "s"

const key_object = "b"

pub type Msg {
  /// Open (or return the already-open) table for a document. `create` is False
  /// for reads: opening a shelf table creates its DETS file, so a read of a
  /// document that does not exist would otherwise bring it into existence —
  /// which both breaks `exists` and lets an unauthenticated probe litter the
  /// data directory.
  Open(topic: String, create: Bool, reply: Subject(Result(Table, Nil)))
  /// Close tables untouched for a full idle window.
  Sweep
}

pub opaque type DocStore {
  DocStore(name: process.Name(Msg), registry: Registry(Entry), data_dir: String)
}

/// What the lookup table holds: the open table and when it was last used.
///
/// The timestamp rides in the same row as the handle so touching a document
/// costs the one ETS write the lookup already knows how to do, rather than a
/// second table or a message to the owner on every read.
pub type Entry =
  #(Table, Int)

/// Tables open at once, capped so a burst of document opens cannot exhaust file
/// descriptors before the idle sweep gets to them — each open document costs a
/// DETS handle, a guardian process, and an ETS table. `0` disables the cap.
fn max_open_documents() -> Int {
  case int.parse(getenv("FLOODGATE_MAX_OPEN_DOCUMENTS", "")) {
    Ok(value) if value >= 0 -> value
    _ -> 1024
  }
}

/// The window an open table survives without being touched. Shared with the
/// document actors' own idle timer (`session.idle_document_ms`) deliberately:
/// they describe the same "nobody is using this document" condition at two
/// layers, and two knobs that must agree is one knob.
fn idle_document_ms() -> Int {
  case int.parse(getenv("FLOODGATE_DOC_IDLE_MS", "")) {
    Ok(value) if value >= 0 -> value
    _ -> 300_000
  }
}

/// Allocate a document store rooted at `data_dir`. The owner actor is *not*
/// started here — `supervise` adds it to the runtime's supervision tree, and
/// every accessor resolves the name at call time, so a restart is invisible to
/// holders of this value.
pub fn new(data_dir: String) -> DocStore {
  let name = process.new_name("floodgate_doc_store")
  DocStore(name:, registry: doc_registry.from_name(name), data_dir:)
}

pub fn supervise(
  builder: static_supervisor.Builder,
  docs: DocStore,
) -> static_supervisor.Builder {
  static_supervisor.add(builder, child_spec(docs))
}

/// A document store with its owner started eagerly and unsupervised, for tests
/// and embedding. A runtime should use `new` + `supervise` instead, the same
/// split `memory_store.new`/`memory_store.supervised` makes and for the same
/// reason: an unsupervised owner that dies leaves every open call timing out.
pub fn started(data_dir: String) -> DocStore {
  let docs = new(data_dir)
  let assert Ok(_) = start(docs)
  docs
}

fn child_spec(docs: DocStore) -> supervision.ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(docs) })
}

/// Everything the owner knows: the store, the tables it has opened, and the
/// windows it enforces.
///
/// `open` duplicates what the lookup table holds so the sweep can enumerate
/// tables without a `to_list` over a table other processes are writing to. The
/// authoritative *timestamps* still live in the lookup table, because callers
/// are what update them.
type OwnerState {
  OwnerState(
    docs: DocStore,
    open: Dict(String, Table),
    idle_ms: Int,
    max_open: Int,
  )
}

fn start(
  docs: DocStore,
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  // Read once, at start: the sweep cadence and the window it enforces must
  // agree, and re-reading per sweep would let them disagree.
  let idle_ms = idle_document_ms()
  actor.new_with_initialiser(1000, fn(self) {
    // Both the cache table and every table it will hold belong to this process,
    // so they share its lifetime — see the module doc.
    doc_registry.open(docs.registry)
    ensure_dir(docs.data_dir)
    schedule_sweep(self, idle_ms)
    actor.initialised(OwnerState(
      docs:,
      open: dict.new(),
      idle_ms:,
      max_open: max_open_documents(),
    ))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.named(docs.name)
  |> actor.start
}

/// Sweeps run at half the idle window, so a table is closed between one and two
/// windows after its last use — the same relationship `session.schedule_sweep`
/// uses, and the same one beryl uses between its heartbeat timeout and check
/// interval.
fn schedule_sweep(self: Subject(Msg), idle_ms: Int) -> Nil {
  case idle_ms {
    0 -> Nil
    _ -> {
      let _ = process.send_after(self, int.max(idle_ms / 2, 1), Sweep)
      Nil
    }
  }
}

fn handle(state: OwnerState, message: Msg) -> actor.Next(OwnerState, Msg) {
  case message {
    Open(topic, create, reply) -> {
      // Re-check under serialization: another caller may have opened this
      // document while the message sat in the mailbox.
      case doc_registry.lookup(state.docs.registry, topic) {
        Ok(#(table, _last_used)) -> {
          process.send(reply, Ok(table))
          actor.continue(state)
        }
        Error(Nil) -> {
          let state = enforce_max_open(state)
          case open_table(state.docs.data_dir, topic, create) {
            Error(Nil) -> {
              process.send(reply, Error(Nil))
              actor.continue(state)
            }
            Ok(table) -> {
              doc_registry.insert(state.docs.registry, topic, #(table, now_ms()))
              process.send(reply, Ok(table))
              actor.continue(
                OwnerState(..state, open: dict.insert(state.open, topic, table)),
              )
            }
          }
        }
      }
    }
    Sweep -> {
      let cutoff = now_ms() - state.idle_ms
      let state =
        close_all(
          state,
          dict.keys(
            dict.filter(state.open, fn(topic, _table) {
              last_used(state, topic) <= cutoff
            }),
          ),
        )
      schedule_sweep(process.named_subject(state.docs.name), state.idle_ms)
      actor.continue(state)
    }
  }
}

/// Make room for one more open table, closing the least recently used when the
/// cap is already reached. Reuses the sweep's own close path, so there is one
/// place a table stops being open.
fn enforce_max_open(state: OwnerState) -> OwnerState {
  case state.max_open {
    0 -> state
    max ->
      case dict.size(state.open) < max {
        True -> state
        False ->
          case
            dict.keys(state.open)
            |> list.sort(fn(left, right) {
              int.compare(last_used(state, left), last_used(state, right))
            })
          {
            [] -> state
            [oldest, ..] -> close_all(state, [oldest])
          }
      }
  }
}

/// When a document was last touched, or `0` if its row has gone — which means
/// it is not in use, so treating it as maximally stale is right.
fn last_used(state: OwnerState, topic: String) -> Int {
  case doc_registry.lookup(state.docs.registry, topic) {
    Ok(#(_table, last_used)) -> last_used
    Error(Nil) -> 0
  }
}

/// Close tables and forget them. The row is deleted *before* the close so a
/// caller resolving concurrently gets a miss and reopens, rather than a handle
/// that is about to become invalid — and if it resolved just before, shelf
/// answers `TableClosed` and `with_table` retries.
fn close_all(state: OwnerState, topics: List(String)) -> OwnerState {
  list.fold(topics, state, fn(state, topic) {
    doc_registry.delete(state.docs.registry, topic)
    case dict.get(state.open, topic) {
      Error(Nil) -> state
      Ok(table) -> {
        let _ = set.close(table)
        OwnerState(..state, open: dict.delete(state.open, topic))
      }
    }
  })
}

/// Resolve a document's table, opening it if this is its first touch, and mark
/// it used so the sweep leaves it alone.
///
/// A hit is answered from public ETS in the calling process. Only a miss calls
/// the owner, and the timeout is generous because opening streams the whole
/// DETS file through shelf's decoder into ETS — a document with a large summary
/// blob pays that once, on a cold open.
///
/// `create` is False for reads; see `Open`.
fn open(docs: DocStore, topic: String, create: Bool) -> Result(Table, Nil) {
  case doc_registry.lookup(docs.registry, topic) {
    Ok(#(table, _last_used)) -> {
      doc_registry.insert(docs.registry, topic, #(table, now_ms()))
      Ok(table)
    }
    Error(Nil) ->
      process.call(process.named_subject(docs.name), 10_000, Open(
        topic,
        create,
        _,
      ))
  }
}

/// Run `operation` against a document's table, reopening once if the sweep
/// closed it in between.
///
/// Losing that race is not an error: `WriteThrough` already put everything on
/// disk, so reopening produces the same table with the same contents. shelf
/// reports a closed table as `TableClosed` rather than crashing the caller,
/// which is what makes retrying possible instead of guarding with a lock.
fn with_table(
  docs: DocStore,
  topic: String,
  create: Bool,
  operation: fn(Table) -> Result(a, shelf.ShelfError),
) -> Result(a, Nil) {
  case attempt(docs, topic, create, operation) {
    Ok(value) -> Ok(value)
    Error(shelf.TableClosed) -> {
      doc_registry.delete(docs.registry, topic)
      attempt(docs, topic, create, operation) |> result.replace_error(Nil)
    }
    Error(_) -> Error(Nil)
  }
}

fn attempt(
  docs: DocStore,
  topic: String,
  create: Bool,
  operation: fn(Table) -> Result(a, shelf.ShelfError),
) -> Result(a, shelf.ShelfError) {
  case open(docs, topic, create) {
    Ok(table) -> operation(table)
    Error(Nil) -> Error(shelf.NotFound)
  }
}

fn open_table(
  data_dir: String,
  topic: String,
  create: Bool,
) -> Result(Table, Nil) {
  let #(dir, file) = document_path(topic)
  use <- bool.guard(
    when: !create && !file_exists(data_dir <> "/" <> dir <> "/" <> file),
    return: Error(Nil),
  )
  ensure_dir(data_dir <> "/" <> dir)
  let config =
    shelf.config(
      name: "floodgate_document",
      path: dir <> "/" <> file,
      base_directory: data_dir,
    )
    |> shelf.write_mode(mode: shelf.WriteThrough)
  // Deliberately not `let assert`: the topic is derived from a client-supplied
  // document id, and a failure to open one document must not take the node
  // down. Hex encoding already makes the path unable to escape `data_dir`, so
  // reaching here means a disk-level problem worth logging.
  case set.open_config(config: config, key: entry_key(), value: decode.string) {
    Ok(table) -> Ok(make_table_public(table))
    Error(_) -> {
      log_open_failure(topic, dir <> "/" <> file)
      Error(Nil)
    }
  }
}

/// `{documents/t<hex tenant>, d<hex document id>.dets}` for a topic.
///
/// The document id is everything after the second `:`, rejoined, so an id that
/// itself contains a colon still maps to one file rather than being truncated.
/// A topic that is not document-shaped at all lands under `t_` keyed by the
/// whole topic, so it is still stored rather than silently dropped.
fn document_path(topic: String) -> #(String, String) {
  let #(tenant, document_id) = case string.split(topic, ":") {
    ["document", tenant, ..rest] -> #(tenant, string.join(rest, ":"))
    _ -> #("", topic)
  }
  #("documents/t" <> hex(tenant), "d" <> hex(document_id) <> ".dets")
}

fn hex(value: String) -> String {
  bit_array.from_string(value) |> bit_array.base16_encode
}

/// Whether a document has anything stored, answered from the filesystem.
///
/// Exact, not an approximation: the file is created by the first write of any
/// kind and never by a read, so "the file is there" is precisely "the marker,
/// an op, a summary, or an object was stored" — the union
/// `doc_state.stored_document_exists` asks for, in one `stat`.
///
/// Deliberately does not open the table. `doc_state.stored_document_exists` is
/// reachable from unauthenticated REST paths, so opening a file per probe would
/// let an unauthenticated caller exhaust file descriptors with requests for
/// document ids that do not exist.
pub fn exists(docs: DocStore, topic: String) -> Bool {
  case doc_registry.lookup(docs.registry, topic) {
    Ok(_) -> True
    Error(Nil) -> {
      let #(dir, file) = document_path(topic)
      file_exists(docs.data_dir <> "/" <> dir <> "/" <> file)
    }
  }
}

/// How many document tables are open right now. Read straight from the lookup
/// table, so it costs no process call. Exists so eviction is observable — a
/// test that only reads data back cannot tell a table that was closed and
/// reopened from one that was never closed.
pub fn open_count(docs: DocStore) -> Int {
  doc_registry.size(docs.registry)
}

pub fn put_marker(docs: DocStore, topic: String) -> Nil {
  put(docs, topic, #(key_marker, ""), topic)
}

pub fn put_op(
  docs: DocStore,
  topic: String,
  sequence_number: Int,
  contents: String,
) -> Nil {
  put(docs, topic, #(key_op, int.to_string(sequence_number)), contents)
}

/// Every op for a document, unordered — `store.get_ops` sorts.
///
/// Folds the document's own table and keeps the `key_op` rows. The fold visits
/// the document's objects too, but only their keys: a value is copied out only
/// for the entries this keeps, so a large summary blob is not materialised
/// here.
pub fn get_ops(docs: DocStore, topic: String) -> List(#(Int, String)) {
  with_table(docs, topic, False, fn(table) {
    use entries <- result.map(set.to_list(from: table))
    list.filter_map(entries, fn(entry) {
      let #(#(tag, parameter), contents) = entry
      case tag == key_op, int.parse(parameter) {
        True, Ok(sequence_number) -> Ok(#(sequence_number, contents))
        _, _ -> Error(Nil)
      }
    })
  })
  |> result.unwrap([])
}

pub fn put_summary(
  docs: DocStore,
  topic: String,
  handle: String,
  sequence_number: Int,
) -> Nil {
  put(
    docs,
    topic,
    #(key_summary, ""),
    int.to_string(sequence_number) <> ":" <> handle,
  )
}

/// `#(handle, sequence_number)`, or `#("", 0)` when the document has never been
/// summarized — the same "no summary" answer every backend gives.
pub fn get_summary(docs: DocStore, topic: String) -> #(String, Int) {
  case get(docs, topic, #(key_summary, "")) {
    Error(Nil) -> #("", 0)
    Ok(stored) ->
      case string.split_once(stored, ":") {
        Ok(#(sequence_number, handle)) ->
          case int.parse(sequence_number) {
            Ok(sequence_number) -> #(handle, sequence_number)
            Error(Nil) -> #("", 0)
          }
        Error(Nil) -> #("", 0)
      }
  }
}

pub fn put_obj(
  docs: DocStore,
  topic: String,
  sha: String,
  body: String,
) -> Nil {
  put(docs, topic, #(key_object, sha), body)
}

pub fn get_obj(
  docs: DocStore,
  topic: String,
  sha: String,
) -> Result(String, Nil) {
  get(docs, topic, #(key_object, sha))
}

fn put(
  docs: DocStore,
  topic: String,
  key: #(String, String),
  value: String,
) -> Nil {
  let _ =
    with_table(docs, topic, True, fn(table) {
      set.insert(into: table, key: key, value: value)
    })
  Nil
}

fn get(
  docs: DocStore,
  topic: String,
  key: #(String, String),
) -> Result(String, Nil) {
  with_table(docs, topic, False, fn(table) { set.lookup(from: table, key: key) })
}

fn entry_key() -> decode.Decoder(#(String, String)) {
  use tag <- decode.field(0, decode.string)
  use parameter <- decode.field(1, decode.string)
  decode.success(#(tag, parameter))
}

@external(erlang, "floodgate_ffi", "getenv")
fn getenv(name: String, default: String) -> String

/// The same monotonic clock the document actors' idle timer uses, so the two
/// idle windows measure the same thing.
@external(erlang, "floodgate_ffi", "now_ms")
fn now_ms() -> Int

@external(erlang, "floodgate_shelf_ffi", "ensure_dir")
fn ensure_dir(dir: String) -> Nil

@external(erlang, "floodgate_shelf_ffi", "file_exists")
fn file_exists(path: String) -> Bool

@external(erlang, "floodgate_shelf_ffi", "log_open_failure")
fn log_open_failure(topic: String, path: String) -> Nil

@external(erlang, "floodgate_shelf_ffi", "make_table_public")
fn make_table_public(table: Table) -> Table
