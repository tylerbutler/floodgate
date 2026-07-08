//// Floodgate-owned `connect_document` protocol decision helpers.
////
//// Tenant secret storage and the document Session/Registry runtime stay in
//// Levee for this migration step, so this module only owns the pure
//// Fluid-protocol pieces of `connect_document` that don't need either of
//// those: payload field extraction, and the doc:read / doc:write scope
//// decision spillway's `Scope` vocabulary implies for a requested connection
//// mode. Callers still perform their own JWT signature verification and the
//// session join, then use `validate_mode_scope/2` on the resulting claims'
//// scopes.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/result
import spillway/types

/// The tenant/document/token fields every `connect_document` payload must
/// carry.
pub type ConnectRequest {
  ConnectRequest(tenant_id: String, document_id: String, token: String)
}

pub type ConnectError {
  MissingField(field: String)
  WriteModeWithoutWriteScope
}

/// The `doc:read` scope string, from spillway's `Scope` vocabulary.
pub fn read_scope() -> String {
  types.scope_to_string(types.DocRead)
}

/// The `doc:write` scope string, from spillway's `Scope` vocabulary.
pub fn write_scope() -> String {
  types.scope_to_string(types.DocWrite)
}

/// Extract the required `connect_document` payload fields.
pub fn parse_request(
  payload: Dict(String, Dynamic),
) -> Result(ConnectRequest, ConnectError) {
  use tenant_id <- result.try(required_string(payload, "tenantId"))
  use document_id <- result.try(required_string(payload, "id"))
  use token <- result.try(required_string(payload, "token"))
  Ok(ConnectRequest(
    tenant_id: tenant_id,
    document_id: document_id,
    token: token,
  ))
}

/// A `connect_document` payload requesting `"mode": "write"` needs the
/// `doc:write` scope in `scopes`; any other (or absent) mode doesn't need
/// this check — callers should already require `doc:read` via their own JWT
/// verification to get this far.
pub fn validate_mode_scope(
  payload: Dict(String, Dynamic),
  scopes: List(String),
) -> Result(Nil, ConnectError) {
  case requested_mode(payload) {
    "write" ->
      case list.contains(scopes, write_scope()) {
        True -> Ok(Nil)
        False -> Error(WriteModeWithoutWriteScope)
      }
    _ -> Ok(Nil)
  }
}

fn requested_mode(payload: Dict(String, Dynamic)) -> String {
  case dict.get(payload, "mode") {
    Ok(value) ->
      case decode.run(value, decode.string) {
        Ok(mode) -> mode
        Error(_) -> ""
      }
    Error(_) -> ""
  }
}

fn required_string(
  payload: Dict(String, Dynamic),
  key: String,
) -> Result(String, ConnectError) {
  case dict.get(payload, key) {
    Ok(value) ->
      case decode.run(value, decode.string) {
        Ok(str) if str != "" -> Ok(str)
        _ -> Error(MissingField(key))
      }
    Error(_) -> Error(MissingField(key))
  }
}
