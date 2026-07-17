// test_yank.hc — in-process tests for the yank and unyank endpoints.
//
// DELETE /api/v1/packages/{name}/{version}/yank  — hides a version from resolution
// PUT    /api/v1/packages/{name}/{version}/unyank — restores a yanked version
//
// Both require a valid Bearer token. Yanked versions remain downloadable so
// existing builds stay reproducible; they are only excluded from `latest`.
//
// Run:  hica test tests/test_yank.hc

import "../src/routes"
import "testclient"
import "./fixtures"

// ── DELETE …/yank — auth guard ────────────────────────────────────────────────

test "DELETE yank without an Authorization header returns 401" {
  let db = fresh_with_auth()
  let r = test_delete(build_routes(db), "/api/v1/packages/json/0.2.0/yank")
  assert(route_response_status(r) == 401)
}

test "DELETE yank with a wrong Bearer token returns 401" {
  let db = fresh_with_auth()
  let r = test_request(build_routes(db), "DELETE",
            "/api/v1/packages/json/0.2.0/yank",
            "Authorization: Bearer wrong-token\n", "")
  assert(route_response_status(r) == 401)
}

// ── DELETE …/yank — happy path ────────────────────────────────────────────────

test "DELETE yank of a known version returns 200 with yanked=true" {
  let db = fresh_with_auth()
  let r = test_request(build_routes(db), "DELETE",
            "/api/v1/packages/json/0.2.0/yank",
            "Authorization: Bearer hica-admin-CHANGEME\n", "")
  assert(route_response_status(r) == 200)
  let body = route_response_body(r)
  assert(contains(body, "\"ok\": true"))
  assert(contains(body, "\"yanked\": true"))
}

test "DELETE yank of an unknown version returns 404" {
  let db = fresh_with_auth()
  let r = test_request(build_routes(db), "DELETE",
            "/api/v1/packages/json/9.9.9/yank",
            "Authorization: Bearer hica-admin-CHANGEME\n", "")
  assert(route_response_status(r) == 404)
}

test "yanking the latest version excludes it from package latest" {
  let db = fresh_with_auth()
  let _ = test_request(build_routes(db), "DELETE",
            "/api/v1/packages/json/0.2.0/yank",
            "Authorization: Bearer hica-admin-CHANGEME\n", "")
  let body = route_response_body(test_get(build_routes(db), "/api/v1/packages/json"))
  // 0.2.0 yanked → latest falls back to 0.1.0
  assert(contains(body, "\"latest\": \"0.1.0\""))
}

test "yank sets yanked=true in the version detail response" {
  let db = fresh_with_auth()
  let _ = test_request(build_routes(db), "DELETE",
            "/api/v1/packages/json/0.2.0/yank",
            "Authorization: Bearer hica-admin-CHANGEME\n", "")
  let body = route_response_body(test_get(build_routes(db), "/api/v1/packages/json/0.2.0"))
  assert(contains(body, "\"yanked\": true"))
}

// ── PUT …/unyank — auth guard ────────────────────────────────────────────────

test "PUT unyank without an Authorization header returns 401" {
  let db = fresh_with_auth()
  let r = test_request(build_routes(db), "PUT",
            "/api/v1/packages/json/0.3.0/unyank", "", "")
  assert(route_response_status(r) == 401)
}

// ── PUT …/unyank — happy path ─────────────────────────────────────────────────

test "PUT unyank of a yanked version returns 200 with yanked=false" {
  let db = fresh_with_auth()
  let r = test_request(build_routes(db), "PUT",
            "/api/v1/packages/json/0.3.0/unyank",
            "Authorization: Bearer hica-admin-CHANGEME\n", "")
  assert(route_response_status(r) == 200)
  let body = route_response_body(r)
  assert(contains(body, "\"ok\": true"))
  assert(contains(body, "\"yanked\": false"))
}

test "PUT unyank of an unknown version returns 404" {
  let db = fresh_with_auth()
  let r = test_request(build_routes(db), "PUT",
            "/api/v1/packages/json/9.9.9/unyank",
            "Authorization: Bearer hica-admin-CHANGEME\n", "")
  assert(route_response_status(r) == 404)
}

test "unyank restores the version as the package latest" {
  let db = fresh_with_auth()
  // fixture: json latest=0.2.0; 0.3.0 is yanked
  // unyank 0.3.0 → it is newer so it becomes latest
  let _ = test_request(build_routes(db), "PUT",
            "/api/v1/packages/json/0.3.0/unyank",
            "Authorization: Bearer hica-admin-CHANGEME\n", "")
  let body = route_response_body(test_get(build_routes(db), "/api/v1/packages/json"))
  assert(contains(body, "\"latest\": \"0.3.0\""))
}
