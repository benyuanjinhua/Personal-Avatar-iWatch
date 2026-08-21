import { mkdirSync, readFileSync, readdirSync, renameSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

export class FallbackJobOutbox {
  constructor({ stateDir }) { this.dir = join(stateDir, 'fallback-outbox'); mkdirSync(this.dir, { recursive: true }) }
  accept({ requestId, audio, meta, context, ledgerSeed = null }) {
    const prior = this.get(requestId)
    if (prior) return prior.audio_sha256 === meta.sha256 ? { status: 'duplicate', record: prior } : { status: 'conflict' }
    const audioPath = join(this.dir, `${encodeURIComponent(requestId)}.audio`)
    const temp = `${audioPath}.tmp`; writeFileSync(temp, audio); renameSync(temp, audioPath)
    const record = { request_id: requestId, audio_sha256: meta.sha256, audio_path: audioPath,
      meta, context, ledger_seed: ledgerSeed, state: 'pending', accepted_at: Date.now() }
    this.#write(record); return { status: 'accepted', record }
  }
  get(requestId) { try { return JSON.parse(readFileSync(this.#path(requestId), 'utf8')) } catch { return null } }
  readAudio(record) { return readFileSync(record.audio_path) }
  settle(requestId, state) { const r = this.get(requestId); if (!r) return; r.state = state; r.settled_at = Date.now(); this.#write(r) }
  pending() { return readdirSync(this.dir).filter(n => n.endsWith('.json')).flatMap(n => {
    try { const r = JSON.parse(readFileSync(join(this.dir, n), 'utf8')); return r.state === 'pending' ? [r] : [] } catch { return [] }
  }) }
  #path(id) { return join(this.dir, `${encodeURIComponent(id)}.json`) }
  #write(r) { const path = this.#path(r.request_id); const temp = `${path}.tmp`; writeFileSync(temp, JSON.stringify(r)); renameSync(temp, path) }
}
