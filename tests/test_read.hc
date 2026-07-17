// test_read.hc — in-process tests for all read-only GET routes.
//
// Routes are dispatched through build_routes with the http test client
// (no socket), backed by a seeded in-memory SQLite database.
//
// Run:  hica test tests/test_read.hc

import "../src/routes"
import "testclient"
import "./fixtures"

// ── GET /health ──────────────────────────────────────────────────────────────

test "GET /health returns 200 ok" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/health")
  assert(route_response_status(r) == 200)
  assert(route_response_body(r) == "ok")
}

// ── GET /api/v1/index ────────────────────────────────────────────────────────

test "GET /api/v1/index lists every package with its latest non-yanked version" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/index")
  assert(route_response_status(r) == 200)
  let body = route_response_body(r)
  assert(contains(body, "\"name\": \"json\""))
  assert(contains(body, "\"latest\": \"0.2.0\""))
  assert(contains(body, "\"name\": \"sqlite\""))
  assert(contains(body, "\"latest\": \"0.4.0\""))
}

// ── GET /api/v1/search ───────────────────────────────────────────────────────

test "GET /api/v1/search?q=json finds the json package by name" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/search?q=json")
  assert(route_response_status(r) == 200)
  assert(contains(route_response_body(r), "\"name\": \"json\""))
}

test "GET /api/v1/search matches on description text" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/search?q=wrapper")
  assert(route_response_status(r) == 200)
  assert(contains(route_response_body(r), "\"name\": \"sqlite\""))
}

test "GET /api/v1/search without q returns 400" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/search")
  assert(route_response_status(r) == 400)
}

// ── GET /api/v1/packages/{name} ───────────────────────────────────────────────

test "GET /api/v1/packages/\{name\} returns detail with the newest active latest" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/packages/json")
  assert(route_response_status(r) == 200)
  let body = route_response_body(r)
  assert(contains(body, "\"latest\": \"0.2.0\""))
  assert(contains(body, "\"repository\": \"https://github.com/cladam/hica\""))
}

test "GET /api/v1/packages/\{name\} still lists a yanked version with yanked=true" {
  let db = fresh_seeded()
  let body = route_response_body(test_get(build_routes(db), "/api/v1/packages/json"))
  assert(contains(body, "\"version\": \"0.3.0\""))
  assert(contains(body, "\"yanked\": true"))
}

test "GET /api/v1/packages/\{name\} returns 404 for an unknown package" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/packages/nonesuch")
  assert(route_response_status(r) == 404)
}

// ── GET /api/v1/packages/{name}/{version} ─────────────────────────────────────

test "GET /api/v1/packages/\{name\}/\{version\} returns version metadata and download URL" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/packages/json/0.2.0")
  assert(route_response_status(r) == 200)
  let body = route_response_body(r)
  assert(contains(body, "\"version\": \"0.2.0\""))
  assert(contains(body, "\"checksum\": \"sha256:bbb\""))
  assert(contains(body, "\"download\": \"https://pkg.hica.dev/api/v1/packages/json/0.2.0/download\""))
}

test "GET /api/v1/packages/\{name\}/\{version\} returns 404 for an unknown version" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/packages/json/9.9.9")
  assert(route_response_status(r) == 404)
}

// ── GET /api/v1/packages/{name}/{version}/download ────────────────────────────

test "download redirects to the canonical tarball URL" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/packages/json/0.2.0/download")
  assert(route_response_status(r) == 302)
  assert(contains(route_response_headers(r), "https://pkg.hica.dev/json/json-0.2.0.tar.gz"))
}

test "a yanked version is still downloadable for reproducibility" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/packages/json/0.3.0/download")
  assert(route_response_status(r) == 302)
}

test "download returns 404 for an unknown version" {
  let db = fresh_seeded()
  let r = test_get(build_routes(db), "/api/v1/packages/json/9.9.9/download")
  assert(route_response_status(r) == 404)
}
