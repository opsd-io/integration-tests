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

  def test_expands_public_and_private_gateway_profiles_independently
    config = {
      "provider" => "digitalocean",
      "scenario_generation" => {
        "base" => { "blueprint" => "kubernetes-foundation", "variant" => "kubernetes" },
        "lifecycle" => {
          "id" => "lifecycle",
          "manifest_overrides" => {
            "kubernetes_config" => { "cluster_subnet" => "10.240.0.0/16" },
            "components" => { "infrastructure" => { "gateway-api" => { "enabled" => true } } }
          },
          "base_modules" => ["kubernetes"],
          "required_modules" => ["kubernetes"],
          "steps" => [],
          "gateway_scenarios" => [
            { "id" => "public", "enabled_profiles" => ["public"], "execution_modes" => ["plan"], "iac_tools" => ["render-only"] },
            { "id" => "private", "enabled_profiles" => ["private"], "execution_modes" => ["plan"], "iac_tools" => ["render-only"] }
          ]
        }
      }
    }

    scenarios = OPSd::PublicScenarioMatrix.expand(config).to_h { |scenario| [scenario.fetch("id"), scenario] }

    assert_equal [], scenarios.fetch("lifecycle").fetch("expected_gateway_profiles")
    assert_equal ["public"], scenarios.fetch("public").fetch("expected_gateway_profiles")
    assert_equal ["private"], scenarios.fetch("private").fetch("expected_gateway_profiles")
    assert_equal ["plan"], scenarios.fetch("public").fetch("execution_modes")
    assert_equal ["render-only"], scenarios.fetch("private").fetch("iac_tools")
    assert_equal "10.240.0.0/16", scenarios.fetch("private").dig("manifest_overrides", "kubernetes_config", "cluster_subnet")
    refute scenarios.fetch("private").dig("manifest_overrides", "components", "infrastructure", "gateway-api", "values", "public", "enabled")
  end

  def test_expands_gateway_tls_scenario_with_dns01_configuration
    config = {
      "provider" => "digitalocean",
      "scenario_generation" => {
        "base" => { "blueprint" => "kubernetes-foundation", "variant" => "kubernetes" },
        "lifecycle" => {
          "id" => "lifecycle",
          "base_modules" => [],
          "required_modules" => [],
          "steps" => [],
          "gateway_scenarios" => [
            {
              "id" => "gateway-tls",
              "enabled_profiles" => ["public"],
              "hostnames" => { "public" => "gateway.example.test" },
              "acme" => { "email" => "certs@example.test", "server" => "staging" }
            }
          ]
        }
      }
    }

    scenario = OPSd::PublicScenarioMatrix.expand(config).find { |entry| entry.fetch("id") == "gateway-tls" }

    assert_equal({ "public" => "gateway.example.test" }, scenario.dig("expected_gateway_tls", "hostnames"))
    assert_equal "staging", scenario.dig("manifest_overrides", "components", "infrastructure", "gateway-api", "values", "acme", "server")
    assert_equal "gateway.example.test", scenario.dig("manifest_overrides", "components", "infrastructure", "gateway-api", "values", "public", "hostname")
  end
end
