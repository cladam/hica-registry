// main.hc — hica package registry server (Phase 1).
//
// A small JSON API over SQLite, built on the http (server), json, and sqlite
// libraries. Read endpoints plus a multipart publish endpoint. Auth, checksum
// verification, yank, and tarball storage are intentionally left as TODOs to
// iterate on later (see documentation/hica-registry-server.md in the compiler
// repo for the full design).
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
import "multipart"
import "json"
import "sqlite"
import "./db"

// ---------------------------------------------------------------------------
// JSON row encoders
// ---------------------------------------------------------------------------

fun version_json(r: Row) : Json {
  JObject([
    ("version",  JString(sopt(row_str(r, 0)))),
    ("checksum", JString(sopt(row_str(r, 1)))),
    ("yanked",   JBool(iopt(row_int(r, 2)) != 0))
  ])
}

// The newest non-yanked version string, or "" if none. Rows arrive newest-first.
fun first_active(rows: list<Row>) : string {
  match rows {
    [] => "",
    [r, ..rest] =>
      if iopt(row_int(r, 2)) == 0 {
        sopt(row_str(r, 0))
      } else {
        first_active(rest)
      }
  }
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

fun handle_health(req) {
  text_response("ok")
}

fun handle_index(db, req) {
  match sqlite_query_p(db,
          "SELECT p.name, " +
          "  (SELECT v.version FROM versions v WHERE v.package_id = p.id " +
          "   AND v.yanked = 0 ORDER BY v.published_at DESC, v.id DESC LIMIT 1) " +
          "FROM packages p ORDER BY p.name", []) {
    Err(e)  => error_response(e.message),
    Ok(res) => {
      let pkgs = map(res.rows, (r) => JObject([
        ("name",   JString(sopt(row_str(r, 0)))),
        ("latest", JString(sopt(row_str(r, 1))))
      ]))
      json_response(json_emit(JObject([("packages", JArray(pkgs))])))
    }
  }
}

fun handle_search(db, req) {
  match query_str(req, "q") {
    None => status_response(400, "missing query parameter 'q'"),
    Some(q) => {
      let like = "%" + q + "%"
      match sqlite_query_p(db,
              "SELECT p.name, p.description, " +
              "  (SELECT v.version FROM versions v WHERE v.package_id = p.id " +
              "   AND v.yanked = 0 ORDER BY v.published_at DESC, v.id DESC LIMIT 1) " +
              "FROM packages p WHERE p.name LIKE ? OR p.description LIKE ? " +
              "ORDER BY p.name LIMIT 25", [param(like), param(like)]) {
        Err(e)  => error_response(e.message),
        Ok(res) => {
          let results = map(res.rows, (r) => JObject([
            ("name",        JString(sopt(row_str(r, 0)))),
            ("description", JString(sopt(row_str(r, 1)))),
            ("version",     JString(sopt(row_str(r, 2))))
          ]))
          json_response(json_emit(JObject([
            ("query",   JString(q)),
            ("results", JArray(results))
          ])))
        }
      }
    }
  }
}

fun handle_get_package(db, req) {
  let name = path_str(req, "name")
  match sqlite_query_p(db,
          "SELECT name, description, repository, license FROM packages " +
          "WHERE name = ?", [param(name)]) {
    Err(e)   => error_response(e.message),
    Ok(pres) => match pres.rows {
      [] => not_found_response(),
      [prow, ..rest] =>
        match sqlite_query_p(db,
                "SELECT v.version, v.checksum, v.yanked FROM versions v " +
                "JOIN packages p ON p.id = v.package_id " +
                "WHERE p.name = ? ORDER BY v.published_at DESC, v.id DESC", [param(name)]) {
          Err(e)   => error_response(e.message),
          Ok(vres) => {
            let versions = map(vres.rows, version_json)
            json_response(json_emit(JObject([
              ("name",        JString(sopt(row_str(prow, 0)))),
              ("description", JString(sopt(row_str(prow, 1)))),
              ("repository",  JString(sopt(row_str(prow, 2)))),
              ("license",     JString(sopt(row_str(prow, 3)))),
              ("latest",      JString(first_active(vres.rows))),
              ("versions",    JArray(versions))
            ])))
          }
        }
    }
  }
}

// Publish a version. Multipart: a JSON `metadata` part and a binary `tarball`
// part. TODO: authenticate the caller, verify sha256(tarball) == checksum, and
// persist the tarball bytes to a store.
fun handle_publish(db, req) {
  let name = path_str(req, "name")
  let ver  = path_str(req, "version")
  match req_part(req, "metadata") {
    None => status_response(400, "missing 'metadata' part"),
    Some(meta) => match req_part(req, "tarball") {
      None => status_response(400, "missing 'tarball' part"),
      Some(tar) => {
        let mdoc = json_ok(parse_json(meta.bytes))
        let desc = str_or(mdoc |> at("description"), "")
        let repo = str_or(mdoc |> at("repository"), "")
        let lic  = str_or(mdoc |> at("license"), "")
        let sum  = str_or(mdoc |> at("checksum"), "")
        let _ = sqlite_exec_p(db,
                  "INSERT OR IGNORE INTO packages(name, description, repository, license) " +
                  "VALUES (?, ?, ?, ?)",
                  [param(name), param(desc), param(repo), param(lic)])
        match sqlite_exec_p(db,
                "INSERT INTO versions(package_id, version, checksum) " +
                "VALUES ((SELECT id FROM packages WHERE name = ?), ?, ?)",
                [param(name), param(ver), param(sum)]) {
          Err(e) => status_response(409,
            "could not publish " + name + "@" + ver + " (already exists?): " + e.message),
          Ok(_) => json_response(json_emit(JObject([
            ("ok",            JBool(true)),
            ("package",       JString(name)),
            ("version",       JString(ver)),
            ("tarball_bytes", JInt(length(tar.bytes)))
          ])))
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

fun main() {
  match sqlite_open("registry.db") {
    Err(e) => println("failed to open database: " + e.message),
    Ok(db) => {
      init_db(db)
      println("hica-registry listening on http://localhost:8080")
      serve_routes(8080, [
        get("/health",                              handle_health),
        get("/api/v1/index",                        (req) => handle_index(db, req)),
        get("/api/v1/search",                       (req) => handle_search(db, req)),
        get("/api/v1/packages/\{name\}",              (req) => handle_get_package(db, req)),
        put("/api/v1/packages/\{name\}/\{version\}",    (req) => handle_publish(db, req))
      ])
    }
  }
}
