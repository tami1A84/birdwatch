# frozen_string_literal: true

require "socket"
require "openssl"
require "uri"
require "json"
require "websocket"

module Nostrd
  # One-shot direct publish to a single relay.
  #
  # The gossip pool dials relays the follows list points at, but a Buzz
  # Desktop install reads exactly one baked relay (VITE_RELAY_URL). Repo
  # announcements (kind 30617) for the Buzz Projects view therefore go
  # straight to that relay over a dedicated blocking connection instead of
  # joining the pool. Handles one NIP-42 AUTH challenge if the relay asks.
  module OneShot
    TIMEOUT = 10 # seconds for the whole dial-EVENT-OK exchange

    module_function

    # -> [ok(bool), message(String)]
    def publish(url, event, auth: nil, dial: nil)
      sock = dial ? dial.call(url) : dial_ws(url)
      hs = WebSocket::Handshake::Client.new(url: url)
      sock.write(hs.to_s)
      frames = WebSocket::Frame::Incoming::Client.new
      handshake_done = false
      auth_used = false
      deadline = Time.now.to_f + TIMEOUT
      loop do
        remaining = deadline - Time.now.to_f
        return [false, "timeout"] if remaining <= 0

        ready = IO.select([sock], nil, nil, remaining)
        return [false, "timeout"] unless ready

        data = sock.read_nonblock(65_536, exception: false)
        next if data == :wait_readable
        return [false, "connection closed"] if data.nil?

        frames << data if handshake_done
        unless handshake_done
          hs << data
          if hs.finished?
            return [false, "handshake failed: #{hs.error}"] unless hs.valid?

            handshake_done = true
            sock.write(frame_text(JSON.generate(["EVENT", event])))
            # a coalesced chunk can carry frames after the 101 response
            leftover = data[/\r\n\r\n(.*)/m, 1]
            frames << leftover if leftover && !leftover.empty?
          end
        end
        next unless handshake_done

        while (frame = frames.next)
          case frame.type
          when :close then return [false, "relay closed"]
          when :ping
            sock.write(pong_for(frame))
          when :text
            msg = JSON.parse(frame.data.to_s) rescue nil
            case msg&.first
            when "OK"
              return [msg[2] == true, msg[3].to_s]
            when "AUTH"
              return [false, "relay requires auth"] if auth.nil? || auth_used

              auth_used = true
              sock.write(frame_text(JSON.generate(["AUTH", auth.call(msg[1])])))
            end
          end
        end
      end
    ensure
      begin
        sock&.close
      rescue StandardError
        nil
      end
    end

    def dial_ws(url)
      uri = URI.parse(url)
      tcp = TCPSocket.new(uri.host, uri.port || (uri.scheme == "wss" ? 443 : 80))
      return tcp if uri.scheme == "ws"

      tls = OpenSSL::SSL::SSLSocket.new(tcp)
      tls.sync_close = true
      tls.connect
      tls
    rescue StandardError => e
      raise "dial #{url} failed: #{e.message}"
    end

    def frame_text(json)
      WebSocket::Frame::Outgoing::Client.new(data: json, type: :text, version: 13).to_s
    end

    def pong_for(frame)
      WebSocket::Frame::Outgoing::Client.new(data: frame.data.to_s, type: :pong, version: 13).to_s
    end
  end
end
