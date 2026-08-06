# frozen_string_literal: true
# Copyright 2026 CBI BUSINESS TRANSACTIONS, LLC
# SPDX-License-Identifier: Apache-2.0
# Part of RailsRuntimes -- https://github.com/laquereric/DataYoursSoftwareMine

require "spec_helper"

RSpec.describe RailsRuntimes::Store::Opfs::SqliteCompiler do
  subject(:compiler) { described_class.new }

  it "compiles select with eq, order, limit, and tombstone filter" do
    plan = {
      type: :select,
      table: "rr_notes_notes",
      predicates: [{ kind: :eq, field: :title, value: "Hi" }],
      orders: [[:title, :asc]],
      limit: 5,
      offset: 1,
      include_tombstones: false
    }
    out = compiler.compile(plan)
    expect(out.ok?).to be(true), out.to_h.inspect
    stmt = out.value
    expect(stmt[:sql]).to include('SELECT * FROM "rr_notes_notes"')
    expect(stmt[:sql]).to include('"title" = ?')
    expect(stmt[:sql]).to include('"_rr_tombstoned_at" IS NULL')
    expect(stmt[:sql]).to include('ORDER BY "title" ASC')
    expect(stmt[:sql]).to include("LIMIT 5")
    expect(stmt[:sql]).to include("OFFSET 1")
    expect(stmt[:binds]).to eq(["Hi"])
  end

  it "compiles in predicates with separate binds" do
    plan = {
      type: :select,
      table: "t",
      predicates: [{ kind: :in, field: :id, value: %w[a b] }],
      orders: [],
      include_tombstones: true
    }
    out = compiler.compile(plan)
    expect(out.ok?).to be(true)
    expect(out.value[:sql]).to include('"id" IN (?, ?)')
    expect(out.value[:binds]).to eq(%w[a b])
    expect(out.value[:sql]).not_to include("_rr_tombstoned_at")
  end

  it "compiles insert from attributes+meta without interpolating values" do
    plan = {
      type: :insert,
      table: "t",
      attributes: { id: "x", title: "a'; DROP TABLE t;--" },
      meta: { _rr_revision: 1 }
    }
    out = compiler.compile(plan)
    expect(out.ok?).to be(true)
    expect(out.value[:sql]).to match(/INSERT INTO "t"/)
    expect(out.value[:sql]).to include("?")
    expect(out.value[:sql]).not_to include("DROP TABLE")
    expect(out.value[:binds]).to include("a'; DROP TABLE t;--")
  end

  it "compiles update with id bind last" do
    plan = {
      type: :update,
      table: "t",
      id: "row-1",
      id_field: :id,
      attributes: { title: "New" },
      meta: { _rr_revision: 2 }
    }
    out = compiler.compile(plan)
    expect(out.ok?).to be(true)
    expect(out.value[:sql]).to include('UPDATE "t" SET')
    expect(out.value[:sql]).to include('WHERE "id" = ?')
    expect(out.value[:binds].last).to eq("row-1")
  end

  it "compiles hard delete and tombstone delete" do
    hard = compiler.compile(type: :delete, table: "t", id: "1", id_field: :id, tombstone: false)
    expect(hard.ok?).to be(true)
    expect(hard.value[:sql]).to eq('DELETE FROM "t" WHERE "id" = ?')
    expect(hard.value[:binds]).to eq(["1"])

    soft = compiler.compile(
      type: :delete, table: "t", id: "1", id_field: :id, tombstone: true, tombstone_at: "2026-01-01T00:00:00Z"
    )
    expect(soft.ok?).to be(true)
    expect(soft.value[:sql]).to include('"_rr_tombstoned_at" = ?')
    expect(soft.value[:binds]).to eq(["2026-01-01T00:00:00Z", "1"])
  end

  it "rejects unknown plan types" do
    out = compiler.compile(type: :merge, table: "t")
    expect(out.err?).to be(true)
    expect(out.reason).to eq(:unsupported_plan)
  end
end
