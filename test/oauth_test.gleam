import floodgate/oauth
import gleeunit/should

// ─────────────────────────────────────────────────────────────────────────────
// Config gating — vestibule/GitHub credentials are validated only when a
// request actually needs them (see `oauth.build_config`'s doc comment), so a
// deployment with none of these set still starts; only `/auth/github` and its
// callback report the missing variable.
// ─────────────────────────────────────────────────────────────────────────────

pub fn build_config_requires_client_id_test() {
  oauth.build_config(oauth.GitHubConfig(
    client_id: "",
    client_secret: "secret",
    redirect_uri: "http://localhost:3000/auth/github/callback",
  ))
  |> should.equal(
    Error(oauth.ConfigMissing(variable: "FLOODGATE_GITHUB_CLIENT_ID")),
  )
}

pub fn build_config_requires_client_secret_test() {
  oauth.build_config(oauth.GitHubConfig(
    client_id: "client-id",
    client_secret: "",
    redirect_uri: "http://localhost:3000/auth/github/callback",
  ))
  |> should.equal(
    Error(oauth.ConfigMissing(variable: "FLOODGATE_GITHUB_CLIENT_SECRET")),
  )
}

pub fn build_config_requires_redirect_uri_test() {
  oauth.build_config(oauth.GitHubConfig(
    client_id: "client-id",
    client_secret: "secret",
    redirect_uri: "",
  ))
  |> should.equal(
    Error(oauth.ConfigMissing(variable: "FLOODGATE_GITHUB_REDIRECT_URI")),
  )
}

pub fn build_config_succeeds_with_every_value_present_test() {
  oauth.build_config(oauth.GitHubConfig(
    client_id: "client-id",
    client_secret: "secret",
    redirect_uri: "http://localhost:3000/auth/github/callback",
  ))
  |> should.be_ok
}

/// The first missing value wins — matching `levee_oauth/config`'s
/// `require_env` short-circuit order (client id, then secret, then redirect).
pub fn build_config_reports_the_first_missing_value_test() {
  oauth.build_config(oauth.GitHubConfig(
    client_id: "",
    client_secret: "",
    redirect_uri: "",
  ))
  |> should.equal(
    Error(oauth.ConfigMissing(variable: "FLOODGATE_GITHUB_CLIENT_ID")),
  )
}
