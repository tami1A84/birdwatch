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

## リレー接続の挙動(gossipモデル)

- 各フォロー先のイベントは、その人の **最適 ~3リレー**(RelayPicker の割当。NIP-65 claim
  + fetch 証拠のスコア順)からだけ取得する — 接続している全リレーで全員を拾わない
- 全員をストリームする例外は2種類: ループバックリレー `ws://127.0.0.1:7777`(自分の
  ストアが唯一の真実)と、設定で inbox/discover を ON にした自分のリレー(証拠が付くまでの
  ブートストラップ面)
- 証拠のない新しいフォローは全接続で観測し、kind 10002 が到着して証拠が付くと割当リレーに
  絞り込まれる(広く観測 → 狭く取得のフィードバックループ)
- 割当を失った発見リレーは home ストリームを CLOSE し、用途がなければ切断する
  (接続は目的のためにある。ループバック・設定リレー・bunker 対象は残す)
- ループバックは特別扱い: 起動直後に即接続(タブに offline が見える隙を作らない)、
  home REQ は `since` 付き(自分のストアの履歴を自分に返して取り込まない)、fetch は証拠に
  数えない(ネットワークリレーの top-3を汚さない)、dial 失敗もペナルティボックスに入れない
- ループバックは seek / サブスクライブの対象からも外れる(network_urls): ストアの鏡に
  すぎないので、profile バッチ・kind 10002 seek・自分の kind 3 更新・bunker / inbox サブを
  そこに投げても新鮮なデータは絶対に帰ってこない。特に bunker サブは過去の kind-24133
  を全量再配信させて署名者に古いリクエストへ再回答させていた(起動時に pure Ruby の
  NIP-44+Schnorr が CPU を張り付き、info フレーム=ユーザー名表示まで遅延する)
- kind 24133 (NIP-46) は 3重のリプレイ対策: サブ REQ に `since = now-600`、
  古いリクエストは破棄、リクエスト id の重複回答は禁止(同じリクエストは保持リレーの
  数だけ届く)。応答 publish も送信先重複を畳んで1回
- profile バッチは 1 回で PROFILE_FANOUT=3 リレーにファンアウトし、1 try ごとに
  回転する(1リレーは 100 人全員を知らない。1リレー/30秒の回転では名前が這って来た)
- TUI へのライブ配信は「ストアに無い新規イベントだけ」(LiveFeed の fresh ゲート)。
  home REQ には since を付けない意図がある(長期オフラインの欠落を取りに戻る)ため、
  リレーは起動のたびに保存済み履歴を再送してくる — それをそのまま配信すると
  TUI がイベント+per-event profile フレームの洪水を受けて操作が数秒固まった。
  自分の投稿は publisher 経由で force 配信(保存後に push するため)
- 同一 URL への同時 dial は1接続に畳まれる(旧実装は競合で同一リレーに複数接続を
  リークしていた — ログに同一起動で同じリレーが複数回 "connected" と出ていたのはこれ)
- `NOSTRD_THREAD_DEBUG=<秒>` を付けると全スレッドの状態と Ruby バックトレースを
  定期的にログへ出す(デバッガが attach できない環境での「なぜ重い」調査用)

## テスト

```sh
for t in test/*_test.rb; do ruby -Ilib -Itest "$t"; done
```
(require 順の影響があるため個別実行。Rakefile で束ねるのが望ましい)

## まだ無いもの(骨組みの外)

- Rails/PWA 向けの第2ソケット
