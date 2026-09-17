# frozen_string_literal: true

module OPSd
  module VersionTarget
    module_function

    def apply!(manifest_path, target, resolution, engines: nil)
      return if target.nil? || resolution.nil?

      manifest = YAML.load_file(manifest_path)
      kubernetes_version = resolution.fetch("kubernetes").fetch(target)
      compute_groups = Array(manifest.dig("spec", "compute_groups"))
      compute_groups.each do |group|
        config = group["config"]
        config["kubernetes_version"] = kubernetes_version if config.is_a?(Hash) && config.key?("kubernetes_version")
      end

      databases = resolution.fetch("databases")
      Array(manifest.dig("spec", "databases")).each do |database|
        engine = database["engine"].to_s
        next if engines && !engines.include?(engine)
        next unless databases.key?(engine)

        database["version"] = databases.fetch(engine).fetch(target)
      end
      File.write(manifest_path, YAML.dump(manifest))
    end
  end
end
