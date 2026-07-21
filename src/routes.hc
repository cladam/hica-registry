// routes.hc — request handlers and route table for the hica registry.
//
// Kept separate from main.hc so the routes can be dispatched in-process by the
// http test client (see tests/test_registry.hc) without opening a socket.
// main.hc is a thin entry point that opens the database and calls build_routes.
//
// Endpoints:
//   GET  /health
//   GET  /api/v1/index                          list all packages + latest
//   GET  /api/v1/summary                        registry-wide stats
//   GET  /api/v1/search?q=<term>                substring search
//   GET  /api/v1/packages/{name}               package detail + versions
//   GET  /api/v1/packages/{name}/{version}     single version metadata
//   GET  /api/v1/packages/{name}/{version}/download   redirect to the tarball
//   PUT  /api/v1/packages/{name}/{version}     publish (multipart)
//   DELETE /api/v1/packages/{name}/{version}/yank     hide a version from resolution
//   PUT  /api/v1/packages/{name}/{version}/unyank     restore a yanked version

import "web"
import "multipart"
import "json"
import "sqlite"
import "./db"
import "./auth"

// ---------------------------------------------------------------------------
// URL builders
// ---------------------------------------------------------------------------
// String concatenation only lowers to Koka's `++` when the operands have a
// known string type, so keep URL building inside `: string` helpers (same
// reason schema_sql in db.hc is annotated).

// Public download endpoint for a version (this server).
pub fun download_url(name: string, ver: string) : string {
  "https://pkg.hica.dev/api/v1/packages/" + name + "/" + ver + "/download"
}

// Canonical tarball location on the static host. Interim source until the
// publish flow persists tarball bytes into a real store (see handle_publish).
pub fun tarball_url(name: string, ver: string) : string {
  "https://pkg.hica.dev/" + name + "/" + name + "-" + ver + ".tar.gz"
}

// ---------------------------------------------------------------------------
// JSON row encoders
// ---------------------------------------------------------------------------

// Encode a summary list entry row.
// Columns expected: 0=name, 1=description, 2=latest_version, 3=total_downloads.
pub fun pkg_stub_json(r: Row) : Json {
  JObject([
    ("name",        JString(sopt(row_str(r, 0)))),
    ("description", JString(sopt(row_str(r, 1)))),
    ("version",     JString(sopt(row_str(r, 2)))),
    ("downloads",   JInt(iopt(row_int(r, 3))))
  ])
}

// Encode a (version, checksum, yanked) row plus the download URL for `name`.
pub fun version_json(name: string, r: Row) : Json {
  JObject([
    ("version",   JString(sopt(row_str(r, 0)))),
    ("checksum",  JString(sopt(row_str(r, 1)))),
    ("yanked",    JBool(iopt(row_int(r, 2)) != 0)),
    ("downloads", JInt(iopt(row_int(r, 3)))),
    ("download",  JString(download_url(name, sopt(row_str(r, 0)))))
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

pub fun handle_health(db, req) {
  match sqlite_query(db, "SELECT 1") {
    Ok(_)  => json_response(json_emit(JObject([
               ("status", JString("ok")),
               ("db",     JString("ok"))
             ]))),
    Err(e) => json_status(503, json_emit(JObject([
               ("status", JString("degraded")),
               ("db",     JString("error: " + e.message))
             ])))
  }
}

// GET /api/v1/summary — registry-wide stats:
//   num_packages, num_versions, num_downloads,
//   most_downloaded (top 5), new_packages (5 newest), just_updated (5 recently published).
pub fun handle_summary(db, req) {
  match sqlite_query_p(db,
          "SELECT (SELECT COUNT(*) FROM packages), " +
          "       (SELECT COUNT(*) FROM versions), " +
          "       (SELECT COALESCE(SUM(count), 0) FROM downloads)",
          []) {
    Err(e) => error_response(e.message),
    Ok(sr) => match sr.rows {
      [] => error_response("stats query returned no rows"),
      [srow, .._] => {
        let num_pkgs = iopt(row_int(srow, 0))
        let num_vers = iopt(row_int(srow, 1))
        let num_dl   = iopt(row_int(srow, 2))
        match sqlite_query_p(db,
                "SELECT p.name, p.description, " +
                "  (SELECT v.version FROM versions v WHERE v.package_id = p.id " +
                "   AND v.yanked = 0 ORDER BY v.published_at DESC, v.id DESC LIMIT 1), " +
                "  COALESCE(SUM(d.count), 0) " +
                "FROM packages p " +
                "LEFT JOIN versions v2 ON v2.package_id = p.id " +
                "LEFT JOIN downloads d ON d.version_id = v2.id " +
                "GROUP BY p.id, p.name, p.description " +
                "ORDER BY COALESCE(SUM(d.count), 0) DESC LIMIT 5",
                []) {
          Err(e) => error_response(e.message),
          Ok(dr) =>
            match sqlite_query_p(db,
                    "SELECT p.name, p.description, " +
                    "  (SELECT v.version FROM versions v WHERE v.package_id = p.id " +
                    "   AND v.yanked = 0 ORDER BY v.published_at DESC, v.id DESC LIMIT 1), " +
                    "  COALESCE((SELECT SUM(d2.count) FROM downloads d2 " +
                    "             JOIN versions v2 ON v2.id = d2.version_id " +
                    "             WHERE v2.package_id = p.id), 0) " +
                    "FROM packages p ORDER BY p.created_at DESC LIMIT 5",
                    []) {
              Err(e) => error_response(e.message),
              Ok(nr) =>
                match sqlite_query_p(db,
                        "SELECT p.name, p.description, " +
                        "  (SELECT v.version FROM versions v WHERE v.package_id = p.id " +
                        "   AND v.yanked = 0 ORDER BY v.published_at DESC, v.id DESC LIMIT 1), " +
                        "  COALESCE((SELECT SUM(d2.count) FROM downloads d2 " +
                        "             JOIN versions v2 ON v2.id = d2.version_id " +
                        "             WHERE v2.package_id = p.id), 0) " +
                        "FROM packages p " +
                        "ORDER BY (SELECT MAX(v.published_at) FROM versions v " +
                        "          WHERE v.package_id = p.id) DESC LIMIT 5",
                        []) {
                  Err(e) => error_response(e.message),
                  Ok(ur) => {
                    let most_dl  = map(dr.rows, (r) => pkg_stub_json(r))
                    let new_pkgs = map(nr.rows, (r) => pkg_stub_json(r))
                    let just_upd = map(ur.rows, (r) => pkg_stub_json(r))
                    json_response(json_emit(JObject([
                      ("num_packages",    JInt(num_pkgs)),
                      ("num_versions",    JInt(num_vers)),
                      ("num_downloads",   JInt(num_dl)),
                      ("most_downloaded", JArray(most_dl)),
                      ("new_packages",    JArray(new_pkgs)),
                      ("just_updated",    JArray(just_upd))
                    ])))
                  }
                }
            }
        }
      }
    }
  }
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

// Returns a safe ORDER BY fragment for the given sort key.
// Only values from a whitelist are returned, preventing SQL injection.
pub fun handle_search(db, req) {
  let q            = match query_str(req, "q") { None => "", Some(s) => s }
  let sort         = match query_str(req, "sort") { None => "name", Some(s) => s }
  let page_raw     = match query_int(req, "page") { None => 1, Some(n) => n }
  let per_page_raw = match query_int(req, "per_page") { None => 25, Some(n) => n }
  let page         = if page_raw < 1 { 1 } else { page_raw }
  let per_page     = if per_page_raw < 1 { 1 } else if per_page_raw > 100 { 100 } else { per_page_raw }
  let offset       = (page - 1) * per_page
  let like         = "%" + q + "%"
  let order : string = if sort == "downloads" { 
    "COALESCE((SELECT SUM(d.count) FROM downloads d JOIN versions v2 ON v2.id = d.version_id WHERE v2.package_id = p.id), 0) DESC" 
  } else if sort == "newest" { 
    "p.created_at DESC" 
  } else if sort == "updated" { 
    "COALESCE((SELECT MAX(v2.published_at) FROM versions v2 WHERE v2.package_id = p.id), p.created_at) DESC" 
  } else { 
    "p.name ASC" 
  }
  match sqlite_query_p(db,
          "SELECT COUNT(*) FROM packages p " +
          "WHERE p.name LIKE ? OR p.description LIKE ?",
          [param(like), param(like)]) {
    Err(e) => error_response(e.message),
    Ok(cres) => match cres.rows {
      [] => error_response("unexpected empty count result"),
      [crow, .._] => {
        let total = iopt(row_int(crow, 0))
        match sqlite_query_p(db,
                "SELECT p.name, p.description, " +
                "  (SELECT v.version FROM versions v WHERE v.package_id = p.id " +
                "   AND v.yanked = 0 ORDER BY v.published_at DESC, v.id DESC LIMIT 1) " +
                "FROM packages p WHERE p.name LIKE ? OR p.description LIKE ? " +
                "ORDER BY " + order + " LIMIT ? OFFSET ?",
                [param(like), param(like), param(show(per_page)), param(show(offset))]) {
          Err(e)  => error_response(e.message),
          Ok(res) => {
            let results = map(res.rows, (r) => JObject([
              ("name",        JString(sopt(row_str(r, 0)))),
              ("description", JString(sopt(row_str(r, 1)))),
              ("version",     JString(sopt(row_str(r, 2))))
            ]))
            json_response(json_emit(JObject([
              ("query",    JString(q)),
              ("sort",     JString(sort)),
              ("page",     JInt(page)),
              ("per_page", JInt(per_page)),
              ("total",    JInt(total)),
              ("results",  JArray(results))
            ])))
          }
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
                "SELECT v.version, v.checksum, v.yanked, COALESCE(d.count, 0) FROM versions v " +
                "JOIN packages p ON p.id = v.package_id " +
                "LEFT JOIN downloads d ON d.version_id = v.id " +
                "WHERE p.name = ? ORDER BY v.published_at DESC, v.id DESC", [param(name)]) {
          Err(e)   => error_response(e.message),
          Ok(vres) => {
            let versions = map(vres.rows, (r) => version_json(name, r))
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

// Publish a version.
//
// Authentication:  `Authorization: Bearer <token>` required; 401 on failure.
// Input:           Multipart with a JSON `metadata` part and a binary `tarball` part.
// Checksum:        sha256 of the uploaded tarball is always recomputed on disk.
//                  If the client declares a `checksum` in metadata it must match;
//                  the verified digest is what gets stored regardless.
// Persistence:     Tarball is written to HICA_TARBALL_DIR/<name>/<name>-<ver>.tar.gz
//                  (default dir: ./tarballs).  The directory is created if absent.
pub fun handle_publish(db, req, on_publish) {
  let name = path_str(req, "name")
  let ver  = path_str(req, "version")
  // 1. Authenticate ─────────────────────────────────────────────────────────
  match check_auth(db, req) {
    None => unauthorized("valid Bearer token required"),
    Some(user_id) =>
      // 2. Reject obviously dangerous name/version strings ──────────────────
      // (The router already strips '/' from path segments; guard against '..'
      // to prevent directory traversal in the tarball store.)
      if contains(name, "..") || contains(ver, "..") {
        status_response(400, "invalid package name or version")
      } else {
        // 3. Parse multipart parts ──────────────────────────────────────────
        match req_part(req, "metadata") {
          None => status_response(400, "missing 'metadata' part"),
          Some(meta) => match req_part(req, "tarball") {
            None => status_response(400, "missing 'tarball' part"),
            Some(tar) => {
              let mdoc    = json_ok(parse_json(meta.bytes))
              let desc    = str_or(mdoc |> at("description"), "")
              let repo    = str_or(mdoc |> at("repository"), "")
              let lic     = str_or(mdoc |> at("license"), "")
              let claimed = str_or(mdoc |> at("checksum"), "")

              // Validate ownership first!
              match sqlite_query_p(db,
                      "SELECT 1 FROM package_owners po " +
                      "JOIN packages p ON p.id = po.package_id " +
                      "WHERE p.name = ? AND po.user_id = ?",
                      [param(name), param(show(user_id))]) {
                Err(e) => error_response(e.message),
                Ok(ores) => {
                  let is_owner = match ores.rows {
                    [] => {
                      match sqlite_query_p(db, "SELECT 1 FROM packages WHERE name = ?", [param(name)]) {
                        Ok(p_res) => match p_res.rows {
                          [] => true,
                          _ => false
                        },
                        Err(_) => false
                      }
                    },
                    _ => true
                  }
                  if !is_owner {
                    forbidden("not an owner of '" + name + "'")
                  } else {
                    // Check if we are doing cooperative background publish or synchronous fallback
                    match on_publish {
                      Some(cb) => {
                        cb(name, ver, desc, repo, lic, claimed, tar.bytes, user_id)
                        accepted("\{\"status\": \"queued\", \"package\": \"" + name + "\", \"version\": \"" + ver + "\"\}")
                      },
                      None => {
                        let tdir  = match get_env("HICA_TARBALL_DIR") {
                          Some(d) => d,
                          None    => "./tarballs"
                        }
                        let pkg_dir = tdir + "/" + name
                        let tpath   = pkg_dir + "/" + name + "-" + ver + ".tar.gz"
                        match exec("mkdir -p " + pkg_dir) {
                          Err(e) => status_response(500, "could not create tarball dir: " + e),
                          Ok(_) => {
                            write_file(tpath, tar.bytes)
                            match sha256_file(tpath) {
                              Err(e) => status_response(500, "sha256 failed: " + e),
                              Ok(actual_sum) =>
                                if claimed != "" && claimed != actual_sum {
                                  status_response(400, "checksum mismatch: declared " + claimed + " but computed " + actual_sum)
                                } else {
                                  let _ = sqlite_exec_p(db,
                                    "INSERT OR IGNORE INTO packages(name, description, repository, license) " +
                                    "VALUES (?, ?, ?, ?)",
                                    [param(name), param(desc), param(repo), param(lic)])
                                  let _ = sqlite_exec_p(db,
                                    "INSERT OR IGNORE INTO package_owners(package_id, user_id) " +
                                    "SELECT p.id, ? FROM packages p " +
                                    "WHERE p.name = ? " +
                                    "AND NOT EXISTS (SELECT 1 FROM package_owners po WHERE po.package_id = p.id)",
                                    [param(show(user_id)), param(name)])
                                  match sqlite_exec_p(db,
                                      "INSERT INTO versions(package_id, version, checksum, tarball_path, published_by) " +
                                      "VALUES ((SELECT id FROM packages WHERE name = ?), ?, ?, ?, ?)",
                                      [param(name), param(ver), param(actual_sum), param(tpath), param(show(user_id))]) {
                                    Err(e) => status_response(409, "could not publish " + name + "@" + ver + " (already exists?): " + e.message),
                                    Ok(_) => json_response(json_emit(JObject([
                                      ("ok",            JBool(true)),
                                      ("package",       JString(name)),
                                      ("version",       JString(ver)),
                                      ("checksum",      JString(actual_sum)),
                                      ("tarball_path",  JString(tpath)),
                                      ("tarball_bytes", JInt(str_length(tar.bytes)))
                                    ])))
                                  }
                                }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
  }
}

// Single version metadata. 404 if the package or version is unknown.
pub fun handle_get_version(db, req) {
  let name = path_str(req, "name")
  let ver  = path_str(req, "version")
  match sqlite_query_p(db,
          "SELECT v.version, v.checksum, v.yanked, COALESCE(d.count, 0) FROM versions v " +
          "JOIN packages p ON p.id = v.package_id " +
          "LEFT JOIN downloads d ON d.version_id = v.id " +
          "WHERE p.name = ? AND v.version = ?", [param(name), param(ver)]) {
    Err(e)  => error_response(e.message),
    Ok(res) => match res.rows {
      []      => not_found_response(),
      [r, .._] => json_response(json_emit(version_json(name, r)))
    }
  }
}

// Download a version's tarball. Yanked versions stay downloadable so existing
// builds remain reproducible (yank only hides from resolution). 404 if the
// version is unknown. Each download increments the per-version counter in the
// downloads table.
pub fun handle_download(db, req) {
  let name = path_str(req, "name")
  let ver  = path_str(req, "version")
  match sqlite_query_p(db,
          "SELECT v.id FROM versions v " +
          "JOIN packages p ON p.id = v.package_id " +
          "WHERE p.name = ? AND v.version = ?", [param(name), param(ver)]) {
    Err(e)  => error_response(e.message),
    Ok(res) => match res.rows {
      []       => not_found_response(),
      [r, .._] => {
        let vid = iopt(row_int(r, 0))
        let _ = sqlite_exec_p(db,
          "INSERT INTO downloads(version_id, count) VALUES(?, 1) " +
          "ON CONFLICT(version_id) DO UPDATE SET count = count + 1",
          [param(show(vid))])
        redirect(tarball_url(name, ver))
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Route table
// ---------------------------------------------------------------------------

// Yank a version — hide it from resolution (authenticated). 404 if unknown.
// Yanked versions remain downloadable so existing builds stay reproducible.
pub fun handle_yank(db, req) {
  let name = path_str(req, "name")
  let ver  = path_str(req, "version")
  match check_auth(db, req) {
    None => unauthorized("valid Bearer token required"),
    Some(_) =>
      match sqlite_query_p(db,
              "SELECT v.id FROM versions v " +
              "JOIN packages p ON p.id = v.package_id " +
              "WHERE p.name = ? AND v.version = ?", [param(name), param(ver)]) {
        Err(e)   => error_response(e.message),
        Ok(res)  => match res.rows {
          [] => not_found_response(),
          [_, .._] =>
            match sqlite_exec_p(db,
                "UPDATE versions SET yanked = 1 " +
                "WHERE package_id = (SELECT id FROM packages WHERE name = ?) " +
                "AND version = ?", [param(name), param(ver)]) {
              Err(e) => error_response(e.message),
              Ok(_)  => json_response(json_emit(JObject([
                ("ok",      JBool(true)),
                ("package", JString(name)),
                ("version", JString(ver)),
                ("yanked",  JBool(true))
              ])))
            }
        }
      }
  }
}

// Unyank a version — restore it to resolution (authenticated). 404 if unknown.
pub fun handle_unyank(db, req) {
  let name = path_str(req, "name")
  let ver  = path_str(req, "version")
  match check_auth(db, req) {
    None => unauthorized("valid Bearer token required"),
    Some(_) =>
      match sqlite_query_p(db,
              "SELECT v.id FROM versions v " +
              "JOIN packages p ON p.id = v.package_id " +
              "WHERE p.name = ? AND v.version = ?", [param(name), param(ver)]) {
        Err(e)   => error_response(e.message),
        Ok(res)  => match res.rows {
          [] => not_found_response(),
          [_, .._] =>
            match sqlite_exec_p(db,
                "UPDATE versions SET yanked = 0 " +
                "WHERE package_id = (SELECT id FROM packages WHERE name = ?) " +
                "AND version = ?", [param(name), param(ver)]) {
              Err(e) => error_response(e.message),
              Ok(_)  => json_response(json_emit(JObject([
                ("ok",      JBool(true)),
                ("package", JString(name)),
                ("version", JString(ver)),
                ("yanked",  JBool(false))
              ])))
            }
        }
      }
  }
}

// ---------------------------------------------------------------------------
// Owners API
// ---------------------------------------------------------------------------

// GET /api/v1/packages/{name}/owners — list all owners of a package (public).
// Returns 404 if the package is unknown.
pub fun handle_list_owners(db, req) {
  let name = path_str(req, "name")
  match sqlite_query_p(db,
          "SELECT id FROM packages WHERE name = ?", [param(name)]) {
    Err(e) => error_response(e.message),
    Ok(pres) => match pres.rows {
      [] => not_found_response(),
      [_, .._] =>
        match sqlite_query_p(db,
                "SELECT u.handle FROM users u " +
                "JOIN package_owners o ON o.user_id = u.id " +
                "JOIN packages p ON p.id = o.package_id " +
                "WHERE p.name = ? ORDER BY u.handle", [param(name)]) {
          Err(e) => error_response(e.message),
          Ok(res) => {
            let owners = map(res.rows, (r) => JObject([("handle", JString(sopt(row_str(r, 0))))]))
            json_response(json_emit(JObject([("owners", JArray(owners))])))
          }
        }
    }
  }
}

// PUT /api/v1/packages/{name}/owners — add an owner (authenticated; must be owner).
// Body: JSON object with "handle" key naming an existing user.
pub fun handle_add_owner(db, req) {
  let name = path_str(req, "name")
  match check_auth(db, req) {
    None => unauthorized("valid Bearer token required"),
    Some(uid) =>
      match sqlite_query_p(db,
              "SELECT id FROM packages WHERE name = ?", [param(name)]) {
        Err(e) => error_response(e.message),
        Ok(pres) => match pres.rows {
          [] => not_found_response(),
          [prow, .._] => {
            let pkg_id = iopt(row_int(prow, 0))
            match sqlite_query_p(db,
                    "SELECT 1 FROM package_owners WHERE package_id = ? AND user_id = ?",
                    [param(show(pkg_id)), param(show(uid))]) {
              Err(e) => error_response(e.message),
              Ok(ores) => match ores.rows {
                [] => forbidden("not an owner of '" + name + "'"),
                [_, .._] => {
                  let bdoc   = json_ok(parse_json(req_body(req)))
                  let handle = str_or(bdoc |> at("handle"), "")
                  if handle == "" {
                    status_response(400, "missing 'handle' in request body")
                  } else {
                    match sqlite_query_p(db,
                            "SELECT id FROM users WHERE handle = ?", [param(handle)]) {
                      Err(e) => error_response(e.message),
                      Ok(ures) => match ures.rows {
                        [] => status_response(400, "user '" + handle + "' does not exist"),
                        [urow, .._] => {
                          let new_uid = iopt(row_int(urow, 0))
                          let _ = sqlite_exec_p(db,
                            "INSERT OR IGNORE INTO package_owners(package_id, user_id) VALUES (?, ?)",
                            [param(show(pkg_id)), param(show(new_uid))])
                          json_response(json_emit(JObject([
                            ("ok",      JBool(true)),
                            ("package", JString(name)),
                            ("handle",  JString(handle))
                          ])))
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
  }
}

// DELETE /api/v1/packages/{name}/owners — remove an owner (authenticated; must be owner).
// Body: JSON object with "handle" key. Cannot remove the last owner.
pub fun handle_remove_owner(db, req) {
  let name = path_str(req, "name")
  match check_auth(db, req) {
    None => unauthorized("valid Bearer token required"),
    Some(uid) =>
      match sqlite_query_p(db,
              "SELECT id FROM packages WHERE name = ?", [param(name)]) {
        Err(e) => error_response(e.message),
        Ok(pres) => match pres.rows {
          [] => not_found_response(),
          [prow, .._] => {
            let pkg_id = iopt(row_int(prow, 0))
            match sqlite_query_p(db,
                    "SELECT 1 FROM package_owners WHERE package_id = ? AND user_id = ?",
                    [param(show(pkg_id)), param(show(uid))]) {
              Err(e) => error_response(e.message),
              Ok(ores) => match ores.rows {
                [] => forbidden("not an owner of '" + name + "'"),
                [_, .._] => {
                  let bdoc   = json_ok(parse_json(req_body(req)))
                  let handle = str_or(bdoc |> at("handle"), "")
                  if handle == "" {
                    status_response(400, "missing 'handle' in request body")
                  } else {
                    match sqlite_query_p(db,
                            "SELECT id FROM users WHERE handle = ?", [param(handle)]) {
                      Err(e) => error_response(e.message),
                      Ok(ures) => match ures.rows {
                        [] => status_response(400, "user '" + handle + "' does not exist"),
                        [urow, .._] => {
                          let rem_uid = iopt(row_int(urow, 0))
                          match sqlite_query_p(db,
                                  "SELECT COUNT(*) FROM package_owners WHERE package_id = ?",
                                  [param(show(pkg_id))]) {
                            Err(e) => error_response(e.message),
                            Ok(cres) => match cres.rows {
                              [crow, .._] =>
                                if iopt(row_int(crow, 0)) <= 1 {
                                  status_response(400, "cannot remove the last owner of '" + name + "'")
                                } else {
                                  let _ = sqlite_exec_p(db,
                                    "DELETE FROM package_owners WHERE package_id = ? AND user_id = ?",
                                    [param(show(pkg_id)), param(show(rem_uid))])
                                  json_response(json_emit(JObject([
                                    ("ok",      JBool(true)),
                                    ("package", JString(name)),
                                    ("handle",  JString(handle))
                                  ])))
                                },
                              _ => error_response("unexpected db state")
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
  }
}

// ---------------------------------------------------------------------------
// hica compiler download tracking
// ---------------------------------------------------------------------------

// GET /api/v1/hica/downloads — total download count for the hica compiler itself,
// broken down by version and by OS.
pub fun handle_hica_downloads(db, req) {
  match sqlite_query_p(db,
          "SELECT COALESCE(SUM(count), 0) FROM hica_downloads", []) {
    Err(e) => error_response(e.message),
    Ok(tr) => match tr.rows {
      [] => error_response("stats query returned no rows"),
      [trow, .._] => {
        let total = iopt(row_int(trow, 0))
        match sqlite_query_p(db,
                "SELECT version, COALESCE(SUM(count), 0) FROM hica_downloads " +
                "GROUP BY version ORDER BY version DESC", []) {
          Err(e) => error_response(e.message),
          Ok(vr) =>
            match sqlite_query_p(db,
                    "SELECT os, COALESCE(SUM(count), 0) FROM hica_downloads " +
                    "WHERE os != '' GROUP BY os ORDER BY SUM(count) DESC", []) {
              Err(e) => error_response(e.message),
              Ok(or) => {
                let by_version = map(vr.rows, (r) => JObject([
                  ("version",   JString(sopt(row_str(r, 0)))),
                  ("downloads", JInt(iopt(row_int(r, 1))))
                ]))
                let by_os = map(or.rows, (r) => JObject([
                  ("os",        JString(sopt(row_str(r, 0)))),
                  ("downloads", JInt(iopt(row_int(r, 1))))
                ]))
                json_response(json_emit(JObject([
                  ("total",      JInt(total)),
                  ("by_version", JArray(by_version)),
                  ("by_os",      JArray(by_os))
                ])))
              }
            }
        }
      }
    }
  }
}

// GET /api/v1/hica/{os}/{arch}/download
// Counts the download (by os/arch) then 302s to GitHub's stable
// releases/latest URL, which GitHub resolves to the current release
// automatically. No version configuration needed on the registry side.
// HICA_RELEASES_BASE_URL overrides the GitHub base if needed.
pub fun handle_hica_download(db, req) {
  let os   = path_str(req, "os")
  let arch = path_str(req, "arch")
  let _ = sqlite_exec_p(db,
    "INSERT INTO hica_downloads(version, os, arch, count) VALUES('latest', ?, ?, 1) " +
    "ON CONFLICT(version, os, arch) DO UPDATE SET count = count + 1",
    [param(os), param(arch)])
  let base = match get_env("HICA_RELEASES_BASE_URL") {
    Some(u) => u,
    None    => "https://github.com/cladam/hica/releases/latest/download"
  }
  redirect(base + "/hica-" + os + "-" + arch)
}

// Build the registry's route table over an open database handle. Shared by the
// server (main.hc) and the in-process tests.
pub fun build_routes(db) {
  build_routes_cooperative(db, None)
}

pub fun build_routes_cooperative(db, on_publish) {
  [
    get("/health",                                              (req) => handle_health(db, req)),
    get("/api/v1/index",                                        (req) => handle_index(db, req)),
    get("/api/v1/summary",                                      (req) => handle_summary(db, req)),
    get("/api/v1/search",                                       (req) => handle_search(db, req)),
    get("/api/v1/packages/\{name\}",                             (req) => handle_get_package(db, req)),
    get("/api/v1/packages/\{name\}/owners",                      (req) => handle_list_owners(db, req)),
    put("/api/v1/packages/\{name\}/owners",                      (req) => handle_add_owner(db, req)),
    delete("/api/v1/packages/\{name\}/owners",                   (req) => handle_remove_owner(db, req)),
    get("/api/v1/packages/\{name\}/\{version\}/download",        (req) => handle_download(db, req)),
    get("/api/v1/packages/\{name\}/\{version\}",                 (req) => handle_get_version(db, req)),
    put("/api/v1/packages/\{name\}/\{version\}",                 (req) => handle_publish(db, req, on_publish)),
    delete("/api/v1/packages/\{name\}/\{version\}/yank",         (req) => handle_yank(db, req)),
    put("/api/v1/packages/\{name\}/\{version\}/unyank",          (req) => handle_unyank(db, req)),
    get("/api/v1/hica/downloads",                                (req) => handle_hica_downloads(db, req)),
    get("/api/v1/hica/\{os\}/\{arch\}/download",                 (req) => handle_hica_download(db, req))
  ]
}
