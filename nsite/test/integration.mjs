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

// Photo attachment path: the compose uploads to Blossom with a NIP-98
// Authorization header — kind 24242 must round-trip the bunker with its
// tags intact (verified locally; the blob PUT itself is not exercised).
const sha = 'f'.repeat(64)
const authDraft = {
  kind: 24242,
  content: '',
  tags: [['t', 'upload'], ['x', sha],
         ['expiration', String(Math.floor(Date.now() / 1000) + 60)],
         ['u', 'https://blossom.primal.net']],
  created_at: Math.floor(Date.now() / 1000),
}
const auth = await client.signEvent(authDraft)
if (!verifyEvent(auth)) throw new Error('NIP-98 auth signature failed local verification')
if (auth.kind !== 24242) throw new Error('kind mutated')
const tagsJson = JSON.stringify(auth.tags)
if (!tagsJson.includes(`"x","${sha}"`)) throw new Error('x tag lost through the bunker')
if (!tagsJson.includes('"t","upload"')) throw new Error('t tag lost through the bunker')
const header = `Nostr ${Buffer.from(JSON.stringify(auth)).toString('base64')}`
if (!header.startsWith('Nostr eyJ')) throw new Error('auth header encoding broken')
console.log(`NIP-98 auth event OK: kind=24242 t=upload x=<${sha.slice(0, 8)}…> header ${header.length}b`)

// imeta-tagged note (photo posts carry NIP-92 imeta through sign_event).
const photoDraft = {
  kind: 1,
  content: `https://blossom.primal.net/${sha}`,
  tags: [['imeta', `url https://blossom.primal.net/${sha}`, 'm image/png', `x ${sha}`]],
  created_at: Math.floor(Date.now() / 1000),
}
const photo = await client.signEvent(photoDraft)
if (!verifyEvent(photo)) throw new Error('imeta note signature failed local verification')
if (!JSON.stringify(photo.tags).includes('imeta')) throw new Error('imeta tag lost')
console.log('imeta note OK: tags survive the round trip')
client.close()
console.log('ALL GREEN')
process.exit(0)
