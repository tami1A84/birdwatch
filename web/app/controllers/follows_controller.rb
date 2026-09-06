class FollowsController < ApplicationController
  before_action :require_bunker_session!, only: %i[create destroy]

  def index
    info = me_info
    @follows = Array(info["follows"])
    @profiles = Array(info["profiles"]).index_by { |p| p["pubkey"] }
    @me = info["me"]
  end

  def create
    pk = params.require(:pubkey).to_s.strip.downcase
    unless valid_pubkey?(pk)
      return redirect_to follows_path, alert: "公開鍵は64桁の16進数（hex）で入力してください"
    end

    nostrd.follow(pk, client: write_client)
    redirect_to follows_path, notice: "フォローしました"
  rescue NostrdClient::Rejected, NostrdClient::Error => e
    redirect_to follows_path, alert: "フォローできませんでした: #{e.message}"
  end

  def destroy
    pk = params.require(:pubkey).to_s.strip.downcase
    nostrd.unfollow(pk, client: write_client)
    redirect_to follows_path, notice: "フォローを解除しました"
  rescue NostrdClient::Rejected, NostrdClient::Error => e
    redirect_to follows_path, alert: "解除できませんでした: #{e.message}"
  end
end
