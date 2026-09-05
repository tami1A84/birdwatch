# frozen_string_literal: true

module NostrCore
  # Exponential decay used by relay scoring. Ported from gossip's misc::exponential_decay.
  module Decay
    module_function

    # Evidence worth +base decays to base/2 after halflife_seconds.
    def exponential(base, halflife_seconds, elapsed_seconds)
      return 0.0 if base.zero? || elapsed_seconds.negative?

      base * (0.5**(elapsed_seconds.to_f / halflife_seconds))
    end
  end
end
