# frozen_string_literal: true

module NostrCore
  # Pure Nostr wire-message builders (NIP-01 subset used by the pool).
  module Subscription
    module_function

    def req(sub_id, filters) = ["REQ", sub_id, filters]

    def close(sub_id) = ["CLOSE", sub_id]

    # Discover where a person writes/reads: their kind 10002 replaceable event.
    def seek_relay_list(sub_id, pubkey) = req(sub_id, { authors: [pubkey], kinds: [10002], limit: 1 })

    # A person's kind 0 replaceable metadata: display name and NIP-05.
    def seek_profile(sub_id, pubkey) = req(sub_id, { authors: [pubkey], kinds: [0], limit: 1 })

    # A person's kind 3 contact list: who they follow. We merge our own into
    # the followed set so logging in adopts the account's real follows.
    def seek_contact_list(sub_id, pubkey) = req(sub_id, { authors: [pubkey], kinds: [3], limit: 1 })

    def relay_list?(event) = event.tags.any? { |t| t[0] == "r" }
  end
end
