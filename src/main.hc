// main.hc — hica package registry server (Phase 2).
//
// Thin entry point: open the database, ensure the schema, run upgrades and
// seed, then serve the routes defined in routes.hc.  The handlers and route
// table live in routes.hc so they can be unit-tested in-process (see
// tests/test_registry.hc).  See documentation/hica-registry-server.md in the
// compiler repo for the full design.
//
// Endpoints:
//   GET  /health
//   GET  /api/v1/index                          list all packages + latest
//   GET  /api/v1/search?q=<term>                substring search
//   GET  /api/v1/packages/{name}               package detail + versions
//   PUT  /api/v1/packages/{name}/{version}     publish (multipart, token auth)
//
// Run:
//   hica run src/main.hc
// Test (read endpoints, no auth):
//   curl localhost:8080/health
//   curl localhost:8080/api/v1/index
// Publish (requires Bearer token):
//   curl -X PUT localhost:8080/api/v1/packages/json/0.1.0 \
//        -H "Authorization: Bearer hica-admin-CHANGEME" \
//        -F metadata='{"description":"JSON parser","license":"MIT"}' \
//        -F tarball=@json-0.1.0.tar.gz

import "web"
import "sqlite"
import "./db"
import "./routes"

fun main() {
  match sqlite_open("registry.db") {
    Err(e) => println("failed to open database: " + e.message),
    Ok(db) => {
      init_db(db)
      upgrade_db(db)
      seed_admin_token(db)
      println("hica-registry listening on http://localhost:8080")
      serve_routes(8080, build_routes(db))
    }
  }
}
