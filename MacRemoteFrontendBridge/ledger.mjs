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
import { createHash } from 'node:crypto'
import { mkdirSync, readFileSync, readdirSync, renameSync, unlinkSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

export const NORTH_STATES = new Set([
  'accepted', 'processing', 'permission_required', 'completed', 'failed', 'cancelled',
])
const TERMINAL = new Set(['completed', 'failed', 'cancelled'])

// ESS-255 / D2 v1.1: Bridge 真实产生的后台终态码。北向 detail 是用户可见字段，
// 不能透传上游 statusReason 或 ERR_*；稳定码继续保留在 error 字段供客户端查表。
export const BRIDGE_TASK_TERMINAL_ERRORS = new Set([
  'ERR_UPSTREAM_UNAVAILABLE',
  'ERR_TASK_NOT_FOUND',
  'ERR_TASK_FAILED',
  'ERR_RESULT_UNKNOWN',
])

const CLIENT_FAILURE_DETAILS = new Map([
  ['ERR_UPSTREAM_UNAVAILABLE', 'Mac 那边没应答。确认助手在运行，点重试不用重新说。'],
  ['ERR_TASK_NOT_FOUND', 'Mac 那边找不到这件事了，点重试我重新交一次。'],
  ['ERR_TASK_FAILED', '这件事我没办成，点重试再跑一次，不用重新说。'],
  ['ERR_RESULT_UNKNOWN', '这件事做完没有我不确定，去 Mac 上看一眼——我不敢替你重跑。'],
])

export function isAutomaticallyRetryableTerminalError(errorCode) {
  return BRIDGE_TASK_TERMINAL_ERRORS.has(errorCode) && errorCode !== 'ERR_RESULT_UNKNOWN'
}

export function clientFailureDetail(errorCode) {
  return CLIENT_FAILURE_DETAILS.get(errorCode) ?? '刚才这件事没成，点重试再来一次；还不行就再说一遍。'
}

export class TurnLedger extends EventEmitter {
  constructor({
    stateDir,
    maxResultChars = 4000,
    maxResultAudioBytes = 2 * 1024 * 1024,
    maxTurns = 5000,
    terminalRetentionMs = 7 * 24 * 60 * 60 * 1000,
    log = () => {},
  }) {
    super()
    // `path` is the pre-ESS-742 monolithic file. New writes are sharded into
    // one atomic file per request so update latency does not grow with history.
    this.path = join(stateDir, 'turn-ledger.json')
    this.recordsDir = join(stateDir, 'turn-ledger.d')
    this.maxResultChars = maxResultChars
    this.maxResultAudioBytes = maxResultAudioBytes
    this.maxTurns = Number.isSafeInteger(maxTurns) && maxTurns > 0 ? maxTurns : 5000
    this.terminalRetentionMs = (Number.isFinite(terminalRetentionMs) || terminalRetentionMs === Infinity)
      && terminalRetentionMs >= 0
      ? terminalRetentionMs : 7 * 24 * 60 * 60 * 1000
    this.log = log
    this.turns = new Map()
    this.load()
  }

  load() {
    let legacy = null
    try {
      legacy = JSON.parse(readFileSync(this.path, 'utf8')).turns || {}
    } catch { /* first boot */ }

    for (const [id, turn] of Object.entries(legacy || {})) this.loadTurn(id, turn)
    try {
      for (const name of readdirSync(this.recordsDir)) {
        if (!name.endsWith('.json')) continue
        try {
          const turn = JSON.parse(readFileSync(join(this.recordsDir, name), 'utf8'))
          if (typeof turn?.request_id === 'string') this.loadTurn(turn.request_id, turn)
        } catch (error) {
          this.log({ evt: 'turn_ledger_record_skipped', file: name, error: error.message })
        }
      }
    } catch { /* no sharded ledger yet */ }

    this.prune({ persist: false })
    if (legacy) {
      // Complete migration before retiring the old snapshot. A crash midway is
      // harmless: the next boot repeats idempotent per-record replacements.
      for (const turn of this.turns.values()) this.save(turn)
      renameSync(this.path, `${this.path}.migrated`)
      this.log({ evt: 'turn_ledger_migrated', turns: this.turns.size })
    }
  }

  loadTurn(id, turn) {
    // Pre-ESS-235 ledgers have no timing object. Backfill only timestamps from
    // the Bridge clock domain; Watch timestamps cannot be reconstructed.
    turn.timing = {
      watch_created_at: null,
      bridge_accepted_at: turn.created_at ?? null,
      processing_started_at: null,
      first_audio_ready_at: null,
      first_audio_source: null,
      completed_at: null,
      ...turn.timing,
    }
    this.turns.set(id, turn)
  }

  recordPath(requestId) {
    const name = createHash('sha256').update(requestId).digest('hex')
    return join(this.recordsDir, `${name}.json`)
  }

  save(turn = null) {
    if (!turn) {
      for (const item of this.turns.values()) this.save(item)
      return
    }
    mkdirSync(this.recordsDir, { recursive: true })
    const path = this.recordPath(turn.request_id)
    const tmp = `${path}.${process.pid}.tmp`
    writeFileSync(tmp, JSON.stringify(turn), { mode: 0o600 })
    renameSync(tmp, path)
  }

  prune({ now = Date.now(), persist = true } = {}) {
    const terminal = [...this.turns.values()]
      .filter(turn => TERMINAL.has(turn.state))
      .sort((a, b) => Date.parse(a.updated_at) - Date.parse(b.updated_at))
    const expired = terminal.filter(turn => {
      const updatedAt = Date.parse(turn.updated_at)
      return Number.isFinite(updatedAt) && now - updatedAt > this.terminalRetentionMs
    })
    const overLimit = Math.max(0, this.turns.size - expired.length - this.maxTurns)
    const victims = new Set([...expired, ...terminal.filter(t => !expired.includes(t)).slice(0, overLimit)])
    for (const turn of victims) {
      this.turns.delete(turn.request_id)
      if (persist) {
        try { unlinkSync(this.recordPath(turn.request_id)) } catch { /* already absent */ }
      }
    }
    if (victims.size) this.log({ evt: 'turn_ledger_pruned', turns: victims.size, retained: this.turns.size })
    return victims.size
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
      playback_receipts: {},      // response_id → real render completion (may arrive before terminal result)
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
        first_audio_source: null,
        completed_at: null,
      },
    }
    this.turns.set(requestId, turn)
    this.save(turn)
    this.prune()
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
    if (persist) this.save(turn)
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
    const turn = this.update(requestId, {
      state,
      permission: null,
      result: { text, audio_base64: audioBase64, audio, truncated, ...extra },
    })
    this.reconcilePlaybackDelivery(requestId)
    return turn
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
    // Derived durations must stay in one clock domain. watch_created_at is
    // retained for trace correlation only; mixing Watch and Bridge wall clocks
    // would silently add clock skew to P50/P95.
    const startAt = Date.parse(timing.bridge_accepted_at)
    const firstAudioAt = Date.parse(timing.first_audio_ready_at)
    const completedAt = Date.parse(timing.completed_at)
    if (Number.isFinite(startAt) && Number.isFinite(firstAudioAt)) timing.voice_ttft_ms = Math.max(0, firstAudioAt - startAt)
    if (Number.isFinite(startAt) && Number.isFinite(completedAt)) timing.end_to_end_ms = Math.max(0, completedAt - startAt)
    return {
      request_id: turn.request_id,
      device_id: turn.device_id,
      status: turn.state,
      detail: turn.state === 'failed' ? clientFailureDetail(turn.error) : turn.detail,
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
    this.save(turn)
    return turn
  }

  // ESS-521: only the Watch player's real final-frame receipt can deliver an
  // audio result. The receipt is persisted even when it races ahead of the
  // terminal projection; setResult() reconciles that out-of-order case.
  recordPlaybackEnded(requestId, { responseId, bytesPlayed, source = 'watch_render' } = {}) {
    const turn = this.turns.get(requestId)
    if (!turn || typeof responseId !== 'string' || responseId.length === 0
      || !Number.isSafeInteger(bytesPlayed) || bytesPlayed <= 0) return null
    turn.playback_receipts = turn.playback_receipts || {}
    if (!turn.playback_receipts[responseId]) {
      turn.playback_receipts[responseId] = {
        at: new Date().toISOString(), bytes_played: bytesPlayed, source,
      }
      this.save(turn)
    }
    return this.reconcilePlaybackDelivery(requestId)
  }

  reconcilePlaybackDelivery(requestId) {
    const turn = this.turns.get(requestId)
    const responseId = turn?.result?.response_id
    if (!turn || turn.state !== 'completed' || typeof responseId !== 'string') return turn ?? null
    const receipt = turn.playback_receipts?.[responseId]
    if (!receipt) return turn
    const duplicate = Boolean(turn.delivered_ack)
    const delivered = this.acknowledgeResult(requestId, { source: receipt.source })
    this.log({
      evt: duplicate ? 'result_replayed_after_delivered' : 'result_delivered_after_render',
      request_id: requestId, response_id: responseId,
      bytes_played: receipt.bytes_played, duplicate,
    })
    return delivered
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
    if (!turn || !TERMINAL.has(turn.state)) return null
    if (turn.delivered_ack) {
      this.log({
        evt: 'result_replayed_after_delivered', request_id: requestId,
        delivered_at: turn.delivered_ack.at, source: turn.delivered_ack.source,
      })
      return null
    }
    turn.delivery_attempts = (turn.delivery_attempts || 0) + 1
    const delay = Math.min(maxDelayMs, baseDelayMs * 2 ** Math.max(0, turn.delivery_attempts - 1))
    turn.next_delivery_at = new Date(now + delay).toISOString()
    this.save(turn)
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
