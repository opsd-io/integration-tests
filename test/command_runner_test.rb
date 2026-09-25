# frozen_string_literal: true

require "minitest/autorun"

require_relative "../ci/command_runner"

class CommandRunnerTest < Minitest::Test
  FakeStatus = Struct.new(:success?, :exitstatus)

  def test_retries_only_matching_transient_failures
    attempts = 0
    sleeps = []
    runner = OPSd::CommandRunner.new(
      sleeper: ->(seconds) { sleeps << seconds },
      executor: lambda do |_environment, _command, _chdir|
        attempts += 1
        if attempts == 1
          OPSd::CommandRunner::Result.new(
            status: FakeStatus.new(false, 1),
            output: "422 database name is not available"
          )
        else
          OPSd::CommandRunner::Result.new(status: FakeStatus.new(true, 0), output: "")
        end
      end
    )

    result = runner.run!({}, ["tofu", "apply"], chdir: ".", retries: 3, retry_delay: 30, retry_on: OPSd::CommandRunner::TRANSIENT_API_ERROR)

    assert result.status.success?
    assert_equal 2, attempts
    assert_equal [30], sleeps
  end

  def test_does_not_retry_non_transient_failures
    attempts = 0
    runner = OPSd::CommandRunner.new(
      sleeper: ->(_seconds) { flunk "non-transient failure was retried" },
      executor: lambda do |_environment, _command, _chdir|
        attempts += 1
        OPSd::CommandRunner::Result.new(status: FakeStatus.new(false, 1), output: "invalid configuration")
      end
    )

    error = assert_raises(RuntimeError) do
      runner.run!({}, ["tofu", "apply"], chdir: ".", retries: 3, retry_delay: 30, retry_on: OPSd::CommandRunner::TRANSIENT_API_ERROR)
    end

    assert_includes error.message, "after 1 attempt"
    assert_equal 1, attempts
  end

  def test_exhausted_transient_retries_preserve_failure
    attempts = 0
    runner = OPSd::CommandRunner.new(
      sleeper: ->(_seconds) {},
      executor: lambda do |_environment, _command, _chdir|
        attempts += 1
        OPSd::CommandRunner::Result.new(status: FakeStatus.new(false, 1), output: "503 temporarily unavailable")
      end
    )

    error = assert_raises(RuntimeError) do
      runner.run!({}, ["tofu", "apply"], chdir: ".", retries: 3, retry_delay: 1, retry_on: OPSd::CommandRunner::TRANSIENT_API_ERROR)
    end

    assert_includes error.message, "after 3 attempt"
    assert_equal 3, attempts
  end
end
