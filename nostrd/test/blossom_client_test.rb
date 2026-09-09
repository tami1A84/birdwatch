# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "securerandom"
require_relative "../lib/nostrd/blossom"

module Nostrd
  module Blossom
    class ClientTest < Minitest::Test
      SK = SecureRandom.random_bytes(32)
      PK = NostrCore::Bip340.public_key(SK) # already hex

      def setup
        @dir = Dir.mktmpdir("blossom-client")
        @local = Server.new(dir: @dir, port: 0)
        @local.start
        # a "public" server that answers every request with 500: exercises
        # the miss path without touching the network
        @fake = TCPServer.new("127.0.0.1", 0)
        @fake_port = @fake.addr[1]
        @fake_thread = Thread.new do
          loop do
            sock = @fake.accept rescue break
            sock.write("HTTP/1.1 500 nope\r\nContent-Length: 0\r\n\r\n")
            sock.close rescue nil
          end
        end
      end

      def teardown
        @local.stop
        @fake.close
        @fake_thread&.kill
        FileUtils.remove_entry(@dir)
      end

      def local_url = "http://127.0.0.1:#{@local.port}"

      def fake_url = "http://127.0.0.1:#{@fake_port}"

      def auth_header(action:, body: nil)
        tags = [["t", action], ["expiration", (Time.now.to_i + 60).to_s]]
        tags << ["x", Digest::SHA256.hexdigest(body)] if body
        created_at = Time.now.to_i
        payload = NostrCore::Event.id_payload(PK, created_at, 24242, tags, "")
        id = Digest::SHA256.hexdigest(payload)
        sig = NostrCore::Bip340.sign([id].pack("H*"), SK, SecureRandom.random_bytes(32))
        ev = {"id" => id, "pubkey" => PK, "created_at" => created_at,
              "kind" => 24242, "tags" => tags, "content" => "", "sig" => sig.unpack1("H*")}
        "Nostr #{Base64.strict_encode64(JSON.generate(ev))}"
      end

      def test_put_uploads_to_local_server_and_dedupes
        data = "hello backup"
        ok, info = Client.put(local_url, "/upload", body: data, mime: "text/plain",
                              auth: auth_header(action: "upload", body: data))
        assert ok, info
        sha = Digest::SHA256.hexdigest(data)
        fetched = Client.get([local_url], "/#{sha}")
        assert_equal ["hello backup", "text/plain"], fetched
        # same bytes again: dedupe, still fine
        ok2, = Client.put(local_url, "/upload", body: data, mime: "text/plain",
                          auth: auth_header(action: "upload", body: data))
        assert ok2
      end

      def test_put_reports_failures_as_false_with_info
        ok, info = Client.put(fake_url, "/upload", body: "x", mime: "text/plain",
                              auth: auth_header(action: "upload", body: "x"))
        refute ok
        assert_includes info, "500"
        ok2, info2 = Client.put("http://127.0.0.1:1", "/upload", body: "x",
                                mime: "text/plain", auth: "Nostr x")
        refute ok2
        assert_match(/ERR/, info2)
      end

      def test_get_falls_through_to_first_healthy_source
        sha = Digest::SHA256.hexdigest("mirror me")
        Client.put(local_url, "/upload", body: "mirror me", mime: "text/plain",
                   auth: auth_header(action: "upload", body: "mirror me"))
        # public (500) first, local mirror second: the fallback order
        result = Client.get([fake_url, "http://127.0.0.1:1", local_url], "/#{sha}")
        assert_equal ["mirror me", "text/plain"], result
        # nothing has it
        assert_nil Client.get([fake_url, "http://127.0.0.1:1"], "/#{sha}")
      end

      def test_loopback_urls_are_detected_private
        assert Client.loopback?("http://127.0.0.1:7778")
        assert Client.loopback?("http://localhost:7778")
        assert Client.loopback?("http://[::1]:7778")
        refute Client.loopback?("https://nostr.download")
        assert Client.loopback?("not a url") # unparseable => treated private
      end
    end
  end
end
