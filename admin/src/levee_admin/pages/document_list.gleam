//// Document list page for a tenant.

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

pub type Document {
  Document(
    id: String,
    tenant_id: String,
    sequence_number: Int,
    session_alive: Bool,
  )
}

pub type PageState {
  Loading
  Loaded
  Error(String)
}

pub type Model {
  Model(tenant_id: String, documents: List(Document), state: PageState)
}

pub fn init(tenant_id: String) -> Model {
  Model(tenant_id: tenant_id, documents: [], state: Loading)
}

// ─────────────────────────────────────────────────────────────────────────────
// Messages
// ─────────────────────────────────────────────────────────────────────────────

pub type Msg {
  DocumentsLoaded(List(Document))
  LoadError(String)
  Retry
}

// ─────────────────────────────────────────────────────────────────────────────
// Update
// ─────────────────────────────────────────────────────────────────────────────

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    DocumentsLoaded(documents) -> {
      #(Model(..model, documents: documents, state: Loaded), effect.none())
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
  div([class("page document-list-page")], [
    div([class("page-header")], [
      div([], [
        a([class("back-link"), href("/admin/tenants/" <> model.tenant_id)], [
          text("Back to Tenant"),
        ]),
        h1([class("page-title")], [text("Documents")]),
      ]),
    ]),
    view_content(model),
  ])
}

fn view_content(model: Model) -> Element(Msg) {
  case model.state {
    Loading ->
      div([class("loading-state")], [p([], [text("Loading documents...")])])

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
      case model.documents {
        [] ->
          div([class("empty-state card")], [
            p([], [text("No documents in this tenant.")]),
          ])

        documents -> {
          let count = list.length(documents)
          div([class("document-table card")], [
            div([class("table-header")], [
              span([], [
                text(
                  int.to_string(count)
                  <> " document"
                  <> case count {
                    1 -> ""
                    _ -> "s"
                  },
                ),
              ]),
            ]),
            ul(
              [class("data-list")],
              list.map(documents, fn(doc) {
                li([class("data-row")], [
                  a(
                    [
                      href(
                        "/admin/tenants/"
                        <> model.tenant_id
                        <> "/documents/"
                        <> doc.id,
                      ),
                    ],
                    [
                      span([class("doc-id mono")], [text(doc.id)]),
                      span([class("doc-meta")], [
                        span([class("doc-sn")], [
                          text("SN: " <> int.to_string(doc.sequence_number)),
                        ]),
                        span(
                          [
                            class(case doc.session_alive {
                              True -> "status-dot status-active"
                              False -> "status-dot status-inactive"
                            }),
                          ],
                          [],
                        ),
                      ]),
                    ],
                  ),
                ])
              }),
            ),
          ])
        }
      }
  }
}
