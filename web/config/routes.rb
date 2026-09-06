Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  root "home#show"

  # Live daemon frames (SSE)
  get "live", to: "live#show"

  get  "search", to: "search#show"
  get  "favorites", to: "favorites#show"

  # Notes + comments + reactions
  get  "notes/:id/item", to: "notes#item", as: :note_item
  get  "notes/:id/section", to: "notes#section", as: :note_section
  get  "notes/:id", to: "notes#show", as: :note
  post "notes", to: "notes#create"
  post "notes/:id/comments", to: "notes#comment", as: :note_comments
  post "notes/:id/like", to: "notes#like", as: :note_like
  post "notes/:id/destroy", to: "notes#destroy", as: :note_destroy

  get  "profiles/:pubkey", to: "profiles#show", as: :profile

  get  "follows", to: "follows#index"
  post "follows", to: "follows#create", as: :follows_create
  post "follows/destroy", to: "follows#destroy", as: :follows_destroy

  get  "relays", to: "relays#index"
  post "relays", to: "relays#create", as: :relays_create
  post "relays/flags", to: "relays#flags", as: :relays_flags
  post "relays/destroy", to: "relays#destroy", as: :relays_destroy
  post "relays/advertise", to: "relays#advertise", as: :relays_advertise

  get  "settings", to: "settings#show"
  post "settings/profile", to: "settings#update_profile", as: :settings_profile
  post "settings/lock", to: "settings#lock", as: :settings_lock
  post "settings/unlock", to: "settings#unlock", as: :settings_unlock
end
