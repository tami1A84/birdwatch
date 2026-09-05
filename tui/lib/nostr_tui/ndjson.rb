# frozen_string_literal: true

require "json"

module NostrTui
  # One JSON object per line, both directions (protocol v0).
  module Ndjson
    module_function

    def encode(hash) = "#{JSON.generate(hash)}\n"

    def parse(line)
      line = line.to_s.strip
      return nil if line.empty?

      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
  end
end
