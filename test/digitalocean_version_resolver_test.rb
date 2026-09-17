# frozen_string_literal: true

require "minitest/autorun"
require_relative "../ci/digitalocean_version_resolver"

class DigitalOceanVersionResolverTest < Minitest::Test
  FakeResponse = Struct.new(:code, :body) do
    def is_a?(klass)
      klass == Net::HTTPSuccess || super
    end
  end

  class FakeHttp
    attr_reader :paths

    def initialize
      @paths = []
    end

    def start(*_args, use_ssl:)
      yield self
    end

    def request(request)
      @paths << request.path
      body = case request.path
      when "/v2/kubernetes/options"
        { options: { versions: [{ slug: "1.36.3-do.5" }, { slug: "1.37.1-do.0" }] } }
      when "/v2/databases/options"
        { options: { engines: [{ slug: "mysql", versions: [{ slug: "8.0" }, { slug: "8.4" }] }] } }
      else
        raise "Unexpected path: #{request.path}"
      end
      FakeResponse.new("200", JSON.generate(body))
    end
  end

  def test_resolves_previous_and_latest_without_a_version_map
    http = FakeHttp.new
    result = OPSd::DigitalOceanVersionResolver.new(token: "secret", http_client: http).resolve(
      region: "fra1",
      engines: ["mysql"]
    )

    assert_equal "1.36.3-do.5", result.fetch("kubernetes").fetch("previous")
    assert_equal "1.37.1-do.0", result.fetch("kubernetes").fetch("latest")
    assert_equal "8.0", result.fetch("databases").fetch("mysql").fetch("previous")
    assert_equal "8.4", result.fetch("databases").fetch("mysql").fetch("latest")
    assert_equal ["/v2/kubernetes/options", "/v2/databases/options"], http.paths
  end
end
