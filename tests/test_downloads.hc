// test_downloads.hc — tests for the per-version download counter.
//
// Each GET …/download increments a counter stored in the downloads table.
// The count is surfaced in both the single-version and package-detail responses.
//
// Run:  hica test tests/test_downloads.hc

import "../src/routes"
import "testclient"
import "./fixtures"

// ── Download counter ──────────────────────────────────────────────────────────

test "a fresh version reports downloads=0 in version detail" {
  let db = fresh_seeded()
  let body = route_response_body(test_get(build_routes(db), "/api/v1/packages/json/0.2.0"))
  assert(contains(body, "\"downloads\": 0"))
}

test "one download increments the counter to 1" {
  let db = fresh_seeded()
  let _ = test_get(build_routes(db), "/api/v1/packages/json/0.2.0/download")
  let body = route_response_body(test_get(build_routes(db), "/api/v1/packages/json/0.2.0"))
  assert(contains(body, "\"downloads\": 1"))
}

test "download counter accumulates across multiple hits" {
  let db = fresh_seeded()
  let _ = test_get(build_routes(db), "/api/v1/packages/json/0.2.0/download")
  let _ = test_get(build_routes(db), "/api/v1/packages/json/0.2.0/download")
  let _ = test_get(build_routes(db), "/api/v1/packages/json/0.2.0/download")
  let body = route_response_body(test_get(build_routes(db), "/api/v1/packages/json/0.2.0"))
  assert(contains(body, "\"downloads\": 3"))
}

test "download count is visible in the package detail versions list" {
  let db = fresh_seeded()
  let _ = test_get(build_routes(db), "/api/v1/packages/json/0.2.0/download")
  let body = route_response_body(test_get(build_routes(db), "/api/v1/packages/json"))
  assert(contains(body, "\"downloads\": 1"))
}
