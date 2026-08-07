//// Origin (CSWSH) policy shared by both socket endpoints.
////
//// beryl_mist enforces its own `Origin` policy on the Phoenix upgrade at
//// `/socket/websocket`, but the Socket.IO transport at `/socket.io/` is
//// floodgate's own code and historically had no origin check at all — so a
//// browser on any site could open a Routerlicious socket. This module holds the
//// one policy both paths derive from, so they cannot diverge again.
////
//// The parsing and comparison here are deliberately pure (no HTTP types) so the
//// semantics are unit-testable without a server; callers extract the `Origin`
//// and `Host` headers and pass them in.

import gleam/list
import gleam/result
import gleam/string

/// What to do with the `Origin` header on a WebSocket upgrade.
pub type OriginPolicy {
  /// Admit only same-origin upgrades, plus clients that send no `Origin` at
  /// all. Mirrors beryl_mist's default.
  SameOrigin
  /// Admit only these exact origins (scheme, host and any port), rejecting
  /// requests with no `Origin`.
  AllowList(List(String))
  /// Disable origin checking entirely.
  AllowAll
}

/// Parse the FLOODGATE_ALLOWED_ORIGINS value: empty means same-origin, `*`
/// disables checking, anything else is a comma-separated allow-list.
pub fn from_env(value: String) -> OriginPolicy {
  case string.trim(value) {
    "" -> SameOrigin
    "*" -> AllowAll
    origins ->
      AllowList(
        string.split(origins, ",")
        |> list.map(string.trim)
        |> list.filter(fn(origin) { origin != "" }),
      )
  }
}

/// Decide whether an upgrade carrying these headers is admissible.
///
/// `origin` and `host` are the raw header lookups; `Error(Nil)` means the header
/// was absent.
pub fn allowed(
  policy: OriginPolicy,
  origin origin: Result(String, Nil),
  host host: Result(String, Nil),
) -> Bool {
  case policy {
    AllowAll -> True
    AllowList(origins) ->
      case origin {
        Ok(value) -> list.contains(origins, value)
        // An allow-list is explicit: no Origin means no match.
        Error(Nil) -> False
      }
    SameOrigin ->
      case origin {
        // Non-browser clients (the official Fluid drivers, the conformance
        // suites) send no Origin and cannot be driven into a cross-site
        // upgrade, so admit them.
        Error(Nil) -> True
        Ok(value) ->
          case host {
            Ok(host_value) -> same_origin(value, host_value)
            // Without a Host header the request's own authority is unknown, so
            // fail closed.
            Error(Nil) -> False
          }
      }
  }
}

/// Compare an `Origin` value against a `Host` value under the same-origin rule:
/// strip the scheme and compare the authority (host plus any port)
/// case-insensitively.
///
/// A malformed or opaque origin (no `scheme://host`, e.g. `null`) never matches.
/// The comparison covers the full `host:port`, so a non-default port must be
/// present and equal on both sides.
pub fn same_origin(origin: String, host: String) -> Bool {
  case origin_authority(origin) {
    Ok(authority) -> authority == string.lowercase(string.trim(host))
    Error(Nil) -> False
  }
}

fn origin_authority(origin: String) -> Result(String, Nil) {
  use #(_scheme, rest) <- result.try(string.split_once(origin, "://"))
  // An Origin carries no path, but strip one defensively so a malformed value
  // cannot smuggle an authority past the comparison.
  let authority = case string.split_once(rest, "/") {
    Ok(#(authority, _path)) -> authority
    Error(Nil) -> rest
  }
  case authority {
    "" -> Error(Nil)
    _ -> Ok(string.lowercase(authority))
  }
}
