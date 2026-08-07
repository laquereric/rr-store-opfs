# frozen_string_literal: true
# Copyright 2026 CBI BUSINESS TRANSACTIONS, LLC
# SPDX-License-Identifier: LicenseRef-DataYoursSoftwareMine-1.0
# Part of RailsRuntimes -- https://github.com/laquereric/DataYoursSoftwareMine

require "sqlite3"
require "json"
require "rails_runtimes/store"
require_relative "sqlite_compiler"

module RailsRuntimes
  module Store
    module Opfs
      # In-process sqlite3 bridge for CI/tests.
      # Implements the same #request(type:, payload:) contract as the browser
      # OPFS worker bridge so WorkerDriver works without a real browser.
      class Sqlite3Bridge
        attr_reader :db, :compiler

        def initialize(database: ":memory:")
          @db = SQLite3::Database.new(database)
          @db.results_as_hash = true
          @db.execute("PRAGMA foreign_keys = ON")
          @schemas = {}
          @compiler = SqliteCompiler.new(self)
          @booted = false
        end

        def surface
          :browser
        end

        def driver_kind
          :opfs_sqlite
        end

        def fetch_by_table(table)
          @schemas[table.to_s]
        end

        def register_schema(schema)
          table = schema.respond_to?(:table_for) ? schema.table_for(surface) : schema.table
          @schemas[table.to_s] = schema
          self
        end

        # Bridge contract used by Store::Browser::WorkerDriver
        def request(type:, payload: nil)
          case type.to_sym
          when :boot
            @booted = true
            Outcome.ok({ engine: "sqlite3", persistent: database_persistent?, mode: "test" })
          when :execute
            execute_plan(payload)
          when :transaction
            execute_transaction(payload)
          when :migrate
            apply_migrate(payload)
          when :diagnostics
            Outcome.ok({ booted: @booted, tables: @schemas.keys.sort })
          when :close
            @db.close unless @db.closed?
            Outcome.ok(true)
          else
            Outcome.err(:unknown_worker_request, details: { type: type })
          end
        rescue SQLite3::BusyException => e
          Outcome.err(:busy, because: e.message)
        rescue SQLite3::ConstraintException => e
          Outcome.err(:constraint, because: e.message)
        rescue StandardError => e
          Outcome.err(:sqlite_failed, because: e.message)
        end

        private

        def database_persistent?
          # :memory: is not durable; file paths are treated as persistent for tests.
          path = begin
            @db.filename
          rescue StandardError
            ""
          end
          !(path.nil? || path.empty? || path == ":memory:")
        end

        def execute_plan(plan)
          plan = plan.transform_keys(&:to_sym)
          compiled = @compiler.compile(plan)
          return compiled if compiled.err?

          stmt = compiled.value
          case stmt[:kind].to_sym
          when :select
            rows = @db.execute(stmt[:sql], stmt[:binds])
            Outcome.ok(normalize_rows(rows))
          else
            @db.execute(stmt[:sql], stmt[:binds])
            Outcome.ok(true)
          end
        end

        def execute_transaction(unit)
          statements =
            if unit.respond_to?(:statements)
              Array(unit.statements)
            else
              u = unit.is_a?(Hash) ? unit.transform_keys(&:to_sym) : {}
              Array(u[:statements])
            end
          result = nil
          @db.transaction do
            statements.each do |stmt|
              result = execute_plan(stmt)
              raise SQLite3::SQLException, result.because.to_s if result.err?
            end
          end
          result || Outcome.ok(true)
        end

        def apply_migrate(payload)
          payload = payload.is_a?(Hash) ? payload.transform_keys(&:to_sym) : {}
          # Prefer live schema objects when WorkerDriver passes them.
          if payload[:schema_object]
            schema = payload[:schema_object]
            register_schema(schema)
            install_schema!(schema)
            return Outcome.ok({ table: schema.table })
          end

          Array(payload[:bootstrap_schemas]).each do |raw|
            schema = coerce_schema(raw)
            next unless schema

            register_schema(schema)
            install_schema!(schema)
          end

          Array(payload[:migrations]).each do |migration|
            # Full migration executor is rr-migrate; accept no-op for now.
            next if migration.nil?
          end

          Outcome.ok(true)
        end

        def coerce_schema(raw)
          return raw if raw.is_a?(RailsRuntimes::Model::Schema)
          return nil unless raw.is_a?(Hash)

          # Minimal table install from descriptor hash (no full Schema rebuild).
          OpenStructSchema.new(raw)
        end

        def install_schema!(schema)
          table = schema.respond_to?(:table_for) ? schema.table_for(surface) : schema.table
          cols = schema.columns.map do |f|
            sql_type = sqlite_type(f.type)
            null_sql = f.null ? "" : " NOT NULL"
            pk = f.primary_key ? " PRIMARY KEY" : ""
            "#{quote_ident(f.name)} #{sql_type}#{null_sql}#{pk}"
          end
          Columns.canonical.each do |c|
            t = c == :_rr_revision ? "INTEGER" : "TEXT"
            cols << "#{quote_ident(c)} #{t}"
          end
          sql = "CREATE TABLE IF NOT EXISTS #{quote_ident(table)} (#{cols.join(', ')})"
          @db.execute(sql)
        end

        def quote_ident(name)
          %("#{name.to_s.gsub('"', '""')}")
        end

        def sqlite_type(type)
          {
            string: "TEXT", text: "TEXT", integer: "INTEGER", decimal: "TEXT",
            float: "REAL", boolean: "INTEGER", date: "TEXT", datetime: "TEXT",
            json: "TEXT", binary: "BLOB", uuid: "TEXT"
          }[type.to_sym] || "TEXT"
        end

        def normalize_rows(rows)
          Array(rows).map do |row|
            row.each_with_object({}) do |(k, v), h|
              next if k.is_a?(Integer) # sqlite3 hash mode can duplicate numeric keys

              h[k.to_s] = v
            end
          end
        end

        # Lightweight stand-in when only a to_h descriptor is available.
        class OpenStructSchema
          Field = Struct.new(:name, :type, :null, :primary_key, keyword_init: true)

          attr_reader :table, :columns, :name

          def initialize(hash)
            h = hash.transform_keys(&:to_sym)
            @name = h[:name].to_s
            @table = h[:table].to_s
            @columns = Array(h[:columns]).map do |c|
              c = c.transform_keys(&:to_sym)
              Field.new(
                name: c[:name].to_sym,
                type: c[:type].to_sym,
                null: c.key?(:null) ? !!c[:null] : true,
                primary_key: !!c[:primary_key]
              )
            end
          end
        end
      end
    end
  end
end
