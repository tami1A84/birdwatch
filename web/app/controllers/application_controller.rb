class ApplicationController < ActionController::Base
  # Only browsers that support everything the UI needs (md components,
  # view transitions degrade gracefully, but modern CSS is assumed).
  allow_browser versions: :modern

  helper_method :nostrd, :display_name, :rel_time, :note_content, :me_info,
                :short_pubkey, :valid_pubkey?, :avatar_url, :avatar_tag

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

  # -- NIP-46 bunker session (write-path authorization) ----------------------
  #
  # The browser holds an encrypted cookie with an ephemeral NIP-46 client
  # keypair. A write is allowed only while that client pubkey has an ACTIVE
  # session on the daemon's bunker — which exists only after a real kind-24133
  # relay handshake the daemon authorized (secret first time, allowlist after).
  # Anyone who can reach the web UI without that handshake stays read-only.

  def bunker_cookie
    c = cookies.encrypted[:bunker_client]
    c.is_a?(Hash) ? c.symbolize_keys : nil
  end

  def bunker_client_pubkey
    bunker_cookie&.dig(:client)
  end

  def bunker_enabled?
    me_info.dig("bunker", "enabled") == true
  end

  def bunker_session_active?(client = bunker_client_pubkey)
    client.present? && Array(me_info.dig("bunker", "sessions")).include?(client)
  end

  # Write-op gate. Bunker disabled → legacy trusted-local mode (no gate).
  # Cookie present but session stale (e.g. daemon restart cleared sessions) →
  # silent re-auth over the relay transport, then retry the check once.
  def require_bunker_session!
    return unless bunker_enabled?
    return if bunker_session_active?
    return if bunker_client_pubkey && reconnect_bunker!

    redirect_to settings_path,
                alert: "リモート署名セッションがありません。設定画面で bunker に接続してください。"
  end

  # The pubkey passed down to nostrd write ops (daemon validates the session
  # server-side too — this is belt and braces, not the real gate).
  def write_client
    bunker_enabled? ? bunker_client_pubkey : nil
  end

  # Re-run the NIP-46 connect handshake with the cookie-held key. Works
  # without the secret because the daemon's allowlist persists across its
  # restarts. Returns true when the daemon now has an active session.
  def reconnect_bunker!
    c = bunker_cookie
    return false unless c&.dig(:sk).present? && c&.dig(:signer).present? && Array(c[:relays]).present?

    client = Nip46Client.new(signer_pubkey: c[:signer], relays: Array(c[:relays]),
                             secret: "", seckey_hex: c[:sk], timeout: 10)
    client.connect!
    @me_info = nil # info frame was cached before the session landed
    true
  rescue StandardError => e
    Rails.logger&.warn("bunker reconnect failed: #{e.class}: #{e.message}")
    false
  end

  def valid_pubkey?(pk)
    pk.to_s.match?(/\A[0-9a-f]{64}\z/)
  end

  # Kind-0 profile picture URL. Only http(s)/data URLs — anything else
  # (buddy lists, garbage content) falls back to the account_circle icon.
  def avatar_url(pubkey)
    p = nostrd.profile(pubkey)
    url = p.is_a?(Hash) ? p["picture"].to_s : ""
    return url if url.match?(/\Ahttps?:\/\//) || url.start_with?("data:image/")
  rescue NostrdClient::Error
    nil
  end

  # Circular avatar with the kind-0 picture; account_circle fallback (also
  # swapped in client-side when the image fails to load — see application.js).
  # klass sizes it: avatar--sm (36), avatar--md (40), avatar--lg (44), avatar--xl (64).
  def avatar_tag(pubkey, klass: "avatar--lg")
    pic = avatar_url(pubkey)
    icon = '<span class="msr msr--outline avatar__fallback">account_circle</span>'
    img = pic ? %(<img src="#{ERB::Util.html_escape(pic)}" alt="" loading="lazy" decoding="async" referrerpolicy="no-referrer">) : ""
    %(<span class="avatar #{klass}">#{icon}#{img}</span>).html_safe
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
