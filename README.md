# rr-store-opfs

Part of the **RailsRuntimes** ecosystem. Apache-2.0.

`rr-store-opfs` is the **browser OPFS SQLite** integration for `rr-store`. It supplies:

| Piece | Role |
| --- | --- |
| `SqliteCompiler` | Plan → parameterized SQLite `{sql, binds}` (injection-safe) |
| `Sqlite3Bridge` | In-process sqlite3 bridge for CI (no browser) |
| `OpfsBridge` | Ruby-in-Wasm posts to the dedicated OPFS worker |
| Worker asset | `lib/rails_runtimes/store/opfs/assets/opfs_sqlite_worker.js` |
| Factory | `Opfs.test_driver` / `Opfs.register!` wire `Store::Browser::WorkerDriver` |

**Pairs with:** `rr-store` (reuses `WorkerDriver` + `DriverRegistry`; does not reinvent the port).

Ruby namespace: `RailsRuntimes::Store::Opfs` (`require "rails_runtimes/store/opfs"` or `require "rr-store-opfs"`).

```ruby
require "rails_runtimes/store/opfs"

schema = RailsRuntimes::Model.define("Notes::Note") { ... }.value
driver = RailsRuntimes::Store::Opfs.test_driver(schema: schema)
notes = RailsRuntimes::Store.for(schema)
notes.create(title: "Offline").await
```

## Status

`0.1.0` — compiler + CI sqlite3 bridge green; real OPFS worker asset for **manual browser validation**.

## Manual browser smoke (not headless-CI)

Headless/CI **cannot** fully validate the OPFS sync-access-handle path (dedicated worker + `FileSystemSyncAccessHandle`). That is expected. CI proves the Ruby compiler and driver logic via `Sqlite3Bridge`.

1. Serve `lib/rails_runtimes/store/opfs/assets/opfs_sqlite_worker.js` (and a host page that spawns it as a Worker).
2. Boot with profile id and VFS preference `opfs-sahpool` (default).
3. Call `migrate` with a schema descriptor, then `execute` insert/select plans.
4. Reload the origin and confirm rows persist in OPFS.
5. Open a second tab and confirm busy/lock is reported as `:busy` rather than data loss.

## Copyright

(c) 2026 CBI BUSINESS TRANSACTIONS, LLC. Part of RailsRuntimes -- https://github.com/laquereric/DataYoursSoftwareMine. Licensed under Apache-2.0.
