# frozen_string_literal: true
# Copyright 2026 CBI BUSINESS TRANSACTIONS, LLC
# SPDX-License-Identifier: Apache-2.0
# Part of RailsRuntimes -- https://github.com/laquereric/DataYoursSoftwareMine

require "spec_helper"

RSpec.describe RailsRuntimes::Store::Opfs do
  def note_schema(table:, name: nil)
    # DriverRegistry keys by schema.name — keep names unique per table.
    model_name = name || "Notes::#{table.split(/_+/).map { |p| p.capitalize }.join}"
    out = RailsRuntimes::Model.define(model_name, table: table) do
      field :id, type: :uuid, null: false, primary_key: true, default: "__rr_uuid__"
      field :title, type: :string, null: false, default: ""
      field :body, type: :text, null: true
      identity :id, strategy: :client_uuid
      validates :title, :presence
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

  def crud_sequence(repo, title_prefix:)
    created = repo.create(title: "#{title_prefix}-Hello", body: "World").await
    expect(created.ok?).to be(true), created.to_h.inspect
    record = created.value
    id = record.id

    found = snapshot_repo(repo, id)
    expect(found[:title]).to eq("#{title_prefix}-Hello")

    listed = repo.where(title: "#{title_prefix}-Hello").all.await
    expect(listed.ok?).to be(true)
    expect(listed.value.map(&:id)).to eq([id])

    updated = repo.update(id, { title: "#{title_prefix}-Hi" }).await
    expect(updated.ok?).to be(true), updated.to_h.inspect
    after_update = snapshot_repo(repo, id)
    expect(after_update[:title]).to eq("#{title_prefix}-Hi")
    expect(after_update[:revision]).to eq(2)

    destroyed = repo.destroy(id).await
    expect(destroyed.ok?).to be(true), destroyed.to_h.inspect
    missing = snapshot_repo(repo, id)
    expect(missing).to be_nil

    {
      id: id,
      after_create: { title: "#{title_prefix}-Hello", body: "World", revision: 1 },
      after_update: after_update,
      after_destroy: nil
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
    it "round-trips create/find/where/update/destroy" do
      schema = note_schema(table: "rr_opfs_notes")
      driver = described_class.test_driver(schema: schema)
      repo = RailsRuntimes::Store.for(schema)
      expect(repo).to be_a(RailsRuntimes::Store::Repository)
      expect(repo.driver).to eq(driver)

      created = repo.create(title: "Offline", body: "OPFS-path").await
      expect(created.ok?).to be(true), created.to_h.inspect
      id = created.value.id

      found = repo.find(id).await
      expect(found.value[:title]).to eq("Offline")

      updated = repo.update(id, { body: "Updated" }).await
      expect(updated.ok?).to be(true)
      expect(repo.find(id).await.value[:body]).to eq("Updated")

      expect(repo.destroy(id).await.ok?).to be(true)
      expect(repo.find(id).await.value).to be_nil
    end
  end

  describe "server AR vs OPFS bridge parity" do
    it "produces identical create/find/where/update/destroy results" do
      schema_ar = note_schema(table: "rr_parity_ar")
      schema_opfs = note_schema(table: "rr_parity_opfs")

      # --- server path ---
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
      ar_driver = RailsRuntimes::Store::Server::ActiveRecordDriver.new
      expect(ar_driver.install_schema(schema_ar).await.ok?).to be(true)
      RailsRuntimes::Store::DriverRegistry.register(schema_ar, ar_driver)
      ar_repo = RailsRuntimes::Store.for(schema_ar)
      ar_trace = crud_sequence(ar_repo, title_prefix: "AR")

      # --- browser/OPFS path via Sqlite3Bridge (CI stand-in) ---
      RailsRuntimes::Store::DriverRegistry.reset!
      opfs_driver = described_class.test_driver(schema: schema_opfs)
      opfs_repo = RailsRuntimes::Store.for(schema_opfs)
      expect(opfs_repo.driver).to eq(opfs_driver)
      opfs_trace = crud_sequence(opfs_repo, title_prefix: "OP")

      # Shape parity (ids differ because client UUIDs; values/revisions match pattern)
      expect(ar_trace[:after_create][:revision]).to eq(opfs_trace[:after_create][:revision])
      expect(ar_trace[:after_update][:revision]).to eq(opfs_trace[:after_update][:revision])
      expect(ar_trace[:after_create][:body]).to eq(opfs_trace[:after_create][:body])
      expect(ar_trace[:after_destroy]).to eq(opfs_trace[:after_destroy])

      # Side-by-side identical attribute payloads when ids are fixed
      fixed_id = "11111111-1111-1111-1111-111111111111"
      RailsRuntimes::Store::DriverRegistry.reset!
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
      schema_a = note_schema(table: "rr_parity_fixed_ar", name: "ParityAr::Note")
      schema_b = note_schema(table: "rr_parity_fixed_opfs", name: "ParityOpfs::Note")
      ar = RailsRuntimes::Store::Server::ActiveRecordDriver.new
      ar.install_schema(schema_a).await
      RailsRuntimes::Store::DriverRegistry.register(schema_a, ar)
      op = described_class.test_driver(schema: schema_b)

      ar_repo2 = RailsRuntimes::Store.for(schema_a)
      op_repo2 = RailsRuntimes::Store.for(schema_b)

      a = ar_repo2.create(id: fixed_id, title: "Same", body: "Body").await
      b = op_repo2.create(id: fixed_id, title: "Same", body: "Body").await
      expect(a.ok?).to be(true)
      expect(b.ok?).to be(true)
      expect(snapshot_repo(ar_repo2, fixed_id)).to eq(snapshot_repo(op_repo2, fixed_id))

      ar_repo2.update(fixed_id, { title: "Same2" }).await
      op_repo2.update(fixed_id, { title: "Same2" }).await
      expect(snapshot_repo(ar_repo2, fixed_id)).to eq(snapshot_repo(op_repo2, fixed_id))

      ar_repo2.destroy(fixed_id).await
      op_repo2.destroy(fixed_id).await
      expect(snapshot_repo(ar_repo2, fixed_id)).to eq(snapshot_repo(op_repo2, fixed_id))
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
