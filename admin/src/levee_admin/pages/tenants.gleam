//// Tenant list page component.

import gleam/int
import gleam/list
import lustre/attribute.{class, href}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html.{a, div, h1, li, p, span, text, ul}
import lustre/event

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

pub type Tenant {
  Tenant(id: String, name: String)
}

pub type PageState {
  Loading
  Loaded
  Error(String)
}

pub type Model {
  Model(tenants: List(Tenant), state: PageState)
}

pub fn init() -> Model {
  Model(tenants: [], state: Loading)
}

// ─────────────────────────────────────────────────────────────────────────────
// Messages
// ─────────────────────────────────────────────────────────────────────────────

pub type Msg {
  LoadTenants
  TenantsLoaded(List(Tenant))
  LoadError(String)
  Retry
}

// ─────────────────────────────────────────────────────────────────────────────
// Update
// ─────────────────────────────────────────────────────────────────────────────

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    LoadTenants -> {
      #(Model(..model, state: Loading), effect.none())
    }

    TenantsLoaded(tenants) -> {
      #(Model(tenants: tenants, state: Loaded), effect.none())
    }

    LoadError(error) -> {
      #(Model(..model, state: Error(error)), effect.none())
    }

    Retry -> {
      #(Model(..model, state: Loading), effect.none())
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// View
// ─────────────────────────────────────────────────────────────────────────────

pub fn view(model: Model) -> Element(Msg) {
  div([class("page tenants-page")], [
    div([class("page-header")], [
      h1([class("page-title")], [text("Tenants")]),
      a([class("btn btn-primary"), href("/admin/tenants/new")], [
        text("Create Tenant"),
      ]),
    ]),
    view_content(model),
  ])
}

fn view_content(model: Model) -> Element(Msg) {
  case model.state {
    Loading ->
      div([class("loading-state")], [p([], [text("Loading tenants...")])])

    Error(message) ->
      div([class("error-state")], [
        div([class("alert alert-error")], [
          span([class("alert-icon")], [text("!")]),
          span([class("alert-message")], [text(message)]),
        ]),
        html.button([class("btn btn-primary"), event.on_click(Retry)], [
          text("Retry"),
        ]),
      ])

    Loaded ->
      case model.tenants {
        [] ->
          div([class("empty-state card")], [
            p([], [text("No tenants registered yet.")]),
            a([class("btn btn-primary"), href("/admin/tenants/new")], [
              text("Create Your First Tenant"),
            ]),
          ])

        tenants -> {
          let count = list.length(tenants)
          div([class("tenant-table card")], [
            div([class("tenant-table-header")], [
              span([], [
                text(
                  int.to_string(count)
                  <> " tenant"
                  <> case count {
                    1 -> ""
                    _ -> "s"
                  },
                ),
              ]),
            ]),
            ul(
              [class("tenant-list")],
              list.map(tenants, fn(tenant) {
                li([class("tenant-row")], [
                  a([href("/admin/tenants/" <> tenant.id)], [
                    span([class("tenant-name")], [text(tenant.name)]),
                    span([class("tenant-id")], [text(tenant.id)]),
                  ]),
                ])
              }),
            ),
          ])
        }
      }
  }
}
