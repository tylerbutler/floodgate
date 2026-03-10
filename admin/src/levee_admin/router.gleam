//// URL routing for the Levee Admin app.

import gleam/uri.{type Uri}

/// Application routes
pub type Route {
  Login
  Register
  Dashboard
  Tenants
  TenantNew
  TenantDetail(id: String)
  DocumentList(tenant_id: String)
  DocumentDetail(tenant_id: String, document_id: String)
  NotFound
}

/// Parse a URI into a Route
pub fn parse(uri: Uri) -> Route {
  case uri.path_segments(uri.path) {
    ["admin"] -> Login
    ["admin", ""] -> Login
    ["admin", "login"] -> Login
    ["admin", "register"] -> Register
    ["admin", "dashboard"] -> Dashboard
    ["admin", "tenants"] -> Tenants
    ["admin", "tenants", "new"] -> TenantNew
    ["admin", "tenants", tid, "documents"] -> DocumentList(tid)
    ["admin", "tenants", tid, "documents", did] -> DocumentDetail(tid, did)
    ["admin", "tenants", id] -> TenantDetail(id)
    _ -> NotFound
  }
}

/// Convert a Route to a path string
pub fn to_path(route: Route) -> String {
  case route {
    Login -> "/admin/login"
    Register -> "/admin/register"
    Dashboard -> "/admin/dashboard"
    Tenants -> "/admin/tenants"
    TenantNew -> "/admin/tenants/new"
    TenantDetail(id) -> "/admin/tenants/" <> id
    DocumentList(tid) -> "/admin/tenants/" <> tid <> "/documents"
    DocumentDetail(tid, did) -> "/admin/tenants/" <> tid <> "/documents/" <> did
    NotFound -> "/admin/404"
  }
}
