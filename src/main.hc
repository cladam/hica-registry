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
import "std/actor"
import "./db"
import "./routes"
import "./auth"

type TarballWorkerMsg {
  PublishTask(
    db: Db,
    name: string,
    ver: string,
    desc: string,
    repo: string,
    lic: string,
    claimed: string,
    tar_bytes: string,
    user_id: int
  )
}

actor TarballWorker {
  var dummy = 0

  receive(msg) => match msg {
    PublishTask(db, name, ver, desc, repo, lic, claimed, tar_bytes, user_id) => {
      let tdir  = match get_env("HICA_TARBALL_DIR") {
        Some(d) => d,
        None    => "./tarballs"
      }
      let pkg_dir = tdir + "/" + name
      let tpath   = pkg_dir + "/" + name + "-" + ver + ".tar.gz"
      match exec("mkdir -p " + pkg_dir) {
        Err(e) => println("[Background Worker] could not create tarball dir: " + e),
        Ok(_) => {
          write_file(tpath, tar_bytes)
          match sha256_file(tpath) {
            Err(e) => println("[Background Worker] sha256 failed: " + e),
            Ok(actual_sum) =>
              if claimed != "" && claimed != actual_sum {
                println("[Background Worker] checksum mismatch")
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
                  Err(e) => println("[Background Worker] could not publish: " + e.message),
                  Ok(_) => println("[Background Worker] successfully published " + name + "@" + ver)
                }
              }
          }
        }
      }
    }
  }
}

fun on_publish(db: Db, name: string, ver: string, desc: string, repo: string, lic: string, claimed: string, tar_bytes: string, user_id: int) {
  let _ = sqlite_exec_p(db,
    "INSERT INTO pending_tasks(name, version, desc, repo, license, claimed, tar_bytes, user_id) " +
    "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    [param(name), param(ver), param(desc), param(repo), param(lic), param(claimed), param(tar_bytes), param(show(user_id))])
}

fun main() {
  let db_path = match get_env("HICA_DB_PATH") {
    Some(p) => p,
    None    => "registry.db"
  }
  match sqlite_open(db_path) {
    Err(e) => println("failed to open database: " + e.message),
    Ok(db) => {
      init_db(db)
      upgrade_db(db)
      seed_admin_token(db)
      println("hica-registry listening on http://localhost:8080 (Cooperative Mode)")

      let srv = http_server_init(8080, (node) => {
        let raw = request_from_id(node)
        let on_pub = (name, ver, desc, repo, lic, claimed, tar_bytes, user_id) => {
          on_publish(db, name, ver, desc, repo, lic, claimed, tar_bytes, user_id)
        }
        let resp = dispatch_routes_safe(raw, build_routes_cooperative(db, Some(on_pub)))
        http_set_response(node, route_response_status(resp), route_response_headers(resp), route_response_body(resp))
      })

      let worker_state = TarballWorkerState { dummy: 0 }
      run_loop(srv, db, worker_state)
    }
  }
}

fun run_loop(srv: int, db: Db, worker: TarballWorkerState) : () {
  let _ = server_poll(srv)
  let next_worker = match sqlite_query_p(db, "SELECT id, name, version, desc, repo, license, claimed, tar_bytes, user_id FROM pending_tasks ORDER BY id LIMIT 1", []) {
    Err(_) => worker,
    Ok(res) => match res.rows {
      [] => worker,
      [row, ..] => {
        let tid       = iopt(row_int(row, 0))
        let name      = sopt(row_str(row, 1))
        let ver       = sopt(row_str(row, 2))
        let desc      = sopt(row_str(row, 3))
        let repo      = sopt(row_str(row, 4))
        let lic       = sopt(row_str(row, 5))
        let claimed   = sopt(row_str(row, 6))
        let tar_bytes = sopt(row_str(row, 7))
        let user_id   = iopt(row_int(row, 8))

        // Process the task
        let task = PublishTask(db, name, ver, desc, repo, lic, claimed, tar_bytes, user_id)
        let w = tarballworker_receive(worker, task)

        // Delete from queue
        let _ = sqlite_exec_p(db, "DELETE FROM pending_tasks WHERE id = ?", [param(show(tid))])
        w
      }
    }
  }
  run_loop(srv, db, next_worker)
}
