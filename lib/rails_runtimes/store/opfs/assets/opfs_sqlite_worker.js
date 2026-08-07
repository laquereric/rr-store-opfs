/**
 * RailsRuntimes OPFS SQLite worker (manual browser validation).
 * Copyright 2026 CBI BUSINESS TRANSACTIONS, LLC
 * SPDX-License-Identifier: LicenseRef-DataYoursSoftwareMine-1.0
 * Part of RailsRuntimes -- https://github.com/laquereric/DataYoursSoftwareMine
 *
 * Protocol (mirrors guidance §12):
 *   request:  { id, type: "boot"|"migrate"|"execute"|"transaction"|"diagnostics"|"close", payload? }
 *   reply:    { id, outcome: { ok, value?, reason?, because?, details? } }
 *
 * NOTE: This worker expects a host page to provide sqlite-wasm (sqlite3.mjs) via
 * importScripts or module worker setup. CI does not execute this file; use
 * Sqlite3Bridge for automated tests.
 */

/* global self, importScripts */

const ok = (value, details = {}) => ({ ok: true, value, details });
const err = (reason, because, details = {}) => ({ ok: false, reason, because, details });

let sqlite3 = null;
let db = null;

function quoteIdent(name) {
  return `"${String(name).replace(/"/g, '""')}"`;
}

async function openDatabase(profile, vfsPreference) {
  if (typeof importScripts === "function" && !sqlite3) {
    // Host must place sqlite3.js on the worker import path, or replace this with
    // a bundler-resolved ES module import of @sqlite.org/sqlite-wasm.
    try {
      importScripts("sqlite3.js");
      if (self.sqlite3InitModule) {
        sqlite3 = await self.sqlite3InitModule({
          print: (line) => console.debug("rr-sqlite", line),
          printErr: (line) => console.warn("rr-sqlite", line)
        });
      }
    } catch (e) {
      throw new Error(`sqlite-wasm bootstrap failed: ${e && e.message ? e.message : e}`);
    }
  }
  if (!sqlite3) {
    throw new Error("sqlite3 module not available in worker");
  }

  const pref = vfsPreference || "opfs-sahpool";
  if (pref === "opfs-sahpool" && sqlite3.installOpfsSAHPoolVfs) {
    await sqlite3.installOpfsSAHPoolVfs({
      name: "rr-opfs-pool",
      directory: `/rr/${profile}/pool`,
      initialCapacity: 12
    });
    db = new sqlite3.oo1.OpfsSAHPoolDb(`/rr/${profile}/store.sqlite3`);
  } else if (pref === "opfs-wl" && sqlite3.capi.sqlite3_vfs_find("opfs-wl")) {
    db = new sqlite3.oo1.OpfsWlDb(`file:/rr/${profile}/store.sqlite3?vfs=opfs-wl`);
  } else if (sqlite3.capi.sqlite3_vfs_find("opfs")) {
    db = new sqlite3.oo1.OpfsDb(`file:/rr/${profile}/store.sqlite3?vfs=opfs`);
  } else {
    throw new Error("No supported RR OPFS VFS is available");
  }
  db.exec("PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 2500;");
}

function sqliteType(type) {
  const map = {
    string: "TEXT", text: "TEXT", integer: "INTEGER", decimal: "TEXT",
    float: "REAL", boolean: "INTEGER", date: "TEXT", datetime: "TEXT",
    json: "TEXT", binary: "BLOB", uuid: "TEXT"
  };
  return map[String(type)] || "TEXT";
}

function installSchema(descriptor) {
  const table = descriptor.table;
  const cols = (descriptor.columns || []).map((f) => {
    const nullSql = f.null === false ? " NOT NULL" : "";
    const pk = f.primary_key ? " PRIMARY KEY" : "";
    return `${quoteIdent(f.name)} ${sqliteType(f.type)}${nullSql}${pk}`;
  });
  ["_rr_revision", "_rr_sync_state", "_rr_created_at", "_rr_updated_at", "_rr_tombstoned_at"].forEach((c) => {
    const t = c === "_rr_revision" ? "INTEGER" : "TEXT";
    cols.push(`${quoteIdent(c)} ${t}`);
  });
  db.exec(`CREATE TABLE IF NOT EXISTS ${quoteIdent(table)} (${cols.join(", ")})`);
  return { table };
}

function runStatement(statement) {
  const sql = statement.sql;
  const binds = statement.binds || statement.bind || [];
  if (statement.kind === "select" || statement.kind === "find") {
    const resultRows = [];
    db.exec({ sql, bind: binds, rowMode: "object", resultRows });
    return resultRows;
  }
  db.exec({ sql, bind: binds });
  return true;
}

function applyMigrate(payload) {
  const schemas = (payload && payload.bootstrap_schemas) || [];
  schemas.forEach((s) => installSchema(s));
  return { installed: schemas.length };
}

function executeUnit(unit) {
  db.exec("BEGIN IMMEDIATE");
  try {
    let result = null;
    (unit.statements || []).forEach((stmt) => {
      result = runStatement(stmt);
    });
    db.exec("COMMIT");
    return result;
  } catch (error) {
    try { db.exec("ROLLBACK"); } catch (_) { /* keep original */ }
    throw error;
  }
}

self.onmessage = async (event) => {
  const request = event.data || {};
  const id = request.id;
  try {
    let value;
    switch (request.type) {
      case "boot":
        await openDatabase(
          (request.payload && request.payload.profile) || "default",
          request.payload && request.payload.vfs
        );
        value = {
          sqliteVersion: sqlite3 && sqlite3.version ? sqlite3.version.libVersion : null,
          persistent: true
        };
        break;
      case "migrate":
        value = applyMigrate(request.payload || {});
        break;
      case "execute": {
        const payload = request.payload || {};
        if (payload.error) {
          self.postMessage({ id, outcome: payload.error });
          return;
        }
        value = runStatement(payload.statement || payload);
        break;
      }
      case "transaction": {
        const payload = request.payload || {};
        if (payload.error) {
          self.postMessage({ id, outcome: payload.error });
          return;
        }
        value = executeUnit(payload);
        break;
      }
      case "diagnostics":
        value = { open: !!db };
        break;
      case "close":
        if (db) { db.close(); db = null; }
        value = true;
        break;
      default:
        self.postMessage({ id, outcome: err("unknown_worker_request") });
        return;
    }
    self.postMessage({ id, outcome: ok(value) });
  } catch (error) {
    const message = String((error && error.message) || error);
    const reason = /busy|locked/i.test(message) ? "busy" : "sqlite_failed";
    self.postMessage({ id, outcome: err(reason, message) });
  }
};
