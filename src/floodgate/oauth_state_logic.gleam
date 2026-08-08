//// Pure, single-use, expiring CSRF-state bookkeeping for the OAuth begin/
//// callback round trip.
////
//// Kept as plain `Dict` operations over an explicit `now`, mirroring
//// `floodgate/session_logic`'s split from its actor: every expiry and
//// single-use rule is tested here directly, with no actor and no real clock
//// involved. `floodgate/oauth_state` wraps this in an actor so one entry
//// survives between the two HTTP requests ("begin" and "callback") of a
//// single login attempt.

import gleam/dict.{type Dict}

/// One in-flight login attempt: the PKCE code verifier generated alongside
/// the CSRF state, and when that state stops being acceptable.
pub type Entry {
  Entry(code_verifier: String, expires_at: Int)
}

pub type StateTable =
  Dict(String, Entry)

pub fn new() -> StateTable {
  dict.new()
}

/// Record a new in-flight login attempt, keyed by its CSRF state token.
///
/// Also drops every already-expired entry first (an opportunistic sweep
/// rather than a scheduled one — see `floodgate/oauth_state`'s module doc for
/// why a timer is not worth it here): the table can only grow on this path, so
/// bounding it here is enough to keep an abandoned login's entry from
/// outliving it indefinitely.
pub fn put(
  table: StateTable,
  state: String,
  code_verifier: String,
  now: Int,
  ttl_seconds: Int,
) -> StateTable {
  table
  |> expire(now)
  |> dict.insert(state, Entry(code_verifier:, expires_at: now + ttl_seconds))
}

/// Validate and consume a CSRF state token: always removes it — single-use,
/// whether or not it turns out to be expired or unknown — and succeeds only
/// when it was both present and not yet expired at `now`.
pub fn take(
  table: StateTable,
  state: String,
  now: Int,
) -> #(StateTable, Result(String, Nil)) {
  case dict.get(table, state) {
    Error(Nil) -> #(table, Error(Nil))
    Ok(entry) -> {
      let table = dict.delete(table, state)
      case now < entry.expires_at {
        True -> #(table, Ok(entry.code_verifier))
        False -> #(table, Error(Nil))
      }
    }
  }
}

/// Drop every entry that has expired by `now`.
pub fn expire(table: StateTable, now: Int) -> StateTable {
  dict.filter(table, fn(_state, entry) { entry.expires_at > now })
}
