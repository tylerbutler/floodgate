import floodgate/oauth_state
import gleeunit/should

/// A thin smoke test for the actor wrapper — the single-use/expiry contract
/// itself is exhaustively covered by `oauth_state_logic_test.gleam` against
/// the pure `Dict` operations directly, with no actor involved.
pub fn store_and_validate_through_the_actor_test() {
  let name = oauth_state.new_name()
  let assert Ok(started) = oauth_state.start_named(name)
  let subject = started.data

  oauth_state.store(subject, "state-1", "verifier-1", 1000, 180)

  oauth_state.validate_and_consume(subject, "state-1", 1001)
  |> should.equal(Ok("verifier-1"))

  // Single-use: a second validate of the same state fails.
  oauth_state.validate_and_consume(subject, "state-1", 1001)
  |> should.be_error
}

pub fn validate_an_expired_state_through_the_actor_fails_test() {
  let name = oauth_state.new_name()
  let assert Ok(started) = oauth_state.start_named(name)
  let subject = started.data

  oauth_state.store(subject, "state-1", "verifier-1", 1000, 1)

  oauth_state.validate_and_consume(subject, "state-1", 1180)
  |> should.be_error
}
