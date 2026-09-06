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

Runbook note (agent sessions): launch it as a systemd --user unit so it
survives the session that started it — plain background jobs get reaped.

```sh
XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR systemd-run --user --unit=birdwatch-web \
  --setenv=SECRET_KEY_BASE=<key> --setenv=RAILS_ENV=production \
  --setenv=NOSTRD_SOCKET=$XDG_RUNTIME_DIR/nostrd.sock \
  --working-directory=$PWD/web \
  ruby bin/rails server -b 127.0.0.1 -p 3000
# stop / status:
XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR systemctl --user stop birdwatch-web.service
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
