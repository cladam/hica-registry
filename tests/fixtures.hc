// fixtures.hc — shared test helpers: in-memory database factory and fixture data.
//
// Import this from any test file that needs a seeded database.
// All functions are pub so they are accessible from importing test files.
//
// Fixture data:
//   json   — versions 0.1.0, 0.2.0, and a yanked 0.3.0  (latest = 0.2.0)
//   sqlite — version 0.4.0                                (latest = 0.4.0)

import "../src/db"
import "sqlite"

pub fun seed(db) {
  let _ = sqlite_exec_p(db,
    "INSERT INTO packages(name, description, repository, license) VALUES (?, ?, ?, ?)",
    [param("json"), param("A JSON parser and emitter"),
     param("https://github.com/cladam/hica"), param("MIT")])
  let _ = sqlite_exec_p(db,
    "INSERT INTO packages(name, description, repository, license) VALUES (?, ?, ?, ?)",
    [param("sqlite"), param("A SQLite3 wrapper"), param(""), param("MIT")])
  let _ = sqlite_exec_p(db,
    "INSERT INTO versions(package_id, version, checksum) VALUES ((SELECT id FROM packages WHERE name = ?), ?, ?)",
    [param("json"), param("0.1.0"), param("sha256:aaa")])
  let _ = sqlite_exec_p(db,
    "INSERT INTO versions(package_id, version, checksum) VALUES ((SELECT id FROM packages WHERE name = ?), ?, ?)",
    [param("json"), param("0.2.0"), param("sha256:bbb")])
  let _ = sqlite_exec_p(db,
    "INSERT INTO versions(package_id, version, checksum, yanked) VALUES ((SELECT id FROM packages WHERE name = ?), ?, ?, 1)",
    [param("json"), param("0.3.0"), param("sha256:ddd")])
  let _ = sqlite_exec_p(db,
    "INSERT INTO versions(package_id, version, checksum) VALUES ((SELECT id FROM packages WHERE name = ?), ?, ?)",
    [param("sqlite"), param("0.4.0"), param("sha256:ccc")])
  ()
}

// Open a fresh in-memory database, apply the schema, and insert the fixture data.
pub fun fresh_seeded() {
  let db = unwrap(sqlite_open(":memory:"))
  init_db(db)
  seed(db)
  db
}

// Like fresh_seeded, but also installs the dev admin user and seed token.
// Use for tests that exercise authenticated endpoints.
pub fun fresh_with_auth() {
  let db = fresh_seeded()
  seed_admin_token(db)
  db
}
