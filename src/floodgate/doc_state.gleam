//// The in-memory state of a single document, and the storage-only logic that
//// rebuilds it.
////
//// Split out of `floodgate/session` so it has exactly one implementation shared
//// by two callers: `floodgate/doc_actor`, which holds a `Doc` for a document
//// someone is using, and `floodgate/session`'s read-only fallback path, which
//// answers questions about a document that has no actor without starting one.
//// Before the per-document split those were the same code because there was one
//// actor; keeping them the same code is what stops the two drifting.

import floodgate/git
import floodgate/store
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import spillway/sequencing
import spillway/session_logic

pub type Doc {
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
    /// Monotonic ms of the last mutation, maintained by `doc_actor` and read
    /// only by the idle timer.
    last_touched_ms: Int,
  )
}

/// Ops retained per document for `initialMessages`. Levee uses the same figure
/// (`@max_history_size` in `Levee.Documents.Session`); clients that need more
/// history bootstrap from the summary and `requestOps`.
pub const max_history_size = 1000

/// Prepend an op to a document's history and trim, via the same spillway helper
/// levee's `Bridge.add_to_history` calls.
pub fn remember(document: Doc, op: #(Int, String)) -> List(#(Int, String)) {
  session_logic.add_to_history(op, document.history, max_history_size)
}

/// Two ops in sequence order — a summarize and its ack, which are always
/// assigned and stored together.
pub fn remember_both(
  document: Doc,
  first: #(Int, String),
  second: #(Int, String),
) -> List(#(Int, String)) {
  session_logic.add_to_history(
    second,
    remember(document, first),
    max_history_size,
  )
}

/// The history in the order clients expect: oldest first.
pub fn initial_messages(history: List(#(Int, String))) -> List(#(Int, String)) {
  list.reverse(history)
}

/// Write clients whose durable join has no later durable leave.
///
/// This must scan the complete op stream rather than `Doc.history`, which is
/// deliberately capped. Application ops are ignored; only Floodgate-authored
/// membership messages affect the active set.
pub fn unmatched_clients(ops: List(#(Int, String))) -> List(String) {
  list.fold(ops, dict.new(), fn(active, op) {
    case membership_change(op.1) {
      Some(#(True, client_id)) -> dict.insert(active, client_id, Nil)
      Some(#(False, client_id)) -> dict.delete(active, client_id)
      None -> active
    }
  })
  |> dict.keys
  |> list.sort(string.compare)
}

fn membership_change(message: String) -> Option(#(Bool, String)) {
  case
    json.parse(message, decode.field("type", decode.string, decode.success))
  {
    Ok("join") ->
      case
        json.parse(message, decode.field("data", decode.string, decode.success))
      {
        Ok(data) ->
          case
            json.parse(
              data,
              decode.field("clientId", decode.string, decode.success),
            )
          {
            Ok(client_id) -> Some(#(True, client_id))
            Error(_) -> None
          }
        Error(_) -> None
      }
    Ok("leave") ->
      case
        json.parse(message, decode.field("data", decode.string, decode.success))
      {
        Ok(data) ->
          case json.parse(data, decode.string) {
            Ok(client_id) -> Some(#(False, client_id))
            Error(_) -> None
          }
        Error(_) -> None
      }
    _ -> None
  }
}

/// Rebuild a document's durable state from storage.
///
/// This is a pure function of `storage` and `topic` — nothing about the calling
/// process or any prior in-memory state feeds into it — which is what makes the
/// per-document actors disposable. `session` closes unmatched durable joins on
/// the first connection after a cold start; sequence numbering never regresses.
pub fn rehydrate(storage: store.Backend, topic: String) -> Doc {
  // Rebuild durable state from ETS so a restarted server keeps numbering
  // after the last persisted op and serves the latest summary.
  let ops = store.get_ops(storage, topic)
  let last_sequence_number =
    list.fold(ops, 0, fn(highest, op) {
      case op.0 > highest {
        True -> op.0
        False -> highest
      }
    })
  let #(handle, summary_sequence_number) =
    store.get_summary(storage, topic) |> result.unwrap(#("", 0))
  // Repair the one crash prefix that is not benign. The summary pointer is
  // written before the ref that mirrors it, so a crash between the two can
  // leave a document whose summary exists but which `GET /commits?sha=<id>`
  // cannot resolve — making it unloadable. Restoring a *missing* ref here is
  // idempotent and only runs when a document is first touched.
  restore_summary_ref(storage, topic, handle)
  let checkpoint = case summary_sequence_number > last_sequence_number {
    True -> summary_sequence_number
    False -> last_sequence_number
  }
  Doc(
    seq: sequencing.from_checkpoint(checkpoint, summary_sequence_number),
    // Newest first, and only as much as a live document would have kept.
    history: ops |> list.reverse |> list.take(max_history_size),
    summary: #(handle, summary_sequence_number),
    presence: dict.new(),
    last_touched_ms: now_ms(),
  )
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
    _, ["document", tenant, document_id] -> {
      // Best-effort: a failed restore leaves exactly the pre-repair state, and
      // the next touch of the document retries it.
      let _ = git.ensure_summary_ref(storage, tenant, document_id, handle)
      Nil
    }
    _, _ -> Nil
  }
}

/// Whether a document has anything persisted, for the `existing` flag every
/// join-shaped reply carries. Deliberately storage-only: it must be answerable
/// without starting an actor, since `session.exists` is reachable from
/// unauthenticated REST paths.
pub fn stored_document_exists(storage: store.Backend, topic: String) -> Bool {
  store.has_document(storage, topic)
  || store.get_ops(storage, topic) != []
  || result.is_ok(store.get_summary(storage, topic))
}

@external(erlang, "floodgate_ffi", "now_ms")
pub fn now_ms() -> Int
