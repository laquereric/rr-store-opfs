# frozen_string_literal: true
# Copyright 2026 CBI BUSINESS TRANSACTIONS, LLC
# SPDX-License-Identifier: LicenseRef-DataYoursSoftwareMine-1.0
# Part of RailsRuntimes -- https://github.com/laquereric/DataYoursSoftwareMine

require "rails_runtimes/store/opfs"
require "rails_runtimes/store/server"
require "rails_runtimes/model"
require "active_record"

RSpec.configure do |c|
  c.disable_monkey_patching!

  c.before(:each) do
    RailsRuntimes::Store::DriverRegistry.reset!
  end
end
