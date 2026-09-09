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
import silt/object
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
  let assert Ok(recovery) = recover(storage, topic)
  recovery.document
}

pub type Recovery {
  Recovery(
    document: Doc,
    commit_bodies: List(#(String, String)),
    warnings: List(String),
  )
}

/// Calculate publication and sequence state without changing storage.
pub fn recover(
  storage: store.Backend,
  topic: String,
) -> Result(Recovery, git.PublicationError) {
  let ops = store.get_ops(storage, topic)
  let last_sequence_number =
    list.fold(ops, 0, fn(highest, op) {
      case op.0 > highest {
        True -> op.0
        False -> highest
      }
    })
  let pointer = store.get_summary(storage, topic) |> result.unwrap(#("", 0))
  use pointer_chain <- result.try(case pointer.0 {
    "" -> Ok([])
    sha -> git.recovery_chain(storage, topic, sha)
  })
  let indexed = dict.from_list(ops)
  use #(summary, chain, warnings) <- result.try(
    list.try_fold(ops, #(pointer, pointer_chain, []), fn(selected, op) {
      case
        json.parse(op.1, decode.field("type", decode.string, decode.success))
      {
        Ok("summaryAck") ->
          case acknowledged_summary(storage, topic, indexed, op) {
            Error(reason) ->
              Ok(#(selected.0, selected.1, [reason, ..selected.2]))
            Ok(#(candidate, bodies)) -> {
              case candidate.1 == selected.0.1, candidate.0 == selected.0.0 {
                True, False if selected.0.0 != "" ->
                  Error(git.CorruptPublication(
                    "Conflicting publications at the same proposal sequence",
                  ))
                _, _ ->
                  case candidate.1 > selected.0.1 || selected.0.0 == "" {
                    True -> Ok(#(candidate, bodies, selected.2))
                    False -> Ok(selected)
                  }
              }
            }
          }
        _ -> Ok(selected)
      }
    }),
  )
  let #(handle, summary_sequence_number) = summary
  let checkpoint = case summary_sequence_number > last_sequence_number {
    True -> summary_sequence_number
    False -> last_sequence_number
  }
  Ok(Recovery(
    Doc(
      seq: sequencing.from_checkpoint(checkpoint, summary_sequence_number),
      // Newest first, and only as much as a live document would have kept.
      history: ops |> list.reverse |> list.take(max_history_size),
      summary: #(handle, summary_sequence_number),
      presence: dict.new(),
      last_touched_ms: now_ms(),
    ),
    chain,
    list.reverse(warnings),
  ))
}

fn acknowledged_summary(
  storage: store.Backend,
  topic: String,
  ops: Dict(Int, String),
  op: #(Int, String),
) -> Result(#(#(String, Int), List(#(String, String))), String) {
  let envelope = {
    use client <- decode.field("clientId", decode.optional(decode.string))
    use csn <- decode.field("clientSequenceNumber", decode.int)
    use sn <- decode.field("sequenceNumber", decode.int)
    use reference <- decode.field("referenceSequenceNumber", decode.int)
    decode.success(#(client, csn, sn, reference))
  }
  use #(client, csn, sn, reference) <- result.try(
    json.parse(op.1, envelope)
    |> result.replace_error("Invalid summaryAck envelope"),
  )
  use Nil <- result.try(case client == None && csn == -1 && sn == op.0 {
    True -> Ok(Nil)
    False -> Error("Summary acknowledgement is not server-authored")
  })
  let ack_contents = {
    use handle <- decode.field("handle", decode.string)
    use proposal_sn <- decode.subfield(
      ["summaryProposal", "summarySequenceNumber"],
      decode.int,
    )
    decode.success(#(handle, proposal_sn))
  }
  use #(handle, proposal_sn) <- result.try(contents(op.1, ack_contents))
  use Nil <- result.try(case reference == proposal_sn && sn == proposal_sn + 1 {
    True -> Ok(Nil)
    False -> Error("Summary acknowledgement sequence fields disagree")
  })
  use proposal <- result.try(
    dict.get(ops, proposal_sn)
    |> result.replace_error("Summary acknowledgement has no proposal"),
  )
  let proposal_envelope = {
    use kind <- decode.field("type", decode.string)
    use client <- decode.field("clientId", decode.string)
    use sn <- decode.field("sequenceNumber", decode.int)
    decode.success(#(kind, client, sn))
  }
  use #(kind, client, sn) <- result.try(
    json.parse(proposal, proposal_envelope)
    |> result.replace_error("Invalid summary proposal envelope"),
  )
  use Nil <- result.try(
    case kind == "summarize" && client != "" && sn == proposal_sn {
      True -> Ok(Nil)
      False ->
        Error("Summary acknowledgement does not reference a summarize proposal")
    },
  )
  let proposal_contents = {
    use _handle <- decode.field("handle", decode.string)
    use _head <- decode.field("head", decode.string)
    use parents <- decode.field("parents", decode.list(decode.string))
    decode.success(parents)
  }
  use parents <- result.try(contents(proposal, proposal_contents))
  use chain <- result.try(
    git.recovery_chain(storage, topic, handle)
    |> result.map_error(fn(error) {
      case error {
        git.CorruptPublication(reason) -> reason
        git.StorageUnavailable -> "Summary commit storage is unavailable"
      }
    }),
  )
  let assert Ok(#(_, body)) = list.first(chain)
  let assert Ok(commit) = object.decode_commit(body)
  case commit.parents == parents {
    True -> Ok(#(#(handle, proposal_sn), chain))
    False -> Error("Acknowledged commit parents disagree with its proposal")
  }
}

fn contents(message: String, decoder: decode.Decoder(a)) -> Result(a, String) {
  use value <- result.try(
    json.parse(
      message,
      decode.field("contents", decode.dynamic, decode.success),
    )
    |> result.replace_error("Summary message has no contents"),
  )
  case decode.run(value, decoder) {
    Ok(value) -> Ok(value)
    Error(_) -> {
      use serialized <- result.try(
        decode.run(value, decode.string)
        |> result.replace_error("Invalid summary contents"),
      )
      json.parse(serialized, decoder)
      |> result.replace_error("Invalid summary contents")
    }
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
