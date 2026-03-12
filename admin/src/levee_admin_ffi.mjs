import { Some, None } from "../gleam_stdlib/gleam/option.mjs";

const TOKEN_KEY = "levee_admin:session_token";

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
