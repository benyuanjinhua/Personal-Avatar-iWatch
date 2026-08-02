#!/usr/bin/env node
// Remote Frontend Bridge — full P1 implementation (ESS-26).
//
// Northbound (iPhone over Tailscale, HTTPS + WSS, HMAC-signed):
//   POST /v1/pair
//   POST /v1/voice/turns              idempotent create; 202 accepted receipt
//   GET  /v1/voice/turns/{id}         stable projection + short result
//   POST /v1/voice/turns/{id}/cancel
//   POST /v1/voice/turns/{id}/permission
//   WSS  /v1/voice/events             state / permission / result events
//   GET  /v1/health
//
// Southbound (loopback gateway only, upstream public protocol — §7):
//   WS   /api/realtime?sessionId=watch-bridge-v1-<device>   (audio inject)
//   SSE  /api/tasks/:id/events, GET/DELETE /api/tasks/:id, POST /api/permissions/:id
//
// Red lines enforced by construction: the bridge never invokes the Codex CLI,
// accepts no command lines / working directories / env vars from clients, and
// exposes no gateway admin API northbound.

import https from 'node:https'
import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { WebSocketServer } from 'ws'

import { ApiError, DeviceAuth, ERR, makeSourceGate, normalizeIp, sha256hex } from './auth.mjs'
import { TurnLedger } from './ledger.mjs'
import { GatewayClient } from './gateway.mjs'
import { TaskWatcher } from './taskwatch.mjs'
import { AudioPipeline } from './audio.mjs'
import { ResultAudioStore } from './result-audio.mjs'
import { QwenRealtimeSessionSupervisor } from './supervisor.mjs'

const BASE = dirname(fileURLToPath(import.meta.url))

// 16-bit PCM 的 RMS 能量（ESS-41 B2）：区分「几乎全静音的误触」与真实语音。
function pcmRms16(pcm) {
  const samples = pcm.length >> 1
  if (samples === 0) return 0
  let sum = 0
  for (let i = 0; i < samples; i++) {
    const v = pcm.readInt16LE(i * 2)
    sum += v * v
  }
  return Math.sqrt(sum / samples)
}

export function createBridge(overrides = {}) {
  const CONFIG = { ...JSON.parse(readFileSync(join(BASE, 'config.json'), 'utf8')), ...overrides }
  const log = obj => process.stdout.write(JSON.stringify({ ts: new Date().toISOString(), ...obj }) + '\n')
  const stateDir = resolve(BASE, CONFIG.state_dir)

  const auth = new DeviceAuth({
    stateDir,
    timestampSkewMs: CONFIG.timestamp_skew_ms,
    pairingCodeTtlMs: CONFIG.pairing_code_ttl_ms,
    log,
  })
  const ledger = new TurnLedger({
    stateDir,
    maxResultChars: CONFIG.max_result_chars,
    maxResultAudioBytes: CONFIG.max_result_audio_bytes,
    log,
  })
  const gateway = new GatewayClient({ baseUrl: CONFIG.gateway_url, log })
  const watcher = new TaskWatcher({ gateway, ledger, config: CONFIG, log })
  watcher.startDenySweeper()   // D1：写开关关闭时全局清扫 pending 权限（no-op otherwise）
  const audio = new AudioPipeline({
    audiopipePath: resolve(BASE, CONFIG.audiopipe_path),
    allowTestPcm: CONFIG.allow_test_pcm === true,
  })
  const resultAudio = new ResultAudioStore({
    stateDir,
    retentionMs: CONFIG.result_audio_retention_ms ?? 24 * 60 * 60 * 1000,
    log,
  })
  const supervisor = new QwenRealtimeSessionSupervisor({
    gatewayUrl: CONFIG.gateway_url.replace(/^http/, 'ws') + '/api/realtime',
    deviceId: CONFIG.device_id,
    idleDisconnectMs: CONFIG.idle_disconnect_ms,
    turnTimeoutMs: CONFIG.turn_timeout_ms,
    injectAckTimeoutMs: CONFIG.inject_ack_timeout_ms ?? 15_000,
    takeoverFromFrontends: CONFIG.takeover_from_frontends === true,
    maxAnnouncementPcmBytes: CONFIG.max_announcement_pcm_bytes ?? 5_760_000,
    ...(CONFIG.trailing_silence_ms ? { trailingSilenceMs: CONFIG.trailing_silence_ms } : {}),
    ...(CONFIG.turn_gap_ms !== undefined ? { turnGapMs: CONFIG.turn_gap_ms } : {}),
    probeTimeoutMs: CONFIG.probe_timeout_ms,
    firstEventTimeoutMs: CONFIG.first_event_timeout_ms,
    maxTurnAttempts: CONFIG.max_turn_attempts,
    log: (...args) => log({ evt: 'supervisor', detail: args.map(String).join(' ').slice(0, 500) }),
  })
  // ESS-36 可观测性 + ESS-37 取证：supervisor journal（ws.connecting/close
  // code/error frame、probe、stall、rebuild、全部网关事件摘要）全量落 Bridge
  // 结构化日志，request_id 由 journal 的 label 字段携带 —— accepted →
  // realtime events → completed 可按同一 request_id 串起来。原始音频永不落
  // 日志（journal 只记字节数）。RT_GATEWAY_EVENTS 同步累计账本事件数
  // （ESS-37：修复 event_count 只统计后台 SSE、从不统计 Realtime 的取证缺口）。
  // ESS-41 B1：此处只走 bumpEvents（纯观测计数）——taskwatch 的熔断预算在
  // bumpTaskEvents 单独分账，Realtime 高频 delta 流永不触发 taskwatch 熔断。
  const RT_GATEWAY_EVENTS = new Set([
    'gateway.connected', 'voice.ready', 'voice.state', 'voice.deactivated',
    'turn.started', 'audio.delta', 'audio.done', 'response.started', 'response.interrupted',
    'transcript.delta', 'transcript.final', 'transcript.discard', 'timeline.inline',
    'playback.clear', 'error',
    'task.running', 'task.delegated', 'task.finalizing', 'task.cancelling', 'task.progress',
    'task.completed', 'task.failed', 'task.cancelled',
    'task.permission.requested', 'task.permission.resolved',
  ])
  supervisor.listeners.add(item => {
    const { ts, label, event, ...rest } = item
    if (label && RT_GATEWAY_EVENTS.has(event)) ledger.bumpEvents(label)
    log({ evt: 'realtime', request_id: label ?? null, event, ...rest })
  })
  const sourceAllowed = makeSourceGate(CONFIG.allowed_peer_ips)

  // 长任务即时回执（ESS-46）：事件本身不进入终态账本，避免改变回合状态机。
  // delivery_sequence 与 final（2）分离，北向/Watch 可据此跨重连幂等去重。
  const deliveredInterims = new Set()
  const interimPayloads = new Map()
  let fallbackInterimAudio = null
  try {
    fallbackInterimAudio = readFileSync(resolve(BASE, CONFIG.interim_fallback_audio_path))
  } catch (error) {
    log({ evt: 'interim_fallback_unavailable', reason: String(error.message) })
  }
  function emitInterim(requestId, payload) {
    if (deliveredInterims.has(requestId)) return
    deliveredInterims.add(requestId)
    const interim = { kind: 'interim', request_id: requestId, delivery_sequence: 1, ...payload }
    interimPayloads.set(requestId, interim)
    const message = JSON.stringify({
      type: 'turn.interim',
      interim,
    })
    for (const client of eventClients) {
      const turn = ledger.get(requestId)
      if (turn && client.deviceId === turn.device_id && client.ws.readyState === client.ws.OPEN) {
        client.ws.send(message)
      }
    }
  }

  function clearInterim(requestId) {
    deliveredInterims.delete(requestId)
    interimPayloads.delete(requestId)
  }

  // ---- announcement 语音下行归属（ESS-38） ---------------------------------
  //
  // 后台任务的结果语音以 origin=announcement 经 Realtime WS 到达，taskId 是
  // 与账本 task_id 的唯一可靠关联。到达次序与 task 终态不定：先到的一方把
  // 数据存进 pendingResultAudio / 账本，后到的一方完成绑定。绑定成功后结果
  // 重新投影（turn.state 事件），北向先拿到文本、随后补到语音元数据。

  const pendingResultAudio = new Map() // request_id → { meta, base64, speechText, at }
  const pendingAnnouncements = new Map() // task_id → raw announcement, waiting for ledger binding
  const PENDING_AUDIO_TTL_MS = 10 * 60 * 1000
  const MAX_PENDING_ANNOUNCEMENTS = 64
  const MAX_PENDING_ANNOUNCEMENT_BYTES = (CONFIG.max_announcement_pcm_bytes ?? 5_760_000) * 4
  let pendingAnnouncementBytes = 0

  function attachPendingResultAudio(requestId) {
    const entry = pendingResultAudio.get(requestId)
    const turn = ledger.get(requestId)
    if (!entry || !turn || turn.state !== 'completed') return
    pendingResultAudio.delete(requestId) // delete first: update re-emits 'turn'
    ledger.attachResultAudio(requestId, {
      audioBase64: entry.base64,
      audio: entry.meta,
      speechText: entry.speechText,
    })
    log({ evt: 'result_audio_attached', request_id: requestId, size_bytes: entry.meta.size_bytes, duration_ms: entry.meta.duration_ms })
  }

  async function bindAnnouncement(announcement, turn) {
    const { taskId, responseId, transcript, pcm24k, truncated } = announcement
    const requestId = turn.request_id
    if (pcm24k.length === 0) {
      // 纯文本播报：没有语音可交付，保留 transcript 作为语气摘要
      if (transcript) {
        pendingResultAudio.set(requestId, { meta: null, base64: null, speechText: transcript, at: Date.now() })
        attachPendingResultAudio(requestId)
      }
      return
    }
    try {
      const m4a = await audio.encode24kToM4a(pcm24k)
      const meta = {
        sha256: sha256hex(m4a),
        codec: 'm4a',
        duration_ms: Math.round(pcm24k.length / 48), // 24kHz mono PCM16 = 48 bytes/ms
        size_bytes: m4a.length,
        ...(truncated ? { truncated: true } : {}),
      }
      resultAudio.put(requestId, m4a)
      pendingResultAudio.set(requestId, {
        meta,
        base64: m4a.length <= CONFIG.max_result_audio_bytes ? m4a.toString('base64') : null,
        speechText: transcript,
        at: Date.now(),
      })
      log({ evt: 'announcement_bound', request_id: requestId, task_id: taskId, response_id: responseId, pcm_bytes: pcm24k.length, m4a_bytes: m4a.length })
      log({ evt: 'l1_audio_ready', request_id: requestId, task_id: taskId, source: 'background', response_id: responseId, codec: 'm4a', duration_ms: meta.duration_ms, size_bytes: meta.size_bytes, sha256: meta.sha256 })
      attachPendingResultAudio(requestId)
    } catch (error) {
      // 转码失败：文本结果照常交付（降级），原因入日志
      log({ evt: 'announcement_encode_failed', request_id: requestId, err: String(error.message) })
      log({ evt: 'l1_audio_failed', request_id: requestId, task_id: taskId, response_id: responseId, source: 'background', stage: 'encode', reason: String(error.message) })
      if (transcript) {
        pendingResultAudio.set(requestId, { meta: null, base64: null, speechText: transcript, at: Date.now() })
        attachPendingResultAudio(requestId)
      }
    }
  }

  function queueAnnouncement(announcement) {
    const { taskId, responseId, pcm24k } = announcement
    if (!taskId) {
      log({ evt: 'announcement_unmatched', task_id: null, response_id: responseId, pcm_bytes: pcm24k.length, reason: 'missing_task_id' })
      log({ evt: 'l1_audio_failed', request_id: null, task_id: null, response_id: responseId, source: 'background', stage: 'ownership', reason: 'missing_task_id' })
      return
    }
    const key = String(taskId)
    const previous = pendingAnnouncements.get(key)
    if (previous?.responseId === responseId) return
    if (previous) pendingAnnouncementBytes -= previous.pcm24k.length
    while (pendingAnnouncements.size >= MAX_PENDING_ANNOUNCEMENTS
      || pendingAnnouncementBytes + pcm24k.length > MAX_PENDING_ANNOUNCEMENT_BYTES) {
      const oldestKey = pendingAnnouncements.keys().next().value
      if (oldestKey === undefined) break
      const dropped = pendingAnnouncements.get(oldestKey)
      pendingAnnouncements.delete(oldestKey)
      pendingAnnouncementBytes -= dropped.pcm24k.length
      log({ evt: 'announcement_unmatched_expired', task_id: oldestKey, response_id: dropped.responseId, reason: 'capacity' })
    }
    if (pcm24k.length > MAX_PENDING_ANNOUNCEMENT_BYTES) {
      log({ evt: 'announcement_unmatched', task_id: key, response_id: responseId, pcm_bytes: pcm24k.length, reason: 'capacity' })
      return
    }
    pendingAnnouncements.set(key, { ...announcement, at: Date.now() })
    pendingAnnouncementBytes += pcm24k.length
    log({ evt: 'announcement_unmatched_pending', task_id: key, response_id: responseId, pcm_bytes: pcm24k.length, ttl_ms: PENDING_AUDIO_TTL_MS })
  }

  function attachPendingAnnouncement(projection) {
    if (!projection.task_id) return
    const key = String(projection.task_id)
    const announcement = pendingAnnouncements.get(key)
    if (!announcement) return
    const turn = ledger.byTaskId(key)
    if (!turn) return
    pendingAnnouncements.delete(key)
    pendingAnnouncementBytes -= announcement.pcm24k.length
    log({ evt: 'announcement_rebound', request_id: turn.request_id, task_id: key, response_id: announcement.responseId })
    void bindAnnouncement(announcement, turn)
  }

  supervisor.onAnnouncement = async announcement => {
    const turn = announcement.taskId ? ledger.byTaskId(announcement.taskId) : null
    if (!turn) return queueAnnouncement(announcement)
    await bindAnnouncement(announcement, turn)
  }

  // task 终态先于 announcement 落账时，completed 投影触发补挂
  ledger.on('turn', projection => {
    attachPendingAnnouncement(projection)
    if (['completed', 'failed', 'cancelled'].includes(projection.status)) {
      clearInterim(projection.request_id)
    }
    if (projection.status === 'completed' && pendingResultAudio.has(projection.request_id)) {
      attachPendingResultAudio(projection.request_id)
    }
  })

  const pendingAudioSweeper = setInterval(() => {
    const cutoff = Date.now() - PENDING_AUDIO_TTL_MS
    for (const [requestId, entry] of pendingResultAudio) {
      if (entry.at < cutoff) pendingResultAudio.delete(requestId)
    }
    for (const [taskId, entry] of pendingAnnouncements) {
      if (entry.at < cutoff) {
        pendingAnnouncements.delete(taskId)
        pendingAnnouncementBytes -= entry.pcm24k.length
        log({ evt: 'announcement_unmatched_expired', task_id: taskId, response_id: entry.responseId, reason: 'ttl' })
      }
    }
  }, 60_000)
  pendingAudioSweeper.unref?.()

  // ---- turn processing ----------------------------------------------------

  const workTimers = new Map() // request_id → deadline timer (realtime phase)

  function armWorkDeadline(requestId) {
    disarmWorkDeadline(requestId) // 重挂（注入真正开始时重置预算），不叠加旧定时器
    const timer = setTimeout(async () => {
      workTimers.delete(requestId)
      const turn = ledger.get(requestId)
      if (!turn || ['completed', 'failed', 'cancelled'].includes(turn.state)) return
      if (turn.task_id) return // background phase: TaskWatcher owns the deadline
      log({ evt: 'work_timeout_realtime', request_id: requestId })
      if (supervisor.currentTurn?.label === requestId) supervisor.abortCurrentTurn('work timeout')
      ledger.fail(requestId, 'ERR_WORK_TIMEOUT')
    }, CONFIG.max_work_ms)
    timer.unref?.()
    workTimers.set(requestId, timer)
  }

  function disarmWorkDeadline(requestId) {
    clearTimeout(workTimers.get(requestId))
    workTimers.delete(requestId)
  }

  async function processTurn(requestId, audioBuf, audioMeta) {
    armWorkDeadline(requestId)
    try {
      if (ledger.get(requestId)?.state === 'cancelled') return // cancelled while queued

      ledger.update(requestId, { state: 'processing', detail: 'decoding' })
      const { pcm16k } = await audio.decodeTo16k(audioBuf, audioMeta.codec)

      // ESS-41 B2：空/误触音频快速失败——最小时长 + 能量下限在注入前拦截，
      // 不进 Realtime 注入 / 停摆重放 / 会话重建机器（真机取证：1920 bytes
      // ≈60ms 的尾部静音走完整停摆链后误报 ERR_REALTIME_STALLED）。
      const durationMs = pcm16k.length / 32 // 16kHz mono PCM16 = 32 bytes/ms
      const rms = pcmRms16(pcm16k)
      if (durationMs < (CONFIG.min_audio_ms ?? 0) || rms < (CONFIG.min_audio_rms ?? 0)) {
        log({ evt: 'audio_too_short', request_id: requestId, pcm_bytes: pcm16k.length, duration_ms: Math.round(durationMs), rms: Math.round(rms) })
        ledger.fail(requestId, 'ERR_AUDIO_TOO_SHORT')
        return
      }

      if (ledger.get(requestId)?.state === 'cancelled') return
      ledger.update(requestId, { state: 'processing', detail: 'realtime_processing' })
      const result = await supervisor.injectTurn(pcm16k, {
        label: requestId,
        // 串行队列：work deadline 在轮到本 turn 注入时重挂——按受理时刻起算
        // 的话，积压队尾在排队期就被判死（ESS-36 真机 4×ERR_WORK_TIMEOUT）。
        onStart: () => armWorkDeadline(requestId),
        // 排队期间已被取消/超时判死的 turn 不再浪费一个 Realtime 会话轮次
        shouldRun: () => !['completed', 'failed', 'cancelled'].includes(ledger.get(requestId)?.state),
      })

      if (ledger.get(requestId)?.state === 'cancelled') {
        // Result arrived after a cancel during injection — do not overwrite.
        return
      }

      if (result.taskId) {
        // Realtime 在委派前生成的口头确认已经随当前 turn 聚合在 result 中。
        // 先下发 interim，再推进 background_accepted，保证 Watch 先看到/听到回执。
        const interimText = result.assistantTranscript?.trim() || '收到，正在处理，请稍后'
        let interimAudio = null
        if (result.audio24k?.length) {
          try {
            const m4a = await audio.encode24kToM4a(result.audio24k)
            interimAudio = {
              base64: m4a.toString('base64'),
              sha256: sha256hex(m4a),
              codec: 'm4a',
              duration_ms: Math.round(result.audio24k.length / 48),
              size_bytes: m4a.length,
            }
            log({ evt: 'l1_audio_ready', request_id: requestId, task_id: result.taskId, source: 'interim', response_id: result.responseIds?.[0] ?? null, codec: 'm4a', duration_ms: interimAudio.duration_ms, size_bytes: interimAudio.size_bytes, sha256: interimAudio.sha256 })
          } catch (error) {
            log({ evt: 'l1_audio_failed', request_id: requestId, task_id: result.taskId, source: 'interim', stage: 'encode', reason: String(error.message) })
          }
        }
        if (!interimAudio && fallbackInterimAudio) {
          interimAudio = {
            base64: fallbackInterimAudio.toString('base64'),
            sha256: sha256hex(fallbackInterimAudio),
            codec: 'm4a',
            duration_ms: null,
            size_bytes: fallbackInterimAudio.length,
          }
          log({ evt: 'l1_audio_ready', request_id: requestId, task_id: result.taskId, source: 'interim', response_id: null, codec: 'm4a', duration_ms: null, size_bytes: interimAudio.size_bytes, sha256: interimAudio.sha256, fallback: true })
        }
        emitInterim(requestId, { text: interimText, audio: interimAudio })
        // Background path: only now (task event captured) is it background_accepted (§6).
        ledger.update(requestId, {
          task_id: result.taskId,
          path: 'background',
          state: 'processing',
          detail: 'background_accepted',
        })
        disarmWorkDeadline(requestId) // hand the 300s deadline to the TaskWatcher
        await watcher.watch(requestId)
        return
      }

      // Direct path: transcode the aggregated 24k reply for the Watch.
      // 同时落结果语音文件 + 元数据（ESS-38）：inline base64 超限被裁掉时，
      // iPhone 仍可经 /audio 端点有界取回。
      let audioBase64 = null
      let resultAudioMeta = null
      if (result.audio24k?.length) {
        try {
          const m4a = await audio.encode24kToM4a(result.audio24k)
          resultAudioMeta = {
            sha256: sha256hex(m4a),
            codec: 'm4a',
            duration_ms: Math.round(result.audio24k.length / 48),
            size_bytes: m4a.length,
          }
          resultAudio.put(requestId, m4a)
          audioBase64 = m4a.toString('base64')
          log({ evt: 'l1_audio_ready', request_id: requestId, task_id: null, source: 'direct', response_id: result.responseIds?.[0] ?? null, codec: 'm4a', duration_ms: resultAudioMeta.duration_ms, size_bytes: resultAudioMeta.size_bytes, sha256: resultAudioMeta.sha256 })
        } catch (error) {
          log({ evt: 'encode_failed', request_id: requestId, err: String(error.message) })
          log({ evt: 'l1_audio_failed', request_id: requestId, task_id: null, source: 'direct', response_id: result.responseIds?.[0] ?? null, stage: 'encode', reason: String(error.message) })
        }
      }
      ledger.update(requestId, { path: 'direct' })
      ledger.setResult(requestId, {
        text: result.assistantTranscript,
        audioBase64,
        audio: resultAudioMeta,
        extra: { source: 'realtime_direct', user_transcript: result.userTranscript },
      }, 'completed')
    } catch (error) {
      const turn = ledger.get(requestId)
      if (!turn || ['completed', 'failed', 'cancelled'].includes(turn.state)) return
      if (error.cancelled || error.skipped) {
        // skipped：排队期间已进入终态（cancel / work timeout），保持原状即可
        if (error.cancelled) ledger.update(requestId, { state: 'cancelled' })
      } else if (/work timeout/.test(String(error.message))) {
        ledger.fail(requestId, 'ERR_WORK_TIMEOUT')
      } else if (/turn timeout/.test(String(error.message))) {
        ledger.fail(requestId, 'ERR_REALTIME_TIMEOUT')
      } else if (error.code === 'ERR_VOICE_BUSY') {
        // 语音所有权被其他前台占用且不允许抢占：快速、确定地失败，
        // 客户端可提示用户关闭占用方后重试，而不是白等 120s 超时
        log({ evt: 'voice_busy', request_id: requestId, holder: error.holder ?? null })
        ledger.fail(requestId, 'ERR_VOICE_BUSY')
      } else if (error.code === 'ERR_REALTIME_NO_EVENTS') {
        ledger.fail(requestId, 'ERR_REALTIME_NO_EVENTS')
      } else if (error.code === 'ERR_TRANSCRIPT_DISCARDED') {
        // 语音未被识别为有效指令：稳定错误码，Watch 端可提示"没听清，请重说"
        ledger.fail(requestId, 'ERR_TRANSCRIPT_DISCARDED')
      } else if (error.stalled || error.sessionDead || error.connectionLost) {
        // 停摆已重放仍失败 / 重建后会话仍无响应：快速终态，禁止头部阻塞
        log({ evt: 'turn_stalled', request_id: requestId, err: String(error.message).slice(0, 300) })
        ledger.fail(requestId, 'ERR_REALTIME_STALLED')
      } else {
        log({ evt: 'turn_failed', request_id: requestId, err: String(error.message).slice(0, 300) })
        ledger.fail(requestId, 'ERR_PROCESSING_FAILED')
      }
    } finally {
      disarmWorkDeadline(requestId)
    }
  }

  // ---- handlers -----------------------------------------------------------

  function handleCreateTurn(rawBody, authInfo) {
    let body
    try { body = JSON.parse(rawBody.toString('utf8')) } catch { throw new ApiError(ERR.BAD_JSON) }
    if (body.protocol_version !== CONFIG.protocol_version) throw new ApiError(ERR.PROTOCOL_VERSION)
    const requestId = body.request_id
    if (!requestId || requestId !== authInfo.requestId) {
      throw new ApiError(ERR.MISSING_FIELD, 'request_id (body must match x-request-id)')
    }
    const meta = body.audio
    if (!meta || !meta.codec || !Number.isFinite(meta.duration_ms) || !meta.sha256 || typeof body.audio_base64 !== 'string') {
      throw new ApiError(ERR.MISSING_FIELD, 'audio{codec,duration_ms,sha256}, audio_base64')
    }

    const bodySha = sha256hex(rawBody)

    // Replay/conflict check must precede payload validation so a byte-identical
    // retry of an accepted turn replays even if limits later changed (§6).
    const existing = ledger.get(requestId)
    if (existing) {
      if (existing.body_sha256 !== bodySha) throw new ApiError(ERR.IDEMPOTENCY_CONFLICT)
      log({ evt: 'turn_replayed', request_id: requestId })
      return { status: 202, body: { ...ledger.projection(existing), idempotent_replay: true } }
    }

    // Validate the payload BEFORE the ledger entry exists — a rejected request
    // must leave no persistent state behind.
    if (meta.duration_ms > CONFIG.max_duration_ms) throw new ApiError(ERR.DURATION_TOO_LONG)
    let audioBuf
    try { audioBuf = Buffer.from(body.audio_base64, 'base64') } catch { throw new ApiError(ERR.AUDIO_INVALID) }
    if (audioBuf.length === 0) throw new ApiError(ERR.AUDIO_INVALID)
    if (audioBuf.length > CONFIG.max_audio_bytes) throw new ApiError(ERR.AUDIO_TOO_LARGE)
    if (sha256hex(audioBuf) !== meta.sha256) throw new ApiError(ERR.AUDIO_HASH_MISMATCH)

    const { turn } = ledger.create({
      requestId,
      deviceId: authInfo.deviceId,
      bodySha256: bodySha,
      sessionId: supervisor.sessionId,
    })
    log({ evt: 'turn_accepted', request_id: requestId, device_id: authInfo.deviceId, audio_bytes: audioBuf.length })
    // Snapshot the `accepted` receipt before processing starts mutating state;
    // the 202 returns immediately, execution continues asynchronously.
    const receipt = ledger.projection(turn)
    processTurn(requestId, audioBuf, meta).catch(err =>
      log({ evt: 'process_turn_crashed', request_id: requestId, err: String(err) }))
    return { status: 202, body: receipt }
  }

  function handleGetTurn(requestId, authInfo) {
    const turn = ledger.get(requestId)
    if (!turn || turn.device_id !== authInfo.deviceId) throw new ApiError(ERR.NOT_FOUND)
    return { status: 200, body: ledger.projection(turn) }
  }

  // GET /v1/voice/turns/:id/audio（ESS-38）：结果语音的有界取回。
  // 请求级鉴权（HMAC 覆盖 path）+ 设备归属校验；支持 Range 断点续传，
  // sha256 随响应头下发，iPhone 校验一致后才 transferFile 给 Watch。
  function handleGetTurnAudio(requestId, authInfo, req, res) {
    const turn = ledger.get(requestId)
    if (!turn || turn.device_id !== authInfo.deviceId) throw new ApiError(ERR.NOT_FOUND)
    const meta = turn.result?.audio
    const file = meta ? resultAudio.read(requestId) : null
    if (!meta || !file) throw new ApiError(ERR.NOT_FOUND, 'no result audio for this turn')
    if (sha256hex(file) !== meta.sha256) {
      // 落盘内容与账本元数据不一致：宁缺毋滥，绝不下发校验不过的音频
      log({ evt: 'result_audio_integrity_mismatch', request_id: requestId })
      throw new ApiError(ERR.NOT_FOUND, 'result audio integrity mismatch')
    }
    const headers = {
      'content-type': 'audio/mp4',
      'accept-ranges': 'bytes',
      'x-audio-sha256': meta.sha256,
      'cache-control': 'no-store',
    }
    const range = /^bytes=(\d+)-(\d*)$/.exec(req.headers.range || '')
    if (req.headers.range && !range) {
      res.writeHead(416, { ...headers, 'content-range': `bytes */${file.length}` })
      return res.end()
    }
    if (range) {
      const start = Number(range[1])
      const end = range[2] === '' ? file.length - 1 : Math.min(Number(range[2]), file.length - 1)
      if (start >= file.length || start > end) {
        res.writeHead(416, { ...headers, 'content-range': `bytes */${file.length}` })
        return res.end()
      }
      const slice = file.subarray(start, end + 1)
      res.writeHead(206, {
        ...headers,
        'content-range': `bytes ${start}-${end}/${file.length}`,
        'content-length': slice.length,
      })
      return res.end(slice)
    }
    res.writeHead(200, { ...headers, 'content-length': file.length })
    return res.end(file)
  }

  async function handleCancelTurn(requestId, authInfo) {
    const turn = ledger.get(requestId)
    if (!turn || turn.device_id !== authInfo.deviceId) throw new ApiError(ERR.NOT_FOUND)
    if (['completed', 'failed'].includes(turn.state)) throw new ApiError(ERR.TURN_NOT_CANCELLABLE)
    if (turn.state === 'cancelled') return { status: 200, body: ledger.projection(turn) }

    if (turn.task_id) {
      watcher.stop(requestId, 'client-cancel')
      const ok = await watcher.cancel(requestId).catch(() => false)
      if (!ok) ledger.update(requestId, { state: 'cancelled' })
    } else {
      if (supervisor.currentTurn?.label === requestId) supervisor.abortCurrentTurn('cancelled')
      ledger.update(requestId, { state: 'cancelled' })
    }
    log({ evt: 'turn_cancelled', request_id: requestId })
    return { status: 200, body: ledger.projection(ledger.get(requestId)) }
  }

  async function handlePermission(requestId, rawBody, authInfo) {
    const turn = ledger.get(requestId)
    if (!turn || turn.device_id !== authInfo.deviceId) throw new ApiError(ERR.NOT_FOUND)
    let body
    try { body = JSON.parse(rawBody.toString('utf8')) } catch { throw new ApiError(ERR.BAD_JSON) }

    const decision = { allow: 'always', always: 'always', deny: 'reject', reject: 'reject' }[body.decision]
    if (!decision) throw new ApiError(ERR.PERMISSION_DECISION_INVALID, 'decision must be allow|deny')
    if (!turn.permission?.id || turn.permission.id !== body.permission_id) {
      throw new ApiError(ERR.PERMISSION_UNKNOWN, 'permission_id does not match the pending permission')
    }

    const result = await gateway.respondPermission(body.permission_id, decision)
      .catch(error => { throw new ApiError(ERR.UPSTREAM_UNAVAILABLE, error.code) })
    if (!result.ok) throw new ApiError(ERR.PERMISSION_UNKNOWN, 'gateway no longer has this permission')

    ledger.update(requestId, { state: 'processing', detail: 'background_processing', permission: null })
    log({ evt: 'permission_forwarded', request_id: requestId, decision })
    return { status: 200, body: ledger.projection(ledger.get(requestId)) }
  }

  // ---- Watch 客户端日志上行（ESS-42） --------------------------------------
  //
  // POST /v1/client-logs：iPhone Relay 转发的 Watch JSONL 日志 chunk，逐行落
  // bridge.log（evt=watch_client_log），与服务端 trace 同构、按 request_id 可
  // grep——无需 Xcode/sudo 即可在 Mac 定位 Watch 侧交互问题。客户端字段一律
  // 白名单 + 截断后再入日志（外部输入是数据不是指令）；chunk_id 幂等去重，
  // 断网重传不重复刷屏。

  const seenLogChunks = new Set()
  const MAX_SEEN_LOG_CHUNKS = 512
  const MAX_LOG_LINES_PER_CHUNK = 5000

  function handleClientLogs(rawBody, authInfo) {
    let body
    try { body = JSON.parse(rawBody.toString('utf8')) } catch { throw new ApiError(ERR.BAD_JSON) }
    if (body.protocol_version !== CONFIG.protocol_version) throw new ApiError(ERR.PROTOCOL_VERSION)
    const chunkId = body.chunk_id
    if (!chunkId || chunkId !== authInfo.requestId) {
      throw new ApiError(ERR.MISSING_FIELD, 'chunk_id (body must match x-request-id)')
    }
    if (typeof body.jsonl !== 'string') throw new ApiError(ERR.MISSING_FIELD, 'jsonl')
    if (seenLogChunks.has(chunkId)) {
      return { status: 200, body: { chunk_id: chunkId, accepted: 0, idempotent_replay: true } }
    }

    const str = (value, max) => (typeof value === 'string' ? value.slice(0, max) : null)
    const lines = body.jsonl.split('\n').filter(line => line.trim().length > 0)
    for (const [index, line] of lines.slice(0, MAX_LOG_LINES_PER_CHUNK).entries()) {
      let entry = null
      let parsed = false
      try { entry = JSON.parse(line); parsed = true } catch { /* bad_line below */ }
      if (parsed && entry && typeof entry === 'object' && !Array.isArray(entry)) {
        log({
          evt: 'watch_client_log',
          device_id: authInfo.deviceId,
          chunk_id: chunkId,
          watch_ts: str(entry.ts, 40),
          request_id: str(entry.request_id, 80),
          module: str(entry.module, 64),
          event: str(entry.event, 64),
          detail: str(entry.detail, 500),
          error_code: str(entry.error?.code, 80),
          error_description: str(entry.error?.description, 300),
        })
      } else {
        // 坏行没通过任何字段白名单，原文是未校验的客户端输入——可能带 Token、
        // 用户语音文本或注入载荷。bridge.log 只记定位所需的元信息：行号、字节数、
        // 内容指纹（可与手表本地 JSONL 对账）、错因；原文一个字节都不落盘。
        log({
          evt: 'watch_client_log_bad_line',
          device_id: authInfo.deviceId,
          chunk_id: chunkId,
          line_index: index,
          bytes: Buffer.byteLength(line, 'utf8'),
          line_sha256: sha256hex(line),
          error_code: parsed ? 'ERR_LOG_LINE_NOT_OBJECT' : 'ERR_LOG_LINE_BAD_JSON',
        })
      }
    }
    if (lines.length > MAX_LOG_LINES_PER_CHUNK) {
      log({ evt: 'watch_client_log_truncated', chunk_id: chunkId, dropped: lines.length - MAX_LOG_LINES_PER_CHUNK })
    }
    seenLogChunks.add(chunkId)
    if (seenLogChunks.size > MAX_SEEN_LOG_CHUNKS) {
      seenLogChunks.delete(seenLogChunks.values().next().value)
    }
    return { status: 200, body: { chunk_id: chunkId, accepted: Math.min(lines.length, MAX_LOG_LINES_PER_CHUNK) } }
  }

  // ---- HTTP plumbing ------------------------------------------------------

  function readBody(req) {
    return new Promise((resolvePromise, reject) => {
      const chunks = []
      let size = 0
      req.on('data', c => {
        size += c.length
        if (size > CONFIG.max_body_bytes) {
          reject(new ApiError(ERR.BODY_TOO_LARGE))
          req.destroy()
          return
        }
        chunks.push(c)
      })
      req.on('end', () => resolvePromise(Buffer.concat(chunks)))
      req.on('error', reject)
    })
  }

  async function route(req, res) {
    const ip = normalizeIp(req.socket.remoteAddress || '')
    const pathName = new URL(req.url, 'https://x').pathname
    const reply = (status, body) => {
      res.writeHead(status, { 'content-type': 'application/json' })
      res.end(JSON.stringify(body))
    }
    try {
      if (!sourceAllowed(ip)) throw new ApiError(ERR.SOURCE_NOT_ALLOWED)

      if (req.method === 'GET' && pathName === '/v1/health') {
        return reply(200, { ok: true, service: 'remote-frontend-bridge', protocol_version: CONFIG.protocol_version })
      }
      const rawBody = ['POST', 'PUT'].includes(req.method) ? await readBody(req) : Buffer.alloc(0)
      const verify = () => auth.verify({ headers: req.headers, method: req.method, pathName, rawBody })

      if (pathName === '/v1/pair') {
        if (req.method !== 'POST') throw new ApiError(ERR.METHOD_NOT_ALLOWED)
        let body
        try { body = JSON.parse(rawBody.toString('utf8')) } catch { throw new ApiError(ERR.BAD_JSON) }
        const paired = auth.pair(body)
        return reply(201, { ...paired, protocol_version: CONFIG.protocol_version })
      }

      if (pathName === '/v1/voice/turns') {
        if (req.method !== 'POST') throw new ApiError(ERR.METHOD_NOT_ALLOWED)
        const r = handleCreateTurn(rawBody, verify())
        return reply(r.status, r.body)
      }

      if (pathName === '/v1/client-logs') {
        if (req.method !== 'POST') throw new ApiError(ERR.METHOD_NOT_ALLOWED)
        const r = handleClientLogs(rawBody, verify())
        return reply(r.status, r.body)
      }

      let m = pathName.match(/^\/v1\/voice\/turns\/([A-Za-z0-9_-]+)$/)
      if (m) {
        if (req.method !== 'GET') throw new ApiError(ERR.METHOD_NOT_ALLOWED)
        const r = handleGetTurn(m[1], verify())
        return reply(r.status, r.body)
      }

      m = pathName.match(/^\/v1\/voice\/turns\/([A-Za-z0-9_-]+)\/audio$/)
      if (m) {
        if (req.method !== 'GET') throw new ApiError(ERR.METHOD_NOT_ALLOWED)
        return handleGetTurnAudio(m[1], verify(), req, res)
      }

      m = pathName.match(/^\/v1\/voice\/turns\/([A-Za-z0-9_-]+)\/cancel$/)
      if (m) {
        if (req.method !== 'POST') throw new ApiError(ERR.METHOD_NOT_ALLOWED)
        const r = await handleCancelTurn(m[1], verify())
        return reply(r.status, r.body)
      }

      m = pathName.match(/^\/v1\/voice\/turns\/([A-Za-z0-9_-]+)\/permission$/)
      if (m) {
        if (req.method !== 'POST') throw new ApiError(ERR.METHOD_NOT_ALLOWED)
        const r = await handlePermission(m[1], rawBody, verify())
        return reply(r.status, r.body)
      }

      m = pathName.match(/^\/v1\/voice\/turns\/([A-Za-z0-9_-]+)\/ack$/)
      if (m) {
        if (req.method !== 'POST') throw new ApiError(ERR.METHOD_NOT_ALLOWED)
        const authInfo = verify()
        if (authInfo.requestId !== m[1]) throw new ApiError(ERR.MISSING_FIELD, 'x-request-id must match turn id')
        let body
        try { body = JSON.parse(rawBody.toString('utf8')) } catch { throw new ApiError(ERR.BAD_JSON) }
        if (body.protocol_version !== CONFIG.protocol_version) throw new ApiError(ERR.PROTOCOL_VERSION)
        const turn = ledger.get(m[1])
        if (!turn) throw new ApiError(ERR.NOT_FOUND)
        if (turn.device_id !== authInfo.deviceId) throw new ApiError(ERR.NOT_FOUND)
        const duplicate = Boolean(turn.delivered_ack)
        const acked = ledger.acknowledgeResult(m[1], { source: 'watch' })
        if (!acked) throw new ApiError(ERR.MISSING_FIELD, 'terminal result required')
        log({ evt: 'result_acked', request_id: m[1], device_id: authInfo.deviceId, duplicate })
        return reply(200, { request_id: m[1], acknowledged: true, acknowledged_at: acked.delivered_ack.at })
      }

      throw new ApiError(ERR.NOT_FOUND)
    } catch (e) {
      if (e instanceof ApiError) {
        log({ evt: 'request_rejected', ip, path: pathName, code: e.code })
        if (!res.headersSent) reply(e.status, { error: e.code, detail: e.detail })
        return
      }
      log({ evt: 'internal_error', ip, path: pathName, err: String(e).slice(0, 300) })
      if (!res.headersSent) reply(500, { error: 'ERR_INTERNAL' })
    }
  }

  // ---- WSS /v1/voice/events ----------------------------------------------

  const wss = new WebSocketServer({ noServer: true })
  const eventClients = new Set() // { ws, deviceId }
  const eventsHeartbeatMs = CONFIG.events_heartbeat_ms ?? 20_000

  ledger.on('turn', projection => {
    const message = JSON.stringify({ type: 'turn.state', turn: projection })
    for (const client of eventClients) {
      if (client.deviceId === projection.device_id && client.ws.readyState === client.ws.OPEN) {
        client.ws.send(message)
      }
    }
  })

  function handleUpgrade(req, socket, head) {
    const ip = normalizeIp(socket.remoteAddress || '')
    const pathName = new URL(req.url, 'https://x').pathname
    const refuse = (status, code) => {
      socket.write(`HTTP/1.1 ${status} ${code}\r\nContent-Type: application/json\r\n\r\n${JSON.stringify({ error: code })}`)
      socket.destroy()
    }
    try {
      if (!sourceAllowed(ip)) return refuse(403, 'ERR_SOURCE_NOT_ALLOWED')
      if (pathName !== '/v1/voice/events') return refuse(404, 'ERR_NOT_FOUND')
      const { deviceId } = auth.verify({ headers: req.headers, method: 'GET', pathName, rawBody: Buffer.alloc(0) })
      wss.handleUpgrade(req, socket, head, ws => {
        const client = { ws, deviceId, alive: true }
        eventClients.add(client)
        log({ evt: 'events_client_connected', device_id: deviceId })
        ws.on('pong', () => { client.alive = true })
        // Reconnect recovery: replay live turns plus recent terminal results until
        // the Watch explicitly confirms durable storage.
        const replayTurns = ledger.replayable({
          terminalTtlMs: CONFIG.result_delivery_ttl_ms ?? 30 * 60 * 1000,
          maxDeliveryAttempts: CONFIG.result_delivery_max_attempts ?? 5,
        }).filter(t => t.device_id === deviceId)
        for (const turn of replayTurns) {
          if (['completed', 'failed', 'cancelled'].includes(turn.state)) {
            const delivery = ledger.markResultRedelivered(turn.request_id, {
              baseDelayMs: CONFIG.result_delivery_backoff_base_ms ?? 2_000,
              maxDelayMs: CONFIG.result_delivery_backoff_max_ms ?? 300_000,
            })
            log({
              evt: 'result_redelivered', request_id: turn.request_id, device_id: deviceId,
              status: turn.state, attempt: delivery?.attempt, retry_after_ms: delivery?.delay_ms,
            })
          }
        }
        ws.send(JSON.stringify({
          type: 'snapshot',
          turns: replayTurns.map(t => ledger.projection(t)),
        }))
        // interim 不改变账本状态，但非终态回合重连时仍须重放；客户端用
        // request_id + delivery_sequence 去重，已持久入 Watch 队列的不会重复播。
        for (const [requestId, interim] of interimPayloads) {
          const turn = ledger.get(requestId)
          if (turn?.device_id === deviceId && !['completed', 'failed', 'cancelled'].includes(turn.state)) {
            ws.send(JSON.stringify({ type: 'turn.interim', interim }))
          }
        }
        ws.on('close', () => eventClients.delete(client))
        ws.on('error', () => eventClients.delete(client))
      })
    } catch (e) {
      const code = e instanceof ApiError ? e.code : 'ERR_INTERNAL'
      log({ evt: 'events_upgrade_rejected', ip, code })
      refuse(e instanceof ApiError ? e.status : 500, code)
    }
  }


  const eventsHeartbeat = setInterval(() => {
    for (const client of eventClients) {
      if (!client.alive) {
        log({ evt: 'events_client_heartbeat_timeout', device_id: client.deviceId })
        client.ws.terminate()
        eventClients.delete(client)
        continue
      }
      client.alive = false
      client.ws.ping()
    }
  }, eventsHeartbeatMs)
  eventsHeartbeat.unref?.()

  // ---- restart recovery (§4.1) -------------------------------------------

  function recover() {
    for (const turn of ledger.nonTerminal()) {
      if (turn.task_id) {
        // Provably safe: tasks are queryable and cancel/query are idempotent.
        log({ evt: 'recover_watch', request_id: turn.request_id, task_id: turn.task_id })
        watcher.watch(turn.request_id)
      } else {
        // Injection outcome unknown → never auto-rerun a non-idempotent turn.
        log({ evt: 'recover_unknown_outcome', request_id: turn.request_id })
        ledger.fail(turn.request_id, 'ERR_RESULT_UNKNOWN', 'manual_confirmation_required')
      }
    }
  }

  // ---- startup ------------------------------------------------------------

  function tailscaleIPv4() {
    if (CONFIG.bind_tailscale_ip === 'none') return null
    if (CONFIG.bind_tailscale_ip !== 'auto') return CONFIG.bind_tailscale_ip
    try {
      return execFileSync('tailscale', ['ip', '-4'], { encoding: 'utf8' }).trim().split('\n')[0]
    } catch {
      log({ evt: 'tailscale_ip_unavailable', note: 'binding loopback only' })
      return null
    }
  }

  const servers = []
  function start() {
    recover()
    resultAudio.startSweeper()
    const tlsOpts = {
      cert: readFileSync(resolve(BASE, CONFIG.tls_cert)),
      key: readFileSync(resolve(BASE, CONFIG.tls_key)),
    }
    const tsIp = tailscaleIPv4()
    const binds = [CONFIG.bind_loopback, ...(tsIp ? [tsIp] : [])] // never 0.0.0.0
    return Promise.all(binds.map(addr => new Promise((resolvePromise, reject) => {
      const server = https.createServer(tlsOpts, route)
      server.on('upgrade', handleUpgrade)
      server.listen(CONFIG.port, addr, () => {
        log({ evt: 'listening', addr, port: CONFIG.port })
        resolvePromise(server)
      })
      server.on('error', reject)
      servers.push(server)
    })))
  }

  function stop() {
    watcher.stopDenySweeper()
    watcher.stopAll()
    supervisor.close('shutdown')
    resultAudio.stopSweeper()
    clearInterval(pendingAudioSweeper)
    clearInterval(eventsHeartbeat)
    for (const client of eventClients) client.ws.close()
    for (const timer of workTimers.values()) clearTimeout(timer)
    return Promise.all(servers.map(s => new Promise(r => s.close(r))))
  }

  return { start, stop, config: CONFIG, ledger, supervisor, watcher, gateway, auth, resultAudio, log }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const bridge = createBridge()
  bridge.start().catch(error => {
    bridge.log({ evt: 'startup_failed', err: String(error) })
    process.exit(1)
  })
  const shutdown = () => bridge.stop().then(() => process.exit(0))
  process.on('SIGINT', shutdown)
  process.on('SIGTERM', shutdown)
}
