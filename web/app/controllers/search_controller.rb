class SearchController < ApplicationController
  def show
    @query = params[:q].to_s.strip
    @notes = []
    @profiles = []
    return if @query.empty?

    data = begin
      nostrd.search(@query, limit: 50)
    rescue NostrdClient::Error
      nostrd.cached_search(@query, limit: 50)
    end
    @notes = Array(data["notes"])
    @profiles = Array(data["profiles"])
  end
end
