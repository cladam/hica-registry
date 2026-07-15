# Hica Registry Server — Design Document

## Status: Exploration / RFC

A server-side package registry for hica, inspired by [crates.io](https://crates.io/),
**written in hica itself** using the `http` (server), `sqlite`, and `json`
libraries. The registry is both a real service and a flagship dogfooding project:
if hica can host its own package registry, it can build real web services.

---

## 1. Motivation

Today `pkg.hica.dev` is a **static file host**. Packages are published by a
GitHub Actions workflow (see `libraries/*/.github/workflows/publish-pkg.yml`)
that uploads three artefacts over FTP:

```
pkg.hica.dev/<name>/latest                     plain text: resolved version
pkg.hica.dev/<name>/<version>.json             package metadata (name, version, tarball, checksum)
pkg.hica.dev/<name>/<name>-<version>.tar.gz    source tarball
```

The client in hica `src/deps.kk` reads exactly these paths:

| Client call | Endpoint |
|---|---|
| resolve `latest` | `GET /<name>/latest` |
| fetch metadata | `GET /<name>/<version>.json` |
| download source | `GET <tarball-url>` (from metadata) |

This works, but it has a hard limit: **there is no index**, so
`hica pkg search` can only search the *local* cache (`GET /index.json` → 404).
There is also no ownership model, no download stats, no yank, and publishing
requires FTP credentials shared across every library repo.

**There are no users or production traffic yet**, so we are free to replace this
wholesale. This design does **not** preserve the static FTP layout — it defines
a clean, dynamic HTTP API backed by SQLite, and the `deps.kk` client is updated
to match (see §7). The only thing carried over is the existing published data,
via a one-time seed (§11).

---

## 2. Goals & non-goals

**Goals**

1. **Clean, coherent API** — a single versioned surface (`/api/v1/…`) modelled on
   crates.io. No legacy paths to carry.
2. **Searchable** — a real server-side search endpoint (`GET /api/v1/search?q=`).
3. **Self-hosted in hica** — server built on the `http` router + `sqlite` + `json`.
4. **Authenticated publish** — token-based `hica publish`, replacing shared FTP creds.
5. **Immutable versions** — once `foo@1.2.3` is published it never changes (crates.io rule).
6. **Auditable** — download counts, publish timestamps, yank state in the database.

**Non-goals (for v1)**

- Semver range resolution / a SAT solver. The client pins exact versions in
  `hica.lock`; `latest` resolves to the newest non-yanked version. Ranges can
  come later.
- A web UI. JSON API first; a static front-end can consume it afterwards.
- Multi-region CDN. Single node + tarball caching is fine at this scale.
- User-to-user permissions beyond "owners" per package.

---

## 3. Architecture

```
                         ┌─────────────────────────────┐
   hica CLI (deps.kk)    │      registry server        │
   ────────────────►     │   (hica + http + json)      │
   GET  /api/v1/…        │                             │
   GET  …/download       │   router.hc  (FastAPI-style)│
   PUT  …/{name}/{ver}   │        │                    │
   (multipart publish)   │        ▼                    │
                         │   handlers ──► sqlite ──► registry.db
                         │        │                    │
   web browser ─────────►│        └──► tarball store   │  (filesystem or BLOB)
   GET  /api/v1/search   │                             │
                         └─────────────────────────────┘
```

- **`http` server** (`router.hc`) provides typed routes, path/query params,
  middleware, and automatic `404`/`500` handling. libmicrohttpd holds
  connections open and hands requests to the single-threaded handler one at a
  time — well suited to an I/O-bound registry.
- **`sqlite`** stores all metadata and the full-text search index. One file,
  `registry.db`, with WAL mode for concurrent readers.
- **`json`** parses publish metadata and emits every API response.
- **Tarball store** — start on the local filesystem
  (`/srv/registry/tarballs/<name>/<name>-<version>.tar.gz`), streamed by the
  download route (which increments the counter); optionally move blobs into
  SQLite or object storage later.

---

## 4. Data model (SQLite schema)

```sql
-- Packages (one row per package name)
CREATE TABLE packages (
  id           INTEGER PRIMARY KEY,
  name         TEXT NOT NULL UNIQUE COLLATE NOCASE,
  description  TEXT NOT NULL DEFAULT '',
  repository   TEXT NOT NULL DEFAULT '',
  homepage     TEXT NOT NULL DEFAULT '',
  license      TEXT NOT NULL DEFAULT '',
  created_at   TEXT NOT NULL,          -- RFC 3339
  updated_at   TEXT NOT NULL
);

-- Versions (immutable; one row per published version)
CREATE TABLE versions (
  id           INTEGER PRIMARY KEY,
  package_id   INTEGER NOT NULL REFERENCES packages(id),
  version      TEXT NOT NULL,          -- "1.2.3"
  checksum     TEXT NOT NULL,          -- "sha256:..."
  tarball_path TEXT NOT NULL,          -- relative path in the tarball store
  yanked       INTEGER NOT NULL DEFAULT 0,
  published_at TEXT NOT NULL,
  published_by INTEGER REFERENCES users(id),
  UNIQUE (package_id, version)
);

-- Dependencies declared by each version (from the package's hica.hml)
CREATE TABLE version_deps (
  version_id   INTEGER NOT NULL REFERENCES versions(id),
  dep_name     TEXT NOT NULL,
  dep_req      TEXT NOT NULL           -- "latest", "1.0.0", "path:..", "git+.."
);

-- Owners
CREATE TABLE users (
  id           INTEGER PRIMARY KEY,
  handle       TEXT NOT NULL UNIQUE,   -- e.g. github login
  created_at   TEXT NOT NULL
);

CREATE TABLE package_owners (
  package_id   INTEGER NOT NULL REFERENCES packages(id),
  user_id      INTEGER NOT NULL REFERENCES users(id),
  PRIMARY KEY (package_id, user_id)
);

-- API tokens (store only a hash, never the raw token)
CREATE TABLE tokens (
  id           INTEGER PRIMARY KEY,
  user_id      INTEGER NOT NULL REFERENCES users(id),
  name         TEXT NOT NULL,
  token_hash   TEXT NOT NULL UNIQUE,   -- sha256 of the presented token
  created_at   TEXT NOT NULL,
  last_used_at TEXT
);

-- Download counters (per version; increment on tarball GET)
CREATE TABLE downloads (
  version_id   INTEGER PRIMARY KEY REFERENCES versions(id),
  count        INTEGER NOT NULL DEFAULT 0
);

-- Full-text search index (FTS5). Rebuilt/updated on publish.
CREATE VIRTUAL TABLE package_fts USING fts5(
  name, description, content=''      -- external-content or contentless
);
```

> **FTS5 availability — verified ✅.** The macOS system SQLite (`3.43.2`) and
> Homebrew SQLite (`3.53.2`) both ship with `ENABLE_FTS5`, and
> `CREATE VIRTUAL TABLE … USING fts5(…)` works. No `sqlite` library changes are
> needed — FTS5 is driven entirely through the existing generic
> `sqlite_exec` / `sqlite_query_p` API (`… USING fts5` to create, `MATCH` to
> query). Still verify on the **Linux production host** (`libsqlite3-dev` on
> recent Debian/Ubuntu enables FTS5 by default), and keep the
> `WHERE name LIKE '%q%' OR description LIKE '%q%'` form (with a `COLLATE NOCASE`
> index) as a portable fallback.

---

## 5. API surface

One versioned JSON API under `/api/v1`, modelled on crates.io (`packages`
instead of `crates`). All responses are JSON except the tarball download.

| Method | Path | Auth | Purpose |
|---|---|---|---|
| `GET` | `/api/v1/packages/{name}` | — | Package detail: metadata, `latest`, and every version |
| `GET` | `/api/v1/packages/{name}/{version}` | — | Single version metadata (checksum, deps, download URL) |
| `GET` | `/api/v1/packages/{name}/{version}/download` | — | Stream the tarball (increments download count) |
| `GET` | `/api/v1/search?q=<term>&limit=<n>` | — | Full-text search → list of packages |
| `GET` | `/api/v1/index` | — | Lightweight catalogue (names + latest) for offline seeding |
| `PUT` | `/api/v1/packages/{name}/{version}` | token | Publish a version (multipart; see §6) |
| `DELETE` | `/api/v1/packages/{name}/{version}/yank` | owner | Hide a version from resolution |
| `PUT` | `/api/v1/packages/{name}/{version}/unyank` | owner | Restore a yanked version |
| `GET` / `PUT` / `DELETE` | `/api/v1/packages/{name}/owners` | owner | List / add / remove owners |

**Package detail** (`GET /api/v1/packages/json`) — one round-trip gives the
client everything it needs to resolve `latest` and any pinned version:

```json
{
  "name": "json",
  "description": "JSON parser and serializer",
  "repository": "https://github.com/cladam/json",
  "license": "MIT",
  "latest": "0.1.0",
  "versions": [
    {
      "version": "0.1.0",
      "checksum": "sha256:49fc1f82…",
      "yanked": false,
      "published_at": "2026-06-30T12:00:00Z",
      "download": "https://pkg.hica.dev/api/v1/packages/json/0.1.0/download",
      "dependencies": [ { "name": "http", "req": "latest" } ]
    }
  ]
}
```

**Search response** (`GET /api/v1/search?q=json`):

```json
{
  "query": "json",
  "results": [
    { "name": "json", "version": "0.1.0", "description": "JSON parser and serializer" }
  ]
}
```

`latest` excludes yanked and (per §13) pre-release versions. This is exactly what
`hica pkg search` and `hica pkg info` consume.

---

## 6. Publishing flow

`hica publish` (new CLI command) builds the tarball, computes its `sha256`, and
uploads it with a token. Publishing is a single authenticated `PUT` to the
version's own URL:

```
PUT /api/v1/packages/{name}/{version}
Authorization: Bearer <token>
Content-Type: multipart/form-data; boundary=…

--boundary
Content-Disposition: form-data; name="metadata"
Content-Type: application/json

{ "name": "json", "version": "0.1.0", "description": "…",
  "repository": "…", "license": "MIT", "checksum": "sha256:…",
  "dependencies": [ { "name": "http", "req": "latest" } ] }
--boundary
Content-Disposition: form-data; name="tarball"; filename="json-0.1.0.tar.gz"
Content-Type: application/gzip

<binary tarball bytes>
--boundary--
```

**Multipart is the transport** — the tarball streams as raw bytes with no
encoding overhead. Multipart parsing shipped in the `http` library (`web`
barrel: `req_part` / `Part`; see §12), so publish reads the two parts directly.

Server-side handler (sketch — real `http`/`sqlite`/`json` APIs):

```rust
import "web"          // router + response helpers + multipart (req_part, Part)
import "body"         // typed bodies (pulls in json)
import "sqlite"

fun handle_publish(db, req) : ServerResponse {
  // 1. Authenticate
  match bearer_token(req) {
    None => unauthorized("missing token"),
    Some(tok) => {
      let uid = user_for_token(db, hash_token(tok))   // sqlite lookup
      if uid < 0 { unauthorized("invalid token") }
      else {
        // 2. Read the two multipart parts.
        match req_part(req, "metadata") {
          None => bad_request("missing 'metadata' part"),
          Some(meta_part) => match req_part(req, "tarball") {
            None => bad_request("missing 'tarball' part"),
            Some(tar_part) => {
              let meta = parse_json(meta_part.bytes) |> json_ok
              let name = meta |> at("name") |> as_str |> str_or("")
              let ver  = meta |> at("version") |> as_str |> str_or("")
              if !valid_name(name) || !valid_semver(ver) {
                bad_request("invalid name or version")
              } elif !owns_or_new(db, uid, name) {
                forbidden("not an owner of '" + name + "'")
              } else {
                // 3. Reject duplicate (immutable versions)
                // 4. Verify sha256(tar_part.bytes) == declared checksum
                // 5. In one sqlite transaction: write tar_part.bytes to the
                //    store, INSERT package/version/version_deps, update
                //    package_fts, bump updated_at
                // 6. Return 201 Created
                publish_version(db, uid, name, ver, meta, tar_part.bytes)
              }
            }
          }
        }
      }
    }
  }
}
```

`req_part` returns a `Part { name, filename, content_type, bytes }`; `bytes` is
binary-safe (holds the gzip tarball, NUL bytes and all). The `http` library caps
each part at **64 MiB** in the C layer and rejects larger uploads before the
handler runs, which covers the upload-size guard in §8.

The `publish-pkg.yml` workflow shrinks to: build tarball → `hica publish`
(the CLI does the multipart `PUT` with the repo's `HICA_TOKEN` secret). No shared
FTP credentials, and the server updates the search index atomically in the same
transaction that records the version.

### One-time seed of existing packages

The packages already on `pkg.hica.dev` are imported once by a small script (or a
`hica` program) that reads each `<name>/latest` + `<name>/<version>.json`, pulls
the tarball, and calls `publish_version` directly against `registry.db`. After
the seed, the static FTP files can be retired.

---

## 7. Client changes (`src/deps.kk`)

The client moves from the flat static paths to the `/api/v1` surface. These are
the concrete edits to `src/deps.kk` (and one to `src/main.kk` for the new
command):

| Current | New |
|---|---|
| `GET /{name}/latest` (plain text) | `GET /api/v1/packages/{name}` → read `latest` from JSON |
| `GET /{name}/{version}.json` | Version block from the same detail response (or `GET /api/v1/packages/{name}/{version}`) |
| tarball URL baked in metadata | `download` URL from the version block (`…/{version}/download`) |
| `pkg search` scans local cache | `GET /api/v1/search?q=` → JSON `results`; cache scan becomes the offline fallback |

Functions touched in `deps.kk`:

- **`fetch-registry`** — replace the `"/" + name + "/latest"` call with a single
  `GET /api/v1/packages/{name}`; parse `latest` and locate the version block.
- **`fetch-registry-install`** — take the `download` URL and `checksum` from the
  version block instead of `<version>.json`; verify `sha256` after download.
- **`json-get-str`** — the responses are richer (nested `versions` array), so
  swap the ad-hoc string scan for the real `json` library (`parse_json` / `at` /
  `nth` / `as_str`). This removes the brittle flat-JSON parser.
- **`pkg-search`** (`pkg-search` command) — call `GET /api/v1/search?q=`, parse
  `results`, print name/version/description; fall back to the local-cache scan on
  any network/HTTP error so it still works offline.
- **`pkg-info`** — read the package detail endpoint (description, latest,
  version count, downloads) instead of `latest` + `<version>.json`.
- **`resolve-dep-for-lock`** — resolve `latest` via the detail endpoint's
  `latest` field.

New commands (in `main.kk`, logic in `deps.kk`):

- **`hica publish`** — build the tarball (reuse the existing tar logic), read
  `HICA_TOKEN` from env, and `PUT /api/v1/packages/{name}/{version}` as
  `multipart/form-data` with a `metadata` JSON part and a `tarball` file part.
- **`hica login`** — store a token in `~/.hica/credentials` (chmod 600) for
  interactive publishing.

The registry base URL should become a single constant (env-overridable, e.g.
`HICA_REGISTRY`) so the server can be pointed at a local instance during
development.

---

## 8. Security considerations

- **Tokens**: store only `sha256(token)`; show the raw token once at creation.
  Send over HTTPS only. Rate-limit publish.
- **Immutable versions**: never allow overwriting an existing `name@version`.
  Deletion is replaced by **yank** (hides from resolution, keeps builds
  reproducible).
- **Checksum verification**: the server recomputes `sha256` of the uploaded
  tarball and rejects a mismatch; the client re-verifies on download against the
  `checksum` in metadata (already the plan for `deps.kk`).
- **Name validation**: enforce `^[a-z0-9][a-z0-9._-]*$`, case-insensitive
  uniqueness, length limits, and a reserved-name blocklist to curb squatting.
- **Path safety**: never build filesystem paths from raw user input — derive
  `tarball_path` from validated `name`/`version` only. (The existing
  `safe-shell-arg` guard in `deps.kk` is the client-side analogue.)
- **SQL injection**: always use parameterised queries (`sqlite_query_p` /
  `sqlite_exec_p` with `param(...)`) — never string-concatenate SQL. The
  `sqlite` library's opaque `SqlParam` type enforces this at the type level.
- **Upload limits**: the `http` library caps each multipart part at 64 MiB and
  rejects larger uploads in the C layer before the handler runs; reject
  non-gzip tarballs in the handler.

---

## 9. Storage & operations

- **Database**: single `registry.db`, WAL mode (`PRAGMA journal_mode=WAL`) for
  concurrent reads during writes; nightly `sqlite3 .backup` to off-box storage.
- **Tarballs**: filesystem under `/srv/registry/tarballs/`, streamed by the
  `download` route (which increments the counter). A fronting nginx/Caddy can
  cache these responses. Blobs can move into SQLite or object storage later.
- **Migrations**: `sqlite_exec_batch` runs the schema on boot; a `schema_version`
  table gates future migrations.
- **Deploy**: single binary (`hica build server.hc -o registry`) behind TLS
  (nginx/Caddy terminating HTTPS on `pkg.hica.dev`, proxying to the hica server
  on `:8080`).

---

## 10. Server skeleton (hica)

```rust
import "web"
import "body"
import "sqlite"

fun main() {
  // Open once; hand the handle to route closures.
  let _ = with_sqlite("registry.db", (db) => {
    let _ = sqlite_exec_batch(db, schema_sql())   // idempotent boot migration

    println("hica registry listening on :8080")
    serve_routes(8080,
      group("/api/v1", [
        get("/packages/{name}",                    (req) => package_handler(db, req)),
        get("/packages/{name}/{version}",          (req) => version_handler(db, req)),
        get("/packages/{name}/{version}/download", (req) => download_handler(db, req)),
        get("/search",                             (req) => search_handler(db, req)),
        get("/index",                              (req) => index_handler(db, req)),
        put("/packages/{name}/{version}",          (req) => handle_publish(db, req)),
        delete("/packages/{name}/{version}/yank",  (req) => yank_handler(db, req))
      ]))
  })
}
```

`search_handler` is the crux of the feature:

```rust
fun search_handler(db, req) : ServerResponse {
  match query_str(req, "q") {
    None => bad_request("missing q"),
    Some(q) => {
      // FTS5: SELECT name, description FROM package_fts WHERE package_fts MATCH ?
      match sqlite_query_p(db,
              "SELECT p.name, p.description, " +
              "  (SELECT version FROM versions v WHERE v.package_id = p.id " +
              "   AND v.yanked = 0 ORDER BY v.published_at DESC LIMIT 1) AS latest " +
              "FROM packages p WHERE p.name LIKE ? OR p.description LIKE ? " +
              "ORDER BY p.name LIMIT 25",
              [param("%" + q + "%"), param("%" + q + "%")]) {
        Err(e) => error_response(e.message),
        Ok(r)  => json_response(rows_to_search_json(q, r))
      }
    }
  }
}
```

(The FTS5 variant swaps the `LIKE` query for `package_fts MATCH ?`; keep the
`LIKE` form as the portable fallback.)

---

## 11. Phased delivery

| Phase | Deliverable |
|---|---|
| **0** | This RFC + schema agreed |
| **1** | Read API: `packages/{name}`, `packages/{name}/{version}`, `.../download`, `search`, `index`. One-time seed from the existing `pkg.hica.dev` static files into `registry.db`. Retire the FTP files. |
| **2** | Authenticated **multipart** publish (`metadata` + `tarball` parts). Adds `hica publish` / `hica login`; `publish-pkg.yml` moves from FTP to `hica publish`. |
| **3** | Yank / unyank, owners, download counts surfaced in `pkg info`. |
| **4** | (Optional) static web UI consuming the JSON API; semver ranges. |

Client (`deps.kk`) adapts to the new endpoints in Phase 1 (§7); everything else
(`add`, `fetch`, `tree`, `update`, lockfile pinning) is unaffected apart from the
URLs it calls.

---

## 12. Library prerequisites & gaps

Findings from investigating the two dependencies this design leans on. One is
ready; one needs work in the `http` library before it can be used.

### FTS5 (SQLite) — ✅ ready, no work needed

Verified available in the system and Homebrew SQLite (both report `ENABLE_FTS5`;
`CREATE VIRTUAL TABLE … USING fts5(…)` succeeds). It is reachable through the
`sqlite` library's existing generic API with **no library changes**:

- create: `sqlite_exec(db, "CREATE VIRTUAL TABLE package_fts USING fts5(name, description)")`
- query: `sqlite_query_p(db, "SELECT … FROM package_fts WHERE package_fts MATCH ?", [param(q)])`

Action items:
- Confirm FTS5 is enabled in the **Linux production** `libsqlite3` (recent
  Debian/Ubuntu builds enable it by default).
- Keep the `LIKE` fallback query (Section 4) for portability.

### Multipart / `multipart/form-data` (http server) — ✅ shipped

Multipart parsing is now in the `http` library. `multipart.hc` (included in the
`web` barrel) parses `multipart/form-data` bodies via libmicrohttpd's
`MHD_PostProcessor` in the C layer; each part's bytes are fully accumulated
before the handler runs. This is everything the publish endpoint (§6) needs — no
base64 interim required.

API used by this design:

| Item | Description |
|---|---|
| `req_part(req, name) : maybe<Part>` | A named part (`None` if absent / not multipart) |
| `req_parts(req) : list<Part>` | All parts |
| `req_files(req) : list<Part>` | Only parts carrying a filename |
| `is_multipart(req) : bool` | True if the request parsed as multipart |
| `part_str(req, name) : maybe<string>` | Bytes of a named text part as a string |
| `Part { name, filename, content_type, bytes }` | `bytes` is binary-safe (holds the gzip tarball) |

Constraints to design around:
- Each part is capped at **64 MiB** by the C layer; larger uploads are rejected
  by MHD before the handler runs (this is the §8 upload guard).
- `Part.bytes` is a raw byte string — safe for binary tarballs including NUL
  bytes; write it straight to the tarball store.

Publish (§6) reads `req_part(req, "metadata")` and `req_part(req, "tarball")`
directly. Reference: the `Multipart / file uploads` section and
`examples/server_multipart.hc` in `libraries/http/README.md`.

---

## 13. Open questions

1. **Identity** — GitHub OAuth for `hica login`, or manually minted tokens to
   start? Tokens-first is faster; OAuth can follow.
2. **Who owns a name on first publish** — first publisher becomes sole owner
   (crates.io model); reserved-name blocklist for stdlib-ish names.
3. **`latest` semantics with prereleases** — exclude `-rc`/`-beta` from `latest`
   unless explicitly requested (like crates.io).
4. **Rate limiting / abuse** — per-token publish quotas; max versions/day.
5. **Seed ownership** — which user owns the seeded packages on import (a bootstrap
   admin account, then transfer).

---

## 14. Related documents

- `documentation/hica-package-manager.md` — the client-side manager & manifest.
- `libraries/http/README.md` — the server framework: router, middleware, static,
  typed bodies, and **multipart** (`req_part` / `Part`) for publish.
- `libraries/sqlite/README.md` — the database layer (parameterised queries).
- `src/deps.kk` — the registry client, updated to the `/api/v1` endpoints (§7).
