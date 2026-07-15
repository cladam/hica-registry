// test_registry.hc — in-process tests for the hica registry.
//
// The read endpoints are dispatched straight through build_routes with the http
// test client (no socket), backed by a seeded in-memory SQLite database. The
// publish endpoint reads its multipart parts from the C layer (libmicrohttpd's
// post-processor), which only runs inside a live server, so it is exercised by
// curl against a running server rather than here; the UNIQUE(package_id,
// version) constraint that its 409 response relies on is tested at the DB level.
//
// Run:  hica test tests/test_registry.hc

import "../src/routes"
import "../src/db"
import "sqlite"
import "testclient"

// A fresh in-memory database with the schema applied and a small fixture:
//   json   — versions 0.1.0, 0.2.0, and a yanked 0.3.0  (latest = 0.2.0)
//   sqlite — version 0.4.0                                (latest = 0.4.0)
fun seed(db) {
  let _ = sqlite_exec_p(db,
    "INSERT INTO packages(name, description, repository, license) VALUES (?, ?, ?, ?)",
    [param("json"), param("A JSON parser and emitter"),
     param("https://github.com/cladam/hica"), param("MIT")])
  let _ = sqlite_exec_p(db,
    "INSERT INTO packages(name, description, repository, license) VALUES (?, ?, ?, ?)",
    [param("sqlite"), param("A SQLite3 wrapper"), param(""), param("MIT")])
  let _ = sqlite_exec_p(db,
    "INSERT INTO versions(package_id, version, checksum) VALUES ((SELECT id FROM packages WHERE name = ?), ?, ?)",
    [param("json"), param("0.1.0"), param("sha256:aaa")])
  let _ = sqlite_exec_p(db,
    "INSERT INTO versions(package_id, version, checksum) VALUES ((SELECT id FROM packages WHERE name = ?), ?, ?)",
    [param("json"), param("0.2.0"), param("sha256:bbb")])
  let _ = sqlite_exec_p(db,
    "INSERT INTO versions(package_id, version, checksum, yanked) VALUES ((SELECT id FROM packages WHERE name = ?), ?, ?, 1)",
    [param("json"), param("0.3.0"), param("sha256:ddd")])
  let _ = sqlite_exec_p(db,
    "INSERT INTO versions(package_id, version, checksum) VALUES ((SELECT id FROM packages WHERE name = ?), ?, ?)",
    [param("sqlite"), param("0.4.0"), param("sha256:ccc")])
  ()
}

fun fresh_seeded() {
  let db = unwrap(sqlite_open(":memory:"))
  init_db(db)
  seed(db)
  db
}

// ── db.hc helpers (pure) ────────────────────────────────────────────────────

test "sopt unwraps Some and defaults None to empty string" {
  assert(sopt(Some("hello")) == "hello")
  assert(sopt(None) == "")
}

test "iopt unwraps Some and defaults None to zero" {
  assert(iopt(Some(7)) == 7)
  assert(iopt(None) == 0)
}

// ── Schema / bootstrap ──────────────────────────────────────────────────────

test "init_db is idempotent" {
  let db = unwrap(sqlite_open(":memory:"))
  init_db(db)
  init_db(db)
  let r = sqlite_query(db, "SELECT count(*) FROM packages")
  assert(is_ok(r))
}

test "duplicate (package, version) is rejected by the schema" {
  let db = fresh_seeded()
  let dup = sqlite_exec_p(db,
    "INSERT INTO versions(package_id, version) VALUES ((SELECT id FROM packages WHERE name = ?), ?)",
    [param("json"), param("0.1.0")])
  assert(is_err(dup))
}

// ── GET /health ─────────────────────────────────────────────────────────────

test "GET /health returns 200 ok" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/health")
  assert(route_response_status(r) == 200)
  assert(route_response_body(r) == "ok")
}

// ── GET /api/v1/index ───────────────────────────────────────────────────────

test "GET /api/v1/index lists every package with its latest version" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/index")
  assert(route_response_status(r) == 200)
  let body = route_response_body(r)
  assert(contains(body, "\"name\": \"json\""))
  assert(contains(body, "\"latest\": \"0.2.0\""))
  assert(contains(body, "\"name\": \"sqlite\""))
  assert(contains(body, "\"latest\": \"0.4.0\""))
}

// ── GET /api/v1/search ──────────────────────────────────────────────────────

test "GET /api/v1/search?q=json finds the json package" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/search?q=json")
  assert(route_response_status(r) == 200)
  let body = route_response_body(r)
  assert(contains(body, "\"name\": \"json\""))
}

test "GET /api/v1/search matches on description text" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/search?q=wrapper")
  assert(route_response_status(r) == 200)
  let body = route_response_body(r)
  assert(contains(body, "\"name\": \"sqlite\""))
}

test "GET /api/v1/search without q is a 400" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/search")
  assert(route_response_status(r) == 400)
}

// ── GET /api/v1/packages/\{name\} ─────────────────────────────────────────────

test "GET /api/v1/packages/\{name\} returns detail with the newest active latest" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/packages/json")
  assert(route_response_status(r) == 200)
  let body = route_response_body(r)
  assert(contains(body, "\"latest\": \"0.2.0\""))
  assert(contains(body, "\"repository\": \"https://github.com/cladam/hica\""))
}

test "GET /api/v1/packages/\{name\} still lists a yanked version, flagged" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/packages/json")
  let body = route_response_body(r)
  assert(contains(body, "\"version\": \"0.3.0\""))
  assert(contains(body, "\"yanked\": true"))
}

test "GET /api/v1/packages/\{name\} for an unknown package is a 404" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/packages/nonesuch")
  assert(route_response_status(r) == 404)
}

// ── GET /api/v1/packages/\{name\}/\{version\} ───────────────────────────────────

test "GET /api/v1/packages/\{name\}/\{version\} returns single version metadata" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/packages/json/0.2.0")
  assert(route_response_status(r) == 200)
  let body = route_response_body(r)
  assert(contains(body, "\"version\": \"0.2.0\""))
  assert(contains(body, "\"checksum\": \"sha256:bbb\""))
  assert(contains(body, "\"download\": \"https://pkg.hica.dev/api/v1/packages/json/0.2.0/download\""))
}

test "GET /api/v1/packages/\{name\}/\{version\} for an unknown version is a 404" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/packages/json/9.9.9")
  assert(route_response_status(r) == 404)
}

// ── GET /api/v1/packages/\{name\}/\{version\}/download ───────────────────────────

test "download redirects to the tarball location" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/packages/json/0.2.0/download")
  assert(route_response_status(r) == 302)
  assert(contains(route_response_headers(r), "https://pkg.hica.dev/json/json-0.2.0.tar.gz"))
}

test "a yanked version is still downloadable" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/packages/json/0.3.0/download")
  assert(route_response_status(r) == 302)
}

test "download of an unknown version is a 404" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/packages/json/9.9.9/download")
  assert(route_response_status(r) == 404)
}
