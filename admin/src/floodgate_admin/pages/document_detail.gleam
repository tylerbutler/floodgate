//// Floodgate document detail with metadata, deltas, summaries, refs, and git objects.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre/attribute.{class, href}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html.{
  a, button, code, dfn, div, form, h1, h2, input, label, p, pre, span, table,
  tbody, td, text, th, thead, tr,
}
import lustre/event

import floodgate_admin/api

@external(javascript, "../../floodgate_admin_ffi.mjs", "focus_element")
fn focus_element(id: String) -> Nil

/// Number of operations fetched per Op Stream page (initial load, Load More,
/// and jump-to-sequence all use this window).
pub const page_size = 100

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
    deltas_error: Option(String),
    // Jump-to-sequence input, and the sequence a jump last targeted (for the
    // "no operations at or after N" empty message).
    seq_input: String,
    jump_target: Option(Int),
    // Summaries
    summaries: List(api.SummaryItem),
    summaries_loading: Bool,
    summaries_error: Option(String),
    // Refs
    refs: List(api.RefItem),
    refs_loading: Bool,
    refs_error: Option(String),
    // Git objects
    git_view: GitView,
    git_loading: Bool,
    git_error: Option(String),
  )
}

pub fn init(tenant_id: String, document_id: String) -> Model {
  Model(
    tenant_id: tenant_id,
    document_id: document_id,
    state: Loading,
    // The operation stream is the primary incident-investigation surface.
    active_tab: OpStreamTab,
    document: None,
    session: None,
    deltas: [],
    deltas_loading: True,
    deltas_from: -1,
    deltas_has_more: False,
    deltas_error: None,
    seq_input: "",
    jump_target: None,
    summaries: [],
    summaries_loading: False,
    summaries_error: None,
    refs: [],
    refs_loading: False,
    refs_error: None,
    git_view: GitNone,
    git_loading: False,
    git_error: None,
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Messages
// ─────────────────────────────────────────────────────────────────────────────

pub type Msg {
  // Tab navigation
  SwitchTab(Tab)
  TabKeyNav(String)
  // Data loaded
  DocumentLoaded(api.DocumentDetailResponse)
  DocumentLoadError(String)
  DeltasLoaded(List(api.DeltaItem))
  DeltasLoadError(String)
  SummariesLoaded(List(api.SummaryItem))
  SummariesLoadError(String)
  RefsLoaded(List(api.RefItem))
  RefsLoadError(String)
  // Deltas pagination and direct sequence access
  LoadMoreDeltas
  UpdateSeqInput(String)
  JumpToSequence
  ReloadOpsFromStart
  // Git object navigation
  ViewBlob(String)
  ViewTree(String)
  ViewCommit(String)
  BlobLoaded(api.GitBlob)
  TreeLoaded(api.GitTree)
  CommitLoaded(api.GitCommit)
  GitLoadError(String)
}

/// Fixed tab order for the tablist, driving roving focus and arrow-key
/// navigation. The operation stream leads because it is the primary surface.
pub fn all_tabs() -> List(Tab) {
  [OpStreamTab, MetadataTab, SummariesTab, RefsTab, GitTab]
}

fn tab_id(tab: Tab) -> String {
  case tab {
    MetadataTab -> "metadata"
    OpStreamTab -> "opstream"
    SummariesTab -> "summaries"
    RefsTab -> "refs"
    GitTab -> "git"
  }
}

fn tab_label(tab: Tab) -> String {
  case tab {
    MetadataTab -> "Metadata"
    OpStreamTab -> "Op Stream"
    SummariesTab -> "Summaries"
    RefsTab -> "Refs"
    GitTab -> "Git Objects"
  }
}

fn is_tab_nav_key(key: String) -> Bool {
  case key {
    "ArrowRight" | "ArrowLeft" | "ArrowUp" | "ArrowDown" | "Home" | "End" ->
      True
    _ -> False
  }
}

/// The tab a keyboard navigation key selects from the current one, wrapping at
/// both ends. Non-navigation keys leave the selection unchanged.
pub fn tab_step(current: Tab, key: String) -> Tab {
  let tabs = all_tabs()
  case key {
    "ArrowRight" | "ArrowDown" -> neighbour(tabs, current, 1)
    "ArrowLeft" | "ArrowUp" -> neighbour(tabs, current, -1)
    "Home" -> result.unwrap(list.first(tabs), current)
    "End" -> result.unwrap(list.last(tabs), current)
    _ -> current
  }
}

fn neighbour(tabs: List(Tab), current: Tab, delta: Int) -> Tab {
  let count = list.length(tabs)
  let index =
    index_of(tabs, current)
    |> option.unwrap(0)
  let next = { index + delta + count } % count
  tabs
  |> list.drop(next)
  |> list.first
  |> result.unwrap(current)
}

fn index_of(tabs: List(Tab), target: Tab) -> Option(Int) {
  tabs
  |> list.index_map(fn(tab, i) { #(tab, i) })
  |> list.find(fn(pair) { pair.0 == target })
  |> option.from_result
  |> option.map(fn(pair) { pair.1 })
}

/// The `from` value that returns operations starting at `target` inclusive.
///
/// The backend deltas query is exclusive — it returns operations whose
/// sequence number is strictly greater than `from` — so viewing from `target`
/// asks for `target - 1`. Sequence 0 (or any lower request) maps to -1, the
/// whole-stream sentinel.
pub fn sequence_to_from(target: Int) -> Int {
  int.max(target - 1, -1)
}

// ─────────────────────────────────────────────────────────────────────────────
// Update
// ─────────────────────────────────────────────────────────────────────────────

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    SwitchTab(tab) -> #(Model(..model, active_tab: tab), effect.none())

    TabKeyNav(key) ->
      case is_tab_nav_key(key) {
        False -> #(model, effect.none())
        True -> {
          let next = tab_step(model.active_tab, key)
          #(Model(..model, active_tab: next), focus_tab_effect(next))
        }
      }

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
          deltas_has_more: list.length(deltas) >= page_size,
          deltas_error: None,
        ),
        effect.none(),
      )
    }

    DeltasLoadError(err) -> #(
      Model(..model, deltas_loading: False, deltas_error: Some(err)),
      effect.none(),
    )

    SummariesLoaded(summaries) -> #(
      Model(
        ..model,
        summaries: summaries,
        summaries_loading: False,
        summaries_error: None,
      ),
      effect.none(),
    )

    SummariesLoadError(err) -> #(
      Model(..model, summaries_loading: False, summaries_error: Some(err)),
      effect.none(),
    )

    RefsLoaded(refs) -> #(
      Model(..model, refs: refs, refs_loading: False, refs_error: None),
      effect.none(),
    )

    RefsLoadError(err) -> #(
      Model(..model, refs_loading: False, refs_error: Some(err)),
      effect.none(),
    )

    LoadMoreDeltas ->
      case model.deltas_loading {
        True -> #(model, effect.none())
        False -> #(
          Model(..model, deltas_loading: True, deltas_error: None),
          effect.none(),
        )
      }

    UpdateSeqInput(value) -> #(Model(..model, seq_input: value), effect.none())

    JumpToSequence ->
      case model.deltas_loading {
        True -> #(model, effect.none())
        False ->
          case parse_sequence(model.seq_input) {
            Some(target) -> #(
              Model(
                ..model,
                deltas: [],
                deltas_from: sequence_to_from(target),
                deltas_loading: True,
                deltas_has_more: False,
                deltas_error: None,
                jump_target: Some(target),
              ),
              effect.none(),
            )
            None -> #(
              Model(
                ..model,
                deltas_error: Some(
                  "Enter a whole sequence number (0 or higher).",
                ),
              ),
              effect.none(),
            )
          }
      }

    ReloadOpsFromStart ->
      case model.deltas_loading {
        True -> #(model, effect.none())
        False -> #(
          Model(
            ..model,
            deltas: [],
            deltas_from: -1,
            deltas_loading: True,
            deltas_has_more: False,
            deltas_error: None,
            jump_target: None,
            seq_input: "",
          ),
          effect.none(),
        )
      }

    ViewBlob(sha) ->
      case model.git_loading {
        True -> #(model, effect.none())
        False -> #(
          Model(
            ..model,
            git_view: GitBlobView(sha, None),
            git_loading: True,
            git_error: None,
          ),
          effect.none(),
        )
      }

    ViewTree(sha) ->
      case model.git_loading {
        True -> #(model, effect.none())
        False -> #(
          Model(
            ..model,
            git_view: GitTreeView(sha, None),
            git_loading: True,
            git_error: None,
          ),
          effect.none(),
        )
      }

    ViewCommit(sha) ->
      case model.git_loading {
        True -> #(model, effect.none())
        False -> #(
          Model(
            ..model,
            git_view: GitCommitView(sha, None),
            git_loading: True,
            git_error: None,
          ),
          effect.none(),
        )
      }

    BlobLoaded(blob) ->
      case model.git_view {
        GitBlobView(sha, None) if sha == blob.sha -> #(
          Model(
            ..model,
            git_view: GitBlobView(blob.sha, Some(blob)),
            git_loading: False,
          ),
          effect.none(),
        )
        _ -> #(model, effect.none())
      }

    TreeLoaded(tree) ->
      case model.git_view {
        GitTreeView(sha, None) if sha == tree.sha -> #(
          Model(
            ..model,
            git_view: GitTreeView(tree.sha, Some(tree)),
            git_loading: False,
          ),
          effect.none(),
        )
        _ -> #(model, effect.none())
      }

    CommitLoaded(commit) ->
      case model.git_view {
        GitCommitView(sha, None) if sha == commit.sha -> #(
          Model(
            ..model,
            git_view: GitCommitView(commit.sha, Some(commit)),
            git_loading: False,
          ),
          effect.none(),
        )
        _ -> #(model, effect.none())
      }

    GitLoadError(err) -> #(
      Model(..model, git_loading: False, git_error: Some(err)),
      effect.none(),
    )
  }
}

/// Parse the jump-to-sequence input: a non-negative whole number.
fn parse_sequence(raw: String) -> Option(Int) {
  case int.parse(string.trim(raw)) {
    Ok(n) if n >= 0 -> Some(n)
    _ -> None
  }
}

fn focus_tab_effect(tab: Tab) -> Effect(Msg) {
  effect.from(fn(_dispatch) { focus_element("tab-" <> tab_id(tab)) })
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
        ]),
      ]),
    ]),
    view_page_content(model),
  ])
}

fn view_page_content(model: Model) -> Element(Msg) {
  case model.state {
    Loading ->
      div([class("loading-state"), attribute.role("status")], [
        p([], [text("Loading document...")]),
      ])

    NotFound ->
      div([class("empty-state card")], [
        p([], [text("Document not found.")]),
      ])

    Error(message) ->
      div([class("error-state")], [
        div([class("alert alert-error"), attribute.role("alert")], [
          span([class("alert-icon"), attribute.aria_hidden(True)], [text("!")]),
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
  div(
    [
      class("tab-bar"),
      attribute.role("tablist"),
      attribute.aria_label("Document views"),
      // Conditionally prevents default only for arrow/Home/End so Tab is never
      // trapped; Lustre's plain on_keydown can't express that.
      event.advanced("keydown", tab_keydown_handler()),
    ],
    list.map(all_tabs(), fn(tab) { tab_button(tab, model.active_tab) }),
  )
}

fn tab_keydown_handler() -> decode.Decoder(event.Handler(Msg)) {
  use key <- decode.field("key", decode.string)
  decode.success(event.handler(
    dispatch: TabKeyNav(key),
    prevent_default: is_tab_nav_key(key),
    stop_propagation: False,
  ))
}

fn tab_button(tab: Tab, active: Tab) -> Element(Msg) {
  let is_active = tab == active
  button(
    [
      class(case is_active {
        True -> "tab-btn tab-btn-active"
        False -> "tab-btn"
      }),
      attribute.id("tab-" <> tab_id(tab)),
      attribute.role("tab"),
      attribute.aria_selected(is_active),
      attribute.aria_controls("panel-" <> tab_id(tab)),
      // Roving tabindex: only the active tab is in the tab sequence.
      attribute.tabindex(case is_active {
        True -> 0
        False -> -1
      }),
      event.on_click(SwitchTab(tab)),
    ],
    [text(tab_label(tab))],
  )
}

fn view_tab_content(model: Model) -> Element(Msg) {
  let tab = model.active_tab
  div(
    [
      class("tab-panel"),
      attribute.id("panel-" <> tab_id(tab)),
      attribute.role("tabpanel"),
      attribute.aria_labelledby("tab-" <> tab_id(tab)),
      attribute.tabindex(0),
    ],
    [
      case tab {
        MetadataTab -> view_metadata(model)
        OpStreamTab -> view_op_stream(model)
        SummariesTab -> view_summaries(model)
        RefsTab -> view_refs(model)
        GitTab -> view_git(model)
      },
    ],
  )
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
          span([class("detail-label")], [text("Sequence number")]),
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
          span([class("detail-label")], [text("Current sequence")]),
          span([class("detail-value")], [text(int.to_string(s.current_sn))]),
        ]),
        div([class("detail-row")], [
          span([class("detail-label")], [text("Minimum sequence")]),
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
    view_op_toolbar(model),
    view_op_error(model.deltas_error),
    case model.deltas {
      [] ->
        case model.deltas_loading {
          True -> p([attribute.role("status")], [text("Loading operations...")])
          False -> view_op_empty(model)
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
                  True ->
                    p([attribute.role("status")], [
                      text("Loading more operations..."),
                    ])
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
            False -> element.none()
          },
        ])
    },
    view_op_legend(),
  ])
}

fn view_op_toolbar(model: Model) -> Element(Msg) {
  div([class("op-toolbar")], [
    form([event.on_submit(fn(_) { JumpToSequence })], [
      div([class("control")], [
        label([attribute.for("seq-jump")], [text("Jump to sequence")]),
        input([
          attribute.id("seq-jump"),
          class("seq-input"),
          attribute.type_("number"),
          attribute.min("0"),
          attribute.value(model.seq_input),
          attribute.placeholder("e.g. 5000"),
          event.on_input(UpdateSeqInput),
        ]),
      ]),
      button([attribute.type_("submit"), class("btn btn-secondary")], [
        text("Go"),
      ]),
    ]),
    case model.jump_target {
      Some(_) ->
        button(
          [class("btn btn-secondary"), event.on_click(ReloadOpsFromStart)],
          [text("From start")],
        )
      None -> element.none()
    },
  ])
}

fn view_op_empty(model: Model) -> Element(Msg) {
  case model.jump_target {
    Some(target) ->
      p([class("text-muted")], [
        text(
          "No operations at or after sequence "
          <> int.to_string(target)
          <> ". Try a lower number or start from the beginning.",
        ),
      ])
    None ->
      p([class("text-muted")], [
        text(
          "No operations recorded yet. Operations appear here as clients edit this document.",
        ),
      ])
  }
}

fn view_op_error(error: Option(String)) -> Element(Msg) {
  case error {
    None -> element.none()
    Some(message) ->
      div([class("alert alert-error"), attribute.role("alert")], [
        span([class("alert-icon"), attribute.aria_hidden(True)], [text("!")]),
        span([class("alert-message")], [text(message)]),
      ])
  }
}

fn view_op_legend() -> Element(Msg) {
  p([class("op-legend")], [
    dfn([], [text("Ref seq")]),
    text(
      " — the sequence number a client had processed when it created the op. ",
    ),
    dfn([], [text("Min seq")]),
    text(" — the lowest sequence number still inside the collaboration window."),
  ])
}

/// A git object that failed to load: prefer the specific recovery message when
/// one was captured, otherwise the tab's own hint.
fn view_git_load_error(model: Model, fallback: String) -> Element(Msg) {
  p([attribute.role("alert")], [
    text(option.unwrap(model.git_error, fallback)),
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
          "ref seq "
          <> int.to_string(d.reference_sequence_number)
          <> " · min seq "
          <> int.to_string(d.minimum_sequence_number),
        ),
      ]),
    ]),
    case d.contents {
      "" -> element.none()
      contents ->
        div([class("op-contents")], [pre([], [code([], [text(contents)])])])
    },
  ])
}

// --- Summaries tab ---

fn view_summaries(model: Model) -> Element(Msg) {
  div([class("card")], [
    h2([], [text("Summaries")]),
    case model.summaries {
      [] ->
        case model.summaries_error, model.summaries_loading {
          Some(message), _ -> view_op_error(Some(message))
          None, True ->
            p([attribute.role("status")], [text("Loading summaries...")])
          None, False ->
            p([class("text-muted")], [
              text(
                "No summaries yet. Summaries appear once the document is snapshotted.",
              ),
            ])
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
      button([class("sha-link sha-button mono"), event.on_click(ViewTree(s))], [
        text(short_sha(s)),
      ])
  }
}

fn view_sha_link_commit(sha: Option(String)) -> Element(Msg) {
  case sha {
    None -> text("-")
    Some(s) ->
      button(
        [class("sha-link sha-button mono"), event.on_click(ViewCommit(s))],
        [
          text(short_sha(s)),
        ],
      )
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
        case model.refs_error, model.refs_loading {
          Some(message), _ -> view_op_error(Some(message))
          None, True -> p([attribute.role("status")], [text("Loading refs...")])
          None, False ->
            p([class("text-muted")], [
              text(
                "No refs yet. Refs point to the latest summary once one exists.",
              ),
            ])
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
                  button(
                    [
                      class("sha-link sha-button mono"),
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
                True -> p([attribute.role("status")], [text("Loading blob...")])
                False ->
                  view_git_load_error(
                    model,
                    "Couldn't load this blob. Try the link again.",
                  )
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
                True -> p([attribute.role("status")], [text("Loading tree...")])
                False ->
                  view_git_load_error(
                    model,
                    "Couldn't load this tree. Try the link again.",
                  )
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
                              button(
                                [
                                  class("sha-link sha-button mono"),
                                  event.on_click(ViewTree(entry.sha)),
                                ],
                                [text(short_sha(entry.sha))],
                              )
                            "blob" ->
                              button(
                                [
                                  class("sha-link sha-button mono"),
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
                True ->
                  p([attribute.role("status")], [text("Loading commit...")])
                False ->
                  view_git_load_error(
                    model,
                    "Couldn't load this commit. Try the link again.",
                  )
              }
            Some(c) ->
              div([class("git-object")], [
                div([class("detail-row")], [
                  span([class("detail-label")], [text("SHA")]),
                  span([class("detail-value mono")], [text(c.sha)]),
                ]),
                div([class("detail-row")], [
                  span([class("detail-label")], [text("Tree")]),
                  button(
                    [
                      class("sha-link sha-button mono"),
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
                        button(
                          [
                            class("sha-link sha-button mono"),
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
