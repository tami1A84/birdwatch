class SettingsController < ApplicationController
  before_action :require_bunker_session!, only: %i[update_profile lock unlock]

  def show
    info = me_info
    @me = info["me"]
    @my_profile = info["my_profile"] || {}
    @locked = info["locked"]
    @relay_count = Array(info["relays"]).size
    @follow_count = Array(info["follows"]).size

    @bunker = info["bunker"] || {}
    @bunker_enabled = @bunker["enabled"] == true
    @bunker_sessions = Array(@bunker["sessions"])
    @bunker_client = bunker_client_pubkey
    @bunker_connected = @bunker_client.present? && @bunker_sessions.include?(@bunker_client)
  end

  # NIP-46 connect: run the real relay handshake with a fresh ephemeral
  # client key, verify the bunker answers, then bind it to this browser via
  # an encrypted cookie. The secret lives in the URI the user pasted (from
  # `bin/nostr --bunker-secret`); afterwards the daemon's persisted allowlist
  # re-authorizes this key without it.
  def bunker_connect
    client = Nip46Client.parse_bunker_uri(params.require(:bunker_uri))
    client.connect!
    gpk = client.get_public_key
    unless gpk == client.signer_pubkey
      return redirect_to settings_path, alert: "bunkerの応答が不正です (公開鍵不一致)"
    end

    cookies.encrypted[:bunker_client] = {
      value: { sk: client.seckey_hex, signer: client.signer_pubkey,
               client: client.client_pubkey, relays: client.relays,
               connected_at: Time.current.iso8601 },
      expires: 1.year.from_now
    }
    @me_info = nil
    redirect_to settings_path, notice: "bunkerに接続しました (#{short_pubkey(client.signer_pubkey)})"
  rescue URI::InvalidURIError, Nip46Client::Malformed => e
    redirect_to settings_path, alert: "URIを読み取れません: #{e.message}"
  rescue Nip46Client::Rejected => e
    redirect_to settings_path, alert: "bunkerに拒否されました: #{e.message}"
  rescue Nip46Client::Timeout, Nip46Client::Error => e
    redirect_to settings_path, alert: "bunkerに接続できませんでした: #{e.message}"
  end

  # Best-effort remote disconnect (clears the daemon-side session), then drop
  # the local binding. The allowlist entry stays until `--bunker-forget`.
  def bunker_disconnect
    c = bunker_cookie
    if c&.dig(:sk).present? && c&.dig(:signer).present? && Array(c[:relays]).present?
      client = Nip46Client.new(signer_pubkey: c[:signer], relays: Array(c[:relays]),
                               secret: "", seckey_hex: c[:sk], timeout: 10)
      client.disconnect!
    end
    cookies.delete(:bunker_client)
    @me_info = nil
    redirect_to settings_path, notice: "bunkerから切断しました"
  rescue StandardError => e
    cookies.delete(:bunker_client)
    redirect_to settings_path, notice: "bunkerセッションを破棄しました (リモート切断は失敗: #{e.message})"
  end

  def update_profile
    fields = params.permit(:name, :display_name, :nip05, :picture, :about).to_h
                   .transform_values { |v| v.to_s.strip }
                   .compact_blank
    if fields.empty?
      return redirect_to settings_path, alert: "変更する項目を入力してください"
    end

    nostrd.update_profile(fields, client: write_client)
    redirect_to settings_path, notice: "プロフィールを更新しました"
  rescue NostrdClient::Rejected, NostrdClient::Error => e
    redirect_to settings_path, alert: "更新できませんでした: #{e.message}"
  end

  def lock
    nostrd.lock
    redirect_to settings_path, notice: "ロックしました"
  rescue NostrdClient::Rejected, NostrdClient::Error => e
    redirect_to settings_path, alert: "ロックできませんでした: #{e.message}"
  end

  def unlock
    nostrd.unlock(params.require(:passphrase).to_s, client: write_client)
    redirect_to settings_path, notice: "ロックを解除しました"
  rescue NostrdClient::Rejected, NostrdClient::Error => e
    redirect_to settings_path, alert: "パスフレーズが違います"
  end
end
