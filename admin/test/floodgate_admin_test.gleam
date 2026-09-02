import gleam/option
import gleam/uri.{type Uri}
import gleeunit
import gleeunit/should

import floodgate_admin/pages/tenant_detail
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
