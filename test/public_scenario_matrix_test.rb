# frozen_string_literal: true

require "minitest/autorun"
require_relative "../ci/public_scenario_matrix"

class PublicScenarioMatrixTest < Minitest::Test
  def test_preserves_scenario_metadata
    config = {
      "provider" => "digitalocean",
      "scenario_generation" => {
        "base" => { "blueprint" => "kubernetes-foundation", "variant" => "kubernetes" },
        "lifecycle" => {
          "id" => "lifecycle",
          "metadata" => { "version_upgrade" => { "kubernetes" => true } },
          "base_modules" => ["kubernetes"],
          "required_modules" => ["kubernetes"],
          "steps" => []
        }
      }
    }

    scenario = OPSd::PublicScenarioMatrix.expand(config).fetch(0)

    assert_equal true, scenario.fetch("metadata").fetch("version_upgrade").fetch("kubernetes")
  end

  def test_preserves_manifest_overrides
    overrides = { "kubernetes_config" => { "cluster_subnet" => "10.240.0.0/16" } }
    config = {
      "provider" => "digitalocean",
      "scenario_generation" => {
        "base" => { "blueprint" => "kubernetes-foundation", "variant" => "kubernetes" },
        "lifecycle" => {
          "id" => "lifecycle",
          "manifest_overrides" => overrides,
          "base_modules" => [], "required_modules" => [], "steps" => []
        }
      }
    }

    scenario = OPSd::PublicScenarioMatrix.expand(config).fetch(0)

    assert_equal overrides, scenario.fetch("manifest_overrides")
  end
end
