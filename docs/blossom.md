# Blossom サーバの使い方 (内蔵 http://127.0.0.1:7778)

nostrd 起動時に内蔵 Blossom サーバが立ちます(停止: `nostrd --blossom-port 0`)。

- 実体: NIP-B7 (BUD-01/02) の Blob サブセット。ループバック専用。
- 保存先: `~/.local/share/nostrd/blobs/<sha256上位2桁>/<残り>`
- 認証: NIP-98 (kind 24242, `t` = action, `x` = sha256)。

## ローカル = プライベートミラー（バックアップ構成）

公開 Blossom が消えてもデータを失わない構成。**10063 に載せるのは公開サーバだけ**。

```
アップロード: 公開サーバ群 + ローカル 7778 に同時ミラー
  (nostr-nsite はミラーを先に書く — 途中で止まっても復旧可能)
取得: blossom-get  公開 → (404/タイムアウト) → ローカル
復旧: ローカルの同一 sha256 を新しい公開サーバへ再アップロードするだけ
```

```bash
# 取得(フォールバック付き): -o で保存、無指定なら stdout
nostrd/bin/blossom-get <sha256|blossom-url> -o FILE

# ローカルミラーをスキップ / ソース追加
nostrd/bin/blossom-get <sha> --no-local
nostrd/bin/blossom-get <sha> --server https://my.blossom.example
```

- nostr-nsite はデフォルトでローカルミラーを先に書く(`--no-local-mirror` で無効)
- ループバック URL は `Blossom::Client.loopback?` で manifest の server タグから除外される

## アップロード (PUT /upload)

認証ヘッダの流れ:

1. kind 24242 イベントを作る
   - tags: `["t","upload"]`, `["x","<sha256(FILE)>"]`, `["expiration","<unix時刻>"]`
   - content: JSON `{"action":"upload"}` 相当の任意文字列
2. `Authorization: Nostr base64(event JSON)` ヘッダを付けて PUT

```bash
SHA=$(sha256sum FILE | cut -d' ' -f1)
# daemon socket で生署名 (docs/protocol.md の raw_sign op)
BIN=$(base64 -w0 event.json)
curl -s -X PUT "http://127.0.0.1:7778/upload" \
  -H "Authorization: Nostr $BIN" \
  --data-binary @FILE
```

## 取得 (GET/HEAD /<sha256>)

```bash
curl -sO "http://127.0.0.1:7778/$SHA"        # 取得
curl -sI "http://127.0.0.1:7778/$SHA"        # 存在確認(404/200)
```

拡張子付き (`/$SHA.png`) も可。中身は sha256 で同一。

## 削除 (DELETE /<sha256>)

所有者(NIP-98, action=delete)のみ。他人の blob は 403。

## 確認

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7778/$(printf '0%.0s' {1..64})
# 404 が返ればサーバは生きている
```
