//// Document detail page with tabbed view for metadata, deltas, summaries, refs, and git objects.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre/attribute.{class, href}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html.{
  a, button, code, div, h1, h2, p, pre, span, table, tbody, td, text, th, thead,
  tr,
}
import lustre/event

import levee_admin/api

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

pub type Tab {
  MetadataTab
  OpStreamTab
  SummariesTab
  RefsTab
  GitTab
}

pub type GitView {
  GitNone
  GitBlobView(sha: String, blob: Option(api.GitBlob))
  GitTreeView(sha: String, tree: Option(api.GitTree))
  GitCommitView(sha: String, commit: Option(api.GitCommit))
}

pub type PageState {
  Loading
  Loaded
  NotFound
  Error(String)
}

pub type Model {
  Model(
    tenant_id: String,
    document_id: String,
    state: PageState,
    active_tab: Tab,
    // Metadata
    document: Option(api.DocumentItem),
    session: Option(api.SessionInfo),
    // Deltas
    deltas: List(api.DeltaItem),
    deltas_loading: Bool,
    deltas_from: Int,
    deltas_has_more: Bool,
    // Summaries
    summaries: List(api.SummaryItem),
    summaries_loading: Bool,
    // Refs
    refs: List(api.RefItem),
    refs_loading: Bool,
    // Git objects
    git_view: GitView,
    git_loading: Bool,
  )
}

pub fn init(tenant_id: String, document_id: String) -> Model {
  Model(
    tenant_id: tenant_id,
    document_id: document_id,
    state: Loading,
    active_tab: MetadataTab,
    document: None,
    session: None,
    deltas: [],
    deltas_loading: False,
    deltas_from: -1,
    deltas_has_more: False,
    summaries: [],
    summaries_loading: False,
    refs: [],
    refs_loading: False,
    git_view: GitNone,
    git_loading: False,
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Messages
// ─────────────────────────────────────────────────────────────────────────────

pub type Msg {
  // Tab navigation
  SwitchTab(Tab)
  // Data loaded
  DocumentLoaded(api.DocumentDetailResponse)
  DocumentLoadError(String)
  DeltasLoaded(List(api.DeltaItem))
  DeltasLoadError(String)
  SummariesLoaded(List(api.SummaryItem))
  SummariesLoadError(String)
  RefsLoaded(List(api.RefItem))
  RefsLoadError(String)
  // Deltas pagination
  LoadMoreDeltas
  // Git object navigation
  ViewBlob(String)
  ViewTree(String)
  ViewCommit(String)
  BlobLoaded(api.GitBlob)
  TreeLoaded(api.GitTree)
  CommitLoaded(api.GitCommit)
  GitLoadError(String)
}

// ─────────────────────────────────────────────────────────────────────────────
// Update
// ─────────────────────────────────────────────────────────────────────────────

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    SwitchTab(tab) -> #(Model(..model, active_tab: tab), effect.none())

    DocumentLoaded(resp) -> #(
      Model(
        ..model,
        state: Loaded,
        document: Some(resp.document),
        session: resp.session,
      ),
      effect.none(),
    )

    DocumentLoadError(err) -> #(
      Model(..model, state: Error(err)),
      effect.none(),
    )

    DeltasLoaded(deltas) -> {
      let new_from =
        list.last(deltas)
        |> result.map(fn(d) { d.sequence_number })
        |> result.unwrap(model.deltas_from)
      #(
        Model(
          ..model,
          deltas: list.append(model.deltas, deltas),
          deltas_loading: False,
          deltas_from: new_from,
          deltas_has_more: list.length(deltas) >= 100,
        ),
        effect.none(),
      )
    }

    DeltasLoadError(_) -> #(
      Model(..model, deltas_loading: False),
      effect.none(),
    )

    SummariesLoaded(summaries) -> #(
      Model(..model, summaries: summaries, summaries_loading: False),
      effect.none(),
    )

    SummariesLoadError(_) -> #(
      Model(..model, summaries_loading: False),
      effect.none(),
    )

    RefsLoaded(refs) -> #(
      Model(..model, refs: refs, refs_loading: False),
      effect.none(),
    )

    RefsLoadError(_) -> #(Model(..model, refs_loading: False), effect.none())

    LoadMoreDeltas -> #(Model(..model, deltas_loading: True), effect.none())

    ViewBlob(sha) -> #(
      Model(..model, git_view: GitBlobView(sha, None), git_loading: True),
      effect.none(),
    )

    ViewTree(sha) -> #(
      Model(..model, git_view: GitTreeView(sha, None), git_loading: True),
      effect.none(),
    )

    ViewCommit(sha) -> #(
      Model(..model, git_view: GitCommitView(sha, None), git_loading: True),
      effect.none(),
    )

    BlobLoaded(blob) -> #(
      Model(
        ..model,
        git_view: GitBlobView(blob.sha, Some(blob)),
        git_loading: False,
      ),
      effect.none(),
    )

    TreeLoaded(tree) -> #(
      Model(
        ..model,
        git_view: GitTreeView(tree.sha, Some(tree)),
        git_loading: False,
      ),
      effect.none(),
    )

    CommitLoaded(commit) -> #(
      Model(
        ..model,
        git_view: GitCommitView(commit.sha, Some(commit)),
        git_loading: False,
      ),
      effect.none(),
    )

    GitLoadError(_) -> #(Model(..model, git_loading: False), effect.none())
  }
}

// Helpers for main app to check pending actions

pub fn get_pending_deltas_load(model: Model) -> Bool {
  model.deltas_loading
}

pub fn get_pending_git_action(model: Model) -> GitView {
  case model.git_loading {
    True -> model.git_view
    False -> GitNone
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// View
// ─────────────────────────────────────────────────────────────────────────────

pub fn view(model: Model) -> Element(Msg) {
  div([class("page document-detail-page")], [
    div([class("page-header")], [
      div([], [
        a(
          [
            class("back-link"),
            href("/admin/tenants/" <> model.tenant_id <> "/documents"),
          ],
          [text("Back to Documents")],
        ),
        div([class("page-title-row")], [
          h1([class("page-title")], [text("Document: " <> model.document_id)]),
          a(
            [
              class("btn btn-secondary btn-sm"),
              href(
                "/api/tenants/"
                <> model.tenant_id
                <> "/documents/"
                <> model.document_id,
              ),
              attribute.target("_blank"),
              attribute.attribute("rel", "noopener"),
            ],
            [text("View Raw")],
          ),
        ]),
      ]),
    ]),
    view_page_content(model),
  ])
}

fn view_page_content(model: Model) -> Element(Msg) {
  case model.state {
    Loading ->
      div([class("loading-state")], [p([], [text("Loading document...")])])

    NotFound ->
      div([class("empty-state card")], [
        p([], [text("Document not found.")]),
      ])

    Error(message) ->
      div([class("error-state")], [
        div([class("alert alert-error")], [
          span([class("alert-icon")], [text("!")]),
          span([class("alert-message")], [text(message)]),
        ]),
      ])

    Loaded ->
      div([class("document-detail-content")], [
        view_tabs(model),
        view_tab_content(model),
      ])
  }
}

fn view_tabs(model: Model) -> Element(Msg) {
  div([class("tab-bar")], [
    tab_button("Metadata", MetadataTab, model.active_tab),
    tab_button("Op Stream", OpStreamTab, model.active_tab),
    tab_button("Summaries", SummariesTab, model.active_tab),
    tab_button("Refs", RefsTab, model.active_tab),
    tab_button("Git Objects", GitTab, model.active_tab),
  ])
}

fn tab_button(label: String, tab: Tab, active: Tab) -> Element(Msg) {
  button(
    [
      class(case tab == active {
        True -> "tab-btn tab-btn-active"
        False -> "tab-btn"
      }),
      event.on_click(SwitchTab(tab)),
    ],
    [text(label)],
  )
}

fn view_tab_content(model: Model) -> Element(Msg) {
  case model.active_tab {
    MetadataTab -> view_metadata(model)
    OpStreamTab -> view_op_stream(model)
    SummariesTab -> view_summaries(model)
    RefsTab -> view_refs(model)
    GitTab -> view_git(model)
  }
}

// --- Metadata tab ---

fn view_metadata(model: Model) -> Element(Msg) {
  case model.document {
    None -> div([], [])
    Some(doc) ->
      div([class("card")], [
        h2([], [text("Document Info")]),
        div([class("detail-row")], [
          span([class("detail-label")], [text("ID")]),
          span([class("detail-value mono")], [text(doc.id)]),
        ]),
        div([class("detail-row")], [
          span([class("detail-label")], [text("Tenant")]),
          span([class("detail-value mono")], [text(doc.tenant_id)]),
        ]),
        div([class("detail-row")], [
          span([class("detail-label")], [text("Sequence #")]),
          span([class("detail-value")], [
            text(int.to_string(doc.sequence_number)),
          ]),
        ]),
        div([class("detail-row")], [
          span([class("detail-label")], [text("Session")]),
          span([class("detail-value")], [
            span(
              [
                class(case doc.session_alive {
                  True -> "status-dot status-active"
                  False -> "status-dot status-inactive"
                }),
              ],
              [],
            ),
            text(case doc.session_alive {
              True -> " Active"
              False -> " Inactive"
            }),
          ]),
        ]),
        view_session_info(model.session),
      ])
  }
}

fn view_session_info(session: Option(api.SessionInfo)) -> Element(Msg) {
  case session {
    None -> div([], [])
    Some(s) ->
      div([class("session-info")], [
        h2([], [text("Live Session")]),
        div([class("detail-row")], [
          span([class("detail-label")], [text("Current SN")]),
          span([class("detail-value")], [text(int.to_string(s.current_sn))]),
        ]),
        div([class("detail-row")], [
          span([class("detail-label")], [text("Current MSN")]),
          span([class("detail-value")], [text(int.to_string(s.current_msn))]),
        ]),
        div([class("detail-row")], [
          span([class("detail-label")], [text("Clients")]),
          span([class("detail-value")], [
            text(int.to_string(s.client_count)),
          ]),
        ]),
        div([class("detail-row")], [
          span([class("detail-label")], [text("History")]),
          span([class("detail-value")], [
            text(int.to_string(s.history_size) <> " ops"),
          ]),
        ]),
      ])
  }
}

// --- Op Stream tab ---

fn view_op_stream(model: Model) -> Element(Msg) {
  div([class("card")], [
    h2([], [text("Op Stream")]),
    case model.deltas {
      [] ->
        case model.deltas_loading {
          True -> p([], [text("Loading ops...")])
          False -> p([class("text-muted")], [text("No ops yet.")])
        }
      deltas ->
        div([], [
          div(
            [class("op-stream")],
            list.map(deltas, fn(d) { view_op_entry(d) }),
          ),
          case model.deltas_has_more {
            True ->
              div([class("load-more")], [
                case model.deltas_loading {
                  True -> p([], [text("Loading...")])
                  False ->
                    button(
                      [
                        class("btn btn-secondary"),
                        event.on_click(LoadMoreDeltas),
                      ],
                      [text("Load More")],
                    )
                },
              ])
            False -> div([], [])
          },
        ])
    },
  ])
}

fn view_op_entry(d: api.DeltaItem) -> Element(Msg) {
  let type_class = "op-type op-type-" <> d.type_
  div([class("op-entry")], [
    div([class("op-header")], [
      span([class("op-sn mono")], [
        text("#" <> int.to_string(d.sequence_number)),
      ]),
      span([class(type_class)], [text(d.type_)]),
      span([class("op-client mono")], [
        text(option.unwrap(d.client_id, "system")),
      ]),
      span([class("op-meta text-muted")], [
        text(
          "rsn="
          <> int.to_string(d.reference_sequence_number)
          <> " msn="
          <> int.to_string(d.minimum_sequence_number),
        ),
      ]),
    ]),
    case d.contents {
      "" -> element.none()
      contents ->
        div([class("op-contents")], [
          pre([], [code([], [text(contents)])]),
        ])
    },
  ])
}

// --- Summaries tab ---

fn view_summaries(model: Model) -> Element(Msg) {
  div([class("card")], [
    h2([], [text("Summaries")]),
    case model.summaries {
      [] ->
        case model.summaries_loading {
          True -> p([], [text("Loading summaries...")])
          False -> p([class("text-muted")], [text("No summaries.")])
        }
      summaries ->
        table([class("data-table")], [
          thead([], [
            tr([], [
              th([], [text("Handle")]),
              th([], [text("SN")]),
              th([], [text("Tree SHA")]),
              th([], [text("Commit SHA")]),
              th([], [text("Parent")]),
            ]),
          ]),
          tbody(
            [],
            list.map(summaries, fn(s) {
              tr([], [
                td([class("mono")], [text(s.handle)]),
                td([], [text(int.to_string(s.sequence_number))]),
                td([], [view_sha_link_tree(s.tree_sha)]),
                td([], [view_sha_link_commit(s.commit_sha)]),
                td([class("mono")], [
                  text(option.unwrap(s.parent_handle, "-")),
                ]),
              ])
            }),
          ),
        ])
    },
  ])
}

fn view_sha_link_tree(sha: Option(String)) -> Element(Msg) {
  case sha {
    None -> text("-")
    Some(s) ->
      a([class("sha-link mono"), href("#"), event.on_click(ViewTree(s))], [
        text(short_sha(s)),
      ])
  }
}

fn view_sha_link_commit(sha: Option(String)) -> Element(Msg) {
  case sha {
    None -> text("-")
    Some(s) ->
      a([class("sha-link mono"), href("#"), event.on_click(ViewCommit(s))], [
        text(short_sha(s)),
      ])
  }
}

fn short_sha(sha: String) -> String {
  case sha {
    "" -> "-"
    _ -> string.slice(sha, 0, 12)
  }
}

// --- Refs tab ---

fn view_refs(model: Model) -> Element(Msg) {
  div([class("card")], [
    h2([], [text("Refs")]),
    case model.refs {
      [] ->
        case model.refs_loading {
          True -> p([], [text("Loading refs...")])
          False -> p([class("text-muted")], [text("No refs.")])
        }
      refs ->
        table([class("data-table")], [
          thead([], [
            tr([], [
              th([], [text("Ref Path")]),
              th([], [text("SHA")]),
            ]),
          ]),
          tbody(
            [],
            list.map(refs, fn(r) {
              tr([], [
                td([class("mono")], [text(r.ref)]),
                td([], [
                  a(
                    [
                      class("sha-link mono"),
                      href("#"),
                      event.on_click(ViewCommit(r.sha)),
                    ],
                    [text(short_sha(r.sha))],
                  ),
                ]),
              ])
            }),
          ),
        ])
    },
  ])
}

// --- Git objects tab ---

fn view_git(model: Model) -> Element(Msg) {
  div([class("card")], [
    h2([], [text("Git Objects")]),
    case model.git_view {
      GitNone ->
        p([class("text-muted")], [
          text("Click a SHA link in Summaries or Refs to view git objects."),
        ])

      GitBlobView(sha, blob) ->
        div([], [
          view_git_breadcrumb("blob", sha),
          case blob {
            None ->
              case model.git_loading {
                True -> p([], [text("Loading blob...")])
                False -> p([], [text("Failed to load blob.")])
              }
            Some(b) ->
              div([class("git-object")], [
                div([class("detail-row")], [
                  span([class("detail-label")], [text("SHA")]),
                  span([class("detail-value mono")], [text(b.sha)]),
                ]),
                div([class("detail-row")], [
                  span([class("detail-label")], [text("Size")]),
                  span([class("detail-value")], [
                    text(int.to_string(b.size) <> " bytes"),
                  ]),
                ]),
                div([class("git-content")], [
                  pre([], [code([], [text(b.content)])]),
                ]),
              ])
          },
        ])

      GitTreeView(sha, tree) ->
        div([], [
          view_git_breadcrumb("tree", sha),
          case tree {
            None ->
              case model.git_loading {
                True -> p([], [text("Loading tree...")])
                False -> p([], [text("Failed to load tree.")])
              }
            Some(t) ->
              div([class("git-object")], [
                div([class("detail-row")], [
                  span([class("detail-label")], [text("SHA")]),
                  span([class("detail-value mono")], [text(t.sha)]),
                ]),
                table([class("data-table")], [
                  thead([], [
                    tr([], [
                      th([], [text("Mode")]),
                      th([], [text("Type")]),
                      th([], [text("SHA")]),
                      th([], [text("Path")]),
                    ]),
                  ]),
                  tbody(
                    [],
                    list.map(t.tree, fn(entry) {
                      tr([], [
                        td([class("mono")], [text(entry.mode)]),
                        td([], [text(entry.entry_type)]),
                        td([], [
                          case entry.entry_type {
                            "tree" ->
                              a(
                                [
                                  class("sha-link mono"),
                                  href("#"),
                                  event.on_click(ViewTree(entry.sha)),
                                ],
                                [text(short_sha(entry.sha))],
                              )
                            "blob" ->
                              a(
                                [
                                  class("sha-link mono"),
                                  href("#"),
                                  event.on_click(ViewBlob(entry.sha)),
                                ],
                                [text(short_sha(entry.sha))],
                              )
                            _ ->
                              span([class("mono")], [
                                text(short_sha(entry.sha)),
                              ])
                          },
                        ]),
                        td([], [text(entry.path)]),
                      ])
                    }),
                  ),
                ]),
              ])
          },
        ])

      GitCommitView(sha, commit) ->
        div([], [
          view_git_breadcrumb("commit", sha),
          case commit {
            None ->
              case model.git_loading {
                True -> p([], [text("Loading commit...")])
                False -> p([], [text("Failed to load commit.")])
              }
            Some(c) ->
              div([class("git-object")], [
                div([class("detail-row")], [
                  span([class("detail-label")], [text("SHA")]),
                  span([class("detail-value mono")], [text(c.sha)]),
                ]),
                div([class("detail-row")], [
                  span([class("detail-label")], [text("Tree")]),
                  a(
                    [
                      class("sha-link mono"),
                      href("#"),
                      event.on_click(ViewTree(c.tree)),
                    ],
                    [text(short_sha(c.tree))],
                  ),
                ]),
                div([class("detail-row")], [
                  span([class("detail-label")], [text("Parents")]),
                  span([class("detail-value")], case c.parents {
                    [] -> [text("(none)")]
                    parents ->
                      list.map(parents, fn(parent) {
                        a(
                          [
                            class("sha-link mono"),
                            href("#"),
                            event.on_click(ViewCommit(parent)),
                          ],
                          [text(short_sha(parent) <> " ")],
                        )
                      })
                  }),
                ]),
                div([class("detail-row")], [
                  span([class("detail-label")], [text("Message")]),
                  span([class("detail-value")], [
                    text(option.unwrap(c.message, "(none)")),
                  ]),
                ]),
              ])
          },
        ])
    },
  ])
}

fn view_git_breadcrumb(object_type: String, sha: String) -> Element(Msg) {
  div([class("git-breadcrumb")], [
    span([class("git-breadcrumb-type")], [text(object_type)]),
    span([class("mono")], [text(short_sha(sha))]),
  ])
}
