# frozen_string_literal: true
# Copyright 2026 CBI BUSINESS TRANSACTIONS, LLC
# SPDX-License-Identifier: Apache-2.0
# Part of RailsRuntimes -- https://github.com/laquereric/DataYoursSoftwareMine

require "rails_runtimes/store"

module RailsRuntimes
  module Store
    module Opfs
      # Compiles rr-store plans into parameterized SQLite statements.
      # Identifiers come only from the plan/schema; values are always bound.
      class SqliteCompiler
        TOMBSTONE = :_rr_tombstoned_at

        def initialize(schema_registry = nil)
          @schema_registry = schema_registry
        end

        def compile(plan)
          plan = plan.transform_keys(&:to_sym)
          case plan[:type].to_sym
          when :select then compile_select(plan)
          when :insert then compile_insert(plan)
          when :update then compile_update(plan)
          when :delete then compile_delete(plan)
          else
            Outcome.err(:unsupported_plan, details: { type: plan[:type] })
          end
        rescue StandardError => e
          Outcome.err(:compile_failed, because: e.message)
        end

        private

        def compile_select(plan)
          sql = "SELECT * FROM #{quote_ident(plan[:table])}"
          where = []
          binds = []

          Array(plan[:predicates]).each do |pred|
            p = pred.transform_keys(&:to_sym)
            case p[:kind].to_s
            when "eq"
              where << "#{quote_ident(p[:field])} = ?"
              binds << p[:value]
            when "in"
              arr = Array(p[:value])
              if arr.empty?
                where << "0 = 1"
              else
                where << "#{quote_ident(p[:field])} IN (#{(['?'] * arr.size).join(', ')})"
                binds.concat(arr)
              end
            when "null"
              where << "#{quote_ident(p[:field])} IS NULL"
            when "invalid"
              return Outcome.err(:invalid_query, details: { predicate: p })
            else
              return Outcome.err(:invalid_query, details: { kind: p[:kind] })
            end
          end

          where << "#{quote_ident(TOMBSTONE)} IS NULL" unless plan[:include_tombstones]
          sql += " WHERE #{where.join(' AND ')}" unless where.empty?

          Array(plan[:orders]).each_with_index do |(field, dir), i|
            sql += i.zero? ? " ORDER BY " : ", "
            sql += "#{quote_ident(field)} #{normalize_dir(dir)}"
          end
          sql += " LIMIT #{Integer(plan[:limit])}" if plan[:limit]
          sql += " OFFSET #{Integer(plan[:offset])}" if plan[:offset]

          Outcome.ok({ kind: :select, sql: sql, binds: binds })
        end

        def compile_insert(plan)
          attrs = (plan[:attributes] || plan[:values] || {}).transform_keys(&:to_sym)
          meta = (plan[:meta] || {}).transform_keys(&:to_sym)
          row = attrs.merge(meta)
          return Outcome.err(:empty_insert) if row.empty?

          cols = row.keys
          sql = "INSERT INTO #{quote_ident(plan[:table])} " \
                "(#{cols.map { |c| quote_ident(c) }.join(', ')}) " \
                "VALUES (#{(['?'] * cols.size).join(', ')})"
          Outcome.ok({ kind: :insert, sql: sql, binds: cols.map { |c| row[c] } })
        end

        def compile_update(plan)
          attrs = (plan[:attributes] || plan[:values] || {}).transform_keys(&:to_sym)
          meta = (plan[:meta] || {}).transform_keys(&:to_sym)
          row = attrs.merge(meta)
          return Outcome.err(:empty_update) if row.empty?

          id_field = plan[:id_field] || :id
          sets = row.keys.map { |c| "#{quote_ident(c)} = ?" }.join(", ")
          sql = "UPDATE #{quote_ident(plan[:table])} SET #{sets} " \
                "WHERE #{quote_ident(id_field)} = ?"
          binds = row.keys.map { |c| row[c] } + [plan[:id]]
          Outcome.ok({ kind: :update, sql: sql, binds: binds })
        end

        def compile_delete(plan)
          id_field = plan[:id_field] || :id
          if plan[:tombstone]
            sql = "UPDATE #{quote_ident(plan[:table])} " \
                  "SET #{quote_ident(TOMBSTONE)} = ?, " \
                  "#{quote_ident(:_rr_revision)} = #{quote_ident(:_rr_revision)} + 1 " \
                  "WHERE #{quote_ident(id_field)} = ?"
            Outcome.ok({ kind: :delete, sql: sql, binds: [plan[:tombstone_at] || Time.now.utc.iso8601, plan[:id]] })
          else
            sql = "DELETE FROM #{quote_ident(plan[:table])} WHERE #{quote_ident(id_field)} = ?"
            Outcome.ok({ kind: :delete, sql: sql, binds: [plan[:id]] })
          end
        end

        def quote_ident(name)
          # Double-quote SQLite identifiers; escape embedded quotes.
          %("#{name.to_s.gsub('"', '""')}")
        end

        def normalize_dir(dir)
          d = dir.to_s.upcase
          %w[ASC DESC].include?(d) ? d : "ASC"
        end
      end
    end
  end
end
