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
      event_count: 0,             // 全量观测计数（Realtime + SSE，ESS-37 取证口径）
      task_event_count: 0,        // 仅 SSE/task 生命周期事件（taskwatch 熔断预算，ESS-41）
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

  // 近期终态回合（ESS-38 复测）：iPhone 后台挂起是常态，WSS 断开期间到达的
  // completed（文本）与语音补挂投影会整体丢失——重连 snapshot 必须把保留窗口
  // 内的终态回合一并回放，靠客户端幂等去重（journal 状态机 + 音频 sha）消重。
  recentlyTerminal(windowMs, now = Date.now()) {
    return [...this.turns.values()].filter(t =>
      TERMINAL.has(t.state) && now - Date.parse(t.updated_at) <= windowMs)
  }
}
