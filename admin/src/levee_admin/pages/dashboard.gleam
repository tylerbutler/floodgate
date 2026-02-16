//// Dashboard page component.

import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute.{class, href}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html.{a, div, h1, h2, li, p, text, ul}

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

pub type Model {
  Model(tenants: List(Tenant), loading: Bool, error: Option(String))
}

pub type Tenant {
  Tenant(id: String, name: String, slug: String, member_count: Int)
}

pub fn init() -> Model {
  Model(tenants: [], loading: False, error: None)
}

// ─────────────────────────────────────────────────────────────────────────────
// Messages
// ─────────────────────────────────────────────────────────────────────────────

pub type Msg {
  LoadTenants
  TenantsLoaded(List(Tenant))
  LoadError(String)
}

// ─────────────────────────────────────────────────────────────────────────────
// Update
// ─────────────────────────────────────────────────────────────────────────────

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    LoadTenants -> {
      let model = Model(..model, loading: True, error: None)
      // TODO: Load tenants from API
      #(model, effect.none())
    }

    TenantsLoaded(tenants) -> {
      let model = Model(..model, tenants: tenants, loading: False)
      #(model, effect.none())
    }

    LoadError(error) -> {
      let model = Model(..model, error: Some(error), loading: False)
      #(model, effect.none())
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// View
// ─────────────────────────────────────────────────────────────────────────────

pub fn view(model: Model) -> Element(Msg) {
  div([class("page dashboard")], [
    h1([class("page-title")], [text("Dashboard")]),
    div([class("dashboard-content")], [
      view_welcome(),
      view_tenants_section(model),
      view_quick_actions(),
    ]),
  ])
}

fn view_welcome() -> Element(Msg) {
  div([class("card welcome-card")], [
    h2([], [text("Welcome to Levee Admin")]),
    p([], [
      text(
        "Manage your tenants, users, and document access from this dashboard.",
      ),
    ]),
  ])
}

fn view_tenants_section(model: Model) -> Element(Msg) {
  div([class("card tenants-card")], [
    h2([], [text("Your Tenants")]),
    case model.loading {
      True -> p([class("loading")], [text("Loading...")])
      False ->
        case model.tenants {
          [] ->
            div([class("empty-state")], [
              p([], [text("You don't have any tenants yet.")]),
              a([class("btn btn-primary"), href("/admin/tenants/new")], [
                text("Create Your First Tenant"),
              ]),
            ])
          tenants -> view_tenant_list(tenants)
        }
    },
  ])
}

fn view_tenant_list(tenants: List(Tenant)) -> Element(Msg) {
  ul([class("tenant-list")], list.map(tenants, view_tenant_item))
}

fn view_tenant_item(tenant: Tenant) -> Element(Msg) {
  li([class("tenant-item")], [
    a([href("/admin/tenants/" <> tenant.id)], [
      div([class("tenant-name")], [text(tenant.name)]),
      div([class("tenant-slug")], [text(tenant.slug)]),
    ]),
  ])
}

fn view_quick_actions() -> Element(Msg) {
  div([class("card quick-actions-card")], [
    h2([], [text("Quick Actions")]),
    ul([class("action-list")], [
      li([], [
        a([href("/admin/tenants/new")], [text("Create New Tenant")]),
      ]),
      li([], [
        a([href("/admin/tenants")], [text("View All Tenants")]),
      ]),
    ]),
  ])
}
