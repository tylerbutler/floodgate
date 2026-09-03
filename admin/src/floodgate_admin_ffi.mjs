import { Some, None } from "../gleam_stdlib/gleam/option.mjs";

const TOKEN_KEY = "floodgate_admin:session_token";

export function get_query_param(name) {
  const params = new URLSearchParams(window.location.search);
  const value = params.get(name);
  if (value) {
    return new Some(value);
  }
  return new None();
}

export function navigate_to(url) {
  window.location.href = url;
}

export function get_origin() {
  return window.location.origin;
}

export function set_document_title(title) {
  document.title = title;
}

// Move keyboard focus to an element after the next paint, so the target exists
// once Lustre has committed the new view (used by the document tab pattern).
export function focus_element(id) {
  requestAnimationFrame(() => {
    const el = document.getElementById(id);
    if (el) {
      el.focus();
    }
  });
}

export function get_current_path() {
  return window.location.pathname;
}

export function save_token(token) {
  try {
    localStorage.setItem(TOKEN_KEY, token);
  } catch (_) {
    // localStorage may be unavailable (private browsing, etc.)
  }
}

export function load_token() {
  try {
    const value = localStorage.getItem(TOKEN_KEY);
    if (value) {
      return new Some(value);
    }
  } catch (_) {
    // localStorage may be unavailable
  }
  return new None();
}

export function clear_token() {
  try {
    localStorage.removeItem(TOKEN_KEY);
  } catch (_) {
    // localStorage may be unavailable
  }
}

export function copy_to_clipboard(value, callback) {
  if (!navigator.clipboard?.writeText) {
    callback(false);
    return;
  }

  navigator.clipboard.writeText(value).then(
    () => callback(true),
    () => callback(false),
  );
}
