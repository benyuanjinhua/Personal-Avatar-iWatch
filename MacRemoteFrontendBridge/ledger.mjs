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

  // task_id → turn（ESS-38：announcement 的 taskId 归属回原 request_id）。
  // 多个 turn 命中同一 task_id 时取最新的一个（Map 保持插入序）：真实网关
  // task id 唯一，命中多条只会来自历史残留，播报只属于最近的请求。
  byTaskId(taskId) {
    if (!taskId) return null
    let match = null
    for (const turn of this.turns.values()) {
      if (turn.task_id && String(turn.task_id) === String(taskId)) match = turn
    }
    return match
  }

  // Idempotent create. Returns { turn, replay } — replay=true means the
  // request_id already exists and the caller must NOT start a second execution.
  create({ requestId, deviceId, bodySha256, sessionId, watchCreatedAt = null }) {
    const existing = this.turns.get(requestId)
    if (existing) {
      if (existing.body_sha256 !== bodySha256) return { turn: existing, conflict: true }
      return { turn: existing, replay: true }
    }
    const now = new Date().toISOString()
    const watchAt = Number.isFinite(Date.parse(watchCreatedAt)) ? new Date(watchCreatedAt).toISOString() : null
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
      delivered_ack: null,        // { at, source } once Watch has durably stored the result
      delivery_attempts: 0,       // terminal snapshot redeliveries (bounded + backed off)
      next_delivery_at: null,
      error: null,                // stable ERR_* code once failed
      event_count: 0,             // 全量观测计数（Realtime + SSE，ESS-37 取证口径）
      task_event_count: 0,        // 仅 SSE/task 生命周期事件（taskwatch 熔断预算，ESS-41）
      created_at: now,
      updated_at: now,
      timing: {
        watch_created_at: watchAt,
        bridge_accepted_at: now,
        processing_started_at: null,
        first_audio_ready_at: null,
        completed_at: null,
      },
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
    const updatedAt = new Date().toISOString()
    const timing = { ...turn.timing, ...patch.timing }
    if (patch.state === 'processing' && !timing.processing_started_at) timing.processing_started_at = updatedAt
    if (patch.state && TERMINAL.has(patch.state) && !timing.completed_at) timing.completed_at = updatedAt
    Object.assign(turn, patch, { updated_at: updatedAt, timing })
    if (persist) this.save()
    this.emitState(turn)
    return turn
  }

  // Trim results to the configured caps before storing (§4.1 result-size limit).
  // `audio`（ESS-38）：结果语音文件的元数据 {sha256, codec, duration_ms,
  // size_bytes}——即使 inline base64 超限被丢弃，元数据仍保留，客户端可经
  // GET /v1/voice/turns/:id/audio 有界下载取回。
  setResult(requestId, { text = null, audioBase64 = null, audio = null, extra = {} }, state = 'completed') {
    let truncated = false
    if (typeof text === 'string' && text.length > this.maxResultChars) {
      text = text.slice(0, this.maxResultChars) + '…'
      truncated = true
    }
    if (typeof audioBase64 === 'string' && Buffer.byteLength(audioBase64, 'utf8') > this.maxResultAudioBytes) {
      audioBase64 = null // inline audio over cap is dropped; metadata + download endpoint remain
      truncated = true
    }
    return this.update(requestId, {
      state,
      permission: null,
      result: { text, audio_base64: audioBase64, audio, truncated, ...extra },
    })
  }

  // 迟到的结果语音补挂到已完成 turn（ESS-38：announcement 在 task 终态之后
  // 到达）。只补 completed；state 不变，重新投影一次让北向客户端拿到音频。
  attachResultAudio(requestId, { audioBase64 = null, audio = null, speechText = null }) {
    const turn = this.turns.get(requestId)
    if (!turn || turn.state !== 'completed' || !turn.result) return null
    if (typeof audioBase64 === 'string' && Buffer.byteLength(audioBase64, 'utf8') > this.maxResultAudioBytes) {
      audioBase64 = null
    }
    return this.update(requestId, {
      result: {
        ...turn.result,
        audio_base64: audioBase64,
        audio,
        ...(speechText ? { speech_text: speechText } : {}),
      },
    })
  }

  fail(requestId, errCode, detail = null) {
    return this.update(requestId, { state: 'failed', error: errCode, detail, permission: null })
  }

  markFirstAudioReady(requestId, { at = new Date().toISOString(), source = null } = {}) {
    const turn = this.turns.get(requestId)
    if (!turn) return null
    const timing = { ...turn.timing }
    if (timing.first_audio_ready_at) return turn
    timing.first_audio_ready_at = at
    timing.first_audio_source = source
    return this.update(requestId, { timing })
  }

  bumpEvents(requestId) {
    const turn = this.turns.get(requestId)
    if (!turn) return 0
    turn.event_count += 1
    return turn.event_count
  }

  // ESS-41 B1：熔断预算与观测计数分账。Realtime 逐字 delta / audio.delta 只进
  // event_count（取证口径不变），SSE/task 生命周期事件才进 task_event_count——
  // taskwatch 的 max_turn_events 只看这里，健康的高频语音流喂不爆它。
  bumpTaskEvents(requestId) {
    const turn = this.turns.get(requestId)
    if (!turn) return 0
    turn.event_count += 1
    turn.task_event_count = (turn.task_event_count || 0) + 1
    return turn.task_event_count
  }

  emitState(turn) {
    this.emit('turn', this.projection(turn))
  }

  // What iPhone/Watch are allowed to see. No gateway internals, no session
  // details beyond the stable ids the client already knows about.
  projection(turn) {
    if (typeof turn === 'string') turn = this.turns.get(turn)
    if (!turn) return null
    const timing = { ...turn.timing }
    const startAt = Date.parse(timing.watch_created_at || timing.bridge_accepted_at)
    const firstAudioAt = Date.parse(timing.first_audio_ready_at)
    const completedAt = Date.parse(timing.completed_at)
    if (Number.isFinite(startAt) && Number.isFinite(firstAudioAt)) timing.voice_ttft_ms = Math.max(0, firstAudioAt - startAt)
    if (Number.isFinite(startAt) && Number.isFinite(completedAt)) timing.end_to_end_ms = Math.max(0, completedAt - startAt)
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
      timing,
    }
  }

  acknowledgeResult(requestId, { source = 'watch' } = {}) {
    const turn = this.turns.get(requestId)
    if (!turn || !TERMINAL.has(turn.state)) return null
    if (turn.delivered_ack) return turn
    turn.delivered_ack = { at: new Date().toISOString(), source }
    turn.updated_at = new Date().toISOString()
    this.save()
    return turn
  }

  dueTerminalDeliveries({ now = Date.now(), terminalTtlMs = 30 * 60 * 1000, maxDeliveryAttempts = 5 } = {}) {
    return [...this.turns.values()].filter(turn =>
      this.isTerminalDeliveryDue(turn, { now, terminalTtlMs, maxDeliveryAttempts }))
  }

  isTerminalDeliveryDue(turn, { now = Date.now(), terminalTtlMs = 30 * 60 * 1000, maxDeliveryAttempts = 5 } = {}) {
    if (!TERMINAL.has(turn.state) || turn.delivered_ack) return false
    if ((turn.delivery_attempts || 0) >= maxDeliveryAttempts) return false
    const nextDeliveryAt = Date.parse(turn.next_delivery_at)
    if (Number.isFinite(nextDeliveryAt) && now < nextDeliveryAt) return false
    const terminalAt = Date.parse(turn.updated_at)
    return Number.isFinite(terminalAt) && now - terminalAt <= terminalTtlMs
  }

  markResultRedelivered(requestId, { now = Date.now(), baseDelayMs = 2_000, maxDelayMs = 300_000 } = {}) {
    const turn = this.turns.get(requestId)
    if (!turn || !TERMINAL.has(turn.state) || turn.delivered_ack) return null
    turn.delivery_attempts = (turn.delivery_attempts || 0) + 1
    const delay = Math.min(maxDelayMs, baseDelayMs * 2 ** Math.max(0, turn.delivery_attempts - 1))
    turn.next_delivery_at = new Date(now + delay).toISOString()
    this.save()
    return { attempt: turn.delivery_attempts, delay_ms: delay }
  }

  replayable({ now = Date.now(), terminalTtlMs = 30 * 60 * 1000, maxDeliveryAttempts = 5 } = {}) {
    return [...this.turns.values()].filter(turn => {
      if (!TERMINAL.has(turn.state)) return true
      return this.isTerminalDeliveryDue(turn, { now, terminalTtlMs, maxDeliveryAttempts })
    })
  }

  nonTerminal() {
    return [...this.turns.values()].filter(t => !TERMINAL.has(t.state))
  }
}
