// Turn ledger — persistent idempotency map and northbound state projection (ESS-26).
//
// request_id is THE idempotency key across the whole chain (§6):
//   request_id → sessionId → qwen task_id → codex session
// Each entry is unique on request_id; a retry with the same body replays the
// stored projection, a retry with a different body is an idempotency conflict.
//
// Northbound projected states (§4.1 / §6):
//   accepted | processing | permission_required | completed | failed | cancelled

import { EventEmitter } from 'node:events'
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'

export const NORTH_STATES = new Set([
  'accepted', 'processing', 'permission_required', 'completed', 'failed', 'cancelled',
])
const TERMINAL = new Set(['completed', 'failed', 'cancelled'])

export class TurnLedger extends EventEmitter {
  constructor({ stateDir, maxResultChars = 4000, maxResultAudioBytes = 2 * 1024 * 1024, log = () => {} }) {
    super()
    this.path = join(stateDir, 'turn-ledger.json')
    this.maxResultChars = maxResultChars
    this.maxResultAudioBytes = maxResultAudioBytes
    this.log = log
    this.turns = new Map()
    this.load()
  }

  load() {
    try {
      const raw = JSON.parse(readFileSync(this.path, 'utf8'))
      for (const [id, turn] of Object.entries(raw.turns || {})) this.turns.set(id, turn)
    } catch { /* first boot */ }
  }

  save() {
    mkdirSync(dirname(this.path), { recursive: true })
    const tmp = this.path + '.tmp'
    writeFileSync(tmp, JSON.stringify({ turns: Object.fromEntries(this.turns) }), { mode: 0o600 })
    renameSync(tmp, this.path)
  }

  get(requestId) { return this.turns.get(requestId) }

  // Idempotent create. Returns { turn, replay } — replay=true means the
  // request_id already exists and the caller must NOT start a second execution.
  create({ requestId, deviceId, bodySha256, sessionId }) {
    const existing = this.turns.get(requestId)
    if (existing) {
      if (existing.body_sha256 !== bodySha256) return { turn: existing, conflict: true }
      return { turn: existing, replay: true }
    }
    const now = new Date().toISOString()
    const turn = {
      request_id: requestId,
      device_id: deviceId,
      body_sha256: bodySha256,
      session_id: sessionId,
      task_id: null,
      codex_session_id: null,
      path: 'unknown',            // direct | background
      state: 'accepted',
      detail: null,               // sub-state for observability (realtime_processing, background_processing…)
      permission: null,           // { id, ...bounded summary } while permission_required
      result: null,               // { text, audio_base64?, truncated? } once terminal
      error: null,                // stable ERR_* code once failed
      event_count: 0,
      created_at: now,
      updated_at: now,
    }
    this.turns.set(requestId, turn)
    this.save()
    this.emitState(turn)
    return { turn, replay: false }
  }

  update(requestId, patch, { persist = true } = {}) {
    const turn = this.turns.get(requestId)
    if (!turn) return null
    if (TERMINAL.has(turn.state) && patch.state && patch.state !== turn.state) {
      // Terminal states are final: late gateway events must not resurrect a turn.
      return turn
    }
    Object.assign(turn, patch, { updated_at: new Date().toISOString() })
    if (persist) this.save()
    this.emitState(turn)
    return turn
  }

  // Trim results to the configured caps before storing (§4.1 result-size limit).
  setResult(requestId, { text = null, audioBase64 = null, extra = {} }, state = 'completed') {
    let truncated = false
    if (typeof text === 'string' && text.length > this.maxResultChars) {
      text = text.slice(0, this.maxResultChars) + '…'
      truncated = true
    }
    if (typeof audioBase64 === 'string' && Buffer.byteLength(audioBase64, 'utf8') > this.maxResultAudioBytes) {
      audioBase64 = null // audio over cap is dropped, text summary still delivered
      truncated = true
    }
    return this.update(requestId, {
      state,
      permission: null,
      result: { text, audio_base64: audioBase64, truncated, ...extra },
    })
  }

  fail(requestId, errCode, detail = null) {
    return this.update(requestId, { state: 'failed', error: errCode, detail, permission: null })
  }

  bumpEvents(requestId) {
    const turn = this.turns.get(requestId)
    if (!turn) return 0
    turn.event_count += 1
    return turn.event_count
  }

  emitState(turn) {
    this.emit('turn', this.projection(turn))
  }

  // What iPhone/Watch are allowed to see. No gateway internals, no session
  // details beyond the stable ids the client already knows about.
  projection(turn) {
    if (typeof turn === 'string') turn = this.turns.get(turn)
    if (!turn) return null
    return {
      request_id: turn.request_id,
      device_id: turn.device_id,
      status: turn.state,
      detail: turn.detail,
      path: turn.path,
      task_id: turn.task_id,
      permission: turn.permission,
      result: turn.result,
      error: turn.error,
      created_at: turn.created_at,
      updated_at: turn.updated_at,
    }
  }

  nonTerminal() {
    return [...this.turns.values()].filter(t => !TERMINAL.has(t.state))
  }
}
