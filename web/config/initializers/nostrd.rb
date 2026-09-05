# frozen_string_literal: true

require Rails.root.join("lib/nostrd_client").to_s

# Single NostrdClient per process. Socket path mirrors the daemon default
# (nostrd/bin/nostrd): $XDG_RUNTIME_DIR/nostrd.sock, overridable via
# NOSTRD_SOCKET. Boot never blocks: the client reconnects in the background,
# and pages render from the in-process cache while offline.
nostrd_socket =
  ENV["NOSTRD_SOCKET"].presence ||
  File.join(ENV.fetch("XDG_RUNTIME_DIR", "/tmp"), "nostrd.sock")

$nostrd = NostrdClient.new(
  socket_path: nostrd_socket,
  history: (ENV["NOSTRD_HISTORY"] || 300).to_i,
  logger: Rails.logger
)
