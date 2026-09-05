class FavoritesController < ApplicationController
  def show
    # Note ids live in the browser (localStorage); the favorites controller
    # fetches each card HTML client-side via /notes/:id/card.
  end
end
