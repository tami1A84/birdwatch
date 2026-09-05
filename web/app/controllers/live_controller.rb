# Streams every daemon frame to the browser as Server-Sent Events.
# The frame bus lives in the process-wide NostrdClient; one Queue per
# SSE connection, heartbeat every 15s so proxies keep the stream open.
class LiveController < ActionController::Base
  include ActionController::Live

  HEARTBEAT = 15

  def show
    response.headers["Content-Type"] = "text/event-stream; charset=utf-8"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"

    handle, queue = $nostrd.add_listener
    write "retry: 3000\n\n"
    loop do
      begin
        line = queue.pop(timeout: HEARTBEAT)
        write "data: #{line}\n\n"
      rescue ThreadError
        write ": ping\n\n" # keepalive
      end
    end
  rescue IOError, SystemCallError
    # browser went away — fall through to cleanup
  ensure
    $nostrd&.remove_listener(handle) if handle
    response.stream.close
  end

  private

  def write(text)
    response.stream.write(text)
  end
end
