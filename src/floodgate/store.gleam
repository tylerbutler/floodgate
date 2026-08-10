//// Typed storage boundary for documents, ops, summaries, Historian data, and
//// tenants.
////
//// A backend is a value, rather than a process-global selection, so a complete
//// Floodgate runtime can be constructed from any implementation. Concrete
//// backends: `floodgate/shelf_store` (shelf typed ETS + DETS, the default) and
//// `floodgate/memory_store` (actor-backed, for tests).
////
//// Tenants ride the same backend selection as documents rather than a
//// separate store: `FLOODGATE_STORAGE_BACKEND=shelf` persists tenants and
//// their secrets in DETS alongside documents, `memory` keeps them in the same
//// ephemeral actor used by tests. That is what lets the startup tenant
//// (`ensure_startup_tenant`) survive a restart on the persistent backend while
//// still starting fresh in tests, with no second storage subsystem to wire up.

import floodgate/admin_auth.{type AdminSession, type AdminUser}
import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/otp/static_supervisor
import gleam/string

/// A tenant without its secrets — the shape returned by list/get, matching
/// levee's `Auth.TenantSecrets.TenantInfo`.
pub type TenantInfo {
  TenantInfo(id: String, name: String)
}

/// A tenant with both secret slots — returned only on create and single-tenant
/// show, never from the list endpoint.
pub type TenantWithSecrets {
  TenantWithSecrets(id: String, name: String, secret1: String, secret2: String)
}

/// Which of a tenant's two rotating secret slots to regenerate.
pub type TenantSlot {
  Slot1
  Slot2
}

pub type Backend {
  Backend(
    /// Add whatever processes this backend needs to the runtime's supervision
    /// tree. Identity for a backend that owns no process.
    ///
    /// The field is a builder transform rather than a child specification
    /// because `ChildSpecification` is parameterized on the child's own subject
    /// type, which differs per backend; a transform erases that difference
    /// without giving up the supervisor's type safety at the `add` site.
    supervise: fn(static_supervisor.Builder) -> static_supervisor.Builder,
    open: fn() -> Nil,
    put_document: fn(String) -> Result(Nil, Nil),
    has_document: fn(String) -> Bool,
    put_op: fn(String, Int, String) -> Result(Nil, Nil),
    get_ops: fn(String) -> List(#(Int, String)),
    put_summary: fn(String, String, Int) -> Result(Nil, Nil),
    get_summary: fn(String) -> Result(#(String, Int), Nil),
    /// Git objects are keyed by **topic**, not tenant: an object belongs to the
    /// document whose summary tree reaches it, which is what lets a document's
    /// storage be self-contained. The document id comes from the caller's token
    /// claims — see `auth.verify_storage_*_authorization`.
    put_object: fn(String, String, String) -> Result(Nil, Nil),
    get_object: fn(String, String) -> Result(String, Nil),
    put_ref: fn(String, String, String) -> Result(Nil, Nil),
    create_ref: fn(String, String, String) -> Result(Bool, Nil),
    get_ref: fn(String, String) -> Result(String, Nil),
    list_refs: fn(String) -> List(#(String, String)),
    create_tenant: fn(String) -> TenantWithSecrets,
    get_tenant: fn(String) -> Result(TenantInfo, Nil),
    get_tenant_secrets: fn(String) -> Result(#(String, String), Nil),
    regenerate_tenant_secret: fn(String, TenantSlot) -> Result(String, Nil),
    register_tenant: fn(String, String) -> Nil,
    unregister_tenant: fn(String) -> Nil,
    tenant_exists: fn(String) -> Bool,
    list_tenants: fn() -> List(TenantInfo),
    /// Admin users/sessions for the GitHub-OAuth-backed admin UI session —
    /// see `floodgate/admin_auth` for the pure construction/decision logic and
    /// `floodgate.gleam`'s OAuth callback handling for how these are called.
    /// Keyed by GitHub's own numeric user id (see `AdminUser.id`'s doc
    /// comment), so there is no separate reverse-index table the way
    /// `tenants` needs none either.
    put_admin_user: fn(AdminUser) -> Nil,
    get_admin_user: fn(String) -> Result(AdminUser, Nil),
    admin_user_count: fn() -> Int,
    put_admin_session: fn(AdminSession) -> Nil,
    get_admin_session: fn(String) -> Result(AdminSession, Nil),
    delete_admin_session: fn(String) -> Nil,
  )
}

/// Add the backend's own processes to a supervision tree under construction.
pub fn supervise(
  builder: static_supervisor.Builder,
  backend: Backend,
) -> static_supervisor.Builder {
  backend.supervise(builder)
}

pub fn open(backend: Backend) -> Nil {
  backend.open()
}

/// The prefix every document topic carries. Also the Phoenix channel topic
/// prefix, which is why the two cannot drift.
pub const topic_prefix = "document:"

/// The storage key for a document. Everything document-scoped — the marker,
/// ops, the summary pointer, and git objects — is keyed by this, so it is the
/// single place the `{tenant, document}` pair becomes one identifier.
pub fn topic(tenant: String, document_id: String) -> String {
  topic_prefix <> tenant <> ":" <> document_id
}

pub fn put_document(backend: Backend, topic: String) -> Result(Nil, Nil) {
  backend.put_document(topic)
}

pub fn has_document(backend: Backend, topic: String) -> Bool {
  backend.has_document(topic)
}

pub fn put_op(
  backend: Backend,
  topic: String,
  sequence_number: Int,
  contents: String,
) -> Result(Nil, Nil) {
  backend.put_op(topic, sequence_number, contents)
}

/// Operations are always returned in sequence order, independent of backend.
pub fn get_ops(backend: Backend, topic: String) -> List(#(Int, String)) {
  backend.get_ops(topic)
  |> list.sort(fn(left, right) { int.compare(left.0, right.0) })
}

pub fn put_summary(
  backend: Backend,
  topic: String,
  handle: String,
  sequence_number: Int,
) -> Result(Nil, Nil) {
  backend.put_summary(topic, handle, sequence_number)
}

/// The latest summary pointer, `#(handle, sequence_number)`, or `Error(Nil)`
/// when the document has never been summarized.
pub fn get_summary(
  backend: Backend,
  topic: String,
) -> Result(#(String, Int), Nil) {
  backend.get_summary(topic)
}

pub fn put_object(
  backend: Backend,
  topic: String,
  sha: String,
  data: String,
) -> Result(Nil, Nil) {
  backend.put_object(topic, sha, data)
}

pub fn get_object(
  backend: Backend,
  topic: String,
  sha: String,
) -> Result(String, Nil) {
  backend.get_object(topic, sha)
}

pub fn put_ref(
  backend: Backend,
  tenant: String,
  ref: String,
  sha: String,
) -> Result(Nil, Nil) {
  backend.put_ref(tenant, ref, sha)
}

/// Create a ref only if absent. `Ok(False)` means it already exists with a
/// different sha; `Error(Nil)` means storage itself failed.
pub fn create_ref(
  backend: Backend,
  tenant: String,
  ref: String,
  sha: String,
) -> Result(Bool, Nil) {
  backend.create_ref(tenant, ref, sha)
}

pub fn get_ref(
  backend: Backend,
  tenant: String,
  ref: String,
) -> Result(String, Nil) {
  backend.get_ref(tenant, ref)
}

/// References are always returned in path order, independent of backend.
pub fn list_refs(backend: Backend, tenant: String) -> List(#(String, String)) {
  backend.list_refs(tenant)
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
}

// ─────────────────────────────────────────────────────────────────────────────
// Tenants
// ─────────────────────────────────────────────────────────────────────────────

/// Create a tenant with a server-generated id and two server-generated
/// secrets, matching levee's `Auth.TenantSecrets.create_tenant/1`.
pub fn create_tenant(backend: Backend, name: String) -> TenantWithSecrets {
  backend.create_tenant(name)
}

/// Tenant info (id, name) without secrets — the shape the list endpoint uses.
pub fn get_tenant(backend: Backend, id: String) -> Result(TenantInfo, Nil) {
  backend.get_tenant(id)
}

/// Both secret slots for a tenant, `#(secret1, secret2)`. Both verify a JWT;
/// only `secret1` is used to mint one.
pub fn get_tenant_secrets(
  backend: Backend,
  id: String,
) -> Result(#(String, String), Nil) {
  backend.get_tenant_secrets(id)
}

/// Replace one secret slot with a freshly generated value, leaving the other
/// slot untouched. Returns the new secret.
pub fn regenerate_tenant_secret(
  backend: Backend,
  id: String,
  slot: TenantSlot,
) -> Result(String, Nil) {
  backend.regenerate_tenant_secret(id, slot)
}

/// Register (or overwrite) a tenant with an explicit id and secret, e.g. the
/// `FLOODGATE_TENANT_ID`/`FLOODGATE_JWT_SECRET` startup path. `secret` becomes
/// slot 1; slot 2 is freshly generated. Matches levee's
/// `Auth.TenantSecrets.register_tenant/2` shape — see `ensure_startup_tenant`
/// for the idempotent seed most callers want instead.
pub fn register_tenant(backend: Backend, id: String, secret: String) -> Nil {
  backend.register_tenant(id, secret)
}

/// Remove a tenant's registration. Deliberately narrow: this only forgets the
/// tenant's id/name/secrets, never touches documents, ops, summaries, or git
/// objects stored under that tenant id — matching levee's
/// `Auth.TenantSecrets.unregister_tenant/1`, which does not cascade either.
pub fn unregister_tenant(backend: Backend, id: String) -> Nil {
  backend.unregister_tenant(id)
}

pub fn tenant_exists(backend: Backend, id: String) -> Bool {
  backend.tenant_exists(id)
}

/// All tenants (id, name), independent of backend order.
pub fn list_tenants(backend: Backend) -> List(TenantInfo) {
  backend.list_tenants()
  |> list.sort(fn(left, right) { string.compare(left.id, right.id) })
}

/// Idempotently seed the startup tenant from `FLOODGATE_TENANT_ID` /
/// `FLOODGATE_JWT_SECRET`: create it if it does not already exist, otherwise
/// leave it untouched.
///
/// This is what keeps existing deployments, clients, tests, docker, and parity
/// suites working unchanged on the persistent shelf backend: the first boot
/// against a data directory creates the tenant with `secret1` equal to
/// `jwt_secret`, and every later boot against the *same* directory finds it
/// already registered and does nothing — so a secret rotated afterwards
/// through the admin API (or a second slot populated by `create_tenant`)
/// survives a restart instead of being silently overwritten by the env var. On
/// the memory backend there is nothing to find on any boot, so this always
/// creates. To rotate the startup tenant's own secret deliberately, use the
/// admin API (`POST /api/tenants/:id/secrets/1`) rather than editing the env
/// var and restarting — this function will not pick the change up once the
/// tenant already exists.
pub fn ensure_startup_tenant(
  backend: Backend,
  tenant_id: String,
  jwt_secret: String,
) -> Nil {
  case tenant_exists(backend, tenant_id) {
    True -> Nil
    False -> register_tenant(backend, tenant_id, jwt_secret)
  }
}

/// A URL-safe random tenant id. 9 bytes (72 bits of entropy) is enough that
/// backends do not need to check for collisions against existing ids.
pub fn generate_tenant_id() -> String {
  crypto.strong_random_bytes(9) |> bit_array.base16_encode |> string.lowercase
}

/// A cryptographically secure hex secret, matching levee's
/// `Auth.TenantSecrets.generate_secret/0` shape (32 bytes, lowercase hex).
pub fn generate_tenant_secret() -> String {
  crypto.strong_random_bytes(32) |> bit_array.base16_encode |> string.lowercase
}

// ─────────────────────────────────────────────────────────────────────────────
// Admin users/sessions — the GitHub-OAuth-backed admin UI session. See
// `floodgate/admin_auth` for how `AdminUser`/`AdminSession` values are built
// and how the GitHub allow-list decision is made; this boundary only
// stores and retrieves whatever it is given.
// ─────────────────────────────────────────────────────────────────────────────

/// Persist an admin user, keyed by `user.id` (GitHub's own numeric user id) —
/// overwrites any existing row for that id.
pub fn put_admin_user(backend: Backend, user: AdminUser) -> Nil {
  backend.put_admin_user(user)
}

/// Look up an admin user by GitHub id (`AdminUser.id`).
pub fn get_admin_user(
  backend: Backend,
  github_id: String,
) -> Result(AdminUser, Nil) {
  backend.get_admin_user(github_id)
}

/// How many admin users are registered.
pub fn admin_user_count(backend: Backend) -> Int {
  backend.admin_user_count()
}

/// Persist an admin session, keyed by `session.id` (the opaque bearer
/// token/cookie value) — overwrites any existing row for that id.
pub fn put_admin_session(backend: Backend, session: AdminSession) -> Nil {
  backend.put_admin_session(session)
}

/// Look up an admin session by its opaque id. Callers still need to check
/// `admin_auth.session_valid` — a stored session past its `expires_at` is not
/// itself removed until an explicit `delete_admin_session` (e.g. logout),
/// matching how tenant secrets are looked up without deleting on read.
pub fn get_admin_session(
  backend: Backend,
  session_id: String,
) -> Result(AdminSession, Nil) {
  backend.get_admin_session(session_id)
}

/// Delete an admin session — logout, or an operator revoking access.
pub fn delete_admin_session(backend: Backend, session_id: String) -> Nil {
  backend.delete_admin_session(session_id)
}
