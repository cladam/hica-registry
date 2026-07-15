// main.hc — hica package registry server (Phase 1).
//
// Thin entry point: open the database, ensure the schema, and serve the routes
// defined in routes.hc. The handlers and route table live in routes.hc so they
// can be unit-tested in-process (see tests/test_registry.hc). See
// documentation/hica-registry-server.md in the compiler repo for the full design.
//
// Endpoints:
//   GET  /health
//   GET  /api/v1/index                          list all packages + latest
//   GET  /api/v1/search?q=<term>                substring search
//   GET  /api/v1/packages/{name}               package detail + versions
//   PUT  /api/v1/packages/{name}/{version}     publish (multipart)
//
// Run:
//   hica run src/main.hc
// Test:
//   curl localhost:8080/health
//   curl localhost:8080/api/v1/index
//   curl -X PUT localhost:8080/api/v1/packages/json/0.1.0 \
//        -F metadata='{"description":"JSON parser","license":"MIT","checksum":"sha256:abc"}' \
//        -F tarball=@json-0.1.0.tar.gz
//   curl localhost:8080/api/v1/packages/json
//   curl "localhost:8080/api/v1/search?q=json"

import "web"
import "sqlite"
import "./db"
import "./routes"

fun main() {
  match sqlite_open("registry.db") {
    Err(e) => println("failed to open database: " + e.message),
    Ok(db) => {
      init_db(db)
      println("hica-registry listening on http://localhost:8080")
      serve_routes(8080, build_routes(db))
    }
  }
}
