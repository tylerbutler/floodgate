//// Server-backed presence (`presence_v1`) — the actor that owns Floodgate's
//// side of beryl's presence registry.
////
//// This exists because beryl's `track`/`untrack`/`untrack_all`/`list` are
//// `process.call`s with a 5 s timeout that **panic** on a slow or dead actor,
//// and channel callbacks run inside the single beryl coordinator process.
//// Calling them from `document_channel` would stall — or kill — every socket on
//// the node. So every command below is a cast, handled here, and results come
//// back to the originating socket through the injected `push`.
////
//// Being one actor is also what serializes join/update/leave/cleanup: an update
//// queued behind a disconnect finds no tracking ref and cannot resurrect a
//// presence the socket already gave up.
////
//// The Fluid client roster in `floodgate/doc_state` (`Doc.presence`) is a
//// different concern with an unfortunately similar name: that is the audience
//// behind Fluid join/leave *signals*, this is the Phoenix presence lane.

import beryl/presence
import beryl/presence/wire as presence_wire
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/otp/actor
import gleam/otp/supervision

/// Client→server commands are camelCase like `submitOp`; server→client frames
/// are snake_case like `connect_document_success`. That split is the existing
/// wire convention, not an inconsistency — watershed's client pins both spellings
/// (`watershed/presence.gleam`).
pub const event_join = "joinPresence"

pub const event_update = "updatePresence"

pub const event_leave = "leavePresence"

pub const event_state = "presence_state"

pub const event_error = "presence_error"

/// The `supportedFeatures` key that tells a client this lane exists. The client
/// gate is strict — present *and* boolean `true`, or it falls back to heartbeat
/// presence with no error anywhere.
pub const feature_presence_v1 = "presence_v1"

/// Fields the server owns. A client naming one at the *top level* of a presence
/// command is claiming an identity and is rejected; the same names nested inside
/// `meta` are stripped instead, since smuggling them there is harmless once
/// dropped. `document_channel.presence_meta` enforces both halves.
pub const reserved_meta_fields = [
  "phx_ref", "phx_ref_prev", "client_id", "key", "session_id", "clientId",
]

/// Deliver one event to one socket: `socket_id`, `topic`, `event`, `payload`.
///
/// Injected rather than imported so this module depends on nothing in Floodgate.
/// `document_channel` must import *this* module for the command constructors, so
/// reaching back for `beryl.send_info` directly would be an import cycle.
pub type Push =
  fn(String, String, String, json.Json) -> Nil

pub type Msg {
  Join(client_id: String, topic: String, key: String, meta: json.Json)
  /// `topic` is carried even though a tracked session already knows its own,
  /// because the `not_joined` rejection has to be pushed to a topic the socket
  /// is actually subscribed to — and by definition there is no tracked session
  /// to read one from.
  Update(client_id: String, topic: String, meta: json.Json)
  Leave(client_id: String)
  Cleanup(client_id: String)
}

/// One tracked session. `ref` is beryl's opaque handle (also stamped into the
/// meta as `phx_ref`); `topic` and `key` are kept so an update can re-track
/// under the same identity without trusting the update's payload for either.
type Tracked {
  Tracked(ref: String, topic: String, key: String)
}

type State {
  State(presence: presence.Presence, push: Push, tracked: Dict(String, Tracked))
}

/// Allocate a fresh name for a presence worker.
pub fn new_name() -> process.Name(Msg) {
  process.new_name("floodgate_presence_worker")
}

/// The handle for a worker registered under `name`. Valid before the actor
/// starts and across restarts, which is what lets `document_channel` capture it
/// while the supervision tree is still being built.
pub fn from_name(name: process.Name(Msg)) -> Subject(Msg) {
  process.named_subject(name)
}

pub fn start_named(
  name: process.Name(Msg),
  presence: presence.Presence,
  push: Push,
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  actor.new(State(presence:, push:, tracked: dict.new()))
  |> actor.on_message(handle)
  |> actor.named(name)
  |> actor.start
}

pub fn child_spec(
  name: process.Name(Msg),
  presence: presence.Presence,
  push: Push,
) -> supervision.ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start_named(name, presence, push) })
}

/// Register this connection's presence: snapshot, then track.
pub fn join(
  worker: Subject(Msg),
  client_id: String,
  topic: String,
  key: String,
  meta: json.Json,
) -> Nil {
  process.send(worker, Join(client_id:, topic:, key:, meta:))
}

/// Replace this connection's metadata, keeping its topic and key.
pub fn update(
  worker: Subject(Msg),
  client_id: String,
  topic: String,
  meta: json.Json,
) -> Nil {
  process.send(worker, Update(client_id:, topic:, meta:))
}

/// Drop this connection's presence. A connection with none is a silent no-op —
/// a duplicate leave, or one racing the socket's own cleanup, must not error.
pub fn leave(worker: Subject(Msg), client_id: String) -> Nil {
  process.send(worker, Leave(client_id:))
}

/// Drop presence because the socket went away. Same no-op contract as `leave`.
pub fn cleanup(worker: Subject(Msg), client_id: String) -> Nil {
  process.send(worker, Cleanup(client_id:))
}

/// A `presence_error` frame. Presence commands are pushes with no reply channel,
/// so a rejection has to come back as a frame of its own.
pub fn error(code: String, message: String) -> json.Json {
  json.object([
    #("code", json.string(code)),
    #("message", json.string(message)),
  ])
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Join(client_id:, topic:, key:, meta:) ->
      case dict.get(state.tracked, client_id) {
        // Already tracked: this is a re-join on a live session, so re-track
        // rather than re-snapshot. Watershed silently discards a second
        // `presence_state` *and* the diffs racing it, so sending one would be
        // worse than useless.
        Ok(previous) ->
          actor.continue(retrack(state, client_id, previous, meta))
        Error(Nil) -> {
          // Snapshot *before* tracking, so the joiner learns of its own session
          // from the diff beryl's `on_diff` broadcasts, not from the snapshot.
          // A remote diff racing the snapshot is just a diff the client queues,
          // which is why this needs no lock on the topic.
          state.push(
            client_id,
            topic,
            event_state,
            presence_wire.encode_state(presence.list(state.presence, topic)),
          )
          let ref = presence.track(state.presence, topic, key, client_id, meta)
          actor.continue(
            State(
              ..state,
              tracked: dict.insert(
                state.tracked,
                client_id,
                Tracked(ref:, topic:, key:),
              ),
            ),
          )
        }
      }

    Update(client_id:, topic:, meta:) ->
      case dict.get(state.tracked, client_id) {
        Error(Nil) -> {
          state.push(
            client_id,
            topic,
            event_error,
            error("not_joined", "this connection has no presence to update"),
          )
          actor.continue(state)
        }
        Ok(previous) ->
          actor.continue(retrack(state, client_id, previous, meta))
      }

    // A client asking to leave something it never joined is a no-op, and must
    // stay a cheap one: a duplicate leave, or one racing the socket's own
    // cleanup, is ordinary traffic rather than an error.
    Leave(client_id:) ->
      case dict.get(state.tracked, client_id) {
        Error(Nil) -> actor.continue(state)
        Ok(_) -> untracked(state, client_id)
      }

    // Unguarded, unlike `Leave`: this map is the only record that a session was
    // ever tracked, and it does not survive a restart of this actor. Asking
    // beryl unconditionally is what stops a worker crash stranding live sessions
    // in the roster forever, since a guarded cleanup would find an empty map and
    // decide there was nothing to remove. Beryl no-ops on an unknown session.
    Cleanup(client_id:) -> untracked(state, client_id)
  }
}

/// Drop a session from beryl and from the ref map.
fn untracked(state: State, client_id: String) -> actor.Next(State, Msg) {
  // `untrack_all` rather than `untrack(ref)`: it clears the session on every
  // topic, so it stays correct if a socket ever tracks more than one.
  presence.untrack_all(state.presence, client_id)
  actor.continue(State(..state, tracked: dict.delete(state.tracked, client_id)))
}

/// Replace a tracked session's metadata under its existing topic and key.
///
/// ponytail: beryl has no metadata-update call, so this is untrack-then-track
/// and the wire carries two diffs — `{leaves: [old]}` then `{joins: [new]}` —
/// where Phoenix would emit one diff carrying both. Watershed applies them as
/// one change (its tracker is keyed by `phx_ref` and idempotent), so the roster
/// is identical; only the frame count differs. Ceiling: a peer counting diffs
/// sees two. Upgrade path: a beryl `update` API collapses it to one.
fn retrack(
  state: State,
  client_id: String,
  previous: Tracked,
  meta: json.Json,
) -> State {
  presence.untrack(state.presence, previous.ref)
  let ref =
    presence.track(
      state.presence,
      previous.topic,
      previous.key,
      client_id,
      meta,
    )
  State(
    ..state,
    tracked: dict.insert(
      state.tracked,
      client_id,
      Tracked(..previous, ref: ref),
    ),
  )
}
