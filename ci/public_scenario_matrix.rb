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

      [scenario(
        lifecycle.fetch("id"),
        base.merge(
          "operations" => steps.map { |step| step.slice("id", "command", "args", "covers") },
          "required_modules" => lifecycle.fetch("required_modules", []),
          "base_modules" => base_modules
        )
      )].map { |entry| entry.merge("provider" => provider) }
    end

    def scenario(id, base)
      {
        "id" => id,
        "blueprint" => base.fetch("blueprint"),
        "variant" => base.fetch("variant"),
        "operations" => base.fetch("operations", []),
        "required_modules" => base.fetch("required_modules", []),
        "base_modules" => base.fetch("base_modules", [])
      }
    end
    private_class_method :scenario

  end
end
