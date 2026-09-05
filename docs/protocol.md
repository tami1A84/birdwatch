# nostrd socket protocol v0

- Transport: unix socket NDJSON(1行 = 1 JSON オブジェクト)。双方向。
- Path: `$XDG_RUNTIME_DIR/nostrd.sock`(dev 時は `--socket` で上書き可)
- すべての行は UTF-8 JSON。未知の op/ev は無視する(前方互換)

## client → daemon

```json
{"op":"hello","client":"tui","proto":1}
{"op":"sub","id":"tl","channel":"timeline","params":{"limit":100}}
{"op":"sub","id":"tl","channel":"timeline"}
{"op":"unsub","id":"tl"}
{"op":"get","id":"g1","kind":"note","params":{"id":"<event id hex>"}}
{"op":"profiles","id":"p1","params":{"limit":100}}
{"op":"action","id":"a1","name":"post_note","params":{"text":"hello"}}
{"op":"info","id":"i1"}
{"op":"ping"}
```

## daemon → client

```json
{"ev":"hello","proto":1}
{"ev":"event","sub":"tl","event":{"id":"…","pubkey":"…","created_at":1700000000,"kind":1,"content":"…","tags":[],"sig":"…"}}
{"ev":"profiles","sub":"tl","profiles":[{"pubkey":"…","name":"…","display_name":"…","nip05":"user@domain","picture":"…","about":"…"}]}
{"ev":"info","id":"i1","follows":["<pubkey hex>"],"relays":[{"url":"wss://…","state":"connected"}],"profiles":[{"pubkey":"<pubkey hex>","name":"…"}]}
{"ev":"eod","sub":"tl"}
{"ev":"event","sub":"live","event":{"id":"…","pubkey":"…","created_at":1700000000,"kind":1,"content":"…","tags":[],"sig":"…"}}
{"ev":"profiles","sub":"live","profiles":[{"pubkey":"…","name":"…"}]}
{"ev":"ack","id":"a1","ok":true,"event_id":"…"}
{"ev":"result","id":"g1","data":{…}}
{"ev":"error","id":null,"sub":null,"code":"not_found","message":"…"}
{"ev":"pong"}
```

## 規約
- `timeline` チャネル: キャッシュ済み履歴(created_at 降順)を流した後 `eod`、以降ライブイベントを継続配信。`params.limit` 省略時はデーモン既定(`--history N`、未指定なら100)
- ライブ配信: `eod` 後、新着 kind 1 + 1111 が `sub:"live"` の `event` フレームでプッシュされる(自分の投稿の即時自己エコー + フォロー先の新着。リレーエコーによる重複はクライアント側で event id 重複排除)。著者の kind 0 が既知なら直後に `sub:"live"` の `profiles` フレームが続く。`eod` は二度来ない
- ライブプロフィール: kind 0 がシークでストアに着地するたび、`sub:"live"` の `profiles` フレームが**単独で**プッシュされる(event フレーム不要)。クライアントは再接続せずに表示名を更新する。使える項目(name等)が1つも無い kind 0 は黙ってスキップ
- `event` は kind 1 と 1111(NIP-22コメント)。履歴の直後に著者分の kind 0 メタデータを `profiles` フレームで同梱(著者全員のプロフィールが未取得なら省略)
- `profiles` op: タイムライン著者のプロフィール再取得(op応答は `id` 付き)。デーモンは kind 0 をフォロー中+自己_pubkeyに対し自動シークする: 1試行1リレーで**その人と縁のあるリレー(本人のwriteリレー → 実績のあるリレー)を優先**、 ticksあたり上限付き・指数バックオフ。中身の空 kind 0 は「取得済み」とみなさず別リレーを試す
- `info` op: TUIのSSSヘッダー用。`follows`(現在フォロー中のpubkey配列)と `relays`(接続中リレーの {url, state})、`profiles`(follows全員の保存済みkind 0メタデータ。名前解決はライブkind-0流入に依存しない)を返す。タブ切替のたびに再要求してよい
- `action` は必ず署名オラクル経由(クライアントは生イベントを渡さない)
- `announce_repo` op: NIP-34 リポジリアナウンス(kind 30617)を署名し、**gossip プールを経由せず
  `params.relay` に直接1回接続して公開する**(既定: `wss://png.communities.buzz.xyz` —
  Buzz Desktop が読む単一の組み込みリレー。NIP-42 AUTH チャレンジには1回だけ署名して応答し、認証後に元の EVENT を再送する)。
  tags は buzz-sdk 同様の d / name / description / clone / web / relays、content は空。
  応答: `{"ev":"ack","id":"r1","ok":true,"event_id":"…","relay":"wss://…","message":""}`。
  Buzz Desktop の Projects ビューはこのリレー上の kind 30617 をそのまま列挙する
  ```json
  {"op":"announce_repo","id":"r1","params":{"repo_id":"birdwatch","name":"birdwatch","description":"…","clone_urls":["https://github.com/tami1A84/birdwatch.git"],"web_url":"https://github.com/tami1A84/birdwatch"}}
  ```
