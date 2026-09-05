class ApplicationController < ActionController::Base
  # Only browsers that support everything the UI needs (md components,
  # view transitions degrade gracefully, but modern CSS is assumed).
  allow_browser versions: :modern

  helper_method :nostrd, :display_name, :rel_time, :note_content, :me_info,
                :short_pubkey, :valid_pubkey?

  rescue_from NostrdClient::DaemonDown, NostrdClient::Timeout do |e|
    @error_message = e.message
    render "application/offline", status: :service_unavailable
  end

  rescue_from NostrdClient::NotFound do
    not_found!
  end

  def nostrd = $nostrd

  def not_found!
    render "application/not_found", status: :not_found
  end

  # Fresh info frame per request — one cheap unix-socket round trip that
  # carries me/locked/my_profile/follows/relays.
  def me_info
    @me_info ||= nostrd.info
  rescue NostrdClient::Error
    {}
  end

  def short_pubkey(pk)
    pk = pk.to_s
    return pk if pk.empty?

    "#{pk[0, 8]}…"
  end

  def valid_pubkey?(pk)
    pk.to_s.match?(/\A[0-9a-f]{64}\z/)
  end

  def display_name(pubkey)
    p = nostrd.profile(pubkey)
    p && (p["display_name"].presence || p["name"].presence) || short_pubkey(pubkey)
  end

  # Japanese relative time: たった今 / N分前 / N時間前 / N日前 / date.
  def rel_time(ts)
    t = ts.is_a?(Time) ? ts : Time.zone.at(ts.to_i)
    return "" if t.year <= 1970

    d = Time.current - t
    return "たった今" if d < 60
    return "#{d.div(60)}分前" if d < 3600
    return "#{d.div(3600)}時間前" if d < 86_400
    return "#{d.div(86_400)}日前" if d < 7 * 86_400

    t.strftime("%Y年%m月%d日")
  end

  # Escape everything, then re-link plain http(s) URLs. Nostr bech32
  # identifiers are left as plain text.
  def note_content(content)
    parts = content.to_s.split(%r{(https?://\S+)}).map do |seg|
      if seg.start_with?("http://", "https://")
        u = ERB::Util.html_escape(seg)
        %(<a href="#{u}" class="note-url" target="_blank" rel="noopener noreferrer">#{u}</a>)
      else
        ERB::Util.html_escape(seg)
      end
    end
    parts.join.gsub(/\r?\n/, "<br>").html_safe
  end

  # NIP-22 comment / NIP-25 reaction tag lookup.
  def tag_values(event, name)
    Array(event && event["tags"]).select { |t| t.is_a?(Array) && t[0] == name }.map { |t| t[1] }
  end
  helper_method :tag_values
end
