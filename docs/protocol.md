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
## Web クライアント用 op (v0 追加)

### follow / unfollow

フォロー状態を変更し、変更後のフォロー一覧で kind 3(コンタクトリスト)を
再署名・再公開する。バリデーション失敗(64-hex 以外)は `error` フレーム
`code:"bad_request"`、処理失敗は `ack ok:false`。

```json
{"op":"follow","id":"w1","params":{"pubkey":"<64hex>"}}
{"op":"unfollow","id":"w2","params":{"pubkey":"<64hex>"}}
```
```json
{"ev":"ack","id":"w1","ok":true,"event_id":"…","published_to":2}
```

### delete_note (NIP-09)

kind 5(削除リクエスト)を署名・公開したのち、対象イベントをストアから
削除する。`ids` は 64-hex のイベント id 配列。ストアに無い id はスキップ。
e-tag は各イベント id、k-tag はストアで参照した各イベントの kind。

```json
{"op":"delete_note","id":"w3","params":{"ids":["<64hex>","<64hex>"]}}
```
```json
{"ev":"ack","id":"w3","ok":true,"event_id":"…","deleted":2,"published_to":1}
```

### get 拡張

- `kind:"note"` + `params.scope:"thread"`: スレッド取得。
  `data: {note:<event>, comments:[kind 1111(E==id, 古い順)], reactions:[kind 7(e==id, 古い順)]}`
- `kind:"author"` + `params:{pubkey, limit}`: その人の kind 1(created_at 降順)。
  `data: {notes:[…]}`
- `kind:"profile"` + `params:{pubkey}`: 保存済み kind 0 メタデータ。
  `data: {profile:{…}|null}`

```json
{"op":"get","id":"w4","kind":"note","params":{"id":"<64hex>","scope":"thread"}}
```

### search

ストア内検索。kind 1/1111 の content と、kind 0 の name / display_name /
nip05 / pubkey 前方一致(ASCII は大小非区別)。空クエリは
`error code:"bad_request"`。

```json
{"op":"search","id":"w5","params":{"query":"うんち","limit":50}}
```
```json
{"ev":"result","id":"w5","data":{"notes":[…],"profiles":[…]}}
```

### timeline フレームの kind

`timeline` チャネル(履歴・ライブとも)の `event` フレームは
kind 1 + 7(NIP-25 リアクション) + 1111(NIP-22 コメント) を運ぶ。
クライアントは kind を見て分岐すること(TUI は 7 を 👍 集計に、Web は
スレッドのリアクション集計に使う)。

## NIP-46 bunker (リモート署名)

nostrd は NIP-46 のリモート署名機(bunker)として動作できる。鍵は vault の
まま外に出ず、外部クライアント(外出先の web セッション、NIP-46 対応
アプリ)がリレー越しから署名を依頼する。

- トランスポート: kind 24133(NIP-44 v2 暗号化 JSON-RPC)。デーモンは自分の
  p タグ宛の 24133 を恒久購読し、リクエスト著者(クライアント鍵)へ暗号化
  レスポンスを返す(受信リレーを最優先にパブリッシュ)。
- 有効条件: `~/.config/nostrd/bunker.json`(0600) が存在し secret を持つ
  こと。`XDG_CONFIG_HOME` を尊重。
- 承認モデル: `connect` は (a) 許可リスト済みクライアント鍵、または
  (b) secret 一致の初回接続(以後その鍵を永続許可リストへ追加)のみ受理。
  他メソッドは全てライブセッション必須。`disconnect` でセッション破棄
  (許可リストは残る。完全失効は `--bunker-forget`)。
- サポートメソッド: `connect` / `get_public_key` / `sign_event`(署名済み
  イベントの JSON 文字列を返す) / `ping` / `disconnect`。

### 関連 op

- `info` の応答に `"bunker": {enabled: bool, sessions: [client 64hex]}`
  を追加。web は自セッションの生存確認に使う。
- `action` は `"client": <64hex>` を受け付ける。bunker 有効時、client
  が指定されたらアクティブセッションであることを検証し、失敗は
  `ack ok:false error:"no_session"`。client 未指定のローカルクライアント
  (TUI)は従来どおり信頼済み。
- `bunker_secret`: bunker.json を作成/読み込み、
  `{uri, relays, secret}` を返す(`bunker://<hex>?relay=…&secret=…`)。
  secret は初回のみ生成し回転しない。
- `bunker_list`: `{clients, sessions, enabled}` を返す。
- `bunker_forget` (params `{client}`): 許可リストから削除+セッション破棄。

### CLI (bin/nostr)

```sh
bin/nostr --bunker-secret            # URI を発行(web の設定画面へ貼る)
bin/nostr --bunker-list              # 許可リスト+セッション一覧
bin/nostr --bunker-forget <64hex>    # クライアントを失効
```

- `nostr_core/nip44.rb`: NIP-44 v2 実装(公式ベクトル全件通過)。
  `encrypt/decrypt(sk32, pk32, …)`、テスト用に `nonce:` 指定可。

## 生署名 op (NIP-5A / Blossom 用, v0 追加)

vault の「action のみ、生イベントは署名しない」境界の例外として、
**kind 許可リスト付き**の生署名 op を追加した。許可リスト外の kind は
`ack ok:false error:"… not raw-signable"` で拒否される。

- 許可 kind: `27235`(NIP-98) / `24242`(Blossom BUD-01/02 auth) /
  `10063`(Blossom サーバ一覧) / `15128` `35128` `5128`(NIP-5A nsite)
- `sign_raw` (params `{kind, content, tags, created_at?}`):
  形状検証(tags は文字列配列の配列、content は 64KiB 以下の文字列)を
  通した事件を署名して `{event}` を返す。
- `publish_raw` (同 params + `urls?`): sign_raw して publisher
  (書き込みリレー群)へ publish。`{event, published_to}` を返す。

### CLI (bin/nostr)

```sh
bin/nostr --nsite-publish DIR [--name birdwatch] [--title T] [--server URL]
# DIR を静的サイトとして Blossom にアップロード(kind 24242 auth、
# デーモン署名)し、kind 35128 マニフェストをデーモン署名+publish。
# ゲートウェイURL(<pubkeyB36><d>.nsite-…)を表示する。
```

### send_dm / dms (NIP-17)

NIP-59 gift wrap (kind 1059) で封印された NIP-17 チャット。daemon が wrap/unwrap
を担当し、ストアには平文の kind 14 rumor のみ置く。

```json
{"op":"send_dm","id":"d1","params":{"pubkey":"<64hex>","text":"hello"}}
{"ev":"ack","id":"d1","ok":true,"event_id":"…","published_to":1}
```
```json
{"op":"sub","id":"dm","channel":"dms","params":{"partner":"<64hex>","limit":50}}
{"ev":"event","sub":"dm","event":{…kind 14…}}
{"ev":"conversations","sub":"dm","conversations":[{"pubkey":"…","last":…,"count":n}]}
{"ev":"eod","sub":"dm"}
```
`partner` 省略時は会話一覧。gift wrap は相手の NIP-65 inbox 主張リレー
(`relay_claims_for`) にだけ発行され、どれにも接続していなければ
接続中リレーへフォールバックする（1059 は受信者以外には暗号文）。
