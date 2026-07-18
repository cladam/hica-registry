// db.hc — schema and database bootstrap for the hica registry.
//
// Phase 1: packages + versions (minimal).
// Phase 2: users + tokens (auth), tarball_path + published_by on versions.
//
// upgrade_db() adds the Phase 2 columns to existing DBs via ALTER TABLE;
// errors are silently ignored (column already exists on a fresh DB).
// seed_admin_token() inserts the dev user and seed token on first boot.
//
// SECURITY: The dev seed token is "hica-admin-CHANGEME".  Its SHA-256 is
// hardcoded below.  Rotate or disable this token before any production deploy.

import "sqlite"

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

// Idempotent schema — safe to run on every boot.
// Table order: packages → users → tokens → versions
// (versions references both packages and users).
pub fun schema_sql() : string {
  "CREATE TABLE IF NOT EXISTS packages (" +
  "  id          INTEGER PRIMARY KEY," +
  "  name        TEXT NOT NULL UNIQUE COLLATE NOCASE," +
  "  description TEXT NOT NULL DEFAULT ''," +
  "  repository  TEXT NOT NULL DEFAULT ''," +
  "  license     TEXT NOT NULL DEFAULT ''," +
  "  created_at  TEXT NOT NULL DEFAULT (datetime('now'))," +
  "  updated_at  TEXT NOT NULL DEFAULT (datetime('now'))" +
  ");" +
  "CREATE TABLE IF NOT EXISTS users (" +
  "  id         INTEGER PRIMARY KEY," +
  "  handle     TEXT NOT NULL UNIQUE," +
  "  created_at TEXT NOT NULL DEFAULT (datetime('now'))" +
  ");" +
  "CREATE TABLE IF NOT EXISTS tokens (" +
  "  id           INTEGER PRIMARY KEY," +
  "  user_id      INTEGER NOT NULL REFERENCES users(id)," +
  "  name         TEXT NOT NULL," +
  "  token_hash   TEXT NOT NULL UNIQUE," +
  "  created_at   TEXT NOT NULL DEFAULT (datetime('now'))," +
  "  last_used_at TEXT" +
  ");" +
  "CREATE TABLE IF NOT EXISTS versions (" +
  "  id           INTEGER PRIMARY KEY," +
  "  package_id   INTEGER NOT NULL REFERENCES packages(id)," +
  "  version      TEXT NOT NULL," +
  "  checksum     TEXT NOT NULL DEFAULT ''," +
  "  tarball_path TEXT NOT NULL DEFAULT ''," +
  "  yanked       INTEGER NOT NULL DEFAULT 0," +
  "  published_at TEXT NOT NULL DEFAULT (datetime('now'))," +
  "  published_by INTEGER REFERENCES users(id)," +
  "  UNIQUE(package_id, version)" +
  ");" +
  "CREATE TABLE IF NOT EXISTS downloads (" +
  "  version_id INTEGER PRIMARY KEY REFERENCES versions(id)," +
  "  count      INTEGER NOT NULL DEFAULT 0" +
  ");" +
  "CREATE TABLE IF NOT EXISTS package_owners (" +
  "  package_id INTEGER NOT NULL REFERENCES packages(id)," +
  "  user_id    INTEGER NOT NULL REFERENCES users(id)," +
  "  PRIMARY KEY (package_id, user_id)" +
  ");" +
  "CREATE TABLE IF NOT EXISTS hica_downloads (" +
  "  id      INTEGER PRIMARY KEY," +
  "  version TEXT NOT NULL," +
  "  os      TEXT NOT NULL DEFAULT ''," +
  "  arch    TEXT NOT NULL DEFAULT ''," +
  "  count   INTEGER NOT NULL DEFAULT 0," +
  "  UNIQUE(version, os, arch)" +
  ");"
}

// Create the tables if they do not exist. Logs on failure; the server still
// starts so the error is visible in the console.
pub fun init_db(db) {
  match sqlite_exec_batch(db, schema_sql()) {
    Err(e) => println("schema error: " + e.message),
    Ok(_)  => println("schema ready")
  }
}

// ---------------------------------------------------------------------------
// Upgrade (for existing Phase 1 databases)
// ---------------------------------------------------------------------------

// Add Phase 2 columns to an existing database created before this version.
// Each ALTER TABLE is attempted and its error silently ignored — on a fresh
// database the columns already exist via schema_sql() so the ALTER fails with
// "duplicate column name", which is expected and harmless.
pub fun upgrade_db(db) {
  let _ = sqlite_exec(db,
    "ALTER TABLE versions ADD COLUMN tarball_path TEXT NOT NULL DEFAULT ''")
  let _ = sqlite_exec(db,
    "ALTER TABLE versions ADD COLUMN published_by INTEGER REFERENCES users(id)")
  let _ = sqlite_exec(db,
    "CREATE TABLE IF NOT EXISTS downloads (" +
    "  version_id INTEGER PRIMARY KEY REFERENCES versions(id)," +
    "  count      INTEGER NOT NULL DEFAULT 0" +
    ")")
  let _ = sqlite_exec(db,
    "CREATE TABLE IF NOT EXISTS package_owners (" +
    "  package_id INTEGER NOT NULL REFERENCES packages(id)," +
    "  user_id    INTEGER NOT NULL REFERENCES users(id)," +
    "  PRIMARY KEY (package_id, user_id)" +
    ")")
  let _ = sqlite_exec(db,
    "CREATE TABLE IF NOT EXISTS hica_downloads (" +
    "  id      INTEGER PRIMARY KEY," +
    "  version TEXT NOT NULL," +
    "  os      TEXT NOT NULL DEFAULT ''," +
    "  arch    TEXT NOT NULL DEFAULT ''," +
    "  count   INTEGER NOT NULL DEFAULT 0," +
    "  UNIQUE(version, os, arch)" +
    ")")
  println("schema upgrade done")
}

// ---------------------------------------------------------------------------
// Dev seed token
// ---------------------------------------------------------------------------

// Insert the admin user and seed token if no users exist yet.
// Dev fallback token value: "hica-admin-CHANGEME"
// Dev fallback SHA-256:     1dcecf9f3ddef5bd408e09fe220f09ee23f97a5c306c4b4dac22fa30543de1a8
//
// In production, set HICA_REGISTRY_ADMIN_TOKEN_HASH to the SHA-256 of your
// chosen token before starting the server.  Example (GitHub Actions):
//   env:
//     HICA_REGISTRY_ADMIN_TOKEN_HASH: ${{ secrets.REGISTRY_ADMIN_TOKEN_HASH }}
//
// Use `Authorization: Bearer <token>` to authenticate.
// CHANGE THIS TOKEN BEFORE ANY PRODUCTION DEPLOYMENT.
pub fun seed_admin_token(db) {
  let dev_hash = "sha256:1dcecf9f3ddef5bd408e09fe220f09ee23f97a5c306c4b4dac22fa30543de1a8"
  let token_hash = match get_env("HICA_REGISTRY_ADMIN_TOKEN_HASH") {
    Some(h) => h,
    None    => dev_hash
  }
  match sqlite_query(db, "SELECT COUNT(*) FROM users") {
    Err(_) => println("seed: could not query users table"),
    Ok(res) => match res.rows {
      [row, ..] =>
        if iopt(row_int(row, 0)) == 0 {
          let _ = sqlite_exec_p(db,
            "INSERT OR IGNORE INTO users(handle) VALUES (?)",
            [param("admin")])
          let _ = sqlite_exec_p(db,
            "INSERT OR IGNORE INTO tokens(user_id, name, token_hash) " +
            "VALUES ((SELECT id FROM users WHERE handle = ?), ?, ?)",
            [param("admin"), param("dev-seed"), param(token_hash)])
          println("seed: admin user and dev token inserted (CHANGE TOKEN IN PRODUCTION)")
        },
      _ => println("seed: unexpected schema state")
    }
  }
}

// ---------------------------------------------------------------------------
// Small maybe unwrappers used when reading rows.
// ---------------------------------------------------------------------------

pub fun sopt(m: maybe<string>) : string {
  match m {
    Some(s) => s,
    None    => ""
  }
}

pub fun iopt(m: maybe<int>) : int {
  match m {
    Some(n) => n,
    None    => 0
  }
}
