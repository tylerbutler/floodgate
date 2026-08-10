//// Floodgate-owned Fluid nack (negative acknowledgment) constructors, built
//// directly on `spillway/nack`.
////
//// Nacks are sent when operations are rejected by the server (unknown
//// client, read-only client attempting to write, invalid client/reference
//// sequence numbers, malformed requests, ...). This module owns the pure
//// constructors; levee's `Levee.Documents.Session` converts the resulting
//// `Nack` value to its wire-format map.

import gleam/option.{type Option}
import spillway/nack as spillway_nack
import spillway/types.{type DocumentMessage}

pub type Nack =
  spillway_nack.Nack

pub type NackErrorType =
  spillway_nack.NackErrorType

/// Convert a nack error type to its wire-format string.
pub fn error_type_to_string(error_type: NackErrorType) -> String {
  spillway_nack.nack_error_type_to_string(error_type)
}

/// Create a nack for an invalid message format.
pub fn bad_request(message: String, op: Option(DocumentMessage)) -> Nack {
  spillway_nack.bad_request(message, op)
}

/// Create a nack for a read-only client attempting to write.
pub fn read_only_client(op: Option(DocumentMessage)) -> Nack {
  spillway_nack.read_only_client(op)
}

/// Create a nack for an invalid client sequence number.
pub fn invalid_csn(
  expected: Int,
  received: Int,
  op: Option(DocumentMessage),
) -> Nack {
  spillway_nack.invalid_csn(expected, received, op)
}

/// Create a nack for an invalid reference sequence number.
pub fn invalid_rsn(
  current_sn: Int,
  received_rsn: Int,
  op: Option(DocumentMessage),
) -> Nack {
  spillway_nack.invalid_rsn(current_sn, received_rsn, op)
}

/// Create a nack for an unknown client.
pub fn unknown_client(client_id: String) -> Nack {
  spillway_nack.unknown_client(client_id)
}
