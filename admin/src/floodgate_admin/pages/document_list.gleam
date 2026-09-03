//// Floodgate document list for a tenant.

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

/// Client-side ordering for the loaded document list.
pub type SortKey {
  SeqDesc
  SeqAsc
  IdAsc
  ActiveFirst
}

pub type Model {
  Model(
    tenant_id: String,
    documents: List(Document),
    state: PageState,
    search: String,
    sort: SortKey,
  )
}

pub fn init(tenant_id: String) -> Model {
  Model(
    tenant_id: tenant_id,
    documents: [],
    state: Loading,
    search: "",
    sort: SeqDesc,
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Messages
// ─────────────────────────────────────────────────────────────────────────────

pub type Msg {
  DocumentsLoaded(List(Document))
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
    DocumentsLoaded(documents) -> {
      #(Model(..model, documents: documents, state: Loaded), effect.none())
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
    "seq-asc" -> SeqAsc
    "id-asc" -> IdAsc
    "active-first" -> ActiveFirst
    _ -> SeqDesc
  }
}

fn sort_value(sort: SortKey) -> String {
  case sort {
    SeqDesc -> "seq-desc"
    SeqAsc -> "seq-asc"
    IdAsc -> "id-asc"
    ActiveFirst -> "active-first"
  }
}

/// Filter by a case-insensitive match on the document id, then order. Pure so
/// the behaviour is unit-testable without the view.
pub fn visible_documents(
  documents: List(Document),
  search: String,
  sort: SortKey,
) -> List(Document) {
  let needle = string.lowercase(string.trim(search))
  documents
  |> list.filter(fn(d) {
    needle == "" || string.contains(string.lowercase(d.id), needle)
  })
  |> list.sort(fn(a, b) {
    case sort {
      SeqDesc -> int.compare(b.sequence_number, a.sequence_number)
      SeqAsc -> int.compare(a.sequence_number, b.sequence_number)
      IdAsc -> string.compare(a.id, b.id)
      ActiveFirst ->
        case rank_alive(a) == rank_alive(b) {
          True -> int.compare(b.sequence_number, a.sequence_number)
          False -> int.compare(rank_alive(a), rank_alive(b))
        }
    }
  })
}

fn rank_alive(doc: Document) -> Int {
  case doc.session_alive {
    True -> 0
    False -> 1
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
      div([class("loading-state"), attribute.role("status")], [
        p([], [text("Loading documents...")]),
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
      case model.documents {
        [] ->
          div([class("empty-state card")], [
            p([], [text("No documents in this tenant.")]),
          ])

        documents -> {
          let total = list.length(documents)
          let shown = visible_documents(documents, model.search, model.sort)
          div([class("document-table card")], [
            view_controls(model),
            view_result_count(list.length(shown), total),
            case shown {
              [] ->
                p([class("no-results")], [
                  text("No documents match \"" <> model.search <> "\"."),
                ])
              rows ->
                ul(
                  [class("data-list")],
                  list.map(rows, fn(doc) { view_document_row(model, doc) }),
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
      label([attribute.for("doc-search")], [text("Search documents")]),
      input([
        attribute.id("doc-search"),
        class("search-input"),
        attribute.type_("search"),
        attribute.value(model.search),
        attribute.placeholder("Filter by document ID"),
        event.on_input(UpdateSearch),
      ]),
    ]),
    div([class("control")], [
      label([attribute.for("doc-sort")], [text("Sort")]),
      select(
        [
          attribute.id("doc-sort"),
          class("sort-select"),
          event.on_change(UpdateSort),
        ],
        [
          sort_option("seq-desc", "Sequence (high → low)", model.sort),
          sort_option("seq-asc", "Sequence (low → high)", model.sort),
          sort_option("id-asc", "ID (A–Z)", model.sort),
          sort_option("active-first", "Active sessions first", model.sort),
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
    True -> int.to_string(total) <> " document" <> plural(total)
    False ->
      int.to_string(shown)
      <> " of "
      <> int.to_string(total)
      <> " document"
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

fn view_document_row(model: Model, doc: Document) -> Element(Msg) {
  li([class("data-row")], [
    a(
      [
        href("/admin/tenants/" <> model.tenant_id <> "/documents/" <> doc.id),
      ],
      [
        span([class("doc-id mono")], [text(doc.id)]),
        span([class("doc-meta")], [
          span([class("doc-sn")], [
            text("Sequence " <> int.to_string(doc.sequence_number)),
          ]),
          span(
            [
              class(case doc.session_alive {
                True -> "status-dot status-active"
                False -> "status-dot status-inactive"
              }),
              attribute.aria_hidden(True),
            ],
            [],
          ),
          span([class("status-label")], [
            text(case doc.session_alive {
              True -> "Active"
              False -> "Inactive"
            }),
          ]),
        ]),
      ],
    ),
  ])
}
