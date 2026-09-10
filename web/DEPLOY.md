# birdwatch web — runbook

Rails 8.1 PWA client for the nostrd daemon (protocol: `../docs/protocol.md`).
No database of its own: the daemon's SQLite is the truth, signing stays in the
daemon (oracle), the browser gets live frames over SSE.

## Requirements

- Ruby 3.4+, bundler
- Node 20+ (esbuild build only)
- nostrd daemon running (this repo: `nostrd/bin/nostrd --help`)

## Production run

```sh
bundle install
bin/rails assets:precompile          # already done in the shipped build
RAILS_ENV=production SECRET_KEY_BASE=<key> \
NOSTRD_SOCKET=$XDG_RUNTIME_DIR/nostrd.sock \
bin/rails server -b 127.0.0.1 -p 3000
```

Runbook note (agent sessions): run it as a persistent systemd --user unit
so it survives the session that started it AND reboots — plain background
jobs get reaped, and transient `systemd-run` units vanish on reboot.

```sh
# unit file: ~/.config/systemd/user/birdwatch-web.service
# (RAILS_ENV, SECRET_KEY_BASE, NOSTRD_SOCKET=%t/nostrd.sock embedded)
systemctl --user daemon-reload
systemctl --user enable --now birdwatch-web.service   # start + login autostart
systemctl --user restart birdwatch-web.service        # after redeploys
systemctl --user status birdwatch-web.service
```

- `NOSTRD_SOCKET` overrides the socket path (default mirrors the daemon:
  `$XDG_RUNTIME_DIR/nostrd.sock`).
- `NOSTRD_HISTORY` overrides the timeline replay size (default 300).
- The app boots without the daemon and reconnects in the background; pages
  that only read the in-process cache (home timeline) keep working offline,
  writes fail with a friendly offline screen.

## Quick smoke (no real identity needed)

```sh
ruby ../nostrd/bin/nostrd --mock     # in-memory store on /tmp/nostrd-dev.sock
NOSTRD_SOCKET=/tmp/nostrd-dev.sock bin/rails server -p 3000
```

## Remote use: NIP-46 bunker (outside access with per-client auth)

The web app itself holds no keys. Reads are served from the local daemon;
every write requires an **active NIP-46 session**: the browser's ephemeral
client key must have completed a real kind-24133 relay handshake with the
daemon's bunker. Anyone who reaches the web UI without that handshake stays
read-only.

One-time setup (on the machine running nostrd):

```sh
bin/nostr --bunker-secret    # prints a bunker:// URI (secret + relays)
bin/nostr --bunker-list      # allowlisted clients + active sessions
bin/nostr --bunker-forget <client-pubkey-hex>
```

The bunker is enabled when `~/.config/nostrd/bunker.json` exists (mode 0600).
To use birdwatch from outside:

1. Reach the web app over a secure channel (Tailscale/VPN or a TLS reverse
   proxy) — it still binds to 127.0.0.1 by default.
2. Open 設定 → リモート署名 (NIP-46 bunker), paste the `bunker://` URI, 接続.
3. Writes now trigger NIP-46 sign requests from that browser session; the
   daemon signs only for allowlisted client keys. Disconnect from the same
   screen (or `--bunker-forget` to revoke the client entirely).

Daemon restarts clear active sessions; the web silently re-connects using the
persisted allowlist (no secret re-entry).

## Layout

- `lib/nostrd_client.rb` — socket client: request/response with id matching,
  permanent timeline subscription feeding the in-process cache, SSE fan-out
- `app/controllers/live_controller.rb` — SSE endpoint (`/live`)
- `app/javascript/controllers/` — live feed updates, compose dialog,
  confirm dialogs, bottom-nav, favorites (localStorage)
- `app/assets/stylesheets/application.css` — M3 Expressive Mono tokens
  (light+dark), small-radius shape scale, Roboto Serif + Material Symbols,
  spring easing, cross-document view transitions

## Tests

- daemon side: `for t in ../nostrd/test/*_test.rb; do ruby $t; done`
- web side: boots + full-page smoke against the mock daemon (see above)
