// db.hc — schema and database bootstrap for the hica registry.
//
// Phase 1 keeps a minimal two-table model (packages + versions). Everything
// else from the design document (owners, tokens, downloads, FTS) can be layered
// on later without changing these tables.

import "sqlite"

// Idempotent schema — safe to run on every boot.
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
  "CREATE TABLE IF NOT EXISTS versions (" +
  "  id           INTEGER PRIMARY KEY," +
  "  package_id   INTEGER NOT NULL REFERENCES packages(id)," +
  "  version      TEXT NOT NULL," +
  "  checksum     TEXT NOT NULL DEFAULT ''," +
  "  yanked       INTEGER NOT NULL DEFAULT 0," +
  "  published_at TEXT NOT NULL DEFAULT (datetime('now'))," +
  "  UNIQUE(package_id, version)" +
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
