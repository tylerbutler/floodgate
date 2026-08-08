//// Pure decision logic for Floodgate's admin session model: opaque
//// user/session construction, expiry, and the GitHub allow-list
//// authorization decision.
////
//// Kept free of storage, actor, and HTTP concerns — every rule here is a
//// plain function over explicit inputs (including the clock, via `now`), so
//// it is fully testable without a running server. `floodgate/store` imports
//// the two types below to shape its admin user/session backend fields;
//// `floodgate.gleam` calls the functions here once it has a request's
//// GitHub identity and a backend to check against.

import gleam/bit_array
import gleam/crypto
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// An administrator account. Unlike levee's `User`, there is no non-admin
/// variant: Floodgate's admin UI/API has exactly one role, so every
/// persisted `AdminUser` is — by construction — permitted to manage tenants.
/// `id` is the GitHub account's own numeric id (vestibule's `Auth.uid`), not a
/// server-generated value: Floodgate has no other identity provider to share
/// the id space with, so the provider's id is already the natural, permanent
/// key.
pub type AdminUser {
  AdminUser(
    id: String,
    github_username: String,
    display_name: String,
    email: String,
    created_at: Int,
  )
}

/// An opaque, server-generated admin session. `id` is the bearer token (and
/// cookie value) the admin UI holds after a successful GitHub login.
pub type AdminSession {
  AdminSession(id: String, user_id: String, created_at: Int, expires_at: Int)
}

/// Default admin session lifetime: 7 days, matching levee_auth's
/// `session.gleam` default so an operator moving between the two servers sees
/// the same default.
pub const default_session_ttl_seconds = 604_800

/// Build a fresh admin user record for a newly allowed GitHub identity.
pub fn new_admin_user(
  github_id github_id: String,
  github_username github_username: String,
  display_name display_name: String,
  email email: String,
  now now: Int,
) -> AdminUser {
  AdminUser(
    id: github_id,
    github_username:,
    display_name:,
    email:,
    created_at: now,
  )
}

/// Build a fresh admin session for `user_id`, expiring `ttl_seconds` after
/// `now`. `id` is 256 bits of `crypto.strong_random_bytes` — opaque, and
/// independent of any user- or time-derived data — matching the entropy
/// `store.generate_tenant_secret` already uses for tenant secrets.
pub fn new_admin_session(
  user_id user_id: String,
  now now: Int,
  ttl_seconds ttl_seconds: Int,
) -> AdminSession {
  AdminSession(
    id: generate_opaque_id(),
    user_id:,
    created_at: now,
    expires_at: now + ttl_seconds,
  )
}

/// A session is valid exactly while `now` is still before its expiry.
pub fn session_valid(session: AdminSession, now: Int) -> Bool {
  now < session.expires_at
}

/// Decide whether a GitHub identity may sign in and hold (or receive) admin
/// access.
///
/// - `already_admin` — true when this GitHub id already has a persisted
///   `AdminUser` — always keeps access. An allow-list change never demotes an
///   existing admin, matching levee's `User` module, which has no
///   auto-demotion path either (`promote_to_admin` is the only transition).
/// - Otherwise, an explicit allow-list (`FLOODGATE_ADMIN_GITHUB_USERS`,
///   parsed by `parse_allowlist`) is authoritative once configured: only a
///   username on it (case-insensitively — GitHub usernames are not
///   case-sensitive) may create a *new* admin account.
/// - With no allow-list configured, new admin accounts are denied. This avoids
///   a first-login-wins race on a freshly exposed deployment.
pub fn github_login_allowed(
  github_username github_username: String,
  allowlist allowlist: Option(List(String)),
  already_admin already_admin: Bool,
  any_admin_exists _any_admin_exists: Bool,
) -> Bool {
  case already_admin {
    True -> True
    False ->
      case allowlist {
        Some(usernames) ->
          list.any(usernames, fn(u) { case_insensitive_eq(u, github_username) })
        None -> False
      }
  }
}

fn case_insensitive_eq(a: String, b: String) -> Bool {
  string.lowercase(a) == string.lowercase(b)
}

/// Parse `FLOODGATE_ADMIN_GITHUB_USERS`: comma-separated GitHub usernames,
/// blanks trimmed and dropped. An unset or entirely-blank value means no new
/// GitHub identity may create an admin account.
pub fn parse_allowlist(raw: String) -> Option(List(String)) {
  let users =
    raw
    |> string.split(",")
    |> list.map(string.trim)
    |> list.filter(fn(u) { u != "" })
  case users {
    [] -> None
    _ -> Some(users)
  }
}

fn generate_opaque_id() -> String {
  crypto.strong_random_bytes(32) |> bit_array.base16_encode |> string.lowercase
}
