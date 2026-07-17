// test_publish.hc — in-process tests for the authenticated PUT publish route.
//
// The multipart body is parsed by libmicrohttpd's post-processor (live server
// only), so the full happy path is exercised via curl. Here we cover every
// early-return branch reachable in-process: 401 (missing/wrong token) and 400
// (traversal guard, missing metadata part on any non-multipart PUT).
//
// Run:  hica test tests/test_publish.hc

import "../src/routes"
import "testclient"
import "./fixtures"

// ── PUT /api/v1/packages/{name}/{version} ─────────────────────────────────────

test "PUT without an Authorization header returns 401" {
  let db = fresh_with_auth()
  let r = test_request(build_routes(db), "PUT",
            "/api/v1/packages/mylib/1.0.0", "", "")
  assert(route_response_status(r) == 401)
}

test "PUT with a wrong Bearer token returns 401" {
  let db = fresh_with_auth()
  let r = test_request(build_routes(db), "PUT",
            "/api/v1/packages/mylib/1.0.0",
            "Authorization: Bearer wrong-token\n", "")
  assert(route_response_status(r) == 401)
}

test "PUT with the correct token passes auth and reaches multipart parsing" {
  let db = fresh_with_auth()
  let r = test_request(build_routes(db), "PUT",
            "/api/v1/packages/mylib/1.0.0",
            "Authorization: Bearer hica-admin-CHANGEME\n", "")
  // No multipart body => missing 'metadata' part => 400 (not 401)
  assert(route_response_status(r) == 400)
  assert(contains(route_response_body(r), "metadata"))
}

test "PUT with .. in the package name is rejected before touching disk" {
  let db = fresh_with_auth()
  let r = test_request(build_routes(db), "PUT",
            "/api/v1/packages/my..lib/1.0.0",
            "Authorization: Bearer hica-admin-CHANGEME\n", "")
  assert(route_response_status(r) == 400)
  assert(contains(route_response_body(r), "invalid"))
}

test "PUT with .. in the version is rejected before touching disk" {
  let db = fresh_with_auth()
  let r = test_request(build_routes(db), "PUT",
            "/api/v1/packages/mylib/1..0",
            "Authorization: Bearer hica-admin-CHANGEME\n", "")
  assert(route_response_status(r) == 400)
  assert(contains(route_response_body(r), "invalid"))
}
