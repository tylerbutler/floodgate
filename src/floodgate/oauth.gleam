//// GitHub OAuth for Floodgate's admin session, using vestibule directly —
//// the same library and two-phase flow (`authorize_url`/`handle_callback`)
//// that `server/levee_oauth` wraps for Levee's Elixir side.
////
//// Floodgate calls vestibule itself rather than depending on `levee_oauth`
//// (an Elixir-facing package that reads its own environment variables via
//// `envoy`): this module is the Floodgate-native equivalent, taking already-
//// resolved config values as plain arguments instead of re-reading the
//// environment, to match how every other Floodgate setting is centralized in
//// `serve_with_backend` (see `floodgate.gleam`).
////
//// CSRF state validation mirrors `levee_oauth`'s composition exactly: look up
//// and consume the state token (single-use, expiring — `floodgate/oauth_state`)
//// *before* calling vestibule, then pass that same value as vestibule's own
//// `expected_state`. vestibule's `handle_callback` already checks
//// `callback_params` for a provider `error` key before requiring `code`, so —
//// unlike `levee_oauth_controller.ex`'s separate `complete_auth_error`
//// function, needed only because of how Phoenix pattern-matches controller
//// actions on required params — one function handles both the success and
//// provider-error callback shapes here.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/result

import vestibule
import vestibule/auth.{type Auth}
import vestibule/authorization_request.{AuthorizationRequest}
import vestibule/config as vestibule_config
import vestibule/error.{type AuthError as VestibuleAuthError}
import vestibule/strategy/github

import floodgate/oauth_state

/// CSRF state TTL in seconds (3 minutes) — matching `levee_oauth`'s default.
pub const state_ttl_seconds = 180

pub type OAuthError {
  /// A required GitHub OAuth config value is unset. Carries the env var name
  /// so the caller can report it, matching `levee_oauth/error.ConfigMissing`.
  ConfigMissing(variable: String)
  /// vestibule itself rejected the exchange — bad/expired code, provider
  /// error, network failure, etc.
  VestibuleError(VestibuleAuthError(Nil))
  /// The CSRF state was missing, unknown, expired, or already consumed.
  StateInvalid
}

/// GitHub OAuth App credentials and callback URL, already resolved from
/// `FLOODGATE_GITHUB_CLIENT_ID` / `FLOODGATE_GITHUB_CLIENT_SECRET` /
/// `FLOODGATE_GITHUB_REDIRECT_URI` (or `FLOODGATE_PUBLIC_URL`) by
/// `floodgate.gleam`.
pub type GitHubConfig {
  GitHubConfig(client_id: String, client_secret: String, redirect_uri: String)
}

/// Build vestibule's config, failing with the first missing required value.
/// Called on every request rather than cached, matching
/// `levee_oauth/config.load_github_config`: this is what makes OAuth
/// configuration validated only when a request actually needs it, so a
/// deployment that never sets these variables still starts and serves every
/// other route.
pub fn build_config(
  cfg: GitHubConfig,
) -> Result(vestibule_config.Config, OAuthError) {
  use <- guard_not_empty(cfg.client_id, "FLOODGATE_GITHUB_CLIENT_ID")
  use <- guard_not_empty(cfg.client_secret, "FLOODGATE_GITHUB_CLIENT_SECRET")
  use <- guard_not_empty(cfg.redirect_uri, "FLOODGATE_GITHUB_REDIRECT_URI")
  Ok(vestibule_config.new(cfg.client_id, cfg.client_secret, cfg.redirect_uri))
}

fn guard_not_empty(
  value: String,
  name: String,
  next: fn() -> Result(vestibule_config.Config, OAuthError),
) -> Result(vestibule_config.Config, OAuthError) {
  case value {
    "" -> Error(ConfigMissing(variable: name))
    _ -> next()
  }
}

/// Phase 1: begin the OAuth flow. Stores the CSRF state and PKCE code
/// verifier (expiring in `state_ttl_seconds`) and returns the URL to redirect
/// the browser to.
pub fn begin_auth(
  cfg: GitHubConfig,
  state_actor: Subject(oauth_state.Msg),
  now: Int,
) -> Result(String, OAuthError) {
  use oauth_config <- result.try(build_config(cfg))
  case vestibule.authorize_url(github.strategy(), oauth_config) {
    Ok(AuthorizationRequest(url:, state:, code_verifier:)) -> {
      oauth_state.store(
        state_actor,
        state,
        code_verifier,
        now,
        state_ttl_seconds,
      )
      Ok(url)
    }
    Error(err) -> Error(VestibuleError(err))
  }
}

/// Phase 2: complete the OAuth flow. `callback_params` is every query
/// parameter the provider's redirect carried (`code`+`state` on success,
/// `error`+`error_description`+`state` on denial); `state` is that same
/// request's `state` parameter, used to look up (and consume) the matching
/// CSRF entry before vestibule ever sees it.
pub fn complete_auth(
  cfg: GitHubConfig,
  state_actor: Subject(oauth_state.Msg),
  callback_params: Dict(String, String),
  state: String,
  now: Int,
) -> Result(Auth, OAuthError) {
  use oauth_config <- result.try(build_config(cfg))
  use code_verifier <- result.try(
    oauth_state.validate_and_consume(state_actor, state, now)
    |> result.replace_error(StateInvalid),
  )
  case
    vestibule.handle_callback(
      github.strategy(),
      oauth_config,
      callback_params,
      state,
      code_verifier,
    )
  {
    Ok(auth) -> Ok(auth)
    Error(err) -> Error(VestibuleError(err))
  }
}
