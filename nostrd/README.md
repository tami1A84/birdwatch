# nostrd

Nostr TUI/PWA クライアントの daemon 側。HTTP を喋らない。リレー接続・SQLite キャッシュ(唯一の真実)・gossip 流リレースコアリング・NIP-46 署名オラクルを担う。

## 構成

- `lib/nostr_core/` — 純粋 Ruby。TUI/Rails に依存しない核
  - `person_relay.rb` — 人×リレーの関連スコア(NIP-65 claim +1.0 / last_fetched +0.2 半減期14日 / last_suggested +0.1 半減期7日)
  - `relay.rb` — リレー品質スコア `rank/9 × (0.5 + 0.5×success_rate)`、低試行ペナルティなし
  - `relay_picker.rb` — 貪欲割当 + ペナルティボックス + GC(gossip RelayPicker の移植)
  - `decay.rb`, `event.rb`
- `lib/nostrd/`
  - `store.rb` — SQLite(WAL)。events / relays / person_relays
  - `server.rb` — unix socket NDJSON サーバ(プロトコル v0)
  - `signer.rb` — 署名オラクルのスタブ(アクション単位のみ。生イベント署名は不可能)
- `bin/nostrd` — 起動スクリプト

## 起動

```sh
# 開発: サンプルイベントを流すモック(ソケットは /tmp/nostrd-dev.sock)
bin/nostrd --mock

# 本来の形
bin/nostrd --socket "$XDG_RUNTIME_DIR/nostrd.sock" --db ~/.local/share/nostrd/nostrd.db
```

### ワンコマンド起動(リポジトリ直下の bin/nostr)

デーモンと TUI を別ターミナルで起動する手間をなくすラッパー:

```sh
bin/nostr            # デーモンが無ければ起動(vaultのパスフレーズを1回だけ聞く)→ TUIを起動
bin/nostr --stop     # デーモン停止(ruby プロセス以外は決して kill しない)
bin/nostr --status   # 稼働確認
bin/nostr --logs     # デーモンログを tail
bin/nostr --setup    # 既存 nsec でログイン(vault作成のみで終了)
bin/nostr --newkey   # 新規鍵を作成(vault作成のみで終了)
```

- デーモンは TUI を終了しても起動し続ける(次回の `nostr` は即座に立ち上がる)
- 設定は環境変数で: `NOSTRD_SOCKET` / `NOSTRD_DB` / `NOSTRD_VAULT` / `NOSTRD_PASSPHRASE` / `NOSTRD_RELAYS`
- ログ: `~/.cache/nostrd/daemon.log`、pid: `~/.cache/nostrd/daemon.pid`

## 主なオプション

- `--socket PATH` / `--db PATH` — unix socket と SQLite の場所
- `--history N` — クライアントの `sub timeline` に流す履歴件数の既定(既定100)。
  クライアントが `params.limit` を明示した場合はそちらが優先
- `--live` — 実リレー接続(gossip: 10002発見 → スコアリング → per-person割当)
- `--new-key` / `--import-nsec` — 鍵の作成/既存鍵(nsec)でのログイン。
  nsec・パスフレーズは隠し入力、vaultはscrypt+AESで暗号化(0600)、平文保存なし
- `--setup-only` — `--new-key`/`--import-nsec` と併用: vault作成とpubkey表示だけで終了する(ワンコマンド起動用)
- `--relay URL` / `--follow PK1,PK2` / `--vault PATH` — live のダイヤル先・フォロー・署名鍵
  (フォローはDBに永続化され、再起動時に復元される)

## テスト

```sh
for t in test/*_test.rb; do ruby -Ilib -Itest "$t"; done
```
(require 順の影響があるため個別実行。Rakefile で束ねるのが望ましい)

## まだ無いもの(骨組みの外)

- WsTransport v2: 単一 EventMachine reactor での複数接続(現行は接続ごとにスレッド)
- NIP-46 リモート署名の本体(現行の signer はローカル vault 直署名)
- Rails/PWA 向けの第2ソケット
