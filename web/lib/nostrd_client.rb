# frozen_string_literal: true

require "socket"
require "json"

# Process-wide client for the nostrd daemon's NDJSON unix socket
# (docs/protocol.md). The Rails app owns NO keys and NO database:
#
# * request/response: op frames with id matching (sub, get, action, info, …)
# * one permanent "timeline" subscription feeds an in-process cache of
#   events (kinds 1, 7, 1111) and kind-0 profiles
# * a fan-out bus mirrors every daemon frame to SSE listeners (LiveController)
#
# The reader thread reconnects forever with a short backoff; requests raised
# while offline fail fast with DaemonDown. Pages that only read the cache
# (home timeline) keep working while the daemon is down.
class NostrdClient
  class Error      < StandardError; end
  class DaemonDown < Error; end
  class Timeout    < Error; end
  class NotFound   < Error; end
  class Rejected   < Error; end # daemon refused (ack ok:false)

  REQUEST_TIMEOUT = 20 # s; generous: signing + relay publish ride the ack
  RECONNECT_DELAY = 3
  CACHE_LIMIT = 600
  CACHED_KINDS = [1, 7, 1111].freeze

  def initialize(socket_path:, history: 300, logger: nil)
    @socket_path = socket_path
    @history = history.clamp(10, 500)
    @logger = logger
    @mutex = Mutex.new
    @seq = 0
    @pending = {}    # id -> Queue
    @listeners = {}  # handle -> Queue (SSE fan-out, raw JSON strings)
    @notes = {}      # event id -> event hash (kinds 1, 7, 1111)
    @timeline = []   # kind-1 event ids, created_at desc
    @profiles = {}   # pubkey -> profile hash
    @connected = false
    @ready = false
    Thread.new { reader_loop }.abort_on_exception = false
  end

  attr_reader :socket_path

  # -- connection / cache state -------------------------------------------

  def connected? = @mutex.synchronize { @connected }
  def ready?     = @mutex.synchronize { @ready }

  # -- cache readers (never raise) ------------------------------------------

  def timeline(limit: 50)
    ids = @mutex.synchronize { @timeline.first(limit.clamp(1, CACHE_LIMIT)) }
    ids.filter_map { |id| @mutex.synchronize { @notes[id] } }
  end

  def note(id)    = @mutex.synchronize { @notes[id] }
  def profile(pk) = @mutex.synchronize { @profiles[pk] }

  def cached_comments(root_id)
    @mutex.synchronize do
      @notes.values
            .select { |e| e["kind"] == 1111 && tag_values(e, "E").include?(root_id) }
            .sort_by { |e| e["created_at"].to_i }
    end
  end

  def cached_reactions(target_id)
    @mutex.synchronize do
      @notes.values.select { |e| e["kind"] == 7 && tag_values(e, "e").include?(target_id) }
    end
  end

  def cached_search(query, limit: 50)
    q = query.to_s.downcase
    notes, profiles = @mutex.synchronize do
      [
        @notes.values.select { |e| e["kind"] == 1 && e["content"].to_s.downcase.include?(q) },
        @profiles.values.select do |p|
          %w[name display_name nip05 about].any? { |k| p[k].to_s.downcase.include?(q) }
        end
      ]
    end
    { "notes" => notes.sort_by { |e| -e["created_at"].to_i }.first(limit),
      "profiles" => profiles.first(limit) }
  end

  # -- requests --------------------------------------------------------------

  def info   = request(op: "info")
  def ping   = request(op: "ping")

  def get_note(id)
    request(op: "get", kind: "note", params: { id: id })["data"]
  end

  def thread(id)
    request(op: "get", kind: "note", params: { id: id, scope: "thread" })["data"]
  end

  def author_notes(pubkey, limit: 50)
    request(op: "get", kind: "author", params: { pubkey: pubkey, limit: limit })["data"]
  end

  def profile_get(pubkey)
    request(op: "get", kind: "profile", params: { pubkey: pubkey })["data"]
  end

  def search(query, limit: 50)
    request(op: "search", params: { query: query, limit: limit })["data"]
  end

  def follow(pubkey, client: nil)     = op_request(op: "follow",   params: { pubkey: pubkey }, client: client)
  def unfollow(pubkey, client: nil)   = op_request(op: "unfollow", params: { pubkey: pubkey }, client: client)
  def delete_note(ids, client: nil)   = op_request(op: "delete_note", params: { ids: Array(ids) }, client: client)
  def relay_add(url, client: nil)     = op_request(op: "relay_add", params: { url: url }, client: client)

  # relay_flags upserts: unknown url is added with these flags (daemon-side
  # set_relay_flags), so add + toggle share one op.
  def relay_flags(url, flags, client: nil)
    p = { url: url }.merge(flags.slice(:read, :inbox, :write, :outbox, :discover, :search))
    op_request(op: "relay_flags", params: p, client: client)
  end

  def relay_remove(url, client: nil) = op_request(op: "relay_remove", params: { url: url }, client: client)
  def advertise_relays(client: nil)  = op_request(op: "advertise_relays", client: client)

  def lock               = op_request(op: "lock")
  def unlock(passphrase, client: nil) = op_request(op: "unlock", params: { passphrase: passphrase }, client: client)

  # -- signing-oracle actions (web never sees keys) --------------------------
  # client: NIP-46 bunker client pubkey — the daemon gates write ops on an
  # active bunker session for it when bunker mode is enabled.

  def post_note(text, client: nil) = action("post_note", { text: text }, client: client)

  # NIP-22: parent is the event being replied to (id/pubkey/kind/tags).
  def post_comment(parent, text, client: nil)
    action("post_comment", { text: text, parent: parent }, client: client)
  end

  def like(note_id, author_pubkey, client: nil) = action("like", { id: note_id, pubkey: author_pubkey }, client: client)

  def update_profile(fields, client: nil)
    action("update_profile", { profile: fields }, client: client)
  end

  # -- SSE fan-out ------------------------------------------------------------

  def add_listener
    q = Queue.new
    handle = "sse-#{next_id}"
    @mutex.synchronize { @listeners[handle] = q }
    [handle, q]
  end

  def remove_listener(handle)
    @mutex.synchronize { @listeners.delete(handle) }
  end

  private

  def op_request(**frame)
    # client: NIP-46 bunker session pubkey — merged into the wire frame for
    # the daemon's action gate. Stays out of the frame when nil (TUI-compat).
    client = frame.delete(:client) || frame.delete("client")
    frame = frame.merge("client" => client) if client
    resp = request(**frame)
    raise Rejected, resp["error"].presence || "拒否されました" if resp["ok"] == false

    resp
  end

  def action(name, params, client: nil)
    op_request(op: "action", name: name, params: params, client: client)
  end

  def request(**frame)
    frame = frame.transform_keys(&:to_s)
    id = next_id
    frame["id"] = id
    line = JSON.generate(frame)
    q = Queue.new
    sock = @mutex.synchronize do
      raise DaemonDown, "nostrd に接続できません" unless @connected && @sock

      @pending[id] = q
      begin
        @sock.write(line + "\n")
      rescue SystemCallError, IOError
        @pending.delete(id)
        raise DaemonDown, "nostrd への書き込みに失敗しました"
      end
      :sent
    end
    raise DaemonDown unless sock == :sent

    resp = begin
      q.pop(timeout: REQUEST_TIMEOUT)
    rescue ThreadError
      @mutex.synchronize { @pending.delete(id) }
      raise Timeout, "nostrd の応答がタイムアウトしました"
    end
    unless resp
      # Queue#pop returns nil on timeout; drop the orphaned request so a
      # later unknown_op can't be misattributed to it
      @mutex.synchronize { @pending.delete(id) }
      raise Timeout, "nostrd の応答がタイムアウトしました"
    end

    case resp["ev"]
    when "error"
      code = resp["code"]
      raise NotFound, resp["message"] if code == "not_found"

      raise Error, resp["message"].presence || code.to_s
    end
    resp
  end

  def next_id
    @mutex.synchronize { "w#{@seq += 1}" }
  end

  # -- reader thread ------------------------------------------------------------

  def reader_loop
    loop do
      sock = nil
      begin
        sock = UNIXSocket.new(@socket_path)
      rescue SystemCallError, IOError
        mark_disconnected
        sleep RECONNECT_DELAY
        next
      end
      begin
        run_connection(sock)
      rescue StandardError => e
        log(:warn, "connection lost: #{e.class}: #{e.message}")
      ensure
        begin
          sock.close unless sock.closed?
        rescue StandardError
          nil
        end
        mark_disconnected
      end
      sleep RECONNECT_DELAY
    end
  end

  def run_connection(sock)
    @sock = sock
    write_line(JSON.generate(op: "hello", client: "web", proto: 1))
    sub_id = next_id
    write_line(JSON.generate(op: "sub", id: sub_id, channel: "timeline", params: { limit: @history }))
    @mutex.synchronize do
      @connected = true
      @ready = false
    end
    log(:info, "connected to #{@socket_path}")
    sock.each_line do |l|
      l = l.strip
      next if l.empty?

      frame = JSON.parse(l)
      dispatch(frame)
    rescue JSON::ParserError
      next
    end
  end

  def mark_disconnected
    @mutex.synchronize do
      @connected = false
      @ready = false
      @sock = nil
      @pending.each_value { |q| q << { "ev" => "error", "code" => "daemon_down", "message" => "nostrd との接続が切断されました" } }
      @pending.clear
    end
  end

  def dispatch(frame)
    case frame["ev"]
    when "event"
      cache_event(frame["event"])
      fanout(frame)
    when "profiles"
      Array(frame["profiles"]).each { |p| cache_profile(p) }
      fanout(frame)
    when "eod"
      @mutex.synchronize { @ready = true }
      fanout(frame)
    when "ack", "result", "error", "info"
      q = @mutex.synchronize { @pending.delete(frame["id"]) }
      if q
        q << frame
      elsif frame["code"] == "unknown_op"
        # Older daemons reply to unknown ops without echoing the request id.
        # When exactly one request is outstanding, fail it fast with a clear
        # message instead of letting it ride to the 20s timeout.
        pair = @mutex.synchronize { @pending.size == 1 ? @pending.first : nil }
        if pair
          @mutex.synchronize { @pending.delete(pair[0]) }
          pair[1] << { "ev" => "error", "code" => "unknown_op",
                       "message" => "接続先の daemon は「#{frame["message"]}」に対応していません" }
        else
          fanout(frame)
        end
      elsif frame["ev"] == "error"
        fanout(frame) # unsolicited (e.g. bad sub) — surface to the UI
      end
    else
      fanout(frame)
    end
  end

  def cache_event(event)
    return unless event.is_a?(Hash) && event["id"] && CACHED_KINDS.include?(event["kind"])

    @mutex.synchronize do
      fresh = !@notes.key?(event["id"])
      @notes[event["id"]] = event
      return if event["kind"] != 1 || !fresh

      @timeline.delete(event["id"])
      idx = @timeline.index { |id| @notes.dig(id, "created_at").to_i <= event["created_at"].to_i } || -1
      @timeline.insert(idx, event["id"])
      if @timeline.size > CACHE_LIMIT
        @timeline.slice!(CACHE_LIMIT..)
      end
    end
  end

  def cache_profile(p)
    return unless p.is_a?(Hash) && p["pubkey"]

    @mutex.synchronize { @profiles[p["pubkey"]] = p }
  end

  def fanout(frame)
    line = JSON.generate(frame)
    @mutex.synchronize { @listeners.values.dup }.each { |q| q << line }
  end

  def write_line(line)
    @mutex.synchronize do
      raise DaemonDown, "nostrd is not connected" unless @sock

      @sock.write(line + "\n")
    end
  end

  def log(level, message)
    return unless @logger

    @logger.public_send(level, "[nostrd] #{message}")
  end
end
