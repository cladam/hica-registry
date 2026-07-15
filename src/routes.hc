// routes.hc — request handlers and route table for the hica registry.
//
// Kept separate from main.hc so the routes can be dispatched in-process by the
// http test client (see tests/test_registry.hc) without opening a socket.
// main.hc is a thin entry point that opens the database and calls build_routes.
//
// Endpoints:
//   GET  /health
//   GET  /api/v1/index                          list all packages + latest
//   GET  /api/v1/search?q=<term>                substring search
//   GET  /api/v1/packages/{name}               package detail + versions
//   PUT  /api/v1/packages/{name}/{version}     publish (multipart)

import "web"
import "multipart"
import "json"
import "sqlite"
import "./db"

// ---------------------------------------------------------------------------
// JSON row encoders
// ---------------------------------------------------------------------------

pub fun version_json(r: Row) : Json {
  JObject([
    ("version",  JString(sopt(row_str(r, 0)))),
    ("checksum", JString(sopt(row_str(r, 1)))),
    ("yanked",   JBool(iopt(row_int(r, 2)) != 0))
  ])
}

// The newest non-yanked version string, or "" if none. Rows arrive newest-first.
pub fun first_active(rows: list<Row>) : string {
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

pub fun handle_health(req) {
  text_response("ok")
}

pub fun handle_index(db, req) {
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

pub fun handle_search(db, req) {
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

pub fun handle_get_package(db, req) {
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
pub fun handle_publish(db, req) {
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
// Route table
// ---------------------------------------------------------------------------

// Build the registry's route table over an open database handle. Shared by the
// server (main.hc) and the in-process tests (tests/test_registry.hc).
pub fun build_routes(db) {
  [
    get("/health",                              handle_health),
    get("/api/v1/index",                        (req) => handle_index(db, req)),
    get("/api/v1/search",                       (req) => handle_search(db, req)),
    get("/api/v1/packages/\{name\}",              (req) => handle_get_package(db, req)),
    put("/api/v1/packages/\{name\}/\{version\}",    (req) => handle_publish(db, req))
  ]
}
