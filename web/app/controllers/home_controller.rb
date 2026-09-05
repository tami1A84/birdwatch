class HomeController < ApplicationController
  def show
    @connected = nostrd.connected?
    @ready = nostrd.ready?
    @notes = nostrd.timeline(limit: 50)
  end
end
