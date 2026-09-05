# nostr-tui

omarchy 用キーボード操作 Nostr クライアントの TUI 側。nostrd(daemon)の unix socket に繋がる薄い curses クライアント。状態は全部 daemon が持つ。

## 起動

通常はリポジトリ直下のワンコマンドランチャーを使う(デーモン起動も自動):

```sh
../bin/nostr        # daemon 無ければ起動して TUI を起動(--stop/--status/--logs あり)
```

直接起動する場合:

```sh
# 1. daemon 側を先に
../nostrd/bin/nostrd --mock &

# 2. TUI
bin/nostr-tui                 # /tmp/nostrd-dev.sock に接続
bin/nostr-tui --demo          # daemon 無しでサンプル描画(curses が必要)
```

curses gem 未導入なら `gem install curses`(ncurses dev が必要)。テストは純粋層のみで curses 不要。

## キーマップ

| キー | 動作 |
|---|---|
| h / l | タブ移動 (timeline / follows / relays / settings) |
| 1–4 | タブ直接移動 |
| j / k | 下 / 上 |
| g / G | 先頭 / 末尾 |
| PgUp / PgDn | ページ移動 |
| Enter | 展開(全文+npub+時刻)※次の一手 |
| / | インクリメンタル検索 |
| r | 返信(composer、RE: ヘッダの下 = 2行目にカーソル) |
| n | 新規投稿($EDITOR を tmpfile で起動) |
| L | いいね(NIP-25。自分の 👍 だけを表示) |
| y | note id を yank |
| o | 開く — timeline: リンク / follows: npub.world / settings: 選択行ごと(birdwatch → GitHub、nostr connect → QR) |
| e | プロフィール編集(settings の profile 行で。kind 0) |
| u | vault アンロック(settings の unlock 行で。入力はマスク) |
| s | ログアウト = daemon signer をロック(settings の logout 行で) |
| i | 秘密鍵インポート(nsec または hex + 新パスフレーズで vault を再暗号化) |
| R / I / W / O / D / S | リレー種別切替(read / inbox / write / outbox / discover / search) |
| a / x | リレー追加 / 削除 |
| A | 現在のリレー一覧を kind 10002 で広告 |
| q / ESC | 終了 |

## 構成

- `ndjson.rb` — プロトコル v0 の行パーサ(純粋)
- `timeline.rb` — 表示キャッシュ(真実は daemon の SQLite)+ フィルタ
- `renderer.rb` — 端末非依存の描画層。差分計算で変更行のみ再描画、表示窓だけ仮想化(X220 の2コア対策)
- `socket_client.rb` — unix socket クライアント。reader スレッドが Queue に投入
- `app.rb` — curses の薄い外殻

## テスト

```sh
ruby -Ilib -Itest test/tui_test.rb
```
