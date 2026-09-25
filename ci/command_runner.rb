# frozen_string_literal: true

require "open3"
require "shellwords"

module OPSd
  class CommandRunner
    Result = Struct.new(:status, :output, keyword_init: true)

    TRANSIENT_API_ERROR = /
      (?:\b429\b|\b500\b|\b502\b|\b503\b|\b504\b)|
      rate\s+limit|too\s+many\s+requests|temporarily\s+unavailable|
      eventual\s+consistency|already\s+exists|not\s+available|
      active\s+(?:members|subnets)|could\s+not\s+find\s+(?:cluster|resource)
    /ix

    def initialize(output: $stdout, error: $stderr, sleeper: ->(seconds) { sleep(seconds) }, executor: nil)
      @output = output
      @error = error
      @sleeper = sleeper
      @executor = executor || method(:execute)
    end

    def run!(environment, command, chdir:, retries: 1, retry_delay: 0, retry_on: nil)
      attempts = 0
      result = nil
      loop do
        result = @executor.call(environment, command, chdir)
        return result if result.status.success?

        attempts += 1
        break unless attempts < retries && retryable?(result.output, retry_on)

        @error.puts "Command failed; retrying in #{retry_delay}s (attempt #{attempts + 1}/#{retries})"
        @sleeper.call(retry_delay)
      end

      raise "Command failed after #{attempts} attempt(s) with status #{result.status.exitstatus || 1}: #{command_text(command)}"
    end

    def retryable?(output, pattern)
      return true if pattern.nil?

      output.match?(pattern)
    end

    private

    def execute(environment, command, chdir)
      captured = +""
      status = nil
      Open3.popen2e(environment, *command, chdir: chdir.to_s) do |stdin, stream, wait_thread|
        stdin.close
        stream.each_line do |line|
          @output.print line
          captured << line
        end
        status = wait_thread.value
      end
      Result.new(status: status, output: captured)
    end

    def command_text(command)
      Shellwords.join(command)
    end
  end
end
