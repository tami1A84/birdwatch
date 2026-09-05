# frozen_string_literal: true

require_relative "signer"

module Nostrd
  # NIP-46 remote signing, transport-agnostic: JSON-RPC request hash in,
  # response hash out. The kind-24133 relay transport (NIP-44 encryption)
  # plugs in around this; the decision surface stays identical for the PWA.
  class Nip46Handler
    METHODS = %w[connect get_public_key sign_event ping].freeze

    def initialize(signer)
      @signer = signer
      @confirmed = false # full NIP-46 confirms via a shared secret challenge
    end

    def handle(request)
      method = request["method"].to_s
      return error(-32601, "unknown method #{method}") unless METHODS.include?(method)
      return error(-32001, "signer is locked") if @signer.locked? && method != "ping"

      case method
      when "connect"
        # v0: accept any connect; real flow requires echoing a secret first.
        @confirmed = true
        { id: request["id"], result: "connect confirmed" }
      when "get_public_key"
        { id: request["id"], result: @signer.pubkey }
      when "sign_event"
        return error(-32001, "not confirmed") unless @confirmed

        e = request["params"] || {}
        signed = @signer.sign_event(e["kind"] || 1, e["content"].to_s, e["tags"] || [],
                                    created_at: e["created_at"] || Time.now.to_i)
        { id: request["id"], result: signed.transform_keys(&:to_s) }
      when "ping"
        { id: request["id"], result: "pong" }
      end
    rescue StandardError => e
      error(-32000, e.message)
    end

    private

    def error(code, message)
      { error: { code: code, message: message } }
    end
  end
end
