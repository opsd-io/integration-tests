# frozen_string_literal: true

require "tempfile"
require "yaml"
require "minitest/autorun"

require_relative "../ci/version_target"

class VersionTargetTest < Minitest::Test
  def test_scopes_database_version_updates_to_selected_engines
    manifest = {
      "spec" => {
        "compute_groups" => [],
        "databases" => [
          { "engine" => "mysql", "version" => "8.4" },
          { "engine" => "postgres", "version" => "16" }
        ]
      }
    }
    resolution = {
      "kubernetes" => { "latest" => "1.36.3-do.5", "previous" => "1.35.7-do.5" },
      "databases" => {
        "mysql" => { "latest" => "8.4", "previous" => "8" },
        "postgres" => { "latest" => "17", "previous" => "16" }
      }
    }

    Tempfile.create(["manifest", ".yaml"]) do |file|
      file.write(YAML.dump(manifest))
      file.flush

      OPSd::VersionTarget.apply!(file.path, "previous", resolution, engines: ["postgres"])

      databases = YAML.load_file(file.path).fetch("spec").fetch("databases")
      assert_equal "8.4", databases.fetch(0).fetch("version")
      assert_equal "16", databases.fetch(1).fetch("version")
    end
  end
end
