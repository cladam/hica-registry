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

type TarballWorkerMsg {
  PublishTask(
    db: db,
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

fun main() {
  let db_path = env_or("HICA_DB_PATH", "registry.db")
  match sqlite_open(db_path) {
    Err(e) => println("failed to open database: " + e.message),
    Ok(db) => {
      init_db(db)
      upgrade_db(db)
      seed_admin_token(db)
      println("hica-registry listening on http://localhost:8080 (Cooperative Mode)")

      var pending_tasks = []
      let get_tasks = () => { pending_tasks }
      let set_tasks = (t) => { pending_tasks = t }

      let on_publish = (name, ver, desc, repo, lic, claimed, tar_bytes, user_id) => {
        let task = PublishTask(db, name, ver, desc, repo, lic, claimed, tar_bytes, user_id)
        pending_tasks = pending_tasks + [task]
      }

      let srv = http_server_init(8080, (node) => {
        let raw = request_from_id(node)
        let resp = dispatch_routes_safe(raw, build_routes(db, Some(on_publish)))
        http_set_response(node, route_response_status(resp), route_response_headers(resp), route_response_body(resp))
      })

      var worker_state = TarballWorkerState { dummy: 0 }
      run_loop(srv, get_tasks, set_tasks, worker_state)
    }
  }
}

fun run_loop(srv: int, get_tasks, set_tasks, worker: TarballWorkerState) : () {
  let _ = server_poll(srv)
  let tasks = get_tasks()
  var next_worker = worker
  match tasks {
    [] => ()
    [task, ..rest] => {
      set_tasks(rest)
      next_worker = tarballworker_receive(worker, task)
    }
  }
  run_loop(srv, get_tasks, set_tasks, next_worker)
}
