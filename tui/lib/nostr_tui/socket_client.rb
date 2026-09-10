# frozen_string_literal: true

require "socket"
require "thread"
require_relative "ndjson"

module NostrTui
  # Thin unix-socket client for protocol v0. Reader thread pushes parsed
  # messages into a queue; the UI drains it between keypresses.
  class SocketClient
    attr_reader :messages, :path

    def initialize(socket_path)
      @path = socket_path
      @messages = Queue.new
      @sock = nil
      @reader = nil
    end

    def connect
      @sock = UNIXSocket.new(@path)
      transmit(op: "hello", client: "tui", proto: 1)
      @reader = Thread.new do
        @sock.each_line { |line| @messages << Ndjson.parse(line) }
      rescue IOError, Errno::EPIPE, Errno::ECONNRESET, EOFError
        @messages << { "ev" => "error", "code" => "disconnected" }
      end
      true
    rescue Errno::ENOENT, Errno::ECONNREFUSED
      false
    end

    def connected? = !@sock.nil?

    # No params.limit: the daemon's default applies (--history). Send an
    # explicit limit only if the TUI ever needs to override it per session.
    def subscribe_timeline
      transmit(op: "sub", id: "tl", channel: "timeline")
    end

    # SSS header data: follows + connected relays.
    def request_info
      transmit(op: "info", id: "info")
    end

    def post_note(text)
      transmit(op: "action", id: "post_#{Time.now.to_i}", name: "post_note", params: { text: text })
    end

    # NIP-22 comment: the daemon signs kind 1111 with the threading tags.
    def post_comment(text, id:, pubkey:, kind:, tags:)
      transmit(op: "action", id: "post_#{Time.now.to_i}", name: "post_comment",
               params: { text: text, parent: { id: id, pubkey: pubkey, kind: kind, tags: tags } })
    end

    # NIP-25 like: the daemon signs kind 7 against the selected note.
    def like(id:, pubkey:)
      transmit(op: "action", id: "like_#{Time.now.to_i}", name: "like",
               params: { id: id, pubkey: pubkey })
    end

    # Gossip relay switches: local-only change (advertise is separate).
    def relay_flags(url, read:, inbox:, write:, outbox:, discover:)
      transmit(op: "relay_flags", id: "rf_#{Time.now.to_i}",
               params: { url: url, read: read, inbox: inbox,
                         write: write, outbox: outbox, discover: discover })
    end

    # Advertise Relay List (gossip): publish kind 10002 from switch state.
    def unlock(passphrase)
    transmit(op: "unlock", id: "un_#{Time.now.to_i}",
             params: { "passphrase" => passphrase })
  end

  def import_key(key, passphrase)
    transmit(op: "import_key", id: "ik_#{Time.now.to_i}",
             params: { "key" => key, "passphrase" => passphrase })
  end

  def signout
    transmit(op: "lock", id: "lock_#{Time.now.to_i}")
  end

  def update_profile(json)
    transmit(op: "action", id: "prof_#{Time.now.to_i}", name: "update_profile",
             params: { "profile" => json })
  end

  def advertise_relays
      transmit(op: "advertise_relays", id: "adv_#{Time.now.to_i}")
    end

    # NIP-46 pairing: ask the daemon for its persistent bunker URI
    # (bunker://…?relay=…&secret=…). The result arrives as ev:"result" with
    # a matching id prefix; App#drain routes it to the QR modal.
    def bunker_secret
      transmit(op: "bunker_secret", id: "bsec_#{Time.now.to_i}")
    end

    # Remove a configured relay (local config only).
    def relay_remove(url)
      transmit(op: "relay_remove", id: "rm_#{Time.now.to_i}", params: { url: url })
    end

    # NIP-17 DM: the daemon wraps (kind 14 rumor → seal → gift) and publishes
    # to the partner's inbox relays. The ack carries our event id.
    def send_dm(pubkey, text)
      transmit(op: "send_dm", id: "dmsend_#{Time.now.to_i}",
               params: { pubkey: pubkey, text: text })
    end

    # Chat history over the dms channel: partner omitted = conversation list,
    # present = that thread's kind-14 rumors. sub lets App#drain route the
    # event frames (they share the generic "event" frame shape with timeline).
    def dms(partner: nil, limit: 50, sub: "dms")
      transmit(op: "sub", id: sub, channel: "dms",
               params: { partner: partner, limit: limit })
    end

    # Blossom upload: the daemon signs NIP-98, mirrors locally, then publishes
    # to public servers. The result frame carries the canonical URL.
    def blob_put(path)
      transmit(op: "blob_put", id: "bput_#{Time.now.to_i}", params: { path: path })
    end

    # Re-establish the session after a daemon restart: the launcher's first
    # connect does hello + timeline sub + info fetch, so replay all three.
    def reconnect
      close
      return false unless connect

      subscribe_timeline
      request_info
      true
    end

    def close
      @reader&.kill
      @sock&.close
    rescue IOError
      nil
    ensure
      @sock = nil
    end

    private

    def transmit(message)
      return false unless connected?

      @sock.write(Ndjson.encode(message))
      true
    rescue Errno::EPIPE, IOError
      @sock = nil # the socket died: connected? must stop claiming online
      false
    end
  end
end
