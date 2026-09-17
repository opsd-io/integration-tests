#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "yaml"

require_relative "../ci/public_scenario_matrix"

config = YAML.load_file(ENV.fetch("COMPATIBILITY_FILE", "ci/public-compatibility.yaml"))
provider = config.fetch("provider")
module_refs = if ENV["OPSD_MODULES_REF"].to_s.strip.empty?
  config.fetch("modules").fetch(provider).fetch("refs")
else
  [ENV.fetch("OPSD_MODULES_REF")]
end
cli_refs = if ENV["OPSD_CLI_REF"].to_s.strip.empty?
  config.fetch("cli_refs", ["current"])
else
  [ENV.fetch("OPSD_CLI_REF")]
end.map do |ref|
  ref == "current" ? ENV.fetch("GITHUB_SHA") : ref
end
tools = config.fetch("iac_tools", %w[terraform tofu])
scenarios = OPSd::PublicScenarioMatrix.expand(config)

entries = cli_refs.flat_map do |cli_ref|
  module_refs.flat_map do |modules_ref|
    scenarios.flat_map do |scenario|
      tools.map do |iac_tool|
        {
          "provider" => provider,
          "cli_ref" => cli_ref,
          "modules_ref" => modules_ref,
          "scenario" => scenario.fetch("id"),
          "iac_tool" => iac_tool
        }
      end
    end
  end
end

abort "Compatibility matrix is empty" if entries.empty?
puts "matrix=#{JSON.generate({ "include" => entries })}"
