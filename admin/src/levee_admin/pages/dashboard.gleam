//// Dashboard page component.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute.{class, href}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html.{a, div, h1, h2, li, p, span, text, ul}

pub type Tenant {
  Tenant(id: String, name: String)
}

pub type Model {
  Model(tenants: List(Tenant), loading: Bool, error: Option(String))
}

pub fn init() -> Model {
  Model(tenants: [], loading: False, error: None)
}

pub type Msg {
  TenantsLoaded(List(Tenant))
  LoadError(String)
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    TenantsLoaded(tenants) -> {
      #(Model(tenants: tenants, loading: False, error: None), effect.none())
    }

    LoadError(error) -> {
      #(Model(..model, error: Some(error), loading: False), effect.none())
    }
  }
}

pub fn start_loading(model: Model) -> Model {
  Model(..model, loading: True, error: None)
}

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
        case model.error {
          Some(error) ->
            div([class("alert alert-error")], [
              span([class("alert-icon")], [text("!")]),
              span([class("alert-message")], [text(error)]),
            ])
          None ->
            case model.tenants {
              [] ->
                div([class("empty-state")], [
                  p([], [text("You don't have any tenants yet.")]),
                  a([class("btn btn-primary"), href("/admin/tenants/new")], [
                    text("Create Your First Tenant"),
                  ]),
                ])
              tenants -> view_tenant_preview(tenants)
            }
        }
    },
  ])
}

fn view_tenant_preview(tenants: List(Tenant)) -> Element(Msg) {
  let count = list.length(tenants)
  let preview = list.take(tenants, 5)

  div([], [
    p([class("tenant-count")], [
      text(
        int.to_string(count)
        <> " tenant"
        <> case count {
          1 -> ""
          _ -> "s"
        }
        <> " registered",
      ),
    ]),
    ul(
      [class("tenant-list")],
      list.map(preview, fn(tenant) {
        li([class("tenant-item")], [
          a([href("/admin/tenants/" <> tenant.id)], [
            text(tenant.name),
            span([class("tenant-id-small")], [text(" (" <> tenant.id <> ")")]),
          ]),
        ])
      }),
    ),
    case count > 5 {
      True ->
        a([class("view-all-link"), href("/admin/tenants")], [
          text("View all " <> int.to_string(count) <> " tenants"),
        ])
      False ->
        a([class("view-all-link"), href("/admin/tenants")], [
          text("View all tenants"),
        ])
    },
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
