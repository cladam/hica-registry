// auth.hc — token authentication and SHA-256 helpers for the hica registry.
//
// Token model (Phase 2):
//   - Tokens are random strings; only their SHA-256 is stored in the DB.
//   - Requests authenticate via `Authorization: Bearer <token>`.
//   - check_auth(db, req) returns Some(user_id) on success, None on failure.
//
// SHA-256 strategy:
//   Hica has no bitwise operators, so we shell out:
//     sha256sum <file> 2>/dev/null || shasum -a 256 <file>
//   (sha256sum on Linux, shasum -a 256 on macOS — same output format)
//
//   For tarball integrity:   sha256_file(path) — hash a file already on disk.
//   For token verification:  sha256_str(s) — write to a private temp file, hash,
//                            remove.  The server is single-threaded; the fixed
//                            temp path /tmp/.hica_tok is safe.
//
// Dev seed token: "hica-admin-CHANGEME"
//   SHA-256: 1dcecf9f3ddef5bd408e09fe220f09ee23f97a5c306c4b4dac22fa30543de1a8
//   Change this before any production deployment.

import "web"
import "sqlite"

// ---------------------------------------------------------------------------
// Bearer token extraction
// ---------------------------------------------------------------------------

// Extract the raw token from `Authorization: Bearer <token>`.
// Returns None if the header is absent or not a Bearer scheme.
// req_header is case-insensitive and works on the router request type.
pub fun bearer_token(req) {
  match req_header(req, "authorization") {
    None => None,
    Some(v) =>
      if starts_with(v, "Bearer ") {
        Some(v[7:])
      } else {
        None
      }
  }
}

// ---------------------------------------------------------------------------
// SHA-256 helpers
// ---------------------------------------------------------------------------

// Compute the SHA-256 of an on-disk file.
// Returns "sha256:<64hexchars>" on success, Err(message) on failure.
// sha256sum (Linux) is tried first; shasum -a 256 (macOS) is the fallback.
pub fun sha256_file(path: string) {
  match exec("sha256sum " + path + " 2>/dev/null || shasum -a 256 " + path) {
    Err(e) => Err("sha256 failed: " + e),
    Ok(out) => {
      let line = trim(out)
      // Both tools emit "<64hex>  <filename>"; the hex is the first space-
      // delimited token (two-space separator means split on " " gives an
      // empty middle element, but the first element is still the 64-char hex).
      match split(line, " ") {
        [hex, ..] =>
          if str_length(hex) == 64 {
            Ok("sha256:" + hex)
          } else {
            Err("unexpected sha256 output: " + out)
          },
        _ => Err("unexpected sha256 output: " + out)
      }
    }
  }
}

// Hash an in-memory string via a private temp file.
// Writes to /tmp/.hica_tok, hashes it, removes immediately.
// The server is single-threaded; the fixed temp path /tmp/.hica_tok is safe.
pub fun sha256_str(s: string) {
  write_file("/tmp/.hica_tok", s)
  let r = sha256_file("/tmp/.hica_tok")
  let _ = exec("rm -f /tmp/.hica_tok")
  r
}

// ---------------------------------------------------------------------------
// Token verification
// ---------------------------------------------------------------------------

// Verify the Bearer token in `req` against the tokens table.
// Returns Some(user_id) on success, None if the token is absent or invalid.
// Also updates tokens.last_used_at on every successful check.
pub fun check_auth(db, req) {
  match bearer_token(req) {
    None => None,
    Some(tok) => match sha256_str(tok) {
      Err(_) => None,
      Ok(hash) =>
        match sqlite_query_p(db,
            "SELECT user_id FROM tokens WHERE token_hash = ?",
            [param(hash)]) {
          Err(_) => None,
          Ok(res) => match res.rows {
            [] => None,
            [r, ..] => {
              let uid = match row_int(r, 0) { Some(n) => n, None => 0 }
              let _ = sqlite_exec_p(db,
                "UPDATE tokens SET last_used_at = datetime('now') " +
                "WHERE token_hash = ?",
                [param(hash)])
              Some(uid)
            }
          }
        }
    }
  }
}
