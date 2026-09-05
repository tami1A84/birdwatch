# frozen_string_literal: true

require "socket"
require "openssl"
require "uri"
require "securerandom"
require "websocket"

module Nostrd
  # WsTransport v2: ONE reader thread multiplexes every relay connection with
  # IO.select. The old transport (websocket-client-simple) spawned a blocking
  # reader thread per connection — a thread leak as gossip grows the pool.
  # No new dependencies: the pure `websocket` gem does handshakes and frames.
  module WsMux
    HANDSHAKE_TIMEOUT = 5
    SELECT_TIMEOUT = 1

    @mos = Mutex.new
    @conns = {} # raw socket => Conn

    class Conn
      attr_reader :url

      def initialize(url, sock)
        @url = url
        @sock = sock
        @open = false
        @closed = false
        @frames = WebSocket::Frame::Incoming::Client.new
        @wmos = Mutex.new
        @open_cb = []
        @msg_cb = []
        @close_cb = []
      end

      def on_open(&b) = @open_cb << b
      def on_message(&b) = @msg_cb << b
      def on_close(&b) = @close_cb << b

      def receive(data)
        @frames << data
        while (frame = @frames.next)
          case frame.type
          when :ping then send_frame(WsMux.pong_for(frame)) # keep relays from timing us out
          when :close then return WsMux.unregister(self)
          when :pong then nil
          else
            unless @open
              @open = true
              @open_cb.each(&:call)
            end
            @msg_cb.each { |cb| cb.call(frame.data.to_s) } if frame.type == :text
          end
        end
      rescue StandardError => e
        WsMux.unregister(self, e)
      end

      def send_text(text)
        send_frame(WebSocket::Frame::Outgoing::Client.new(data: text, type: :text, version: 13).to_s)
      end

      def close
        send_frame(WebSocket::Frame::Outgoing::Client.new(type: :close, version: 13).to_s) if @open
      rescue StandardError
        nil
      ensure
        WsMux.unregister(self)
      end

      def shutdown!(err = nil)
        @closed = true
        cbs = @close_cb
        @sock.close rescue nil
        cbs.each { |cb| safe { cb.call(err) } }
      end

      def mark_open
        return if @open

        @open = true
        @open_cb.each { |cb| safe { cb.call } }
      end

      def send_frame(bytes)
        @wmos.synchronize { @sock.write(bytes) }
      rescue Errno::EPIPE, IOError, OpenSSL::SSL::SSLError => e
        WsMux.unregister(self, e)
        raise
      end

      def safe = yield
    rescue StandardError
      nil
    end

    module_function

    # Dial + websocket handshake. Blocks (caller dials in its own thread);
    # raises on failure so RelayPool can penalty-box dead relays loudly.
    def connect(url, transport)
      sock = dial(url)
      conn = Conn.new(url, sock)
      conn.on_open(&transport.open_callback)
      conn.on_message(&transport.message_callback)
      conn.on_close(&transport.close_callback)
      @mos.synchronize do
        @conns[conn.instance_variable_get(:@sock)] = conn
        spawn_reader
      end
      conn.mark_open # handshake completed in dial(); open == connected now
      conn
    end

    def dial(url)
      uri = URI.parse(url)
      tcp = TCPSocket.new(uri.host, uri.port || (uri.scheme == "wss" ? 443 : 80))
      tcp.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      tcp.timeout = HANDSHAKE_TIMEOUT # Ruby 3.4 IO#timeout: never block forever
      sock = wrap_tls(uri, tcp)
      key = SecureRandom.base64(16)
      path = uri.path.empty? ? "/" : uri.path
      path << "?#{uri.query}" if uri.query
      sock.write(
        "GET #{path} HTTP/1.1\r\nHost: #{uri.host}\r\nUpgrade: websocket\r\n" \
        "Connection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
      )
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HANDSHAKE_TIMEOUT
      head = +""
      while !head.include?("\r\n\r\n") && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        head << sock.readpartial(4096)
      end
      raise "handshake failed: #{head[/\AHTTP\/[\d.]+\s*(\S+)/, 1]}" unless head.include?(" 101")

      sock
    end

    def wrap_tls(uri, tcp)
      return tcp unless uri.scheme == "wss"

      ssl = OpenSSL::SSL::SSLSocket.new(tcp)
      ssl.sync_close = true
      ssl.hostname = uri.host
      ssl.connect
      ssl
    end

    def pong_for(frame)
      WebSocket::Frame::Outgoing::Client.new(data: frame.data, type: :pong, version: 13).to_s
    end

    def unregister(conn, err = nil)
      deleted = false
      @mos.synchronize do
        deleted = !!@conns.delete(conn.instance_variable_get(:@sock))
      end
      # bug 21: callbacks OUTSIDE the mutex — close callbacks re-enter the mux
      # (RelayPool drop -> transport.close -> Conn.close -> unregister).
      conn.shutdown!(err) if deleted
    end

    # The single reader thread. Dies when the last connection goes away and
    # respawns on the next connect — no idle threads between quiet periods.
    def spawn_reader
      return if @thread&.alive?

      @thread = Thread.new do
        Thread.current.name = "ws-mux" if Thread.current.respond_to?(:name=)
        loop do
          socks = @mos.synchronize { @conns.keys }
          break if socks.empty?

          ready = IO.select(socks, nil, nil, SELECT_TIMEOUT)
          next unless ready

          ready[0].each do |sock|
            conn = @mos.synchronize { @conns[sock] }
            next unless conn

            conn.receive(sock.read_nonblock(65_536))
          rescue IO::WaitReadable, Errno::EAGAIN
            next
          rescue SystemCallError, IOError, OpenSSL::SSL::SSLError => e
            unregister(conn, e)
          end
        end
      end
    end
  end

  # Public transport API — identical surface to the v1 (websocket-client-simple)
  # transport: open raises on failed handshake, callbacks fire on the mux thread.
  class WsTransport
    def initialize(url)
      @url = url
      @open_callbacks = []
      @message_callbacks = []
      @close_callbacks = []
    end

    def on_open(&b) = @open_callbacks << b
    def on_message(&b) = @message_callbacks << b
    def on_close(&b) = @close_callbacks << b

    # Blocks until the TLS+HTTP handshake is done; raises if the relay is dead.
    def open
      @mux_conn = WsMux.connect(@url, self)
      true
    end

    def send_text(text) = @mux_conn&.send_text(text)
    def close = @mux_conn&.close

    public

    def open_callback = -> { @open_callbacks.each(&:call) }
    def message_callback = ->(data) { @message_callbacks.each { |cb| cb.call(data) } }
    def close_callback = ->(*_e) { @close_callbacks.each(&:call) }
  end
end
