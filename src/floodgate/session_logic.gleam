//// Floodgate-owned document-session decision helpers — feature/version
//// negotiation, summarize-content validation, signal-recipient targeting,
//// sequenced-op/summary-ack wire builders, and op-history trimming — built
//// directly on `spillway/session_logic`.
////
//// These are the pure (no side effects, no session/client state) pieces of
//// Fluid document-session protocol logic that levee's
//// `Levee.Documents.Session` GenServer needs. The GenServer state itself
//// (connected client PIDs, storage, summaries) stays in Levee; only the
//// decision logic moves here so it isn't duplicated between Levee's
//// vendored `levee_protocol` copy and this package's `spillway` dependency.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option}
import spillway/session_logic as spillway_session_logic

pub type SequencedOpParams =
  spillway_session_logic.SequencedOpParams

/// Negotiate features between server and client capabilities. See
/// `spillway/session_logic.negotiate_features` for the precedence rules.
pub fn negotiate_features(
  server_features: Dict(String, Bool),
  client_features: Dict(String, Bool),
) -> Dict(String, Bool) {
  spillway_session_logic.negotiate_features(server_features, client_features)
}

/// Negotiate the protocol version from the client's supported version
/// ranges, falling back to "0.1.0" when nothing matches.
pub fn negotiate_version(
  supported_versions: List(String),
  client_versions: List(String),
) -> String {
  spillway_session_logic.negotiate_version(supported_versions, client_versions)
}

/// Validate that summarize operation contents have all required fields.
pub fn validate_summarize_contents(
  contents: Dict(String, Dynamic),
) -> Result(Nil, String) {
  spillway_session_logic.validate_summarize_contents(contents)
}

/// Determine which clients should receive a signal, given targeting rules.
/// Priority: targeted_clients > ignored_clients > single_target > broadcast.
pub fn determine_signal_recipients(
  sender_client_id: String,
  targeted_clients: Option(List(String)),
  ignored_clients: Option(List(String)),
  single_target: Option(String),
  all_client_ids: List(String),
) -> List(String) {
  spillway_session_logic.determine_signal_recipients(
    sender_client_id,
    targeted_clients,
    ignored_clients,
    single_target,
    all_client_ids,
  )
}

/// Build a sequenced operation for the wire format.
pub fn build_sequenced_op(params: SequencedOpParams) -> List(#(String, Dynamic)) {
  spillway_session_logic.build_sequenced_op(params)
}

/// Build a summary ack for the wire format.
pub fn build_summary_ack(
  handle: String,
  sn: Int,
  msn: Int,
  timestamp: Int,
) -> List(#(String, Dynamic)) {
  spillway_session_logic.build_summary_ack(handle, sn, msn, timestamp)
}

/// Add an operation to the history (newest first) and trim to max size —
/// the delta catch-up history levee's Session keeps for `requestOps`/
/// `get_ops_since`.
pub fn add_to_history(op: a, history: List(a), max_size: Int) -> List(a) {
  spillway_session_logic.add_to_history(op, history, max_size)
}
