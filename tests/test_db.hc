// test_db.hc — unit tests for database helpers and auth primitives.
//
// Covers db.hc (sopt, iopt, init_db, upgrade_db, seed_admin_token, schema
// constraints) and auth.hc (sha256_str). No HTTP layer involved.
//
// Run:  hica test tests/test_db.hc

import "../src/db"
import "../src/auth"
import "sqlite"

// ── db.hc helpers (pure) ────────────────────────────────────────────────────

test "sopt returns the string inside Some" {
  assert(sopt(Some("hello")) == "hello")
}

test "sopt returns empty string for None" {
  assert(sopt(None) == "")
}

test "iopt returns the int inside Some" {
  assert(iopt(Some(7)) == 7)
}

test "iopt returns 0 for None" {
  assert(iopt(None) == 0)
}

// ── Schema / bootstrap ──────────────────────────────────────────────────────

test "init_db is idempotent — second call is a no-op" {
  let db = unwrap(sqlite_open(":memory:"))
  init_db(db)
  init_db(db)
  let r = sqlite_query(db, "SELECT count(*) FROM packages")
  assert(is_ok(r))
}

test "UNIQUE(package_id, version) rejects a duplicate publish" {
  let db = unwrap(sqlite_open(":memory:"))
  init_db(db)
  let _ = sqlite_exec_p(db,
    "INSERT INTO packages(name, description, repository, license) VALUES (?, ?, ?, ?)",
    [param("json"), param("A JSON parser and emitter"), param(""), param("MIT")])
  let _ = sqlite_exec_p(db,
    "INSERT INTO versions(package_id, version, checksum) VALUES ((SELECT id FROM packages WHERE name = ?), ?, ?)",
    [param("json"), param("0.1.0"), param("sha256:aaa")])
  let dup = sqlite_exec_p(db,
    "INSERT INTO versions(package_id, version) VALUES ((SELECT id FROM packages WHERE name = ?), ?)",
    [param("json"), param("0.1.0")])
  assert(is_err(dup))
}

// ── upgrade_db ───────────────────────────────────────────────────────────────

test "upgrade_db is idempotent on a fresh schema" {
  let db = unwrap(sqlite_open(":memory:"))
  init_db(db)
  upgrade_db(db)
  upgrade_db(db)
  let r = sqlite_query(db, "SELECT COUNT(*) FROM versions")
  assert(is_ok(r))
}

// ── seed_admin_token ─────────────────────────────────────────────────────────

test "seed_admin_token inserts exactly one user and one token" {
  let db = unwrap(sqlite_open(":memory:"))
  init_db(db)
  seed_admin_token(db)
  match sqlite_query(db, "SELECT COUNT(*) FROM users") {
    Err(_)  => assert(false),
    Ok(res) => match res.rows {
      [row, ..] => assert(iopt(row_int(row, 0)) == 1),
      _         => assert(false)
    }
  }
}

test "seed_admin_token is idempotent — a second call does not add rows" {
  let db = unwrap(sqlite_open(":memory:"))
  init_db(db)
  seed_admin_token(db)
  seed_admin_token(db)
  match sqlite_query(db, "SELECT COUNT(*) FROM tokens") {
    Err(_)  => assert(false),
    Ok(res) => match res.rows {
      [row, ..] => assert(iopt(row_int(row, 0)) == 1),
      _         => assert(false)
    }
  }
}

// ── auth.hc — sha256_str ─────────────────────────────────────────────────────

// SHA-256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
// Both sha256sum (Linux) and shasum -a 256 (macOS) agree on this value.
test "sha256_str returns a prefixed hex digest for a known input" {
  match sha256_str("hello") {
    Err(_) => assert(false),
    Ok(h)  => assert(h == "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
  }
}
