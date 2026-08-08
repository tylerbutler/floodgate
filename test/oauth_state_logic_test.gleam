import floodgate/oauth_state_logic as logic
import gleeunit/should

// ─────────────────────────────────────────────────────────────────────────────
// Single-use — a validated state cannot be validated again.
// ─────────────────────────────────────────────────────────────────────────────

pub fn take_returns_the_code_verifier_on_first_use_test() {
  let table = logic.new() |> logic.put("state-1", "verifier-1", 1000, 180)
  let #(_table, result) = logic.take(table, "state-1", 1001)
  result |> should.equal(Ok("verifier-1"))
}

pub fn take_consumes_the_entry_so_a_second_take_fails_test() {
  let table = logic.new() |> logic.put("state-1", "verifier-1", 1000, 180)
  let #(table, first) = logic.take(table, "state-1", 1001)
  first |> should.equal(Ok("verifier-1"))

  let #(_table, second) = logic.take(table, "state-1", 1001)
  second |> should.equal(Error(Nil))
}

// ─────────────────────────────────────────────────────────────────────────────
// Expiry — deterministic via an injected `now`, never a sleep.
// ─────────────────────────────────────────────────────────────────────────────

pub fn take_succeeds_the_instant_before_expiry_test() {
  let table = logic.new() |> logic.put("state-1", "verifier-1", 1000, 180)
  // expires_at = 1180; 1179 is still valid.
  let #(_table, result) = logic.take(table, "state-1", 1179)
  result |> should.equal(Ok("verifier-1"))
}

pub fn take_fails_at_or_after_expiry_test() {
  let table = logic.new() |> logic.put("state-1", "verifier-1", 1000, 180)
  let #(_table, result) = logic.take(table, "state-1", 1180)
  result |> should.equal(Error(Nil))
}

/// Even an expired entry is consumed (removed) on the failed `take` — single-
/// use applies whether or not the token turned out to still be valid, so a
/// second attempt with a *corrected* clock cannot resurrect it.
pub fn expired_take_still_consumes_the_entry_test() {
  let table = logic.new() |> logic.put("state-1", "verifier-1", 1000, 180)
  let #(table, first) = logic.take(table, "state-1", 1180)
  first |> should.equal(Error(Nil))

  let #(_table, second) = logic.take(table, "state-1", 1001)
  second |> should.equal(Error(Nil))
}

// ─────────────────────────────────────────────────────────────────────────────
// Mismatch/unknown state — never seen before, or belongs to a different
// login attempt.
// ─────────────────────────────────────────────────────────────────────────────

pub fn take_unknown_state_fails_test() {
  let table = logic.new()
  let #(_table, result) = logic.take(table, "never-stored", 1000)
  result |> should.equal(Error(Nil))
}

pub fn take_does_not_confuse_two_concurrent_attempts_test() {
  let table =
    logic.new()
    |> logic.put("state-a", "verifier-a", 1000, 180)
    |> logic.put("state-b", "verifier-b", 1000, 180)

  let #(table, a) = logic.take(table, "state-a", 1001)
  a |> should.equal(Ok("verifier-a"))

  // state-a is consumed, but state-b is untouched.
  let #(_table, b) = logic.take(table, "state-b", 1001)
  b |> should.equal(Ok("verifier-b"))
}

// ─────────────────────────────────────────────────────────────────────────────
// Opportunistic sweep on `put` — see the module doc for why this replaces a
// scheduled cleanup timer.
// ─────────────────────────────────────────────────────────────────────────────

pub fn put_sweeps_already_expired_entries_test() {
  let table = logic.new() |> logic.put("stale", "stale-verifier", 1000, 1)
  // stale expires at 1001; a later put at now=2000 should drop it.
  let table = logic.put(table, "fresh", "fresh-verifier", 2000, 180)

  let #(_table, stale_result) = logic.take(table, "stale", 2000)
  stale_result |> should.equal(Error(Nil))

  let #(_table, fresh_result) = logic.take(table, "fresh", 2000)
  fresh_result |> should.equal(Ok("fresh-verifier"))
}

pub fn expire_drops_only_entries_past_now_test() {
  let table =
    logic.new()
    |> logic.put("old", "old-verifier", 1000, 1)
    |> logic.put("new", "new-verifier", 1000, 500)

  let table = logic.expire(table, 1002)

  let #(table, old_result) = logic.take(table, "old", 1002)
  old_result |> should.equal(Error(Nil))

  let #(_table, new_result) = logic.take(table, "new", 1002)
  new_result |> should.equal(Ok("new-verifier"))
}
