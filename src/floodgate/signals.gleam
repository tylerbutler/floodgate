//// Floodgate-owned Fluid signal v1/v2 normalization, built directly on
//// `spillway/signals`.
////
//// Signals are ephemeral (unsequenced, unpersisted) messages relayed
//// between clients. This module owns the pure normalization step that
//// converts either the legacy v1 envelope format (`address`/`contents`) or
//// the current v2 format (`content`/`type`/targeting fields) into a single
//// internal shape, so levee's `Levee.Documents.Session` doesn't need its
//// own copy of the v1/v2 detection heuristics.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/option.{None}
import spillway/signals as spillway_signals

pub type NormalizedSignal =
  spillway_signals.NormalizedSignal

/// Normalize a raw signal map (v1 or v2) to the internal format. Detects
/// v1 vs v2 based on the presence of `address`/`contents` keys.
pub fn normalize_signal(raw: Dict(String, Dynamic)) -> NormalizedSignal {
  spillway_signals.normalize_signal(raw)
}

/// Convert a `NormalizedSignal` to a `Dict` for Elixir interop.
pub fn normalized_to_map(signal: NormalizedSignal) -> Dict(String, Dynamic) {
  spillway_signals.normalized_to_map(signal)
}

/// Normalize a batch of signals (handles list, single map, or JSON string).
pub fn normalize_signal_batch(batch: Dynamic) -> List(NormalizedSignal) {
  spillway_signals.normalize_signal_batch(batch)
}

/// A signal carrying content and no targeting.
///
/// For the legacy `{signals: ["...", ...]}` shape, which has nowhere to put
/// targeting fields, so those signals go to the whole topic. `NormalizedSignal`
/// is re-exported as an alias, which does not carry its constructor, so this is
/// what lets callers build one without importing spillway directly.
pub fn untargeted(content: Dynamic) -> NormalizedSignal {
  spillway_signals.NormalizedSignal(
    content: content,
    signal_type: None,
    client_connection_number: None,
    reference_sequence_number: None,
    target_client_id: None,
    targeted_clients: None,
    ignored_clients: None,
  )
}
