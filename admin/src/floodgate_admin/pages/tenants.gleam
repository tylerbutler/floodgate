//// Floodgate tenant list page.

import gleam/int
import gleam/list
import gleam/string
import lustre/attribute.{class, href}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html.{
  a, div, h1, input, label, li, option, p, select, span, text, ul,
}
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

/// Client-side ordering for the loaded tenant list.
pub type SortKey {
  NameAsc
  NameDesc
  IdAsc
}

pub type Model {
  Model(tenants: List(Tenant), state: PageState, search: String, sort: SortKey)
}

pub fn init() -> Model {
  Model(tenants: [], state: Loading, search: "", sort: NameAsc)
}

// ─────────────────────────────────────────────────────────────────────────────
// Messages
// ─────────────────────────────────────────────────────────────────────────────

pub type Msg {
  LoadTenants
  TenantsLoaded(List(Tenant))
  LoadError(String)
  Retry
  UpdateSearch(String)
  UpdateSort(String)
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
      #(Model(..model, tenants: tenants, state: Loaded), effect.none())
    }

    LoadError(error) -> {
      #(Model(..model, state: Error(error)), effect.none())
    }

    Retry -> {
      #(Model(..model, state: Loading), effect.none())
    }

    UpdateSearch(query) -> {
      #(Model(..model, search: query), effect.none())
    }

    UpdateSort(raw) -> {
      #(Model(..model, sort: parse_sort(raw)), effect.none())
    }
  }
}

fn parse_sort(raw: String) -> SortKey {
  case raw {
    "name-desc" -> NameDesc
    "id-asc" -> IdAsc
    _ -> NameAsc
  }
}

fn sort_value(sort: SortKey) -> String {
  case sort {
    NameAsc -> "name-asc"
    NameDesc -> "name-desc"
    IdAsc -> "id-asc"
  }
}

/// Filter by a case-insensitive match on name or id, then order. Pure so the
/// behaviour is unit-testable without the view.
pub fn visible_tenants(
  tenants: List(Tenant),
  search: String,
  sort: SortKey,
) -> List(Tenant) {
  let needle = string.lowercase(string.trim(search))
  tenants
  |> list.filter(fn(t) {
    needle == ""
    || string.contains(string.lowercase(t.name), needle)
    || string.contains(string.lowercase(t.id), needle)
  })
  |> list.sort(fn(a, b) {
    case sort {
      NameAsc ->
        string.compare(string.lowercase(a.name), string.lowercase(b.name))
      NameDesc ->
        string.compare(string.lowercase(b.name), string.lowercase(a.name))
      IdAsc -> string.compare(a.id, b.id)
    }
  })
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
      div([class("loading-state"), attribute.role("status")], [
        p([], [text("Loading tenants...")]),
      ])

    Error(message) ->
      div([class("error-state")], [
        div([class("alert alert-error"), attribute.role("alert")], [
          span([class("alert-icon"), attribute.aria_hidden(True)], [text("!")]),
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
          let total = list.length(tenants)
          let shown = visible_tenants(tenants, model.search, model.sort)
          div([class("tenant-table card")], [
            view_controls(model),
            view_result_count(list.length(shown), total),
            case shown {
              [] ->
                p([class("no-results")], [
                  text("No tenants match \"" <> model.search <> "\"."),
                ])
              rows ->
                ul(
                  [class("tenant-list")],
                  list.map(rows, fn(tenant) {
                    li([class("tenant-row")], [
                      a([href("/admin/tenants/" <> tenant.id)], [
                        span([class("tenant-name")], [text(tenant.name)]),
                        span([class("tenant-id")], [text(tenant.id)]),
                      ]),
                    ])
                  }),
                )
            },
          ])
        }
      }
  }
}

fn view_controls(model: Model) -> Element(Msg) {
  div([class("list-controls")], [
    div([class("control control-search")], [
      label([attribute.for("tenant-search")], [text("Search tenants")]),
      input([
        attribute.id("tenant-search"),
        class("search-input"),
        attribute.type_("search"),
        attribute.value(model.search),
        attribute.placeholder("Filter by name or ID"),
        event.on_input(UpdateSearch),
      ]),
    ]),
    div([class("control")], [
      label([attribute.for("tenant-sort")], [text("Sort")]),
      select(
        [
          attribute.id("tenant-sort"),
          class("sort-select"),
          event.on_change(UpdateSort),
        ],
        [
          sort_option("name-asc", "Name (A–Z)", model.sort),
          sort_option("name-desc", "Name (Z–A)", model.sort),
          sort_option("id-asc", "ID (A–Z)", model.sort),
        ],
      ),
    ]),
  ])
}

fn sort_option(
  value: String,
  label_text: String,
  current: SortKey,
) -> Element(Msg) {
  option(
    [attribute.value(value), attribute.selected(value == sort_value(current))],
    label_text,
  )
}

fn view_result_count(shown: Int, total: Int) -> Element(Msg) {
  let text_value = case shown == total {
    True -> int.to_string(total) <> " tenant" <> plural(total)
    False ->
      int.to_string(shown)
      <> " of "
      <> int.to_string(total)
      <> " tenant"
      <> plural(total)
  }
  p([class("list-result-count"), attribute.role("status")], [text(text_value)])
}

fn plural(count: Int) -> String {
  case count {
    1 -> ""
    _ -> "s"
  }
}
