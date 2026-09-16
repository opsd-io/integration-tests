# frozen_string_literal: true

module OPSd
  module PublicScenarioMatrix
    module_function

    def expand(config)
      provider = config.fetch("provider")
      generation = config.fetch("scenario_generation")
      base = generation.fetch("base")
      capabilities = generation.fetch("capabilities")

      scenarios = [scenario("kubernetes-foundation", base)]

      capabilities.each do |resource, capability|
        Array(capability.fetch("engines", [nil])).each do |engine|
          id = ["kubernetes-foundation", "with", resource, engine].compact.join("-")
          resource_id_value = resource_id(resource, 1)
          scenarios << scenario(
            id,
            base.merge("operations" => [
              add_operation(resource, engine, id: resource_id_value),
              remove_operation(resource, resource_id_value)
            ])
          )
        end
      end

      capabilities.each do |resource, capability|
        max_count = capability.fetch("max_count", 1)
        next unless max_count > 1

        engine = Array(capability.fetch("engines", [nil])).first
        operations = (1..max_count).map do |index|
          add_operation(resource, engine, id: resource_id(resource, index))
        end
        operations.concat((1..max_count).to_a.reverse.map { |index| remove_operation(resource, resource_id(resource, index)) })
        id = ["kubernetes-foundation", "with", max_count, resource].join("-")
        scenarios << scenario(id, base.merge("operations" => operations))
      end

      capabilities.to_a.combination(2).each do |(left_resource, left_capability), (right_resource, right_capability)|
        left_engine = Array(left_capability.fetch("engines", [nil])).first
        right_engine = Array(right_capability.fetch("engines", [nil])).first
        id = ["kubernetes-foundation", "with", left_engine, right_engine].compact.join("-")
        operations = [
          add_operation(left_resource, left_engine, id: resource_id(left_resource, 1)),
          add_operation(right_resource, right_engine, id: resource_id(right_resource, 1)),
          remove_operation(right_resource, resource_id(right_resource, 1)),
          remove_operation(left_resource, resource_id(left_resource, 1))
        ]
        scenarios << scenario(id, base.merge("operations" => operations))
      end

      scenarios.uniq { |entry| entry.fetch("id") }.map do |entry|
        entry.merge("provider" => provider)
      end
    end

    def scenario(id, base)
      {
        "id" => id,
        "blueprint" => base.fetch("blueprint"),
        "variant" => base.fetch("variant"),
        "operations" => base.fetch("operations", [])
      }
    end
    private_class_method :scenario

    def add_operation(resource, engine, id: nil)
      command_resource = resource.to_s.delete_suffix("s")
      args = id.nil? ? [] : ["--id", id]
      { "command" => ["add", command_resource, engine], "args" => args }
    end
    private_class_method :add_operation

    def resource_id(resource, index)
      prefix = resource.to_s.delete_suffix("s")
      "#{prefix}-#{index}"
    end
    private_class_method :resource_id

    def remove_operation(resource, id)
      { "command" => ["remove", resource.to_s.delete_suffix("s")], "args" => [id] }
    end
    private_class_method :remove_operation
  end
end
