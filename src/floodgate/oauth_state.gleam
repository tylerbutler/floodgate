//// Ephemeral CSRF-state actor for Floodgate's GitHub OAuth flow — the same
//// single-use, expiring token store `levee_oauth/state_store.gleam` keeps for
//// Levee, ported to Floodgate's own supervision tree so Floodgate's OAuth
//// support carries no cross-package dependency on the Elixir-facing
//// `levee_oauth`. `floodgate/oauth_state_logic` holds the actual rules; this
//// module only keeps that logic alive between the two requests ("begin" and
//// "callback") of one login attempt.
////
//// Deliberately NOT part of `store.Backend`: CSRF state is a few minutes of
//// process memory, not data a deployment needs to survive a restart for — an
//// in-flight login across a restart just means retrying it — so neither
//// storage backend needs a table for it, and there is no scheduled cleanup
//// timer either; `oauth_state_logic.put` sweeps expired entries opportunistically
//// on every new login attempt instead.

import floodgate/oauth_state_logic as logic
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/otp/supervision

pub type Msg {
  Store(state: String, code_verifier: String, now: Int, ttl_seconds: Int)
  Validate(state: String, now: Int, reply: Subject(Result(String, Nil)))
}

/// Allocate a fresh name for an oauth-state actor.
pub fn new_name() -> process.Name(Msg) {
  process.new_name("floodgate_oauth_state")
}

/// Start the actor under `name`.
pub fn start_named(
  name: process.Name(Msg),
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  actor.new(logic.new())
  |> actor.on_message(handle)
  |> actor.named(name)
  |> actor.start
}

/// Supervisable child specification for the actor.
pub fn child_spec(
  name: process.Name(Msg),
) -> supervision.ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start_named(name) })
}

/// Record a new in-flight login attempt (fire-and-forget).
pub fn store(
  subject: Subject(Msg),
  state: String,
  code_verifier: String,
  now: Int,
  ttl_seconds: Int,
) -> Nil {
  process.send(subject, Store(state:, code_verifier:, now:, ttl_seconds:))
}

/// Validate and consume a CSRF state token. See `oauth_state_logic.take` for
/// the single-use/expiry contract this enforces.
pub fn validate_and_consume(
  subject: Subject(Msg),
  state: String,
  now: Int,
) -> Result(String, Nil) {
  process.call(subject, 1000, fn(reply) { Validate(state:, now:, reply:) })
}

fn handle(
  table: logic.StateTable,
  msg: Msg,
) -> actor.Next(logic.StateTable, Msg) {
  case msg {
    Store(state:, code_verifier:, now:, ttl_seconds:) ->
      actor.continue(logic.put(table, state, code_verifier, now, ttl_seconds))
    Validate(state:, now:, reply:) -> {
      let #(table, result) = logic.take(table, state, now)
      process.send(reply, result)
      actor.continue(table)
    }
  }
}
