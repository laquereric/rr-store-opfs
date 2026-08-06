/**
 * Thin main-thread loader for the RR OPFS SQLite worker.
 * Copyright 2026 CBI BUSINESS TRANSACTIONS, LLC
 * SPDX-License-Identifier: Apache-2.0
 * Part of RailsRuntimes -- https://github.com/laquereric/DataYoursSoftwareMine
 *
 * Usage (browser):
 *   const bridge = RailsRuntimesOpfsLoader.start({ workerUrl: "/assets/opfs_sqlite_worker.js" });
 *   const boot = await bridge.request({ type: "boot", payload: { profile: "default", vfs: "opfs-sahpool" } });
 */

(function (root) {
  function start(options) {
    options = options || {};
    const workerUrl = options.workerUrl || "opfs_sqlite_worker.js";
    const worker = new Worker(workerUrl, { name: "rr-store-opfs" });
    const pending = new Map();

    worker.onmessage = function (event) {
      const msg = event.data || {};
      const entry = pending.get(msg.id);
      if (!entry) return;
      pending.delete(msg.id);
      entry.resolve(msg.outcome || msg);
    };

    worker.onerror = function (event) {
      pending.forEach(function (entry) {
        entry.reject(event.error || new Error(event.message || "worker error"));
      });
      pending.clear();
    };

    function request(message) {
      const id = message.id || (typeof crypto !== "undefined" && crypto.randomUUID
        ? crypto.randomUUID()
        : String(Date.now()) + Math.random());
      const envelope = Object.assign({}, message, { id: id });
      return new Promise(function (resolve, reject) {
        pending.set(id, { resolve: resolve, reject: reject });
        worker.postMessage(envelope);
      });
    }

    return {
      worker: worker,
      request: request,
      close: function () {
        return request({ type: "close" }).finally(function () {
          worker.terminate();
        });
      }
    };
  }

  root.RailsRuntimesOpfsLoader = { start: start };
})(typeof self !== "undefined" ? self : this);
