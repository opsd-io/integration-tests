#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "open3"
require "pathname"
require "rbconfig"
require "shellwords"
require "tempfile"
require "tmpdir"
require "yaml"

require_relative "../ci/public_scenario_matrix"
require_relative "../ci/command_runner"
require_relative "../ci/digitalocean_version_resolver"
require_relative "../ci/resource_name"
require_relative "../ci/version_target"

TEST_ROOT = Pathname(__dir__).join("..").realpath
CLI_ROOT = Pathname(ENV.fetch("OPSD_CLI_ROOT")).realpath
scenario_id = ENV.fetch("OPSD_PUBLIC_SCENARIO")
modules_ref = ENV.fetch("OPSD_PUBLIC_MODULES_REF")
iac_tool = ENV.fetch("OPSD_PUBLIC_IAC_TOOL")
execution_mode = ENV.fetch("OPSD_EXECUTION_MODE", "plan")
compatibility_file = Pathname(ENV.fetch("OPSD_PUBLIC_COMPATIBILITY_FILE", "ci/public-compatibility.yaml"))
compatibility_file = TEST_ROOT.join(compatibility_file) unless compatibility_file.absolute?

abort "Unsupported IaC tool: #{iac_tool}" unless %w[terraform tofu render-only].include?(iac_tool)
abort "Unsupported execution mode: #{execution_mode}" unless %w[plan apply].include?(execution_mode)
abort "render-only scenarios cannot run in apply mode" if iac_tool == "render-only" && execution_mode == "apply"

config = YAML.load_file(compatibility_file)
scenario = OPSd::PublicScenarioMatrix.expand(config).find { |entry| entry.fetch("id") == scenario_id }
abort "Unknown public scenario: #{scenario_id}" if scenario.nil?

run_root = Pathname(Dir.mktmpdir("opsd-public-#{scenario_id}-"))
workspace_root = run_root.join("workspace")
manifest_path = run_root.join("environment.yaml")
opsd = CLI_ROOT.join("bin/opsd").to_s

child_env = {
  "OPSD_APP_ROOT" => CLI_ROOT.to_s,
  "OPSD_WORKSPACE_ROOT" => workspace_root.to_s,
  "OPSD_PROFILE" => "ci",
  "OPSD_MODULES_DIGITALOCEAN_REF" => modules_ref
}

def command_text(command)
  Shellwords.join(command)
end

COMMAND_RUNNER = OPSd::CommandRunner.new

def run!(environment, command, chdir: CLI_ROOT, retries: 1, retry_delay: 0, retry_on: nil)
  puts "$ #{command_text(command)}"
  COMMAND_RUNNER.run!(environment, command, chdir: chdir, retries: retries, retry_delay: retry_delay, retry_on: retry_on)
rescue RuntimeError => e
  abort e.message
end

def run_with_input!(environment, command, input, chdir: CLI_ROOT)
  puts "$ #{command_text(command)} < stdin"
  stdout, stderr, status = Open3.capture3(environment, *command, stdin_data: input, chdir: chdir.to_s)
  print stdout unless stdout.empty?
  warn stderr unless stderr.empty?
  return if status.success?

  abort "Command failed with status #{status.exitstatus || 1}: #{command_text(command)}"
end

def opsd_command(opsd, *arguments)
  [opsd, *arguments]
end

def assert_rendered_components!(manifest_path, rendered, required_modules:, base_modules:)
  manifest = YAML.load_file(manifest_path)
  spec = manifest.fetch("spec", {})
  module_source = rendered.join("main.tf").read
  module_names = {
    "managed-mysql" => "mysql",
    "managed-postgres" => "postgres",
    "managed-valkey" => "valkey"
  }
  required_modules.uniq.each do |required_module|
    module_name = module_names.fetch(required_module, required_module)
    next if module_source.match?(/module\s+"#{Regexp.escape(module_name)}"\s*\{/)

    # A module is required for the lifecycle only after its corresponding step
    # has been applied. Earlier stages intentionally do not contain it.
    next unless Array(spec["databases"]).any? { |entry| entry.is_a?(Hash) && entry.fetch("engine", "") == required_module.delete_prefix("managed-") } ||
                Array(spec["caches"]).any? { |entry| entry.is_a?(Hash) && entry.fetch("engine", "") == required_module.delete_prefix("managed-") } ||
                base_modules.include?(required_module)

    abort "Rendered configuration is missing required module [#{required_module}] for #{manifest_path}"
  end

  if Array(spec["caches"]).empty? && module_source.match?(/module\s+"valkey"\s*\{/)
    abort "Rendered configuration still contains Valkey after it was removed"
  end
end

def remove_placeholder_credentials!(rendered)
  rendered.glob("**/*.tfvars").each do |tfvars_file|
    content = tfvars_file.read
    sanitized = content.lines.reject { |line| line.include?("set-via-TF_VAR_digitalocean_token") }.join
    tfvars_file.write(sanitized) unless sanitized == content
  end
end

def namespace_manifest!(manifest_path, iac_tool, cli_ref, modules_ref)
  manifest = YAML.load_file(manifest_path)
  metadata = manifest.fetch("metadata")
  base_name = metadata.fetch("name")
  run_id = ENV.fetch("GITHUB_RUN_ID", Process.pid.to_s)
  attempt = ENV.fetch("GITHUB_RUN_ATTEMPT", "1")
  ref_label = lambda do |ref|
    label = ref.to_s.downcase.gsub(/[^a-z0-9-]/, "-")
    label = label.gsub(/-+/, "-").sub(/\A-/, "").sub(/-\z/, "")
    label.empty? ? "ref" : label[0, 24].sub(/-\z/, "")
  end
  labels = [
    iac_tool,
    "cli-#{ref_label.call(cli_ref)}",
    "modules-#{ref_label.call(modules_ref)}",
    run_id,
    attempt
  ]
  metadata["name"] = OPSd::ResourceName.bounded(base_name, labels)
  File.write(manifest_path, YAML.dump(manifest))
end

def apply_manifest_overrides!(manifest_path, overrides)
  return if overrides.empty?

  manifest = YAML.load_file(manifest_path)
  spec = manifest.fetch("spec")
  overrides.fetch("kubernetes_config", {}).each do |key, value|
    spec.fetch("compute_groups").first.fetch("config")[key] = value
  end
  overrides.fetch("components", {}).each do |layer, components|
    target = spec.fetch("layers").fetch(layer).fetch("components")
    components.each do |component, settings|
      target[component] ||= {}
      target[component].merge!(settings)
    end
  end
  File.write(manifest_path, YAML.dump(manifest))
end

def assert_removed_components!(rendered, removed_modules:)
  module_source = rendered.join("main.tf").read
  module_names = {
    "managed-mysql" => "mysql",
    "managed-postgres" => "postgres",
    "managed-valkey" => "valkey"
  }
  removed_modules.each do |removed_module|
    module_name = module_names.fetch(removed_module, removed_module)
    next unless module_source.match?(/module\s+"#{Regexp.escape(module_name)}(?:_\d+)?"\s*\{/)

    abort "Rendered configuration still contains removed module [#{removed_module}]"
  end
end

def assert_gateway_profiles!(manifest_path, rendered, expected_profiles:)
  manifest = YAML.load_file(manifest_path)
  component = manifest.dig("spec", "layers", "infrastructure", "components", "gateway-api") || {}
  values = component.fetch("values", {})
  enabled_profiles = %w[public private].select { |profile| values.dig(profile, "enabled") == true }
  unless enabled_profiles.sort == expected_profiles.sort
    abort "Manifest Gateway profiles #{enabled_profiles.inspect} do not match scenario expectation #{expected_profiles.inspect}"
  end

  gateway_dir = rendered.join("layers", "10-infrastructure", "gateways")
  rendered_profiles = gateway_dir.directory? ? gateway_dir.glob("*.yaml").map { |path| path.basename(".yaml").to_s }.sort : []
  unless rendered_profiles == expected_profiles.sort
    abort "Rendered Gateway profiles #{rendered_profiles.inspect} do not match scenario expectation #{expected_profiles.inspect}"
  end

  expected_profiles.each do |profile|
    gateway = YAML.load_file(gateway_dir.join("#{profile}.yaml"))
    abort "#{profile} profile did not render a Gateway" unless gateway["kind"] == "Gateway"
    abort "#{profile} Gateway does not use the DOKS-managed Cilium class" unless gateway.dig("spec", "gatewayClassName") == "cilium"
    next unless profile == "private"

    network = gateway.dig("spec", "infrastructure", "annotations", "service.beta.kubernetes.io/do-loadbalancer-network")
    abort "Private Gateway is missing the internal load balancer setting" unless network == "INTERNAL"
  end
end

def assert_gateway_tls!(rendered, expected_tls:)
  return if expected_tls.empty?

  certificates_dir = rendered.join("layers", "10-infrastructure", "gateways", "certificates")
  cert_manager = YAML.load_file(certificates_dir.join("cert-manager.yaml"))
  abort "cert-manager Application did not render" unless cert_manager["kind"] == "Application"
  abort "cert-manager chart is not pinned" if cert_manager.dig("spec", "source", "targetRevision").to_s.empty?

  issuer = YAML.load_file(certificates_dir.join("cluster-issuer.yaml"))
  abort "ClusterIssuer did not render" unless issuer["kind"] == "ClusterIssuer"
  expected_server = expected_tls.dig("acme", "server") == "staging" ?
    "https://acme-staging-v02.api.letsencrypt.org/directory" :
    "https://acme-v02.api.letsencrypt.org/directory"
  abort "ClusterIssuer did not use the expected ACME server" unless issuer.dig("spec", "acme", "server") == expected_server
  solver = issuer.dig("spec", "acme", "solvers", 0, "dns01", "digitalocean")
  abort "ClusterIssuer is missing the DigitalOcean DNS-01 solver" unless solver.is_a?(Hash)

  expected_tls.fetch("hostnames").each do |profile, hostname|
    gateway = YAML.load_file(rendered.join("layers", "10-infrastructure", "gateways", "#{profile}.yaml"))
    listener = gateway.dig("spec", "listeners").find { |entry| entry["name"] == "https" }
    abort "#{profile} Gateway HTTPS listener has the wrong hostname" unless listener&.fetch("hostname") == hostname
    abort "#{profile} Gateway listener does not terminate TLS" unless listener&.dig("tls", "mode") == "Terminate"

    certificate = YAML.load_file(certificates_dir.join("#{profile}.yaml"))
    abort "#{profile} Certificate does not cover its Gateway hostname" unless certificate.dig("spec", "dnsNames") == [hostname]
    secret_name = certificate.dig("spec", "secretName")
    reference = listener.dig("tls", "certificateRefs", 0)
    abort "#{profile} Gateway does not reference the issued TLS Secret" unless reference&.fetch("name") == secret_name
  end
end

def assert_external_dns!(rendered, expected:)
  return if expected.empty?

  application_path = rendered.join("layers", "10-infrastructure", "external-dns.yaml")
  abort "ExternalDNS Application did not render" unless application_path.file?
  application = YAML.load_file(application_path)
  abort "ExternalDNS chart is not pinned" unless application.dig("spec", "source", "targetRevision") == "1.23.0"
  values = YAML.safe_load(application.dig("spec", "source", "helm", "values"))
  abort "ExternalDNS is missing Gateway API route and Service sources" unless values.fetch("sources").sort == %w[gateway-httproute service]
  abort "ExternalDNS is missing the configured domain filters" unless values.fetch("domainFilters") == expected.fetch("domain_filters")
  abort "ExternalDNS TXT ownership policy is incorrect" unless values.fetch("registry") == "txt" && values.fetch("txtOwnerId") == expected.fetch("txt_owner_id")
  abort "ExternalDNS deletion policy is unsafe or unexpected" unless values.fetch("policy") == expected.fetch("policy", "upsert-only")
  webhook_env = values.dig("provider", "webhook", "env")
  token = webhook_env.find { |entry| entry["name"] == "DO_TOKEN" }
  secret_ref = token&.dig("valueFrom", "secretKeyRef")
  abort "ExternalDNS token is not sourced from a Kubernetes Secret" unless secret_ref == {
    "name" => expected.fetch("token_secret_name", "digitalocean-dns"),
    "key" => "access-token"
  }
  abort "ExternalDNS domain filter is not applied to the webhook" unless webhook_env.any? do |entry|
    entry["name"] == "DO_DOMAIN_FILTER" && entry["value"] == expected.fetch("domain_filters").join(",")
  end
  abort "ExternalDNS webhook provider is not configured" unless values.dig("provider", "name") == "webhook" &&
    values.dig("extraArgs", "webhook-provider-url") == "http://localhost:8080"
end

def configure_local_backend!(rendered, state_path)
  rendered.join("backend.tf").write(<<~HCL)
    terraform {
      backend "local" {
        path = #{state_path.to_s.dump}
      }
    }
  HCL
end

def destroy_with_retries!(environment, iac_tool, chdir:, retries: 12, retry_delay: 15)
  command = [iac_tool, "destroy", "-auto-approve", "-input=false", "-lock=false"]
  puts "$ #{command_text(command)}"
  COMMAND_RUNNER.run!(
    environment,
    command,
    chdir: chdir,
    retries: retries,
    retry_delay: retry_delay,
    retry_on: OPSd::CommandRunner::TRANSIENT_API_ERROR
  )
  true
rescue RuntimeError => e
  warn e.message
  false
end

run_with_input!(child_env, opsd_command(opsd, "config", "profile", "create", "ci"), "digitalocean\n\nfra1\n")
run!(child_env, opsd_command(opsd, "config", "profile", "use", "ci"))
run!(child_env, opsd_command(opsd, "init", "blueprint", scenario.fetch("blueprint"), manifest_path.to_s, "--variant", scenario.fetch("variant")))
namespace_manifest!(manifest_path, iac_tool, ENV.fetch("OPSD_CLI_REF", "current"), modules_ref)
apply_manifest_overrides!(manifest_path, scenario.fetch("manifest_overrides", {}))

upgrade_metadata = scenario.dig("metadata", "version_upgrade") || {}
version_resolution = nil
if execution_mode == "apply" && upgrade_metadata.any?
  manifest = YAML.load_file(manifest_path)
  engines = Array(upgrade_metadata["databases"])
  resolver = OPSd::DigitalOceanVersionResolver.new(
    token: ENV.fetch("DIGITALOCEAN_TOKEN", ENV.fetch("TF_VAR_digitalocean_token"))
  )
  version_resolution = resolver.resolve(region: manifest.dig("metadata", "region"), engines: engines)
  File.write(run_root.join("version-resolution.yaml"), YAML.dump(version_resolution))
  kubernetes_versions = version_resolution.fetch("kubernetes")
  kubernetes_summary = kubernetes_versions["previous"] ?
    "#{kubernetes_versions["previous"]} -> #{kubernetes_versions["latest"]}" : kubernetes_versions["latest"]
  puts "Resolved provider versions: Kubernetes #{kubernetes_summary}" \
       + (engines.empty? ? "" : ", databases #{engines.join(", ")}")
end

operations = scenario.fetch("operations", [])
kubernetes_upgradeable = version_resolution && version_resolution.fetch("kubernetes").fetch("previous")
stages = [{ "label" => "foundation", "operation" => nil, "version_target" => kubernetes_upgradeable ? "previous" : "latest" }]
if kubernetes_upgradeable
  stages << {
    "label" => "upgrade-kubernetes",
    "operation" => nil,
    "version_target" => "latest",
    "version_engines" => []
  }
end
operations.each_with_index do |operation, index|
  command = operation.fetch("command")
  args = operation.fetch("args", [])
  stages << {
    "label" => operation.fetch("id", "step-#{index + 1}-#{command.join('-')}"),
    "operation" => [command, args],
    "covers" => Array(operation["covers"]),
    "version_target" => if version_resolution && command.length == 3 && command[0] == "add" && command[1] == "database" &&
                           Array(upgrade_metadata["databases"]).include?(command[2])
                         version_resolution.fetch("databases").fetch(command[2], {}).fetch("previous", nil) ? "previous" : "latest"
                       end,
    "version_engines" => if command.length == 3 && command[0] == "add" && command[1] == "database"
                           [command[2]]
                         end
  }
  if version_resolution && command.length == 3 && command[0] == "add" && command[1] == "database" &&
     Array(upgrade_metadata["databases"]).include?(command[2]) &&
     version_resolution.fetch("databases").fetch(command[2], {}).fetch("previous", nil)
    stages << {
      "label" => "upgrade-#{command[2]}",
      "operation" => nil,
      "version_target" => "latest",
      "version_engines" => [command[2]]
    }
  end
end

active_rendered = nil
cleanup_done = false
state_path = run_root.join("#{iac_tool}.tfstate")
at_exit do
  next unless execution_mode == "apply" && !cleanup_done && active_rendered&.directory?

  warn "Cleaning up the active integration environment"
  destroy_with_retries!(child_env, iac_tool, chdir: active_rendered)
end

stages.each_with_index do |stage, index|
  operation = stage.fetch("operation")
  unless operation.nil?
    command, args = operation
    if command.length == 3 && command[0] == "add"
      resource = command[1]
      value = command[2]
      run!(child_env, opsd_command(opsd, "add", resource, value, manifest_path.to_s, *args))
    elsif command.length == 2 && command[0] == "remove"
      resource = command[1]
      resource_id = args.fetch(0) { abort "Missing resource id for remove #{resource}" }
      run!(child_env, opsd_command(opsd, "remove", resource, manifest_path.to_s, resource_id, *args.drop(1)))
    else
      abort "Unsupported public scenario operation: #{command.inspect}"
    end
  end

  OPSd::VersionTarget.apply!(manifest_path, stage["version_target"], version_resolution, engines: stage["version_engines"])

  rendered = run_root.join("rendered-#{index}")
  active_rendered = rendered if execution_mode == "apply"
  run!(child_env, opsd_command(opsd, "validate", "manifest", manifest_path.to_s))
  run!(child_env, opsd_command(opsd, "render", "manifest", manifest_path.to_s, "--output", rendered.to_s))
  remove_placeholder_credentials!(rendered) if execution_mode == "apply"
  assert_rendered_components!(
    manifest_path,
    rendered,
    required_modules: scenario.fetch("required_modules", []),
    base_modules: scenario.fetch("base_modules", [])
  )
  assert_gateway_profiles!(manifest_path, rendered, expected_profiles: scenario.fetch("expected_gateway_profiles", []))
  assert_gateway_tls!(rendered, expected_tls: scenario.fetch("expected_gateway_tls", {}))
  assert_external_dns!(rendered, expected: scenario.fetch("expected_external_dns", {}))
  assert_removed_components!(rendered, removed_modules: stage.fetch("covers", [])) if operation&.first&.first == "remove"
  if iac_tool == "render-only"
    puts "Completed render-only scenario stage: #{stage.fetch('label')}"
    next
  end
  configure_local_backend!(rendered, state_path)
  run!(child_env, [iac_tool, "init", "-input=false"], chdir: rendered, retries: 3, retry_delay: 5)
  # The rendered directory is a generated artifact. Normalize it first, then
  # keep the check below as a guard against non-deterministic formatting.
  run!(child_env, [iac_tool, "fmt", "-recursive"], chdir: rendered)
  run!(child_env, [iac_tool, "fmt", "-check", "-recursive"], chdir: rendered)
  run!(child_env, [iac_tool, "validate"], chdir: rendered)
  plan_args = [iac_tool, "plan", "-refresh=false", "-input=false", "-lock=false"]
  plan_args << "-var=digitalocean_token=public-plan-placeholder" if execution_mode == "plan"
  run!(child_env, plan_args, chdir: rendered)
  if execution_mode == "apply"
    run!(
      child_env,
      [iac_tool, "apply", "-auto-approve", "-input=false", "-lock=false"],
      chdir: rendered,
      retries: 3,
      retry_delay: 30,
      retry_on: OPSd::CommandRunner::TRANSIENT_API_ERROR
    )
  end
  puts "Completed public scenario stage: #{stage.fetch('label')}"
end

if execution_mode == "apply"
  final_rendered = run_root.join("rendered-#{stages.length - 1}")
  abort "Unable to clean up the integration environment" unless destroy_with_retries!(child_env, iac_tool, chdir: final_rendered)
  cleanup_done = true
end

puts "Scenario passed: #{scenario_id} (#{iac_tool}, modules #{modules_ref}, mode #{execution_mode})"
