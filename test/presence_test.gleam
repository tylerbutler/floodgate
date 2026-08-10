//// Server-backed presence (`presence_v1`) — issue #87.
////
//// The frame shapes asserted here are the ones watershed's client decoders
//// require, lifted from its `sluice/frames_test` and `sluice/core_test`. Two
//// details are load-bearing and fail *silently* if wrong: `phx_ref` must be
//// present on every meta (watershed drops a meta without one), and `client_id`
//// must be too (without it every session in the roster collapses to `""`).

import beryl
import beryl/coordinator
import beryl/presence
import beryl/transport
import beryl/wire/codec.{Join}
import floodgate
import floodgate/auth
import floodgate/document_channel
import floodgate/memory_store
import floodgate/presence_worker
import floodgate/server_codec
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

const secret = "presence-test-secret"

const tenant = "fluid"

@external(erlang, "floodgate_ffi", "now_seconds")
fn now() -> Int

fn token_for(doc: String, user: String) -> String {
  auth.mint_token(
    tenant,
    doc,
    ["doc:read", "doc:write"],
    user,
    secret,
    now(),
    3600,
  )
}

// ── Metadata validation (pure) ───────────────────────────────────────────────

fn parse(payload: String) -> dynamic.Dynamic {
  let assert Ok(value) = json.parse(payload, decode.dynamic)
  value
}

fn meta_of(payload: String, client_id: String) -> Result(String, String) {
  case document_channel.presence_meta(parse(payload), client_id) {
    Ok(meta) -> Ok(json.to_string(meta))
    Error(frame) -> Error(json.to_string(frame))
  }
}

/// A well-formed command yields the app's fields plus the server's session id.
pub fn presence_meta_stamps_the_server_session_id_test() {
  let assert Ok(meta) = meta_of("{\"meta\":{\"panel\":\"sudoku\"}}", "client-7")

  meta |> string.contains("\"client_id\":\"client-7\"") |> should.be_true
  meta |> string.contains("\"panel\":\"sudoku\"") |> should.be_true
}

/// A server-owned name at the command's *top level* is an identity claim, and is
/// rejected rather than ignored.
pub fn claiming_a_server_owned_field_is_rejected_test() {
  ["key", "clientId", "session_id", "phx_ref", "phx_ref_prev"]
  |> list.each(fn(field) {
    let assert Error(frame) =
      meta_of(
        "{\"" <> field <> "\":\"mine\",\"meta\":{\"panel\":\"x\"}}",
        "client-7",
      )
    frame |> string.contains("\"code\":\"invalid_meta\"") |> should.be_true
    frame
    |> string.contains("the server owns key, session, and ref")
    |> should.be_true
  })
}

/// The same names *inside* `meta` are smuggled rather than claimed: strip them
/// and keep the command, so the server's own values reach the wire.
pub fn reserved_fields_inside_meta_are_replaced_test() {
  let assert Ok(meta) =
    meta_of(
      "{\"meta\":{\"client_id\":\"forged\",\"phx_ref\":\"forged\",\"panel\":\"x\"}}",
      "client-7",
    )

  meta |> string.contains("forged") |> should.be_false
  meta |> string.contains("\"client_id\":\"client-7\"") |> should.be_true
  meta |> string.contains("\"panel\":\"x\"") |> should.be_true
}

/// Metadata must be an object: the `metas` shape puts `phx_ref` and `client_id`
/// alongside the app's fields, and a scalar or array leaves nowhere to put them.
pub fn non_object_metadata_is_rejected_test() {
  ["{\"meta\":\"sudoku\"}", "{\"meta\":[1,2]}", "{\"meta\":7}", "{}", "[]"]
  |> list.each(fn(payload) {
    let assert Error(frame) = meta_of(payload, "client-7")
    frame |> string.contains("\"code\":\"invalid_meta\"") |> should.be_true
    frame
    |> string.contains("presence metadata must be a JSON object")
    |> should.be_true
  })
}

// ── Wire frames, end to end ──────────────────────────────────────────────────

fn attach(
  channels: beryl.Channels,
  socket_id: String,
) -> process.Subject(String) {
  let sent = process.new_subject()
  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      socket_id,
      fn(text) {
        process.send(sent, text)
        Ok(Nil)
      },
      fn(_binary) { Ok(Nil) },
      None,
      dynamic.nil(),
    ),
  )
  sent
}

fn route(channels: beryl.Channels, socket_id: String, frame: String) -> Nil {
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    socket_id,
    frame,
  )
}

fn phoenix_event(doc: String, event: String, payload: String) -> String {
  "[\"1\",\"2\",\"document:"
  <> tenant
  <> ":"
  <> doc
  <> "\",\""
  <> event
  <> "\","
  <> payload
  <> "]"
}

fn connect(
  channels: beryl.Channels,
  doc: String,
  token: String,
  socket_id: String,
) -> Nil {
  route(
    channels,
    socket_id,
    "[\"1\",\"1\",\"document:"
      <> tenant
      <> ":"
      <> doc
      <> "\",\"phx_join\",{\"token\":\""
      <> token
      <> "\"}]",
  )
  route(
    channels,
    socket_id,
    phoenix_event(
      doc,
      "connect_document",
      "{\"tenantId\":\""
        <> tenant
        <> "\",\"id\":\""
        <> doc
        <> "\",\"token\":\""
        <> token
        <> "\",\"mode\":\"write\",\"client\":{},\"versions\":[\"^0.4.0\"]}",
    ),
  )
}

fn drain(sent: process.Subject(String)) -> Nil {
  case process.receive(sent, 200) {
    Ok(_) -> drain(sent)
    Error(Nil) -> Nil
  }
}

fn join_presence(
  channels: beryl.Channels,
  doc: String,
  socket_id: String,
  meta: String,
) -> Nil {
  route(
    channels,
    socket_id,
    phoenix_event(doc, "joinPresence", "{\"meta\":" <> meta <> "}"),
  )
}

/// The next frame carrying `event`, discarding anything queued ahead of it.
/// Presence frames interleave with op traffic from the same join, and this is
/// about presence.
fn next(sent: process.Subject(String), event: String) -> String {
  let assert Ok(frame) = process.receive(sent, 1000)
  case string.contains(frame, "\"" <> event <> "\"") {
    True -> frame
    False -> next(sent, event)
  }
}

/// A Phoenix v2 frame is `[join_ref, ref, topic, event, payload]` — and on a
/// server push the first two are `null`, so this decodes the array rather than
/// splitting on punctuation.
fn payload_of(frame: String) -> dynamic.Dynamic {
  let assert Ok([_, _, _, _, payload]) =
    json.parse(frame, decode.list(decode.dynamic))
  payload
}

/// `{key: {metas: [...]}}` as `#(key, [meta json string])`, keys sorted.
fn groups(payload: dynamic.Dynamic) -> List(#(String, List(String))) {
  let assert Ok(grouped) =
    decode.run(
      payload,
      decode.dict(
        decode.string,
        decode.at(["metas"], decode.list(decode.dynamic)),
      ),
    )
  grouped
  |> dict.to_list
  |> list.map(fn(group) {
    #(
      group.0,
      list.map(group.1, fn(meta) {
        json.to_string(document_channel.dynamic_to_json(meta))
      }),
    )
  })
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
}

fn side(
  payload: dynamic.Dynamic,
  name: String,
) -> List(#(String, List(String))) {
  let assert Ok(inner) = decode.run(payload, decode.at([name], decode.dynamic))
  groups(inner)
}

fn start(doc: String) -> #(beryl.Channels, String) {
  let assert Ok(#(channels, _sess)) =
    floodgate.start_with_backend(tenant, secret, memory_store.new())
  #(channels, token_for(doc, "alice"))
}

/// The capability, without which every watershed client silently negotiates down
/// to heartbeat presence. The gate is strict: present *and* boolean `true`.
pub fn handshake_advertises_presence_v1_test() {
  let doc = "presence-capability"
  let #(channels, token) = start(doc)
  let sent = attach(channels, "s-cap")
  connect(channels, doc, token, "s-cap")

  let frame = next(sent, "connect_document_success")
  let assert Ok(supported) =
    decode.run(
      payload_of(frame),
      decode.at(["supportedFeatures", "presence_v1"], decode.bool),
    )
  supported |> should.be_true
}

/// Phoenix's join ordering: the snapshot is taken *before* the joiner is
/// tracked, so it learns of its own session from the diff that follows. A
/// snapshot already containing the joiner would make the diff a duplicate.
pub fn joining_sends_state_then_broadcasts_a_diff_test() {
  let doc = "presence-join"
  let #(channels, token) = start(doc)
  let sent = attach(channels, "s-join")
  connect(channels, doc, token, "s-join")
  drain(sent)

  join_presence(channels, doc, "s-join", "{\"panel\":\"sudoku\"}")

  groups(payload_of(next(sent, "presence_state"))) |> should.equal([])

  let diff = payload_of(next(sent, "presence_diff"))
  side(diff, "leaves") |> should.equal([])
  let assert [#("alice", [meta])] = side(diff, "joins")
  meta |> string.contains("\"client_id\":\"s-join\"") |> should.be_true
  meta |> string.contains("\"panel\":\"sudoku\"") |> should.be_true
  // Required by watershed's decoder — a meta without it is dropped entirely.
  meta |> string.contains("phx_ref") |> should.be_true
}

/// The property heartbeat presence cannot have: a late joiner has the full
/// roster immediately, with no wait for anyone's next heartbeat.
pub fn a_late_joiner_receives_the_existing_roster_test() {
  let doc = "presence-late"
  let #(channels, token) = start(doc)
  let first = attach(channels, "s-late-1")
  connect(channels, doc, token, "s-late-1")
  join_presence(channels, doc, "s-late-1", "{\"panel\":\"sudoku\"}")
  drain(first)

  let second = attach(channels, "s-late-2")
  connect(channels, doc, token_for(doc, "bob"), "s-late-2")
  drain(second)
  join_presence(channels, doc, "s-late-2", "{\"panel\":\"text\"}")

  let assert [#("alice", [meta])] =
    groups(payload_of(next(second, "presence_state")))
  meta |> string.contains("\"client_id\":\"s-late-1\"") |> should.be_true
  meta |> string.contains("\"panel\":\"sudoku\"") |> should.be_true
}

/// Two tabs of one user are two sessions under one key, not one overwriting the
/// other — which is exactly what the `{key: {metas: [...]}}` grouping is for.
pub fn two_sessions_share_one_key_test() {
  let doc = "presence-two-tabs"
  let #(channels, token) = start(doc)
  let first = attach(channels, "s-tab-1")
  let second = attach(channels, "s-tab-2")
  connect(channels, doc, token, "s-tab-1")
  connect(channels, doc, token, "s-tab-2")
  join_presence(channels, doc, "s-tab-1", "{\"panel\":\"a\"}")
  join_presence(channels, doc, "s-tab-2", "{\"panel\":\"b\"}")
  drain(first)
  drain(second)

  let third = attach(channels, "s-tab-3")
  connect(channels, doc, token_for(doc, "bob"), "s-tab-3")
  drain(third)
  join_presence(channels, doc, "s-tab-3", "{\"panel\":\"c\"}")

  let assert [#("alice", metas)] =
    groups(payload_of(next(third, "presence_state")))
  list.length(metas) |> should.equal(2)

  // And they leave independently: one tab closing must not take the other's
  // session with it, which is what keying on session rather than user buys.
  drain(third)
  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketDisconnected("s-tab-1"),
  )
  let assert [#("alice", [gone])] =
    side(payload_of(next(third, "presence_diff")), "leaves")
  gone |> string.contains("\"client_id\":\"s-tab-1\"") |> should.be_true

  // A fresh snapshot confirms it: alice is down to one session, not zero.
  let fourth = attach(channels, "s-tab-4")
  connect(channels, doc, token_for(doc, "carol"), "s-tab-4")
  drain(fourth)
  join_presence(channels, doc, "s-tab-4", "{\"panel\":\"d\"}")

  let assert [#("alice", [survivor]), #("bob", [_])] =
    groups(payload_of(next(fourth, "presence_state")))
  survivor |> string.contains("\"client_id\":\"s-tab-2\"") |> should.be_true
}

/// An update replaces the metadata under the same key.
///
/// beryl has no update call, so this is untrack-then-track and the wire carries
/// the leave and the join as two diffs where Phoenix emits one. Watershed applies
/// both as a single change (its tracker is keyed by `phx_ref` and idempotent), so
/// the resulting roster is identical.
pub fn updating_emits_a_leave_then_a_join_test() {
  let doc = "presence-update"
  let #(channels, token) = start(doc)
  let sent = attach(channels, "s-upd")
  connect(channels, doc, token, "s-upd")
  join_presence(channels, doc, "s-upd", "{\"panel\":\"sudoku\"}")
  drain(sent)

  route(
    channels,
    "s-upd",
    phoenix_event(doc, "updatePresence", "{\"meta\":{\"panel\":\"text\"}}"),
  )

  let leave = payload_of(next(sent, "presence_diff"))
  side(leave, "joins") |> should.equal([])
  let assert [#("alice", [old])] = side(leave, "leaves")
  old |> string.contains("\"panel\":\"sudoku\"") |> should.be_true

  let join = payload_of(next(sent, "presence_diff"))
  side(join, "leaves") |> should.equal([])
  let assert [#("alice", [new])] = side(join, "joins")
  new |> string.contains("\"panel\":\"text\"") |> should.be_true
}

/// An explicit leave removes the session, and a duplicate leave is a silent
/// no-op — deliberately asymmetric with update, which errors.
pub fn leaving_broadcasts_only_leaves_and_repeats_are_silent_test() {
  let doc = "presence-leave"
  let #(channels, token) = start(doc)
  let sent = attach(channels, "s-leave")
  connect(channels, doc, token, "s-leave")
  join_presence(channels, doc, "s-leave", "{\"panel\":\"sudoku\"}")
  drain(sent)

  route(channels, "s-leave", phoenix_event(doc, "leavePresence", "{}"))

  let diff = payload_of(next(sent, "presence_diff"))
  side(diff, "joins") |> should.equal([])
  let assert [#("alice", [_])] = side(diff, "leaves")

  route(channels, "s-leave", phoenix_event(doc, "leavePresence", "{}"))
  process.receive(sent, 300) |> should.equal(Error(Nil))
}

/// Socket loss removes presence with no browser involvement — the property
/// server presence exists for, which a TTL can only approximate.
pub fn disconnect_removes_presence_for_the_survivors_test() {
  let doc = "presence-disconnect"
  let #(channels, token) = start(doc)
  let leaving = attach(channels, "s-dc-1")
  let survivor = attach(channels, "s-dc-2")
  connect(channels, doc, token, "s-dc-1")
  connect(channels, doc, token_for(doc, "bob"), "s-dc-2")
  join_presence(channels, doc, "s-dc-1", "{\"panel\":\"sudoku\"}")
  join_presence(channels, doc, "s-dc-2", "{\"panel\":\"text\"}")
  drain(leaving)
  drain(survivor)

  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketDisconnected("s-dc-1"),
  )

  let diff = payload_of(next(survivor, "presence_diff"))
  side(diff, "joins") |> should.equal([])
  let assert [#("alice", [meta])] = side(diff, "leaves")
  meta |> string.contains("\"client_id\":\"s-dc-1\"") |> should.be_true
}

/// An update queued behind a disconnect must not resurrect the presence.
///
/// Driven straight at the worker, because that is where the property lives: the
/// two commands have to be *in the mailbox together* for the ordering to mean
/// anything, and a disconnected socket cannot send the update through the
/// channel at all. Being one actor is the whole mechanism — cleanup drops the
/// tracking ref, so the update behind it finds nothing to re-track.
pub fn an_update_behind_a_disconnect_does_not_resurrect_test() {
  let #(worker, diffs, pushes) = worker_only("race")

  presence_worker.join(
    worker,
    "sock-1",
    "document:t:d",
    "alice",
    json.object([#("panel", json.string("sudoku"))]),
  )
  let assert Ok(_state) = process.receive(pushes, 1000)
  let assert Ok(_join) = process.receive(diffs, 1000)

  presence_worker.cleanup(worker, "sock-1")
  presence_worker.update(
    worker,
    "sock-1",
    "document:t:d",
    json.object([#("panel", json.string("text"))]),
  )

  let assert Ok(leave) = process.receive(diffs, 1000)
  presence.diff_joins(leave, "document:t:d") |> should.equal([])
  presence.diff_leaves(leave, "document:t:d") |> list.length |> should.equal(1)
  // No second diff: the update found no tracking ref and re-tracked nothing.
  process.receive(diffs, 300) |> should.equal(Error(Nil))
  // It was rejected rather than silently dropped.
  let assert Ok(#(_, _, event, frame)) = process.receive(pushes, 1000)
  event |> should.equal("presence_error")
  frame |> string.contains("\"code\":\"not_joined\"") |> should.be_true
}

/// A worker wired to a presence actor of its own, with diffs and per-socket
/// pushes captured instead of broadcast. For the properties that are about
/// command ordering rather than the wire.
fn worker_only(
  label: String,
) -> #(
  process.Subject(presence_worker.Msg),
  process.Subject(presence.Diff),
  process.Subject(#(String, String, String, String)),
) {
  let diffs = process.new_subject()
  let pushes = process.new_subject()
  let assert Ok(p) =
    presence.default_config(label)
    |> presence.with_on_diff(fn(diff) { process.send(diffs, diff) })
    |> presence.start
  let name = presence_worker.new_name()
  let assert Ok(_) =
    presence_worker.start_named(name, p, fn(socket, topic, event, payload) {
      process.send(pushes, #(socket, topic, event, json.to_string(payload)))
    })
  #(presence_worker.from_name(name), diffs, pushes)
}

/// A duplicate cleanup is a no-op, not a second leave.
pub fn a_repeated_cleanup_emits_nothing_test() {
  let #(worker, diffs, pushes) = worker_only("repeat")

  presence_worker.join(
    worker,
    "sock-1",
    "document:t:d",
    "alice",
    json.object([]),
  )
  let assert Ok(_state) = process.receive(pushes, 1000)
  let assert Ok(_join) = process.receive(diffs, 1000)

  presence_worker.cleanup(worker, "sock-1")
  let assert Ok(_leave) = process.receive(diffs, 1000)

  presence_worker.cleanup(worker, "sock-1")
  presence_worker.leave(worker, "sock-1")
  process.receive(diffs, 300) |> should.equal(Error(Nil))
}

/// Presence commands are pushes with no reply channel, so a rejection has to
/// come back as a frame of its own.
pub fn updating_without_joining_is_rejected_test() {
  let doc = "presence-not-joined"
  let #(channels, token) = start(doc)
  let sent = attach(channels, "s-nj")
  connect(channels, doc, token, "s-nj")
  drain(sent)

  route(
    channels,
    "s-nj",
    phoenix_event(doc, "updatePresence", "{\"meta\":{\"panel\":\"x\"}}"),
  )

  let frame = next(sent, "presence_error")
  frame |> string.contains("\"code\":\"not_joined\"") |> should.be_true
}

/// Presence works on the Socket.IO endpoint too, with no transport change.
///
/// Watershed itself is Phoenix-only, so this is not a client requirement — it is
/// the check that `socketio_transport`'s catch-all really does carry an event it
/// has never heard of, in both directions. If that ever stops being true, the two
/// endpoints have diverged and this is where it shows.
pub fn presence_works_over_the_socketio_endpoint_test() {
  let doc = "presence-socketio"
  let topic = "document:" <> tenant <> ":" <> doc
  let #(channels, token) = start(doc)

  let sent = process.new_subject()
  transport.socket_connected_with_codec(
    channels: channels,
    socket_id: "s-sio-presence",
    send: fn(text) {
      process.send(sent, text)
      Ok(Nil)
    },
    send_binary: fn(_binary) { Ok(Nil) },
    codec: Some(server_codec.server_codec()),
    assigns: dynamic.nil(),
  )
  // A Socket.IO join *is* the connect_document payload, so one frame connects.
  transport.route_decoded(
    channels,
    "s-sio-presence",
    codec.inbound(
      None,
      None,
      topic,
      Join,
      dynamic.properties([
        #(dynamic.string("tenantId"), dynamic.string(tenant)),
        #(dynamic.string("id"), dynamic.string(doc)),
        #(dynamic.string("token"), dynamic.string(token)),
        #(dynamic.string("mode"), dynamic.string("read")),
      ]),
    ),
  )
  let assert Ok(connected) = process.receive(sent, 1000)
  connected |> string.contains("presence_v1") |> should.be_true
  drain(sent)

  transport.route_decoded(
    channels,
    "s-sio-presence",
    codec.inbound(
      None,
      None,
      topic,
      codec.Event("joinPresence"),
      dynamic.properties([
        #(
          dynamic.string("meta"),
          dynamic.properties([
            #(dynamic.string("panel"), dynamic.string("sudoku")),
          ]),
        ),
      ]),
    ),
  )

  let state = next(sent, "presence_state")
  state |> string.contains("metas") |> should.be_false
  let diff = next(sent, "presence_diff")
  diff |> string.contains("\"client_id\":\"s-sio-presence\"") |> should.be_true
  diff |> string.contains("\"panel\":\"sudoku\"") |> should.be_true
}

/// Presence must never be attributable to an unauthenticated socket: before
/// connect there is no verified user id to key it by.
pub fn joining_before_the_handshake_is_rejected_test() {
  let doc = "presence-unauth"
  let #(channels, token) = start(doc)
  let sent = attach(channels, "s-unauth")
  // Phase one only: joined, but no connect_document.
  route(
    channels,
    "s-unauth",
    "[\"1\",\"1\",\"document:"
      <> tenant
      <> ":"
      <> doc
      <> "\",\"phx_join\",{\"token\":\""
      <> token
      <> "\"}]",
  )
  drain(sent)

  join_presence(channels, doc, "s-unauth", "{\"panel\":\"x\"}")

  let frame = next(sent, "presence_error")
  frame |> string.contains("\"code\":\"unauthenticated\"") |> should.be_true
  frame
  |> string.contains("presence requires a completed document connection")
  |> should.be_true
}
