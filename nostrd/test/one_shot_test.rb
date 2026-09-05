# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "digest"
require_relative "../lib/nostrd/one_shot"

# A scripted socket backed by a real pipe (OneShot uses IO.select): a thread
# waits for the client handshake request, answers with a correct
# Sec-WebSocket-Accept, then replays the canned chunks and closes.
class FakeRelaySock
  attr_reader :written

  def initialize(chunks)
    @r, @w = IO.pipe
    @written = +""
    @mos = Mutex.new
    Thread.new do
      deadline = Time.now.to_f + 5
      loop do
        break if Time.now.to_f > deadline

        if @mos.synchronize { @written.include?("\r\n\r\n") }
          # keep handshake bytes and frame bytes in separate reads
          @w.write handshake_answer
          chunks.each { |c| @w.write c }
          @w.close
          break
        end
        sleep 0.01
      end
    rescue StandardError
      nil
    end
  end

  def handshake_answer
    key = @mos.synchronize { @written[/Sec-WebSocket-Key: (\S+)/, 1] }
    raise "no key in request" unless key

    accept = Base64.strict_encode64(Digest::SHA1.digest(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
      "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
  end

  # Decode the masked client frames that followed the HTTP request.
  def client_frames
    rest = @mos.synchronize { @written.dup }[/\r\n\r\n(.*)/m, 1].to_s
    frames = WebSocket::Frame::Incoming::Server.new
    frames << rest
    out = []
    loop do
      f = frames.next
      break unless f

      out << f.data.to_s
    end
    out
  end

  def to_io = @r

  def write(data)
    @mos.synchronize { @written << data }
    self
  end

  def read_nonblock(n, exception: false) = @r.read_nonblock(n, exception: exception)

  def close
    @r.close
    @w.close
  rescue StandardError
    nil
  end
end

def server_frame(json)
  WebSocket::Frame::Outgoing::Server.new(data: json, type: :text, version: 13).to_s
end

class OneShotTest < Minitest::Test
  EVENT = { id: "ab" * 32, pubkey: "cd" * 32, created_at: 1, kind: 30617, tags: [], content: "", sig: "e" * 128 }

  def test_publishes_event_and_returns_relay_ok
    sock = FakeRelaySock.new([server_frame('["OK","abab",true,"dup:3"]')])
    ok, message = Nostrd::OneShot.publish("wss://relay.example", EVENT, dial: ->(_u) { sock })

    assert ok
    assert_equal "dup:3", message
    texts = sock.client_frames
    assert texts.any? { |t| t.start_with?('["EVENT"') } # event went out after handshake
    assert texts.any? { |t| t.include?('"kind":30617') }
  end

  def test_answers_auth_challenge_then_retries_event_per_nip42
    auth_events = []
    sock = FakeRelaySock.new([
                               server_frame('["AUTH","chal-1"]'),
                               server_frame('["OK","abab",false,"auth-required: not authenticated"]'),
                               server_frame('["OK","abab",true,""]')
                             ])
    ok, = Nostrd::OneShot.publish("wss://relay.example", EVENT,
                                  auth: ->(challenge) {
                                    auth_events << challenge
                                    { kind: 22242, tags: [["challenge", challenge]] }
                                  },
                                  dial: ->(_u) { sock })

    assert ok
    assert_equal ["chal-1"], auth_events
    texts = sock.client_frames
    assert_equal 2, texts.count { |t| t.start_with?('["EVENT"') } # original + NIP-42 retry
    assert texts.any? { |t| t.start_with?('["AUTH"') } # challenge answered on the wire
  end

  def test_auth_retry_when_rejection_arrives_before_challenge
    sock = FakeRelaySock.new([
                               server_frame('["OK","abab",false,"auth-required: please authenticate"]'),
                               server_frame('["AUTH","chal-2"]'),
                               server_frame('["OK","abab",true,"dup:1"]')
                             ])
    ok, message = Nostrd::OneShot.publish("wss://relay.example", EVENT,
                                          auth: ->(c) { { kind: 22242, tags: [["challenge", c]] } },
                                          dial: ->(_u) { sock })

    assert ok
    assert_equal "dup:1", message
  end

  def test_rejection_surfaces_the_relay_message
    sock = FakeRelaySock.new([server_frame('["OK","abab",false,"blocked: not registered"]')])
    ok, message = Nostrd::OneShot.publish("wss://relay.example", EVENT, dial: ->(_u) { sock })

    refute ok
    assert_equal "blocked: not registered", message
  end
end
