import floodgate/origin
import gleeunit/should

// ── FLOODGATE_ALLOWED_ORIGINS parsing ────────────────────────────────────────

pub fn unset_allowed_origins_is_same_origin_test() {
  origin.from_env("")
  |> should.equal(origin.SameOrigin)
}

pub fn blank_allowed_origins_is_same_origin_test() {
  origin.from_env("   ")
  |> should.equal(origin.SameOrigin)
}

pub fn star_disables_origin_checking_test() {
  origin.from_env("*")
  |> should.equal(origin.AllowAll)
}

pub fn allowed_origins_are_split_and_trimmed_test() {
  origin.from_env("https://a.example.com, https://b.example.com")
  |> should.equal(
    origin.AllowList(["https://a.example.com", "https://b.example.com"]),
  )
}

pub fn empty_entries_are_dropped_from_the_allow_list_test() {
  // A trailing comma must not admit an empty Origin header.
  origin.from_env("https://a.example.com,,")
  |> should.equal(origin.AllowList(["https://a.example.com"]))
}

// ── SameOrigin ───────────────────────────────────────────────────────────────

pub fn same_origin_admits_clients_that_send_no_origin_test() {
  // The official Fluid drivers and the conformance suites are not browsers and
  // send no Origin. They cannot be driven into a cross-site upgrade, so the
  // default policy must admit them — this is what keeps the check safe to
  // enable on the Socket.IO endpoint.
  origin.allowed(
    origin.SameOrigin,
    origin: Error(Nil),
    host: Ok("localhost:3000"),
  )
  |> should.equal(True)
}

pub fn same_origin_admits_a_matching_origin_test() {
  origin.allowed(
    origin.SameOrigin,
    origin: Ok("http://localhost:3000"),
    host: Ok("localhost:3000"),
  )
  |> should.equal(True)
}

pub fn same_origin_rejects_a_cross_site_origin_test() {
  origin.allowed(
    origin.SameOrigin,
    origin: Ok("https://evil.example.com"),
    host: Ok("localhost:3000"),
  )
  |> should.equal(False)
}

pub fn same_origin_rejects_a_port_mismatch_test() {
  origin.allowed(
    origin.SameOrigin,
    origin: Ok("http://localhost:4000"),
    host: Ok("localhost:3000"),
  )
  |> should.equal(False)
}

pub fn same_origin_fails_closed_without_a_host_header_test() {
  origin.allowed(
    origin.SameOrigin,
    origin: Ok("http://localhost:3000"),
    host: Error(Nil),
  )
  |> should.equal(False)
}

pub fn same_origin_rejects_an_opaque_origin_test() {
  // A sandboxed iframe sends `Origin: null`; it has no authority to match.
  origin.allowed(
    origin.SameOrigin,
    origin: Ok("null"),
    host: Ok("localhost:3000"),
  )
  |> should.equal(False)
}

// ── AllowList ────────────────────────────────────────────────────────────────

pub fn allow_list_admits_a_listed_origin_test() {
  origin.allowed(
    origin.AllowList(["https://app.example.com"]),
    origin: Ok("https://app.example.com"),
    host: Ok("floodgate.example.com"),
  )
  |> should.equal(True)
}

pub fn allow_list_rejects_an_unlisted_origin_test() {
  origin.allowed(
    origin.AllowList(["https://app.example.com"]),
    origin: Ok("https://evil.example.com"),
    host: Ok("floodgate.example.com"),
  )
  |> should.equal(False)
}

pub fn allow_list_rejects_a_missing_origin_test() {
  // An explicit allow-list is exhaustive: no Origin cannot match an entry.
  origin.allowed(
    origin.AllowList(["https://app.example.com"]),
    origin: Error(Nil),
    host: Ok("floodgate.example.com"),
  )
  |> should.equal(False)
}

// ── AllowAll ─────────────────────────────────────────────────────────────────

pub fn allow_all_admits_any_origin_test() {
  origin.allowed(
    origin.AllowAll,
    origin: Ok("https://evil.example.com"),
    host: Ok("localhost:3000"),
  )
  |> should.equal(True)
}

// ── same_origin authority comparison ─────────────────────────────────────────

pub fn same_origin_comparison_is_case_insensitive_test() {
  origin.same_origin("HTTP://LocalHost:3000", "localhost:3000")
  |> should.equal(True)
}

pub fn same_origin_comparison_requires_a_scheme_test() {
  origin.same_origin("localhost:3000", "localhost:3000")
  |> should.equal(False)
}

pub fn same_origin_comparison_ignores_a_trailing_path_test() {
  origin.same_origin("http://localhost:3000/", "localhost:3000")
  |> should.equal(True)
}

pub fn same_origin_comparison_rejects_an_empty_authority_test() {
  origin.same_origin("http://", "localhost:3000")
  |> should.equal(False)
}
