# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module OPSd
  class DigitalOceanVersionResolver
    API_ROOT = "https://api.digitalocean.com/v2/"

    def initialize(token:, http_client: Net::HTTP)
      @token = token
      @http_client = http_client
    end

    def resolve(region:, engines: [])
      kubernetes = kubernetes_versions
      databases = engines.uniq.to_h do |engine|
        [engine, database_versions(engine)]
      end

      {
        "region" => region,
        "kubernetes" => pair(kubernetes),
        "databases" => databases.transform_values { |versions| pair(versions) }
      }
    end

    def kubernetes_versions
      payload = get("/kubernetes/options")
      versions = Array(payload.dig("options", "versions"))
      normalize_versions(versions)
    end

    def database_versions(engine)
      payload = get("/databases/options")
      engine_key = { "postgres" => "pg" }.fetch(engine.to_s, engine.to_s)
      normalize_versions(payload.dig("options", engine_key))
    end

    private

    def get(path)
      uri = URI.join(API_ROOT, path.delete_prefix("/"))
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@token}"
      request["Accept"] = "application/json"
      response = @http_client.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(request)
      end
      return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)

      raise "DigitalOcean API #{path} returned #{response.code}: #{response.body}"
    end

    def normalize_versions(values)
      Array(values).each_with_object([]) do |value, result|
        slug = value.is_a?(Hash) ? (value["slug"] || value["version"] || value["kubernetes_version"]) : value
        result << slug.to_s unless slug.to_s.empty?
      end.uniq.sort_by { |slug| version_key(slug) }
    end

    def version_key(slug)
      numbers = slug.to_s.scan(/\d+/).map(&:to_i)
      [numbers, slug.to_s]
    end

    def pair(versions)
      values = Array(versions)
      raise "DigitalOcean returned no versions: #{values.inspect}" if values.empty?

      { "previous" => values[-2], "latest" => values[-1] }
    end
  end
end
