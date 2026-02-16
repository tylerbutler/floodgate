//// URL routing for the Levee Admin app.

import gleam/uri.{type Uri}

/// Application routes
pub type Route {
  Login
  Register
  Dashboard
  Tenants
  TenantDetail(id: String)
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
    TenantDetail(id) -> "/admin/tenants/" <> id
    NotFound -> "/admin/404"
  }
}
