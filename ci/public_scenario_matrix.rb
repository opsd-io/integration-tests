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

        overrides = deep_merge(
          lifecycle.fetch("manifest_overrides", {}),
          {
            "components" => {
              "infrastructure" => {
                "gateway-api" => {
                  "enabled" => true,
                  "values" => %w[public private].to_h do |profile|
                    [profile, { "enabled" => enabled_profiles.include?(profile) }]
                  end
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
            "execution_modes" => gateway_scenario.fetch("execution_modes", ["plan"]),
            "iac_tools" => gateway_scenario.fetch("iac_tools", ["render-only"])
          )
        )
      end

      ([lifecycle_scenario] + gateway_scenarios).map { |entry| entry.merge("provider" => provider) }
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
        "execution_modes" => base.fetch("execution_modes", ["plan", "apply"]),
        "iac_tools" => base["iac_tools"]
      }
    end
    private_class_method :scenario

  end
end
