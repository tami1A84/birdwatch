# birdwatch

omarchy (Arch Linux + Hyprland) 向け、キーボード操作中心の Nostr TUI クライアント。
![スクリーンショット](https://blossom.ditto.pub/3aaab04da51e562643fedf996b38f6f4b9cc08d20357a042c5160576d30599c6.png)

`nostrd` (daemon) と `nostr-tui` (curses) の2プロセス構成。全部 Ruby。
TUI は薄く、状態の真実は daemon 側の SQLite が単独で持つ。

```
┌────────────┐  NDJSON / unix socket  ┌──────────────────┐   wss   ┌────────┐
│ nostr-tui  │ ◄────────────────────► │      nostrd      │ ◄─────► │ relays │
│ curses UI  │  action intents/events │ SQLite · signer  │         └────────┘
└────────────┘                        └──────────────────┘
```

## 特徴

- **署名オラクル分離** — TUI は生の鍵・イベントに触れない。投稿・リプライ・いいね・
  プロフィール更新は「アクション意図」として unix socket (0600) 経由で daemon に渡り、
  daemon だけが署名する。秘密鍵は NIP-49 (scrypt + AES) で暗号化した vault の中だけ
- **gossip outbox モデル** — フォロワーの kind 10002 を読んで書き込み先リレーを自動発見、
  スコアリング (NIP-65 claim + 直近成功の減衰) して自動ダイヤル。
  死んだリレーはハンドシェイクゲートで検出してペナルティボックスへ
- **ぬるい TUI** — 差分再描画 (変更行だけ) + 表示窓の仮想化。古い2コア端末でも操作が軽い
- **NIP-46 nostr connect** — 設定タブから QR を表示 (QR はローカルの `qrencode` で生成、
  URI が外部サービスに流れることはない)。リモート署名 (kind 24133) はロードマップ
- **設定タブから鍵のライフサイクル操作** — ログアウト (ロック) / パスフレーズでアンロック /
  nsec インポート (vault を作り直して再暗号化)

### 対応 NIP

| NIP | 内容 |
|---|---|
| 01 | イベント・フォロー・kind 0 メタデータ |
| 19 | bech32 (npub / note / nsec) の受け入れ |
| 22 | コメント (リプライは kind 1111 でスレッド化) |
| 25 | リアクション (自分の 👍 だけを表示) |
| 42 | AUTH (リレー要求チャレンジ) |
| 46 | nostr connect URI + QR (リモート署名は今後) |
| 49 | 秘密鍵 vault (ncryptsec) |
| 65 | リレーリストの発見と広告 (kind 10002) |

## クイックスタート

```sh
# ビルド依存 (Arch)
sudo pacman -S --needed base-devel sqlite ncurses

# gems
gem install curses sqlite3 websocket

git clone https://github.com/tami1A84/birdwatch
cd birdwatch

bin/nostr --setup     # 既存の nsec でログイン (入力は隠される)
bin/nostr --newkey    # または新規鍵を生成

bin/nostr             # daemon が無ければ起動 (パスフレーズ1回) → TUI
```

- daemon は TUI を終了しても常駐する。次回の `bin/nostr` は即座に立ち上がり、
  daemon が生きている限りパスフレーズは二度と聞かれない
- `bin/nostr --stop` / `--status` / `--logs` で daemon を管理
- 設定は環境変数で: `NOSTRD_SOCKET` / `NOSTRD_DB` / `NOSTRD_VAULT` / `NOSTRD_RELAYS`
- daemon のデータは `~/.local/share/nostrd`、vault は `~/.config/nostrd`、
  ログは `~/.cache/nostrd` — いずれもリポジトリ外

## キーマップ (概要)

| キー | 動作 |
|---|---|
| `h` / `l` / `1`–`4` | タブ移動 (timeline / follows / relays / settings) |
| `j` / `k` / `g` / `G` | 選択移動 |
| `n` / `r` | 投稿 / 返信 (`$EDITOR`、返信は RE: ヘッダの下にカーソル) |
| `L` | いいね |
| `o` | 開く (timeline=リンク / follows=プロフィール / settings=行ごと) |
| `R` `I` `W` `O` `D` `S` | リレー切替 (read / inbox / write / outbox / discover / search) |
| `a` / `x` / `A` | リレー追加 / 削除 / kind 10002 で広告 |
| `q` / `ESC` | 終了 |

全体は [tui/README.md](tui/README.md)、daemon のオプションは [nostrd/README.md](nostrd/README.md)。

## プロトコル

TUI と daemon の間は行指向 JSON (NDJSON) の単純なプロトコル。
仕様は [docs/protocol.md](docs/protocol.md) — 別クライアント (PWA 等) を
同じ daemon に生やすための契約書でもある。

## テスト

```sh
(cd nostrd && for t in test/*_test.rb; do ruby -Ilib -Itest "$t"; done)
(cd tui    && ruby -Ilib -Itest test/tui_test.rb)
```

実リレーでの検証記録は [docs/live-run-2026-09-04.md](docs/live-run-2026-09-04.md)。

## ロードマップ

- NIP-46 リモート署名本体 (kind 24133) — QR ペアリングしたスマホ PWA から
  birdwatch の daemon に署名を委譲
- 検索リレーへの REQ 転送
- 複数クライアント同時接続の整理

## License

[MIT](LICENSE)
