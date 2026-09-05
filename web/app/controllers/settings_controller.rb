class SettingsController < ApplicationController
  def show
    info = me_info
    @me = info["me"]
    @my_profile = info["my_profile"] || {}
    @locked = info["locked"]
    @relay_count = Array(info["relays"]).size
    @follow_count = Array(info["follows"]).size
  end

  def update_profile
    fields = params.permit(:name, :display_name, :nip05, :picture, :about).to_h
                   .transform_values { |v| v.to_s.strip }
                   .compact_blank
    if fields.empty?
      return redirect_to settings_path, alert: "変更する項目を入力してください"
    end

    nostrd.update_profile(fields)
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
    nostrd.unlock(params.require(:passphrase).to_s)
    redirect_to settings_path, notice: "ロックを解除しました"
  rescue NostrdClient::Rejected, NostrdClient::Error => e
    redirect_to settings_path, alert: "パスフレーズが違います"
  end
end
