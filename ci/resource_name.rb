# frozen_string_literal: true

require "digest"

module OPSd
  module ResourceName
    MAX_LENGTH = 63

    module_function

    def bounded(base_name, labels, max_length: MAX_LENGTH)
      candidate = ([base_name] + labels).join("-")
      return candidate if candidate.length <= max_length

      digest = Digest::SHA256.hexdigest(candidate)[0, 8]
      prefix_length = max_length - digest.length - 1
      prefix = candidate[0, prefix_length].sub(/-+\z/, "")
      "#{prefix}-#{digest}"
    end
  end
end
