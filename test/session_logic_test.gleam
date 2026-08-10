import floodgate/nack
import floodgate/session_logic
import floodgate/signals
import gleam/dict
import gleam/dynamic
import gleam/option.{None, Some}
import gleeunit/should

// ─────────────────────────────────────────────────────────────────────────────
// session_logic: feature/version negotiation
// ─────────────────────────────────────────────────────────────────────────────

pub fn negotiate_features_client_agrees_test() {
  let server = dict.from_list([#("submit_signals_v2", True)])
  let client = dict.from_list([#("submit_signals_v2", True)])
  session_logic.negotiate_features(server, client)
  |> should.equal(dict.from_list([#("submit_signals_v2", True)]))
}

pub fn negotiate_features_client_silent_advertises_test() {
  let server = dict.from_list([#("submit_signals_v2", True)])
  let client = dict.new()
  session_logic.negotiate_features(server, client)
  |> should.equal(dict.from_list([#("submit_signals_v2", True)]))
}

pub fn negotiate_features_client_declines_test() {
  let server = dict.from_list([#("submit_signals_v2", True)])
  let client = dict.from_list([#("submit_signals_v2", False)])
  session_logic.negotiate_features(server, client)
  |> should.equal(dict.from_list([#("submit_signals_v2", False)]))
}

pub fn negotiate_version_matches_test() {
  session_logic.negotiate_version(["^0.1.0", "^1.0.0"], ["^1.0.0"])
  |> should.equal("1.0.0")
}

pub fn negotiate_version_falls_back_test() {
  session_logic.negotiate_version(["^0.1.0", "^1.0.0"], ["^9.9.9"])
  |> should.equal("0.1.0")
}

// ─────────────────────────────────────────────────────────────────────────────
// session_logic: summarize content validation
// ─────────────────────────────────────────────────────────────────────────────

pub fn validate_summarize_contents_ok_test() {
  let contents =
    dict.from_list([
      #("handle", dynamic.string("h")),
      #("message", dynamic.string("m")),
      #("parents", dynamic.string("p")),
      #("head", dynamic.string("head")),
    ])
  session_logic.validate_summarize_contents(contents) |> should.equal(Ok(Nil))
}

pub fn validate_summarize_contents_missing_field_test() {
  let contents = dict.from_list([#("handle", dynamic.string("h"))])
  let assert Error(_) = session_logic.validate_summarize_contents(contents)
}

// ─────────────────────────────────────────────────────────────────────────────
// session_logic: signal recipient targeting
// ─────────────────────────────────────────────────────────────────────────────

pub fn determine_signal_recipients_broadcast_test() {
  session_logic.determine_signal_recipients("c1", None, None, None, [
    "c1",
    "c2",
    "c3",
  ])
  |> should.equal(["c2", "c3"])
}

pub fn determine_signal_recipients_targeted_test() {
  session_logic.determine_signal_recipients(
    "c1",
    Some(["c1", "c2"]),
    None,
    None,
    ["c1", "c2", "c3"],
  )
  |> should.equal(["c2"])
}

pub fn determine_signal_recipients_ignored_test() {
  session_logic.determine_signal_recipients("c1", None, Some(["c2"]), None, [
    "c1",
    "c2",
    "c3",
  ])
  |> should.equal(["c3"])
}

pub fn determine_signal_recipients_single_target_test() {
  session_logic.determine_signal_recipients("c1", None, None, Some("c3"), [
    "c1",
    "c2",
    "c3",
  ])
  |> should.equal(["c3"])
}

// ─────────────────────────────────────────────────────────────────────────────
// session_logic: wire builders + history trimming
// ─────────────────────────────────────────────────────────────────────────────

pub fn build_summary_ack_shape_test() {
  let fields = session_logic.build_summary_ack("handle-1", 10, 5, 1000)
  let assert Ok(sn) = get_field(fields, "sequenceNumber")
  let assert Ok(rsn) = get_field(fields, "referenceSequenceNumber")
  let assert Ok(kind) = get_field(fields, "type")
  sn |> should.equal(dynamic.int(11))
  rsn |> should.equal(dynamic.int(10))
  kind |> should.equal(dynamic.string("summaryAck"))
}

pub fn add_to_history_trims_and_prepends_test() {
  session_logic.add_to_history(4, [3, 2, 1], 3)
  |> should.equal([4, 3, 2])
}

fn get_field(fields: List(#(String, a)), key: String) -> Result(a, Nil) {
  case fields {
    [] -> Error(Nil)
    [#(k, v), ..] if k == key -> Ok(v)
    [_, ..rest] -> get_field(rest, key)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// signals: v1/v2 normalization
// ─────────────────────────────────────────────────────────────────────────────

pub fn normalize_signal_v1_test() {
  let raw =
    dict.from_list([
      #("address", dynamic.string("")),
      #(
        "contents",
        dynamic.properties([
          #(dynamic.string("type"), dynamic.string("cursor")),
          #(dynamic.string("content"), dynamic.string("payload")),
        ]),
      ),
      #("clientBroadcastSignalSequenceNumber", dynamic.int(3)),
    ])
  let normalized = signals.normalize_signal(raw)
  let map = signals.normalized_to_map(normalized)
  let assert Ok(kind) = dict.get(map, "type")
  kind |> should.equal(dynamic.string("cursor"))
}

pub fn normalize_signal_v2_targeting_test() {
  let raw =
    dict.from_list([
      #("content", dynamic.string("payload")),
      #("targetedClients", dynamic.list([dynamic.string("c2")])),
    ])
  let normalized = signals.normalize_signal(raw)
  let map = signals.normalized_to_map(normalized)
  let assert Ok(targeted) = dict.get(map, "targetedClients")
  targeted |> should.equal(dynamic.list([dynamic.string("c2")]))
}

// ─────────────────────────────────────────────────────────────────────────────
// nack: constructors
// ─────────────────────────────────────────────────────────────────────────────

pub fn unknown_client_nack_test() {
  let nack_result = nack.unknown_client("c1")
  nack_result.sequence_number |> should.equal(-1)
  nack_result.content.code |> should.equal(400)
}

pub fn read_only_client_nack_test() {
  let nack_result = nack.read_only_client(None)
  nack_result.content.message |> should.equal("Client is in read-only mode")
}

pub fn invalid_csn_nack_test() {
  let nack_result = nack.invalid_csn(2, 5, None)
  nack_result.content.code |> should.equal(400)
  nack_result.content.message
  |> should.equal("Invalid client sequence number: expected > 2, received 5")
}

pub fn invalid_rsn_nack_test() {
  let nack_result = nack.invalid_rsn(9, 3, None)
  nack_result.content.message
  |> should.equal("Invalid RSN: current SN is 9, received 3")
}

pub fn error_type_to_string_test() {
  nack.invalid_csn(1, 2, None).content.error_type
  |> nack.error_type_to_string()
  |> should.equal("BadRequestError")
}
