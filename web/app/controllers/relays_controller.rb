class RelaysController < ApplicationController
  FLAGS = %i[read inbox write outbox discover search].freeze

  def index
    info = me_info
    @relays = Array(info["relays"])
  end

  # relay_flags upserts: an unknown url is added with the posted flags.
  def create
    url = params.require(:url).to_s.strip
    unless url.match?(/\Aws[s]?:\/\//)
      return redirect_to relays_path, alert: "リレーURLは wss:// または ws:// で始まる必要があります"
    end

    nostrd.relay_flags(url, default_flags)
    redirect_to relays_path, notice: "リレーを追加しました"
  rescue NostrdClient::Rejected, NostrdClient::Error => e
    redirect_to relays_path, alert: "追加できませんでした: #{e.message}"
  end

  def flags
    url = params.require(:url).to_s.strip
    nostrd.relay_flags(url, FLAGS.index_with { |f| params[f].present? })
    redirect_to relays_path, notice: "リレーの設定を保存しました"
  rescue NostrdClient::Rejected, NostrdClient::Error => e
    redirect_to relays_path, alert: "保存できませんでした: #{e.message}"
  end

  def destroy
    url = params.require(:url).to_s.strip
    nostrd.relay_remove(url)
    redirect_to relays_path, notice: "リレーを削除しました"
  rescue NostrdClient::Rejected, NostrdClient::Error => e
    redirect_to relays_path, alert: "削除できませんでした: #{e.message}"
  end

  def advertise
    nostrd.advertise_relays
    redirect_to relays_path, notice: "リレーリスト（NIP-65）を公開しました"
  rescue NostrdClient::Rejected, NostrdClient::Error => e
    redirect_to relays_path, alert: "公開できませんでした: #{e.message}"
  end

  private

  def default_flags
    { read: true, inbox: false, write: true, outbox: false, discover: false, search: false }
  end
end
