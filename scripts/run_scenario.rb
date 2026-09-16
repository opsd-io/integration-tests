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

TEST_ROOT = Pathname(__dir__).join("..").realpath
CLI_ROOT = Pathname(ENV.fetch("OPSD_CLI_ROOT")).realpath
scenario_id = ENV.fetch("OPSD_PUBLIC_SCENARIO")
modules_ref = ENV.fetch("OPSD_PUBLIC_MODULES_REF")
iac_tool = ENV.fetch("OPSD_PUBLIC_IAC_TOOL")
execution_mode = ENV.fetch("OPSD_EXECUTION_MODE", "plan")
compatibility_file = Pathname(ENV.fetch("OPSD_PUBLIC_COMPATIBILITY_FILE", "ci/public-compatibility.yaml"))
compatibility_file = TEST_ROOT.join(compatibility_file) unless compatibility_file.absolute?

abort "Unsupported IaC tool: #{iac_tool}" unless %w[terraform tofu].include?(iac_tool)
abort "Unsupported execution mode: #{execution_mode}" unless %w[plan apply].include?(execution_mode)

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

def run!(environment, command, chdir: CLI_ROOT, retries: 1, retry_delay: 0)
  puts "$ #{command_text(command)}"
  attempts = 0
  loop do
    return if system(environment, *command, chdir: chdir.to_s)

    attempts += 1
    break if attempts >= retries

    warn "Command failed; retrying in #{retry_delay}s (attempt #{attempts + 1}/#{retries})"
    sleep retry_delay
  end

  abort "Command failed with status #{$?.exitstatus || 1}: #{command_text(command)}"
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
    "managed-redis" => "redis"
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

  if Array(spec["caches"]).empty? && module_source.match?(/module\s+"redis"\s*\{/)
    abort "Rendered configuration still contains Redis after it was removed"
  end
end

def remove_placeholder_credentials!(rendered)
  rendered.glob("**/*.tfvars").each do |tfvars_file|
    content = tfvars_file.read
    sanitized = content.lines.reject { |line| line.include?("set-via-TF_VAR_digitalocean_token") }.join
    tfvars_file.write(sanitized) unless sanitized == content
  end
end

def namespace_manifest!(manifest_path, iac_tool)
  manifest = YAML.load_file(manifest_path)
  metadata = manifest.fetch("metadata")
  base_name = metadata.fetch("name")
  run_id = ENV.fetch("GITHUB_RUN_ID", Process.pid.to_s)
  attempt = ENV.fetch("GITHUB_RUN_ATTEMPT", "1")
  suffix = "#{iac_tool}-#{run_id}-#{attempt}".downcase.gsub(/[^a-z0-9-]/, "-")
  metadata["name"] = "#{base_name}-#{suffix}"
  File.write(manifest_path, YAML.dump(manifest))
end

def assert_removed_components!(rendered, removed_modules:)
  module_source = rendered.join("main.tf").read
  module_names = {
    "managed-mysql" => "mysql",
    "managed-postgres" => "postgres",
    "managed-redis" => "redis"
  }
  removed_modules.each do |removed_module|
    module_name = module_names.fetch(removed_module, removed_module)
    next unless module_source.match?(/module\s+"#{Regexp.escape(module_name)}(?:_\d+)?"\s*\{/)

    abort "Rendered configuration still contains removed module [#{removed_module}]"
  end
end
run_with_input!(child_env, opsd_command(opsd, "config", "profile", "create", "ci"), "digitalocean\n\nfra1\n")
run!(child_env, opsd_command(opsd, "config", "profile", "use", "ci"))
run!(child_env, opsd_command(opsd, "init", "blueprint", scenario.fetch("blueprint"), manifest_path.to_s, "--variant", scenario.fetch("variant")))
namespace_manifest!(manifest_path, iac_tool)

operations = scenario.fetch("operations", [])
stages = [{ "label" => "foundation", "operation" => nil }]
operations.each_with_index do |operation, index|
  command = operation.fetch("command")
  args = operation.fetch("args", [])
  stages << {
    "label" => operation.fetch("id", "step-#{index + 1}-#{command.join('-')}"),
    "operation" => [command, args],
    "covers" => Array(operation["covers"])
  }
end

active_rendered = nil
cleanup_done = false
state_path = run_root.join("#{iac_tool}.tfstate")
at_exit do
  next unless execution_mode == "apply" && !cleanup_done && active_rendered&.directory?

  warn "Cleaning up the active integration environment"
  system(child_env, iac_tool, "destroy", "-auto-approve", "-input=false", "-lock=false", "-state=#{state_path}", chdir: active_rendered.to_s)
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
  assert_removed_components!(rendered, removed_modules: stage.fetch("covers", [])) if operation&.first&.first == "remove"
  run!(child_env, [iac_tool, "init", "-backend=false", "-input=false"], chdir: rendered, retries: 3, retry_delay: 5)
  # The rendered directory is a generated artifact. Normalize it first, then
  # keep the check below as a guard against non-deterministic formatting.
  run!(child_env, [iac_tool, "fmt", "-recursive"], chdir: rendered)
  run!(child_env, [iac_tool, "fmt", "-check", "-recursive"], chdir: rendered)
  run!(child_env, [iac_tool, "validate"], chdir: rendered)
  state_args = ["-state=#{state_path}"]
  plan_args = [iac_tool, "plan", "-refresh=false", "-input=false", "-lock=false", *state_args]
  plan_args << "-var=digitalocean_token=public-plan-placeholder" if execution_mode == "plan"
  run!(child_env, plan_args, chdir: rendered)
  if execution_mode == "apply"
    run!(child_env, [iac_tool, "apply", "-auto-approve", "-input=false", "-lock=false", *state_args], chdir: rendered)
  end
  puts "Completed public scenario stage: #{stage.fetch('label')}"
end

if execution_mode == "apply"
  final_rendered = run_root.join("rendered-#{stages.length - 1}")
  run!(child_env, [iac_tool, "destroy", "-auto-approve", "-input=false", "-lock=false", "-state=#{state_path}"], chdir: final_rendered)
  cleanup_done = true
end

puts "Scenario passed: #{scenario_id} (#{iac_tool}, modules #{modules_ref}, mode #{execution_mode})"
