class ProfilesController < ApplicationController
  def show
    @pubkey = params[:pubkey].to_s.downcase
    return not_found! unless valid_pubkey?(@pubkey)

    data = (nostrd.profile_get(@pubkey) || {})["profile"]
    @profile = data || nostrd.profile(@pubkey)
    @notes = begin
      (nostrd.author_notes(@pubkey, limit: 50) || {})["notes"] || []
    rescue NostrdClient::Error
      []
    end
    info = me_info
    @me = info["me"]
    @following = @me.present? && @me != @pubkey && Array(info["follows"]).include?(@pubkey)
  end
end
