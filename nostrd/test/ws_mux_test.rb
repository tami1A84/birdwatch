# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/nostrd/ws_client"

# Bug 21: unregister() used to run close callbacks INSIDE the mux mutex, so a
# callback that closed the transport again (RelayPool drop -> transport.close)
# re-entered the mutex -> ThreadError. Callbacks must run outside the lock.
class WsMuxTest < Minitest::Test
  def setup
    @a, @b = UNIXSocket.pair
    @conn = Nostrd::WsMux::Conn.new("wss://t.example", @a)
    Nostrd::WsMux.instance_variable_get(:@conns)[@a] = @conn # register directly
  end

  def teardown
    @a.close rescue nil
    @b.close rescue nil
  end

  def test_reentrant_close_from_close_callback_does_not_deadlock
    closed = 0
    @conn.on_close { closed += 1; @conn.close rescue nil } # re-entrant close
    @conn.mark_open
    Nostrd::WsMux.unregister(@conn)
    assert_equal 1, closed # shutdown! ran exactly once
    Nostrd::WsMux.unregister(@conn) # second unregister: already gone
    assert_equal 1, closed # re-entrant close was a no-op, no re-shutdown
  end

  def test_receive_parses_frame_and_pings_get_ponged
    msgs = []
    @conn.on_message { |d| msgs << d }
    @conn.mark_open
    @conn.receive([0x81, 0x02].pack("C*") + "hi") # text frame "hi"
    assert_equal "hi", msgs.first

    drain_sock(@b) # clear any socket noise
    @conn.receive([0x89, 0x02].pack("C*") + "xy") # ping "xy" -> pong to @a
    sleep 0.05
    pong = (@b.read_nonblock(64) rescue "")
    assert_equal [0x8A], pong.bytes[0, 1] # pong opcode
  end

  private

  def drain_sock(sock)
    loop { sock.read_nonblock(4096) }
  rescue IO::WaitReadable, EOFError, Errno::EAGAIN
    nil
  end
end
