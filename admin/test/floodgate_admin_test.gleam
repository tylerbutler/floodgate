import gleam/list
import gleam/option
import gleam/uri.{type Uri}
import gleeunit
import gleeunit/should

import floodgate_admin/api
import floodgate_admin/pages/document_detail
import floodgate_admin/pages/document_list
import floodgate_admin/pages/tenant_detail
import floodgate_admin/pages/tenant_new
import floodgate_admin/pages/tenants
import floodgate_admin/router

pub fn main() {
  gleeunit.main()
}

// Router tests

pub fn parse_login_route_test() {
  let uri = uri_from_path("/admin/login")
  router.parse(uri)
  |> should.equal(router.Login)
}

pub fn parse_register_route_test() {
  let uri = uri_from_path("/admin/register")
  router.parse(uri)
  |> should.equal(router.Register)
}

pub fn parse_dashboard_route_test() {
  let uri = uri_from_path("/admin/dashboard")
  router.parse(uri)
  |> should.equal(router.Dashboard)
}

pub fn parse_tenants_route_test() {
  let uri = uri_from_path("/admin/tenants")
  router.parse(uri)
  |> should.equal(router.Tenants)
}

pub fn parse_tenant_detail_route_test() {
  let uri = uri_from_path("/admin/tenants/abc123")
  router.parse(uri)
  |> should.equal(router.TenantDetail("abc123"))
}

pub fn parse_unknown_route_test() {
  let uri = uri_from_path("/unknown/path")
  router.parse(uri)
  |> should.equal(router.NotFound)
}

pub fn parse_root_admin_route_test() {
  let uri = uri_from_path("/admin")
  router.parse(uri)
  |> should.equal(router.Login)
}

pub fn to_path_login_test() {
  router.to_path(router.Login)
  |> should.equal("/admin/login")
}

pub fn to_path_dashboard_test() {
  router.to_path(router.Dashboard)
  |> should.equal("/admin/dashboard")
}

pub fn to_path_tenant_detail_test() {
  router.to_path(router.TenantDetail("tenant-123"))
  |> should.equal("/admin/tenants/tenant-123")
}

pub fn parse_tenant_new_route_test() {
  let uri = uri_from_path("/admin/tenants/new")
  router.parse(uri)
  |> should.equal(router.TenantNew)
}

pub fn to_path_tenant_new_test() {
  router.to_path(router.TenantNew)
  |> should.equal("/admin/tenants/new")
}

pub fn regenerate_requires_exact_confirmation_test() {
  let model = tenant_detail.init("tenant-123")
  let model = tenant_detail.update(model, tenant_detail.RequestRegenerate(1)).0
  let model =
    tenant_detail.update(
      model,
      tenant_detail.UpdateRegenerateConfirmation(1, "regenerate"),
    ).0
  let model = tenant_detail.update(model, tenant_detail.ConfirmRegenerate(1)).0

  tenant_detail.get_pending_regenerate(model)
  |> should.equal(option.None)
}

pub fn regenerate_accepts_exact_confirmation_test() {
  let model = tenant_detail.init("tenant-123")
  let model = tenant_detail.update(model, tenant_detail.RequestRegenerate(2)).0
  let model =
    tenant_detail.update(
      model,
      tenant_detail.UpdateRegenerateConfirmation(2, "REGENERATE"),
    ).0
  let model = tenant_detail.update(model, tenant_detail.ConfirmRegenerate(2)).0

  tenant_detail.get_pending_regenerate(model)
  |> should.equal(option.Some(2))
}

pub fn copy_success_is_exposed_to_the_view_test() {
  let model = tenant_detail.init("tenant-123")
  let model =
    tenant_detail.update(model, tenant_detail.CopyFinished("Tenant ID", True)).0

  model.copy_state
  |> should.equal(tenant_detail.CopySuccess("Tenant ID copied."))
}

// API error presentation (HARDEN)

pub fn session_expired_detects_401_and_403_test() {
  api.is_session_expired(api.ServerError(401, ""))
  |> should.equal(True)
  api.is_session_expired(api.ServerError(403, ""))
  |> should.equal(True)
  api.is_session_expired(api.ServerError(500, ""))
  |> should.equal(False)
  api.is_session_expired(api.NetworkError("x"))
  |> should.equal(False)
}

pub fn error_message_distinguishes_failure_kinds_test() {
  let network = api.error_message(api.NetworkError("x"))
  let rate = api.error_message(api.ServerError(429, ""))
  let server = api.error_message(api.ServerError(500, ""))
  let missing = api.error_message(api.ServerError(404, ""))

  { network == rate } |> should.equal(False)
  { rate == server } |> should.equal(False)
  { server == missing } |> should.equal(False)
  { network == server } |> should.equal(False)
}

// Direct sequence access — `from` is exclusive (POLISH)

pub fn sequence_to_from_is_exclusive_test() {
  document_detail.sequence_to_from(5000)
  |> should.equal(4999)
  document_detail.sequence_to_from(1)
  |> should.equal(0)
  document_detail.sequence_to_from(0)
  |> should.equal(-1)
}

pub fn document_detail_starts_with_operations_loading_test() {
  let model = document_detail.init("tenant", "document")

  model.deltas_loading
  |> should.equal(True)
}

pub fn delta_actions_are_ignored_while_loading_test() {
  let model =
    document_detail.init("tenant", "document")
    |> document_detail.update(document_detail.DeltasLoaded([]))
    |> fn(result) { result.0 }
    |> document_detail.update(document_detail.UpdateSeqInput("500"))
    |> fn(result) { result.0 }
    |> document_detail.update(document_detail.JumpToSequence)
    |> fn(result) { result.0 }

  model.deltas_from
  |> should.equal(499)

  let unchanged =
    document_detail.update(model, document_detail.ReloadOpsFromStart).0

  unchanged.deltas_from
  |> should.equal(499)
}

pub fn git_navigation_is_ignored_while_loading_test() {
  let model = document_detail.init("tenant", "document")
  let model = document_detail.update(model, document_detail.ViewBlob("sha-a")).0
  let model = document_detail.update(model, document_detail.ViewTree("sha-b")).0

  model.git_view
  |> should.equal(document_detail.GitBlobView("sha-a", option.None))
}

// Accessible tab keyboard model (POLISH)

pub fn tab_step_moves_and_wraps_test() {
  // all_tabs order: OpStream, Metadata, Summaries, Refs, Git
  document_detail.tab_step(document_detail.OpStreamTab, "ArrowRight")
  |> should.equal(document_detail.MetadataTab)
  document_detail.tab_step(document_detail.OpStreamTab, "ArrowLeft")
  |> should.equal(document_detail.GitTab)
  document_detail.tab_step(document_detail.GitTab, "ArrowRight")
  |> should.equal(document_detail.OpStreamTab)
  document_detail.tab_step(document_detail.RefsTab, "Home")
  |> should.equal(document_detail.OpStreamTab)
  document_detail.tab_step(document_detail.OpStreamTab, "End")
  |> should.equal(document_detail.GitTab)
  // A non-navigation key leaves the selection unchanged.
  document_detail.tab_step(document_detail.RefsTab, "a")
  |> should.equal(document_detail.RefsTab)
}

// Client-side search and sort (POLISH)

pub fn visible_tenants_filters_case_insensitively_test() {
  let ts = [
    tenants.Tenant("id-b", "Beta"),
    tenants.Tenant("id-a", "alpha"),
    tenants.Tenant("id-c", "Gamma"),
  ]

  tenants.visible_tenants(ts, "ALP", tenants.NameAsc)
  |> should.equal([tenants.Tenant("id-a", "alpha")])

  // No data vs no results: a non-matching query yields an empty list.
  tenants.visible_tenants(ts, "zzz", tenants.NameAsc)
  |> should.equal([])

  tenants.visible_tenants(ts, "", tenants.NameAsc)
  |> list.map(fn(t) { t.id })
  |> should.equal(["id-a", "id-b", "id-c"])
}

pub fn visible_documents_search_and_active_first_test() {
  let ds = [
    document_list.Document("doc-1", "t", 10, False),
    document_list.Document("doc-2", "t", 50, True),
    document_list.Document("other", "t", 5, True),
  ]

  document_list.visible_documents(ds, "doc", document_list.SeqDesc)
  |> list.map(fn(d) { d.id })
  |> should.equal(["doc-2", "doc-1"])

  document_list.visible_documents(ds, "", document_list.ActiveFirst)
  |> list.map(fn(d) { d.id })
  |> should.equal(["doc-2", "other", "doc-1"])
}

// Duplicate destructive/mutation submits are ignored (HARDEN)

pub fn tenant_new_ignores_submit_while_submitting_test() {
  let model = tenant_new.init()
  let model = tenant_new.update(model, tenant_new.UpdateName("My App")).0
  let model = tenant_new.update(model, tenant_new.Submit).0
  // The parent starts the request, moving the form into its submitting state.
  let model = tenant_new.start_loading(model)
  // A second submit while in flight must not queue another create.
  let model = tenant_new.update(model, tenant_new.Submit).0

  tenant_new.get_pending_submit(model)
  |> should.equal(option.None)
}

// Helper to create a URI from a path
fn uri_from_path(path: String) -> Uri {
  uri.Uri(
    scheme: option.None,
    userinfo: option.None,
    host: option.None,
    port: option.None,
    path: path,
    query: option.None,
    fragment: option.None,
  )
}
