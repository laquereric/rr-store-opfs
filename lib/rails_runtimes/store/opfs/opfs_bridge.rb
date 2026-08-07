# frozen_string_literal: true
# Copyright 2026 CBI BUSINESS TRANSACTIONS, LLC
# SPDX-License-Identifier: LicenseRef-DataYoursSoftwareMine-1.0
# Part of RailsRuntimes -- https://github.com/laquereric/DataYoursSoftwareMine

require "rails_runtimes/store"
require "securerandom"
require_relative "sqlite_compiler"

module RailsRuntimes
  module Store
    module Opfs
      # Ruby-in-Wasm side of the OPFS worker bridge.
      # Posts compiled plans to the dedicated SQLite worker. Real OPFS path
      # requires a browser; CI uses Sqlite3Bridge instead.
      class OpfsBridge
        ASSET_RELATIVE = "assets/opfs_sqlite_worker.js"

        class << self
          def asset_path
            File.expand_path(ASSET_RELATIVE, __dir__)
          end

          def start(worker: nil, post: nil, **_opts)
            new(worker: worker, post: post)
          end
        end

        def initialize(worker: nil, post: nil)
          @worker = worker
          @post = post
          @compiler = SqliteCompiler.new
          @pending = {}
        end

        def boot(profile:, vfs: :"opfs-sahpool")
          request(type: :boot, payload: { profile: profile, vfs: vfs.to_s })
        end

        def request(type:, payload: nil)
          outbound = prepare_payload(type, payload)
          return Outcome.err(:worker_unavailable, because: "no worker transport configured") if @worker.nil? && @post.nil?

          id = SecureRandom.uuid
          message = { id: id, type: type.to_s, payload: outbound }

          if @post
            reply = @post.call(message)
            return Outcome.from_hash(extract_outcome(reply))
          end

          # Async worker: postMessage + onmessage correlation (browser only).
          # Without a real worker runtime this returns unavailable.
          if @worker.respond_to?(:postMessage)
            return Task.new do |resolve|
              @pending[id] = resolve
              @worker.postMessage(message)
            rescue StandardError => e
              resolve.call(Outcome.err(:worker_unavailable, because: e.message))
            end
          end

          Outcome.err(:worker_unavailable, because: "worker does not support postMessage")
        rescue StandardError => e
          Outcome.err(:worker_unavailable, because: e.message)
        end

        # Browser runtime should call this from the worker's onmessage handler.
        def handle_reply(message)
          msg = message.respond_to?(:transform_keys) ? message.transform_keys(&:to_sym) : {}
          id = msg[:id]
          resolve = @pending.delete(id)
          return unless resolve

          resolve.call(Outcome.from_hash(extract_outcome(msg)))
        end

        private

        def prepare_payload(type, payload)
          case type.to_sym
          when :execute
            plan = payload.is_a?(Hash) ? payload.transform_keys(&:to_sym) : payload
            compiled = @compiler.compile(plan)
            return { error: compiled.to_h } if compiled.err?

            { statement: compiled.value }
          when :transaction
            unit = payload.is_a?(Hash) ? payload.transform_keys(&:to_sym) : {}
            statements = Array(unit[:statements]).map do |stmt|
              compiled = @compiler.compile(stmt)
              return { error: compiled.to_h } if compiled.err?

              compiled.value
            end
            { statements: statements, oplog_entry: unit[:oplog_entry] }
          when :migrate
            # Pass schema descriptors; worker materializes CREATE TABLE.
            if payload.is_a?(Hash)
              p = payload.transform_keys(&:to_sym)
              p.delete(:schema_object) # not JSON-serializable for worker
              p
            else
              payload
            end
          else
            payload
          end
        end

        def extract_outcome(reply)
          return reply if reply.is_a?(Outcome)
          return reply unless reply.is_a?(Hash)

          h = reply.transform_keys(&:to_sym)
          h[:outcome] || h
        end
      end
    end
  end
end
