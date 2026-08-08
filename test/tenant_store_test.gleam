import floodgate/memory_store
import floodgate/shelf_store
import floodgate/store
import gleam/bit_array
import gleam/crypto
import gleam/list
import gleeunit/should

/// A fresh, unique on-disk data directory so each run starts from empty DETS
/// (shelf persists via WriteThrough, so reused dirs would leak state between
/// runs). Lives under build/, which is gitignored and cleaned by `gleam clean`.
fn unique_dir() -> String {
  "build/floodgate_tenant_test/"
  <> { crypto.strong_random_bytes(8) |> bit_array.base16_encode }
}

pub fn shelf_backend_satisfies_tenant_boundary_test() {
  assert_tenant_backend_contract(shelf_store.new(unique_dir()))
}

pub fn memory_backend_satisfies_tenant_boundary_test() {
  assert_tenant_backend_contract(memory_store.new())
}

/// The same contract, run against both backends, matching
/// `store_backend_test.assert_backend_contract`'s pattern for documents/ops.
fn assert_tenant_backend_contract(backend: store.Backend) {
  // Unknown tenants report absence consistently across every read path.
  store.get_tenant(backend, "no-such-tenant") |> should.equal(Error(Nil))
  store.get_tenant_secrets(backend, "no-such-tenant")
  |> should.equal(Error(Nil))
  store.tenant_exists(backend, "no-such-tenant") |> should.be_false
  store.regenerate_tenant_secret(backend, "no-such-tenant", store.Slot1)
  |> should.equal(Error(Nil))

  // Create: server-generated id, both secrets populated, name is what the
  // caller asked for — matching levee's `Auth.TenantSecrets.create_tenant/1`.
  let tenant = store.create_tenant(backend, "Acme Co")
  tenant.name |> should.equal("Acme Co")
  { tenant.id != "" } |> should.be_true
  { tenant.secret1 != "" } |> should.be_true
  { tenant.secret2 != "" } |> should.be_true
  { tenant.secret1 != tenant.secret2 } |> should.be_true

  store.tenant_exists(backend, tenant.id) |> should.be_true
  store.get_tenant(backend, tenant.id)
  |> should.equal(Ok(store.TenantInfo(id: tenant.id, name: "Acme Co")))
  store.get_tenant_secrets(backend, tenant.id)
  |> should.equal(Ok(#(tenant.secret1, tenant.secret2)))

  // List never carries secrets, and includes every registered tenant.
  let other = store.create_tenant(backend, "Widgets Inc")
  let names =
    store.list_tenants(backend)
    |> list.map(fn(info) { info.name })
  names |> list.contains("Acme Co") |> should.be_true
  names |> list.contains("Widgets Inc") |> should.be_true

  // Regenerating one slot leaves the other untouched.
  let assert Ok(new_secret1) =
    store.regenerate_tenant_secret(backend, tenant.id, store.Slot1)
  { new_secret1 != tenant.secret1 } |> should.be_true
  store.get_tenant_secrets(backend, tenant.id)
  |> should.equal(Ok(#(new_secret1, tenant.secret2)))

  let assert Ok(new_secret2) =
    store.regenerate_tenant_secret(backend, tenant.id, store.Slot2)
  { new_secret2 != tenant.secret2 } |> should.be_true
  store.get_tenant_secrets(backend, tenant.id)
  |> should.equal(Ok(#(new_secret1, new_secret2)))

  // `register_tenant` is the explicit-id/secret path (startup env seeding):
  // the given secret becomes slot 1, slot 2 is freshly generated.
  store.register_tenant(backend, "explicit-tenant", "explicit-secret")
  store.get_tenant_secrets(backend, "explicit-tenant")
  |> should.equal(
    Ok(#("explicit-secret", read_secret2(backend, "explicit-tenant"))),
  )
  store.get_tenant(backend, "explicit-tenant")
  |> should.equal(
    Ok(store.TenantInfo(id: "explicit-tenant", name: "explicit-tenant")),
  )

  // Unregister forgets the tenant, and only the tenant.
  store.unregister_tenant(backend, tenant.id)
  store.tenant_exists(backend, tenant.id) |> should.be_false
  store.get_tenant(backend, tenant.id) |> should.equal(Error(Nil))
  // The other tenant this contract created is unaffected.
  store.tenant_exists(backend, other.id) |> should.be_true
}

/// Read back whatever a previous call generated for a tenant's slot 2, so a
/// test does not need to guess a random value.
fn read_secret2(backend: store.Backend, id: String) -> String {
  let assert Ok(#(_secret1, secret2)) = store.get_tenant_secrets(backend, id)
  secret2
}

/// Tenant deletion must not cascade to documents, matching levee's
/// `Auth.TenantSecrets.unregister_tenant/1`, which only forgets the tenant's
/// own row — never touches `Levee.Documents.*`.
pub fn unregister_tenant_does_not_delete_documents_test() {
  let backend = memory_store.new()
  let tenant = store.create_tenant(backend, "Doomed Co")
  let topic = "document:" <> tenant.id <> ":doc-1"

  store.put_document(backend, topic)
  store.put_op(backend, topic, 1, "first-op")
  store.put_obj(backend, tenant.id, "obj-sha", "obj-body")
  store.put_ref(backend, tenant.id, "refs/heads/main", "obj-sha")

  store.unregister_tenant(backend, tenant.id)

  store.tenant_exists(backend, tenant.id) |> should.be_false
  store.has_document(backend, topic) |> should.be_true
  store.get_ops(backend, topic) |> should.equal([#(1, "first-op")])
  store.get_obj(backend, tenant.id, "obj-sha") |> should.equal(Ok("obj-body"))
  store.list_refs(backend, tenant.id)
  |> should.equal([#("refs/heads/main", "obj-sha")])
}

// ─────────────────────────────────────────────────────────────────────────────
// Startup tenant compatibility — FLOODGATE_TENANT_ID/FLOODGATE_JWT_SECRET must
// keep authorizing existing deployments unchanged, even on the persistent
// shelf backend across a restart.
// ─────────────────────────────────────────────────────────────────────────────

pub fn ensure_startup_tenant_creates_when_absent_test() {
  let backend = memory_store.new()
  store.tenant_exists(backend, "fluid") |> should.be_false
  store.ensure_startup_tenant(backend, "fluid", "startup-secret")
  store.get_tenant_secrets(backend, "fluid")
  |> should.equal(Ok(#("startup-secret", read_secret2(backend, "fluid"))))
}

/// A second `ensure_startup_tenant` call with a *different* secret — the
/// shape of a redeploy that changed `FLOODGATE_JWT_SECRET` without also
/// clearing shelf storage — must not silently replace what is already
/// registered, including any rotation the admin API already applied. This is
/// the exact idempotent-seed contract `store.ensure_startup_tenant`'s doc
/// comment describes.
pub fn ensure_startup_tenant_is_idempotent_test() {
  let backend = memory_store.new()
  store.ensure_startup_tenant(backend, "fluid", "first-secret")
  let assert Ok(#(secret1_after_first, secret2_after_first)) =
    store.get_tenant_secrets(backend, "fluid")
  secret1_after_first |> should.equal("first-secret")

  // Simulate the admin API rotating slot 2 before a restart.
  let assert Ok(rotated_secret2) =
    store.regenerate_tenant_secret(backend, "fluid", store.Slot2)
  { rotated_secret2 != secret2_after_first } |> should.be_true

  // A later boot with a changed env var must not touch what is already there.
  store.ensure_startup_tenant(backend, "fluid", "second-secret")
  store.get_tenant_secrets(backend, "fluid")
  |> should.equal(Ok(#("first-secret", rotated_secret2)))
}

/// The persistent backend keeps the seeded tenant — and any rotation applied
/// to it — across a process restart, simulated by re-opening the same data
/// directory. This is what makes `ensure_startup_tenant` safe to call on
/// every boot without clobbering an admin-rotated secret.
pub fn shelf_backend_persists_startup_tenant_across_restart_test() {
  let dir = unique_dir()
  let backend = shelf_store.new(dir)
  store.ensure_startup_tenant(backend, "fluid", "boot-secret")
  let assert Ok(rotated) =
    store.regenerate_tenant_secret(backend, "fluid", store.Slot2)

  // "Restart": open a fresh backend value over the same directory.
  let restarted = shelf_store.new(dir)
  store.get_tenant_secrets(restarted, "fluid")
  |> should.equal(Ok(#("boot-secret", rotated)))

  // A boot-time seed call after the restart must still be a no-op.
  store.ensure_startup_tenant(restarted, "fluid", "a-different-secret")
  store.get_tenant_secrets(restarted, "fluid")
  |> should.equal(Ok(#("boot-secret", rotated)))
}

/// The shelf backend's tenant table is durable in the same way as its
/// document tables: a full tenant lifecycle (create, rotate, list) survives a
/// reopen of the same directory.
pub fn shelf_backend_persists_tenant_lifecycle_across_restart_test() {
  let dir = unique_dir()
  let backend = shelf_store.new(dir)
  let tenant = store.create_tenant(backend, "Persisted Co")
  let assert Ok(new_secret1) =
    store.regenerate_tenant_secret(backend, tenant.id, store.Slot1)

  let reopened = shelf_store.new(dir)
  store.get_tenant(reopened, tenant.id)
  |> should.equal(Ok(store.TenantInfo(id: tenant.id, name: "Persisted Co")))
  store.get_tenant_secrets(reopened, tenant.id)
  |> should.equal(Ok(#(new_secret1, tenant.secret2)))
  store.list_tenants(reopened)
  |> list.map(fn(info) { info.id })
  |> list.contains(tenant.id)
  |> should.be_true
}
