# hica-registry

A server-side package registry for [hica](https://www.hica.dev), inspired by
[crates.io](https://crates.io/) and **written in hica itself** using the `http`
(server), `sqlite`, and `json` libraries.

The registry is both a real service and a flagship dogfooding project: if hica
can host its own package registry, it can build real web services.

> **Status:** Exploration / RFC → early implementation. See
> [docs/hica-registry-server.md](docs/hica-registry-server.md) for the full
> design document.

## Why

Today `pkg.hica.dev` is a **static file host**: packages are published over FTP
as three flat artefacts (`latest`, `<version>.json`, and a source tarball). It
works, but it has no index (so search only scans the local cache), no ownership
model, no download stats, no yank, and publishing requires shared FTP
credentials.

There are no production users yet, so this project replaces that wholesale with a
clean, dynamic HTTP API backed by SQLite.

## Goals

1. **Clean, coherent API** — a single versioned surface (`/api/v1/…`) modelled on
   crates.io, with no legacy paths to carry.
2. **Searchable** — a real server-side search endpoint (`GET /api/v1/search?q=`),
   backed by SQLite FTS5 (with a `LIKE` fallback for portability).
3. **Self-hosted in hica** — the server is built on the `http` router + `sqlite`
   + `json` libraries.
4. **Authenticated publish** — token-based `hica publish`, replacing shared FTP
   credentials.
5. **Immutable versions** — once `foo@1.2.3` is published it never changes; hiding
   is done via **yank**.
6. **Auditable** — download counts, publish timestamps, and yank state live in the
   database.

**Non-goals (v1):** semver range resolution / SAT solving, a web UI, multi-region
CDN, and user-to-user permissions beyond per-package owners.

## Architecture

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
   web browser ─────────►│        └──► tarball store   │
   GET  /api/v1/search   │                             │
                         └─────────────────────────────┘
```

- **`http` server** provides typed routes, path/query params, middleware, and
  automatic `404`/`500` handling.
- **`sqlite`** stores all metadata and the full-text search index in one
  `registry.db` file (WAL mode for concurrent readers).
- **`json`** parses publish metadata and emits every API response.
- **Tarball store** — starts on the local filesystem, streamed by the download
  route (which increments the counter).

## API surface

One versioned JSON API under `/api/v1` (all responses JSON except the tarball
download):

| Method | Path | Auth | Purpose |
|---|---|---|---|
| `GET` | `/api/v1/packages/{name}` | — | Package detail: metadata, `latest`, every version |
| `GET` | `/api/v1/packages/{name}/{version}` | — | Single version metadata |
| `GET` | `/api/v1/packages/{name}/{version}/download` | — | Stream the tarball (bumps count) |
| `GET` | `/api/v1/search?q=<term>&limit=<n>` | — | Full-text search |
| `GET` | `/api/v1/index` | — | Lightweight catalogue for offline seeding |
| `PUT` | `/api/v1/packages/{name}/{version}` | token | Publish a version (multipart) |
| `DELETE` | `/api/v1/packages/{name}/{version}/yank` | owner | Hide a version from resolution |
| `PUT` | `/api/v1/packages/{name}/{version}/unyank` | owner | Restore a yanked version |
| `GET`/`PUT`/`DELETE` | `/api/v1/packages/{name}/owners` | owner | List / add / remove owners |

## Roadmap

| Phase | Deliverable |
|---|---|
| **0** | RFC + schema agreed |
| **1** | Read API (`packages`, `download`, `search`, `index`) + one-time seed from the existing static files; retire FTP |
| **2** | Authenticated multipart publish (`hica publish` / `hica login`); move `publish-pkg.yml` off FTP |
| **3** | Yank / unyank, owners, download counts surfaced in `pkg info` |
| **4** | (Optional) static web UI over the JSON API; semver ranges |

## Development

```sh
hica build   # compile to binary
hica run     # compile and run
hica fmt     # format according to hica style guide
hica check   # type-check without emitting
hica clean   # remove generated files
```

Dependencies (`json`, `sqlite`, `http`) are declared in [hica.hml](hica.hml).

## Documents

- [docs/hica-registry-server.md](docs/hica-registry-server.md) — the full design
  document (schema, publishing flow, client changes, security, operations).
