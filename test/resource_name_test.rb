# frozen_string_literal: true

require "minitest/autorun"

require_relative "../ci/resource_name"

class ResourceNameTest < Minitest::Test
  def test_keeps_short_names_unchanged
    assert_equal "scenario-terraform-123", OPSd::ResourceName.bounded("scenario", %w[terraform 123])
  end

  def test_limits_long_names_and_keeps_distinct_inputs_unique
    first = OPSd::ResourceName.bounded("kubernetes-foundation", ["terraform", "cli-v2-0-0", "modules-main", "35225642401", "1"])
    second = OPSd::ResourceName.bounded("kubernetes-foundation", ["tofu", "cli-v2-0-0", "modules-main", "35225642401", "1"])

    assert_operator first.length, :<=, OPSd::ResourceName::MAX_LENGTH
    assert_operator second.length, :<=, OPSd::ResourceName::MAX_LENGTH
    refute_equal first, second
    assert_match(/\A[a-z0-9-]+\z/, first)
  end
end
