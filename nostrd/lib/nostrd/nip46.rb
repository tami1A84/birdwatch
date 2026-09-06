# frozen_string_literal: true

require "json"
require_relative "signer"

module Nostrd
  # NIP-46 remote signing request handling (transport-agnostic): a parsed
  # JSON-RPC-ish request hash in, a response hash out. The kind-24133 relay
  # transport (Nostrd::Bunker, NIP-44 encrypted) plugs in around this.
  #
  # Authorization model: a client must first `connect` — either it is already
  # on the persistent allowlist (bunker.json clients[]) or it presents the
  # configured secret, which then allowlists it. Every other method requires
  # a live session registered by a successful connect.
  class Nip46Handler
    METHODS = %w[connect get_public_key sign_event ping disconnect].freeze

    # config: responds to #secret (String|nil), #allow?(pubkey), #allow!(pubkey),
    # #clients (Nostrd::Bunker::Config in production).
    def initialize(signer:, config:)
      @signer = signer
      @config = config
      @sessions = {} # client_pubkey => {connected_at:, last_seen:}
    end

    # client_pubkey: the kind-24133 event author — the transport passes it so
    # a request can never claim someone else's identity via payload fields.
    def handle(request, client_pubkey:)
      req = request.is_a?(Hash) ? request.transform_keys(&:to_s) : {}
      method = req["method"].to_s
      return error(req["id"], -32601, "unknown method #{method}") unless METHODS.include?(method)
      return connect(req, client_pubkey) if method == "connect"

      # Session gate: every method except connect needs a prior successful
      # connect from this exact client pubkey.
      return error(req["id"], -32001, "not connected") unless @sessions.key?(client_pubkey)

      touch(client_pubkey)
      case method
      when "ping"
        { "id" => req["id"], "result" => "pong" }
      when "disconnect"
        @sessions.delete(client_pubkey)
        { "id" => req["id"], "result" => "ack" }
      else
        return error(req["id"], -32001, "signer is locked") if @signer.locked?

        case method
        when "get_public_key"
          { "id" => req["id"], "result" => @signer.pubkey }
        when "sign_event"
          sign_event(req)
        end
      end
    rescue StandardError => e
      error(req.is_a?(Hash) ? req["id"] : nil, -32000, e.message)
    end

    # Session registry (hash copy) for the info op / tests.
    def active_sessions = @sessions.dup

    def active?(pubkey) = @sessions.key?(pubkey)

    def clear_session(pubkey) = @sessions.delete(pubkey)

    private

    def connect(req, client_pubkey)
      params = Array(req["params"])
      remote = params[0].to_s
      unless remote.empty? || remote == @signer.pubkey
        return error(req["id"], -32001, "remote signer pubkey mismatch")
      end

      secret = params[1].to_s
      if @config.allow?(client_pubkey)
        # already trusted: reconnect without a secret
      elsif !secret.empty? && !@config.secret.to_s.empty? && secret == @config.secret
        # secret matches: allowlist the client permanently (persisted)
        @config.allow!(client_pubkey)
      else
        return error(req["id"], -32001, "connect not authorized")
      end

      now = Time.now.to_i
      @sessions[client_pubkey] = { connected_at: now, last_seen: now }
      { "id" => req["id"], "result" => "ack" }
    end

    def touch(pubkey)
      s = @sessions[pubkey]
      s[:last_seen] = Time.now.to_i if s
    end

    # params[0] is the event: Hash or JSON string per NIP-46. The result is
    # the JSON string of the full signed event (NIP-46 json_stringified form).
    def sign_event(req)
      params = Array(req["params"])
      event = params[0]
      event = JSON.parse(event) if event.is_a?(String)
      raise ArgumentError, "sign_event needs an event object" unless event.is_a?(Hash)

      created_at = event["created_at"].is_a?(Integer) ? event["created_at"] : Time.now.to_i
      signed = @signer.sign_event(event["kind"] || 1, event["content"].to_s,
                                  event["tags"] || [], created_at: created_at)
      { "id" => req["id"], "result" => JSON.generate(signed.transform_keys(&:to_s)) }
    end

    def error(id, code, message)
      { "id" => id, "error" => { "code" => code, "message" => message } }
    end
  end
end
