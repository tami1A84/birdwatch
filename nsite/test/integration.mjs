// Integration test: run the REAL BunkerClient (same code the browser ships)
// in node against the live daemon through real relays.
//
//   BW_BUNKER_URI=bunker://… node test/integration.mjs
//   (or it reads $REPO/.scratch/real_uri.txt)
//
// Verifies: connect (secret accepted) → get_public_key → sign_event with a
// locally verified signature. Nothing is published to feeds.
import { readFile, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { generateSecretKey, verifyEvent } from 'nostr-tools'
import { BunkerClient, parseBunkerUri } from '../src/nip46.js'

const KEY_FILE = new URL('../../.scratch/nsite-test-sk.txt', import.meta.url)
let sk
if (existsSync(KEY_FILE)) {
  const hex = (await readFile(KEY_FILE, 'utf8')).trim()
  sk = Uint8Array.from(hex.match(/.{2}/g).map((h) => parseInt(h, 16)))
} else {
  sk = generateSecretKey()
  await writeFile(KEY_FILE, [...sk].map((b) => b.toString(16).padStart(2, '0')).join(''))
}

let uri = process.env.BW_BUNKER_URI
if (!uri) {
  const f = new URL('../../.scratch/real_uri.txt', import.meta.url)
  uri = (await readFile(f, 'utf8')).trim()
}
const parsed = parseBunkerUri(uri)
console.log(`daemon ${parsed.pubkey.slice(0, 8)}… via ${parsed.relays.length} relays`)

const client = new BunkerClient()
const t0 = Date.now()
const daemonPk = await client.connect(uri, sk, (s) => console.log(`  ${s}`))
if (daemonPk !== parsed.pubkey) throw new Error(`get_public_key mismatch: ${daemonPk}`)
console.log(`connect + get_public_key OK in ${((Date.now() - t0) / 1000).toFixed(1)}s`)

const draft = {
  kind: 1,
  content: `birdwatch nsite integration test ${new Date().toISOString()} (署名のみ、投稿されません)`,
  tags: [],
  created_at: Math.floor(Date.now() / 1000),
}
const signed = await client.signEvent(draft)
if (!verifyEvent(signed)) throw new Error('signature failed local verification')
if (signed.pubkey !== parsed.pubkey) throw new Error('signed by wrong pubkey')
if (signed.content !== draft.content) throw new Error('content mutated')
console.log(`sign_event OK: id=${signed.id.slice(0, 16)}… sig verified locally`)
client.close()
console.log('ALL GREEN')
process.exit(0)
