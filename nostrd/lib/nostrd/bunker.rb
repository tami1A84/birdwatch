# frozen_string_literal: true

require "json"
require "securerandom"
require "uri"
require_relative "nip46"
require_relative "../nostr_core/nip44"

module Nostrd
  # NIP-46 bunker: persistent config (bunker.json) + kind-24133 relay
  # transport. Requests arrive as NIP-44-encrypted kind-24133 events p-tagged
  # to us; responses go back encrypted to the requesting client pubkey.
  class Bunker
    # bunker.json: secret (32 hex chars = 16 random bytes), allowlisted
    # client pubkeys, and the relays advertised in the bunker:// URI.
    # 0600 on disk — the secret gate-keeps signing access.
    class Config
      def self.default_path
        base = ENV.fetch("XDG_CONFIG_HOME", File.expand_path("~/.config"))
        File.join(base, "nostrd", "bunker.json")
      end

      attr_reader :path

      def initialize(path: nil)
        @path = path || self.class.default_path
        load
      end

      def secret = @data["secret"]

      def relays = @data["relays"] || []

      def relays=(urls)
        @data["relays"] = Array(urls).select { |u| u.to_s.start_with?("ws") }
        save
      end

      def clients = @data["clients"] || []

      def allow?(pubkey) = clients.include?(pubkey)

      # Persist an allowlisted client (64-hex). Called after a successful
      # secret connect so the next connection needs no secret.
      def allow!(pubkey)
        raise ArgumentError, "client pubkey must be 64 hex chars" unless
          pubkey.to_s.match?(/\A[0-9a-f]{64}\z/)

        unless clients.include?(pubkey)
          @data["clients"] = clients + [pubkey]
          save
        end
        pubkey
      end

      def forget!(pubkey)
        removed = clients.delete(pubkey)
        save if removed
        removed
      end

      # Idempotent: an existing secret is kept (clients already store it);
      # a first call mints 16 random bytes, hex-encoded, and saves.
      def ensure_secret!
        return secret unless secret.to_s.empty?

        @data["secret"] = SecureRandom.bytes(16).unpack1("H*")
        save
        secret
      end

      # bunker://<remote-signer-pubkey>?relay=...&relay=...&secret=... (NIP-46 §initiating)
      def bunker_uri(pubkey_hex)
        uri = "bunker://#{pubkey_hex}"
        sep = "?"
        relays.each do |r|
          uri << "#{sep}relay=#{URI.encode_www_form_component(r)}"
          sep = "&"
        end
        uri << "#{sep}secret=#{secret}"
        uri
      end

      # Returns nil when the file is missing (bunker stays disabled).
      def load
        @data = if File.exist?(@path)
                  JSON.parse(File.read(@path))
                else
                  {}
                end
      rescue JSON::ParserError
        # A corrupt config must not take the daemon down; start fresh and
        # the next save rewrites a valid file.
        @data = {}
      end

      def save
        dir = File.dirname(@path)
        require "fileutils"
        FileUtils.mkdir_p(dir)
        File.write(@path, JSON.pretty_generate(@data))
        File.chmod(0600, @path) # never world-readable
        @path
      end
    end

    attr_reader :config, :handler

    # pool may be nil (socket-op-only use, e.g. non-live daemon) — transport
    # methods no-op but the config/handler ops still work. default_relays
    # seeds the advertised relay set on first enable (the bunker:// URI must
    # carry relays the daemon actually listens on).
    def initialize(signer:, config:, pool: nil, my_pubkey: nil, handler: nil,
                   default_relays: [], logger: $stderr)
      @signer = signer
      @config = config
      @pool = pool
      @my_pubkey = my_pubkey || signer.pubkey
      @handler = handler || Nip46Handler.new(signer: signer, config: config)
      @default_relays = Array(default_relays)
      @logger = logger
      @subs = {} # url => true — relays currently carrying the bunker sub
    end

    # Enabled only when a config with a secret exists (bunker.json present).
    def enabled? = !@config.secret.to_s.empty?

    def active?(pubkey) = @handler.active?(pubkey)

    def session_pubkeys = @handler.active_sessions.keys

    def clients = @config.clients

    def bunker_uri(pubkey) = @config.bunker_uri(pubkey)

    # bunker_secret op: creates/loads the config and returns the connection
    # material. Never rotates an existing secret. First enable seeds the
    # advertised relays from the daemon's dial list so the URI is usable.
    def enable
      @config.relays = @default_relays if @config.relays.empty? && @default_relays.any?
      secret = @config.ensure_secret!
      # Subscribe immediately when live — otherwise the persistent kind-24133
      # sub waits for the next 30s tick and the first client connect misses.
      # (MUST run after ensure_secret!: enabled? gates on the secret.)
      if @pool
        ensure_subscribed((@pool.connections.keys + @config.relays).uniq)
      end

      { "secret" => secret,
        "relays" => @config.relays,
        "uri" => bunker_uri(@my_pubkey) }
    end

    # bunker_forget op: drop the client from the allowlist and kill its session.
    def forget!(pubkey)
      removed = @config.forget!(pubkey)
      @handler.clear_session(pubkey)
      removed
    end

    # --- transport ---------------------------------------------------------

    # Persistent kind-24133 inbox: one "bunker" sub per connected relay.
    # Called from the orchestrator tick so the sub survives reconnects.
    def ensure_subscribed(urls)
      return unless enabled? && @pool

      urls.each do |url|
        next if @subs.key?(url)

        @subs[url] = true if @pool.subscribe_bunker(url, "bunker", @my_pubkey)
      end
      (@subs.keys - urls).each { |url| @subs.delete(url) }
    end

    # Configured bunker relays must be dialed even if gossip never picks them.
    def relay_targets = enabled? ? @config.relays : []

    # Inbound kind-24133 event -> encrypted request -> handler -> encrypted
    # response. Never raises: relay threads call this on arrival. url is the
    # relay the request landed on — the response MUST reach that relay even
    # when it is not a gossip write relay, or the client never sees the ack.
    def handle_event(event, url: nil)
      return unless enabled?
      return unless event.is_a?(Hash) && event["kind"] == 24133

      client = event["pubkey"].to_s
      return if client == @my_pubkey # our own response events echo back
      return unless client.match?(/\A[0-9a-f]{64}\z/)
      return unless event["tags"].is_a?(Array) &&
                    event["tags"].any? { |t| t.is_a?(Array) && t[0] == "p" && t[1] == @my_pubkey }

      seckey = @signer.seckey
      return unless seckey # locked signer: cannot derive conversation keys

      request_json = NostrCore::Nip44.decrypt(seckey, [client].pack("H*"),
                                              event["content"].to_s)
      request = JSON.parse(request_json)
      response = @handler.handle(request, client_pubkey: client)
      respond(client, response, url: url)
    rescue JSON::ParserError, ArgumentError => e
      # Undecryptable/garbage requests are dropped with a warning — a
      # misbehaving client must not kill the relay thread.
      @logger.puts "bunker: dropped request from #{client[0, 8]}: #{e.class}"
    rescue StandardError => e
      @logger.puts "bunker: request from #{client[0, 8]} failed: #{e.class}: #{e.message}"
    end

    private

    def respond(client, response, url: nil)
      return unless response.is_a?(Hash)

      content = NostrCore::Nip44.encrypt(@signer.seckey, [client].pack("H*"),
                                         JSON.generate(response))
      event = @signer.sign_event(24133, content, [["p", client]])
      # Source relay first (that is where the client is listening), then the
      # regular gossip fan-out for redundancy.
      @pool&.publish(event, urls: url ? [url] : nil)
      @pool&.publish(event) if url
      event
    end
  end
end
