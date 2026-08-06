# frozen_string_literal: true
# Copyright 2026 CBI BUSINESS TRANSACTIONS, LLC
# SPDX-License-Identifier: Apache-2.0
# Part of RailsRuntimes -- https://github.com/laquereric/DataYoursSoftwareMine

require "rails_runtimes/store"
require "rails_runtimes/store/browser"
require_relative "opfs/version"
require_relative "opfs/sqlite_compiler"
require_relative "opfs/sqlite3_bridge"
require_relative "opfs/opfs_bridge"

# OPFS SQLite browser store integration for RailsRuntimes.
# Reuses Store::Browser::WorkerDriver; supplies SqliteCompiler + bridges.
module RailsRuntimes
  module Store
    module Opfs
      module_function

      def version = VERSION

      def hello
        { ok: true, gem: "rr-store-opfs", version: VERSION }
      end

      # Build a WorkerDriver backed by the in-process sqlite3 test bridge.
      def test_driver(schema: nil, database: ":memory:")
        bridge = Sqlite3Bridge.new(database: database)
        driver = Browser::WorkerDriver.new(bridge: bridge)
        if schema
          bridge.register_schema(schema)
          installed = driver.install_schema(schema).await
          return [driver, installed] if installed.err?

          DriverRegistry.register(schema, driver)
        end
        driver
      end

      # Register a browser OPFS worker driver for a schema.
      # In production, pass an OpfsBridge connected to the worker asset.
      def register!(schema, bridge:)
        driver = Browser::WorkerDriver.new(bridge: bridge)
        installed = driver.install_schema(schema).await
        return installed if installed.err?

        DriverRegistry.register(schema, driver)
        Outcome.ok(driver)
      end

      def worker_asset_path
        OpfsBridge.asset_path
      end
    end
  end
end
