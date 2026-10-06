# frozen_string_literal: true

module OPSd
  module PublicScenarioMatrix
    module_function

    def expand(config)
      provider = config.fetch("provider")
      generation = config.fetch("scenario_generation")
      base = generation.fetch("base")
      lifecycle = generation.fetch("lifecycle")
      steps = lifecycle.fetch("steps", [])
      base_modules = Array(lifecycle["base_modules"])
      covered_modules = base_modules + steps.flat_map { |step| Array(step["covers"]) }
      missing_modules = Array(lifecycle["required_modules"]) - covered_modules.uniq
      abort "Lifecycle #{lifecycle.fetch('id')} does not cover required modules: #{missing_modules.join(', ')}" unless missing_modules.empty?

      lifecycle_scenario = scenario(
        lifecycle.fetch("id"),
        base.merge(
          "operations" => steps.map { |step| step.slice("id", "command", "args", "covers") },
          "required_modules" => lifecycle.fetch("required_modules", []),
          "base_modules" => base_modules,
          "metadata" => lifecycle.fetch("metadata", {}),
          "manifest_overrides" => lifecycle.fetch("manifest_overrides", {}),
          "expected_gateway_profiles" => []
        )
      )
      gateway_scenarios = Array(lifecycle["gateway_scenarios"]).map do |gateway_scenario|
        enabled_profiles = Array(gateway_scenario.fetch("enabled_profiles"))
        invalid_profiles = enabled_profiles - %w[public private]
        abort "Unsupported Gateway profiles: #{invalid_profiles.join(', ')}" unless invalid_profiles.empty?
        hostnames = gateway_scenario.fetch("hostnames", {})
        invalid_hostname_profiles = hostnames.keys - enabled_profiles
        abort "Hostnames configured for disabled Gateway profiles: #{invalid_hostname_profiles.join(', ')}" unless invalid_hostname_profiles.empty?

        gateway_values = %w[public private].to_h do |profile|
          values = { "enabled" => enabled_profiles.include?(profile) }
          values["hostname"] = hostnames.fetch(profile) if hostnames.key?(profile)
          [profile, values]
        end
        gateway_values["acme"] = gateway_scenario.fetch("acme") unless hostnames.empty?

        overrides = deep_merge(
          lifecycle.fetch("manifest_overrides", {}),
          {
            "components" => {
              "infrastructure" => {
                "gateway-api" => {
                  "enabled" => true,
                  "values" => gateway_values
                }
              }
            }
          }
        )
        scenario(
          gateway_scenario.fetch("id"),
          base.merge(
            "operations" => [],
            "required_modules" => base_modules,
            "base_modules" => base_modules,
            "metadata" => {},
            "manifest_overrides" => overrides,
            "expected_gateway_profiles" => enabled_profiles,
            "expected_gateway_tls" => hostnames.empty? ? {} : {
              "hostnames" => hostnames,
              "acme" => gateway_scenario.fetch("acme")
            },
            "execution_modes" => gateway_scenario.fetch("execution_modes", ["plan"]),
            "iac_tools" => gateway_scenario.fetch("iac_tools", ["render-only"])
          )
        )
      end

      external_dns_scenario = lifecycle["external_dns_scenario"]
      generated_scenarios = ([lifecycle_scenario] + gateway_scenarios)
      if external_dns_scenario
        values = external_dns_scenario.fetch("values")
        overrides = deep_merge(
          lifecycle.fetch("manifest_overrides", {}),
          {
            "components" => {
              "infrastructure" => {
                "external-dns" => { "enabled" => true, "values" => values }
              }
            }
          }
        )
        generated_scenarios << scenario(
          external_dns_scenario.fetch("id"),
          base.merge(
            "operations" => [],
            "required_modules" => base_modules,
            "base_modules" => base_modules,
            "metadata" => {},
            "manifest_overrides" => overrides,
            "expected_external_dns" => values,
            "execution_modes" => external_dns_scenario.fetch("execution_modes", ["plan"]),
            "iac_tools" => external_dns_scenario.fetch("iac_tools", ["render-only"])
          )
        )
      end

      external_secrets_scenario = lifecycle["external_secrets_scenario"]
      if external_secrets_scenario
        overrides = deep_merge(
          lifecycle.fetch("manifest_overrides", {}),
          {
            "components" => {
              "infrastructure" => {
                "external-secrets" => { "enabled" => true }
              }
            }
          }
        )
        generated_scenarios << scenario(
          external_secrets_scenario.fetch("id"),
          base.merge(
            "operations" => [],
            "required_modules" => base_modules,
            "base_modules" => base_modules,
            "metadata" => {},
            "manifest_overrides" => overrides,
            "expected_external_secrets" => true,
            "execution_modes" => external_secrets_scenario.fetch("execution_modes", ["plan"]),
            "iac_tools" => external_secrets_scenario.fetch("iac_tools", ["render-only"])
          )
        )
      end

      generated_scenarios.map { |entry| entry.merge("provider" => provider) }
    end

    def deep_merge(left, right)
      left.merge(right) do |_key, existing, replacement|
        existing.is_a?(Hash) && replacement.is_a?(Hash) ? deep_merge(existing, replacement) : replacement
      end
    end

    def scenario(id, base)
      {
        "id" => id,
        "blueprint" => base.fetch("blueprint"),
        "variant" => base.fetch("variant"),
        "operations" => base.fetch("operations", []),
        "required_modules" => base.fetch("required_modules", []),
        "base_modules" => base.fetch("base_modules", []),
        "metadata" => base.fetch("metadata", {}),
        "manifest_overrides" => base.fetch("manifest_overrides", {}),
        "expected_gateway_profiles" => base.fetch("expected_gateway_profiles", []),
        "expected_gateway_tls" => base.fetch("expected_gateway_tls", {}),
        "expected_external_dns" => base.fetch("expected_external_dns", {}),
        "expected_external_secrets" => base.fetch("expected_external_secrets", false),
        "execution_modes" => base.fetch("execution_modes", ["plan", "apply"]),
        "iac_tools" => base["iac_tools"]
      }
    end
    private_class_method :scenario

  end
end
