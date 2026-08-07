# frozen_string_literal: true
# Copyright 2026 CBI BUSINESS TRANSACTIONS, LLC
# SPDX-License-Identifier: LicenseRef-DataYoursSoftwareMine-1.0
# Part of RailsRuntimes -- https://github.com/laquereric/DataYoursSoftwareMine

require "spec_helper"

RSpec.describe RailsRuntimes::Store::Opfs do
  # ONE logical identity — multi-store routing is by (name, surface).
  def note_schema
    out = RailsRuntimes::Model.define("Notes::Note", table: "notes") do
      field :id, type: :uuid, null: false, primary_key: true, default: "__rr_uuid__"
      field :title, type: :string, null: false, default: ""
      field :body, type: :text, null: true
      identity :id, strategy: :client_uuid
      validates :title, :presence
      store surface: :server, table: "notes", driver_kind: :active_record
      store surface: :browser, table: "notes", driver_kind: :opfs_sqlite
      local_only
    end
    expect(out.ok?).to be(true), out.to_h.inspect
    out.value
  end

  def snapshot_repo(repo, id)
    found = repo.find(id).await
    expect(found.ok?).to be(true), found.to_h.inspect
    rec = found.value
    return nil if rec.nil?

    {
      id: rec.id,
      title: rec[:title],
      body: rec[:body],
      revision: rec.revision
    }
  end

  it "has a version and hello envelope" do
    expect(described_class::VERSION).to match(/\A\d+\.\d+\.\d+/)
    expect(described_class.hello[:ok]).to be(true)
  end

  it "ships a worker asset on disk" do
    path = described_class.worker_asset_path
    expect(File.file?(path)).to be(true)
    expect(File.read(path)).to include("onmessage")
  end

  describe "Sqlite3Bridge + WorkerDriver" do
    it "round-trips create/find/where/update/destroy with browser origin" do
      schema = note_schema
      driver = described_class.test_driver(schema: schema, surface: :browser)
      expect(driver.surface).to eq(:browser)
      expect(driver.driver_kind).to eq(:opfs_sqlite)

      repo = RailsRuntimes::Store.for(schema, surface: :browser)
      expect(repo).to be_a(RailsRuntimes::Store::Repository)
      expect(repo.driver).to eq(driver)

      created = repo.create(title: "Offline", body: "OPFS-path").await
      expect(created.ok?).to be(true), created.to_h.inspect
      record = created.value
      expect(record.origin.surface).to eq(:browser)
      expect(record.origin.driver_kind).to eq(:opfs_sqlite)
      expect(record.graph_terms).to include(
        ["urn:rr:record:#{record.id}", "urn:rr:storedIn", "urn:rr:store:browser:opfs_sqlite"]
      )

      found = repo.find(record.id).await
      expect(found.value[:title]).to eq("Offline")
      expect(found.value.origin.surface).to eq(:browser)

      updated = repo.update(record.id, { body: "Updated" }).await
      expect(updated.ok?).to be(true)
      expect(repo.find(record.id).await.value[:body]).to eq("Updated")

      expect(repo.destroy(record.id).await.ok?).to be(true)
      expect(repo.find(record.id).await.value).to be_nil
    end
  end

  describe "dual-surface Notes::Note (acceptance gates)" do
    it "registers SAME logical name on :server and :browser without collision" do
      schema = note_schema
      expect(schema.name).to eq("Notes::Note")
      expect(schema.graph_terms).to include(
        ["urn:rr:model:notes.note", "urn:rr:hasBinding", "urn:rr:binding:notes.note:server"]
      )
      expect(schema.graph_terms).to include(
        ["urn:rr:model:notes.note", "urn:rr:hasBinding", "urn:rr:binding:notes.note:browser"]
      )

      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
      ar = RailsRuntimes::Store::Server::ActiveRecordDriver.new
      expect(ar.install_schema(schema).await.ok?).to be(true)
      RailsRuntimes::Store::DriverRegistry.register(schema, ar, surface: :server)

      opfs = described_class.test_driver(schema: schema, surface: :browser)
      expect(opfs.surface).to eq(:browser)

      server_repo = RailsRuntimes::Store.for(schema, surface: :server)
      browser_repo = RailsRuntimes::Store.for(schema, surface: :browser)
      expect(server_repo.driver).to eq(ar)
      expect(browser_repo.driver).to eq(opfs)

      token = "22222222-2222-2222-2222-222222222222"
      a = server_repo.create(id: token, title: "Shared", body: "A").await
      b = browser_repo.create(id: token, title: "Shared", body: "B").await
      expect(a.ok?).to be(true), a.to_h.inspect
      expect(b.ok?).to be(true), b.to_h.inspect

      # same entity_token; origins differ by surface
      expect(a.value.id).to eq(token)
      expect(b.value.id).to eq(token)
      expect(a.value.origin.entity_token).to eq(token)
      expect(b.value.origin.entity_token).to eq(token)
      expect(a.value.origin.surface).to eq(:server)
      expect(b.value.origin.surface).to eq(:browser)
      expect(a.value.origin.driver_kind).to eq(:active_record)
      expect(b.value.origin.driver_kind).to eq(:opfs_sqlite)
      expect(a.value.origin.table).to eq("notes")
      expect(b.value.origin.table).to eq("notes")

      expect(a.value.graph_terms).to include(
        ["urn:rr:record:#{token}", "urn:rr:onSurface", "urn:rr:surface:server"]
      )
      expect(b.value.graph_terms).to include(
        ["urn:rr:record:#{token}", "urn:rr:onSurface", "urn:rr:surface:browser"]
      )
      expect(a.value.graph_terms).to include(
        ["urn:rr:record:#{token}", "urn:rr:viaBinding", "urn:rr:binding:notes.note:server"]
      )
      expect(b.value.graph_terms).to include(
        ["urn:rr:record:#{token}", "urn:rr:viaBinding", "urn:rr:binding:notes.note:browser"]
      )

      # Same token; independent store bodies until intentionally aligned
      expect(snapshot_repo(server_repo, token)[:title]).to eq("Shared")
      expect(snapshot_repo(browser_repo, token)[:title]).to eq("Shared")

      server_repo.update(token, { title: "Same2", body: "Aligned" }).await
      browser_repo.update(token, { title: "Same2", body: "Aligned" }).await
      expect(snapshot_repo(server_repo, token)).to eq(snapshot_repo(browser_repo, token))
    end
  end

  it "contains no private-substrate vocabulary in library sources" do
    root = File.expand_path("../lib", __dir__)
    hits = Dir[File.join(root, "**", "*.{rb,js}")].flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, i|
        if line.match?(/\b(Mmg|mmg-|urn:mm:|epic_|SAL|substrate|vv-|a2a)\b/i)
          "#{path}:#{i + 1}:#{line.strip}"
        end
      end
    end
    expect(hits).to eq([])
  end
end
