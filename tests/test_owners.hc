// test_owners.hc — in-process tests for the owners endpoints.
//
// GET    /api/v1/packages/{name}/owners  — list owners (public)
// PUT    /api/v1/packages/{name}/owners  — add an owner (must be owner)
// DELETE /api/v1/packages/{name}/owners  — remove an owner (must be owner)
//
// Run:  hica test tests/test_owners.hc

import "../src/routes"
import "testclient"
import "sqlite"
import "./fixtures"

// ── GET …/owners — list ───────────────────────────────────────────────────────

test "GET owners of a known package returns 200 with owners list" {
  let db = fresh_with_owners()
  let r = test_get(build_routes(db), "/api/v1/packages/json/owners")
  assert(route_response_status(r) == 200)
  let body = route_response_body(r)
  assert(contains(body, "\"owners\""))
  assert(contains(body, "\"handle\": \"admin\""))
}

test "GET owners of an unknown package returns 404" {
  let db = fresh_with_owners()
  let r = test_get(build_routes(db), "/api/v1/packages/nope/owners")
  assert(route_response_status(r) == 404)
}

test "GET owners of a package with no owners returns empty list" {
  let db = fresh_with_auth()
  let r = test_get(build_routes(db), "/api/v1/packages/json/owners")
  assert(route_response_status(r) == 200)
  let body = route_response_body(r)
  assert(contains(body, "\"owners\": []"))
}

// ── PUT …/owners — add ────────────────────────────────────────────────────────

test "PUT owners without an Authorization header returns 401" {
  let db = fresh_with_owners()
  let r = test_request(build_routes(db), "PUT",
            "/api/v1/packages/json/owners", "",
            "\{\"handle\": \"admin\"\}")
  assert(route_response_status(r) == 401)
}

test "PUT owners with a wrong Bearer token returns 401" {
  let db = fresh_with_owners()
  let r = test_request(build_routes(db), "PUT",
            "/api/v1/packages/json/owners",
            "Authorization: Bearer wrong-token\n",
            "\{\"handle\": \"admin\"\}")
  assert(route_response_status(r) == 401)
}

test "PUT owners by a non-owner returns 403" {
  let db = fresh_with_owners()
  // Insert a second user who is NOT an owner of json
  let _ = sqlite_exec(db,
    "INSERT OR IGNORE INTO users(handle) VALUES ('other')")
  let _ = sqlite_exec(db, "INSERT OR IGNORE INTO tokens(user_id, name, token_hash) VALUES ((SELECT id FROM users WHERE handle = 'other'), 'tok', 'sha256:aaaa')")
  let r = test_request(build_routes(db), "PUT",
            "/api/v1/packages/json/owners",
            "Authorization: Bearer other-token\n",
            "\{\"handle\": \"admin\"\}")
  assert(route_response_status(r) == 401)
}

test "PUT owners on an unknown package returns 404" {
  let db = fresh_with_owners()
  let r = test_request(build_routes(db), "PUT",
            "/api/v1/packages/nope/owners",
            "Authorization: Bearer hica-admin-CHANGEME\n",
            "\{\"handle\": \"admin\"\}")
  assert(route_response_status(r) == 404)
}

test "PUT owners with an unknown handle returns 400" {
  let db = fresh_with_owners()
  let r = test_request(build_routes(db), "PUT",
            "/api/v1/packages/json/owners",
            "Authorization: Bearer hica-admin-CHANGEME\n",
            "\{\"handle\": \"ghost\"\}")
  assert(route_response_status(r) == 400)
}

test "PUT owners adds a new user as owner and returns 200" {
  let db = fresh_with_owners()
  let _ = sqlite_exec(db,
    "INSERT OR IGNORE INTO users(handle) VALUES ('alica')")
  let r = test_request(build_routes(db), "PUT",
            "/api/v1/packages/json/owners",
            "Authorization: Bearer hica-admin-CHANGEME\n",
            "\{\"handle\": \"alica\"\}")
  assert(route_response_status(r) == 200)
  let body = route_response_body(r)
  assert(contains(body, "\"ok\": true"))
  assert(contains(body, "\"handle\": \"alica\""))
}

test "PUT owners is idempotent — adding an existing owner again returns 200" {
  let db = fresh_with_owners()
  let r = test_request(build_routes(db), "PUT",
            "/api/v1/packages/json/owners",
            "Authorization: Bearer hica-admin-CHANGEME\n",
            "\{\"handle\": \"admin\"\}")
  assert(route_response_status(r) == 200)
}

test "GET owners lists the newly added owner" {
  let db = fresh_with_owners()
  let _ = sqlite_exec(db,
    "INSERT OR IGNORE INTO users(handle) VALUES ('alica')")
  let _ = test_request(build_routes(db), "PUT",
            "/api/v1/packages/json/owners",
            "Authorization: Bearer hica-admin-CHANGEME\n",
            "\{\"handle\": \"alica\"\}")
  let body = route_response_body(test_get(build_routes(db), "/api/v1/packages/json/owners"))
  assert(contains(body, "\"handle\": \"alica\""))
}

// ── DELETE …/owners — remove ──────────────────────────────────────────────────

test "DELETE owners without an Authorization header returns 401" {
  let db = fresh_with_owners()
  let r = test_request(build_routes(db), "DELETE",
            "/api/v1/packages/json/owners", "",
            "\{\"handle\": \"admin\"\}")
  assert(route_response_status(r) == 401)
}

test "DELETE owners on an unknown package returns 404" {
  let db = fresh_with_owners()
  let r = test_request(build_routes(db), "DELETE",
            "/api/v1/packages/nope/owners",
            "Authorization: Bearer hica-admin-CHANGEME\n",
            "\{\"handle\": \"admin\"\}")
  assert(route_response_status(r) == 404)
}

test "DELETE owners with an unknown handle returns 400" {
  let db = fresh_with_owners()
  let r = test_request(build_routes(db), "DELETE",
            "/api/v1/packages/json/owners",
            "Authorization: Bearer hica-admin-CHANGEME\n",
            "\{\"handle\": \"ghost\"\}")
  assert(route_response_status(r) == 400)
}

test "DELETE owners cannot remove the last owner — returns 400" {
  let db = fresh_with_owners()
  let r = test_request(build_routes(db), "DELETE",
            "/api/v1/packages/json/owners",
            "Authorization: Bearer hica-admin-CHANGEME\n",
            "\{\"handle\": \"admin\"\}")
  assert(route_response_status(r) == 400)
}

test "DELETE owners removes a co-owner and returns 200" {
  let db = fresh_with_owners()
  // Add alica as co-owner first
  let _ = sqlite_exec_p(db, "INSERT OR IGNORE INTO users(handle) VALUES ('alica')", [])
  let _ = sqlite_exec_p(db, "INSERT OR IGNORE INTO package_owners(package_id, user_id) VALUES ((SELECT id FROM packages WHERE name = 'json'), (SELECT id FROM users WHERE handle = 'alica'))", [])
  let r = test_request(build_routes(db), "DELETE",
            "/api/v1/packages/json/owners",
            "Authorization: Bearer hica-admin-CHANGEME\n",
            "\{\"handle\": \"alica\"\}")
  assert(route_response_status(r) == 200)
  let body = route_response_body(r)
  assert(contains(body, "\"ok\": true"))
  assert(contains(body, "\"handle\": \"alica\""))
}

test "GET owners no longer lists a removed owner" {
  let db = fresh_with_owners()
  let _ = sqlite_exec_p(db, "INSERT OR IGNORE INTO users(handle) VALUES ('alica')", [])
  let _ = sqlite_exec_p(db, "INSERT OR IGNORE INTO package_owners(package_id, user_id) VALUES ((SELECT id FROM packages WHERE name = 'json'), (SELECT id FROM users WHERE handle = 'alica'))", [])
  let _ = test_request(build_routes(db), "DELETE",
            "/api/v1/packages/json/owners",
            "Authorization: Bearer hica-admin-CHANGEME\n",
            "\{\"handle\": \"alica\"\}")
  let body = route_response_body(test_get(build_routes(db), "/api/v1/packages/json/owners"))
  assert(!contains(body, "\"handle\": \"alica\""))
}
