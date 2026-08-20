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
// Southbound: full-file fallback uses the loopback AudioRealtimeGateway HMAC
// job API. Only Gateway owns the qwen voice WebSocket in production.
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
import { prepareDownlinkMessage } from './audio-policy.mjs'
import { VoiceStreamDownlink, VoiceStreamingNegotiator } from './voice-stream-downlink.mjs'
import { VoiceStreamUplink } from './voice-stream-uplink.mjs'
import { PendingAnnouncementStreams } from './pending-announcement-streams.mjs'
import { RealtimeMediaSession } from './realtime-media-session.mjs'
import { FallbackJobClient } from './fallback-job-client.mjs'
import { FallbackJobOutbox } from './fallback-job-outbox.mjs'

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

function optionalBoundedString(value, field, maxLength) {
  if (value === undefined || value === null) return null
  if (typeof value !== 'string' || value.length > maxLength) {
    throw new ApiError(ERR.MISSING_FIELD, `${field} must be a string up to ${maxLength} characters`)
  }
  return value
}

export function createBridge(overrides = {}) {
  const CONFIG = { ...JSON.parse(readFileSync(join(BASE, 'config.json'), 'utf8')), ...overrides }
  const log = obj => process.stdout.write(JSON.stringify({ ts: new Date().toISOString(), ...obj }) + '\n')
  const stateDir = resolve(BASE, CONFIG.state_dir)

  const auth = new DeviceAuth({
    stateDir,
    timestampSkewMs: CONFIG.timestamp_skew_ms,
    pairingCodeTtlMs: CONFIG.pairing_code_ttl_ms,
    // ESS-175: 允许 config 声明可 pair 的固定 device_id 列表（如 jackson-watch）。
    allowedPairingDeviceIds: CONFIG.allowed_pairing_device_ids ?? [],
    log,
  })
  const ledger = new TurnLedger({
    stateDir,
    maxResultChars: CONFIG.max_result_chars,
    maxResultAudioBytes: CONFIG.max_result_audio_bytes,
    maxTurns: CONFIG.turn_ledger_max_turns ?? 5000,
    terminalRetentionMs: CONFIG.turn_ledger_terminal_retention_ms ?? 7 * 24 * 60 * 60 * 1000,
    log,
  })
  const fallbackOutbox = new FallbackJobOutbox({ stateDir })
  const gateway = new GatewayClient({
    baseUrl: CONFIG.gateway_url,
    sseMaxEventBytes: CONFIG.sse_max_event_bytes ?? 256 * 1024,
    sseMaxBufferBytes: CONFIG.sse_max_buffer_bytes ?? 1024 * 1024,
    log,
  })
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
  // Deterministic Bridge tests explicitly enable allow_test_pcm and retain
  // their scripted supervisor as a test double. Production never selects this
  // branch: its only full-file path is the authenticated Gateway job client.
  const fallbackJobs = overrides.fallbackJobClient ?? (CONFIG.allow_test_pcm === true ? {
    submitAndWait: async ({ requestId, audio: pcm16k, context = {} }) => {
      const result = await supervisor.injectTurn(pcm16k, {
        label: requestId, shouldRun: () => true,
        parentRequestId: context.parentRequestId ?? null,
        contextSummary: context.contextSummary ?? null,
      })
      return {
        audio24k_base64: result.audio24k?.toString('base64') ?? null,
        assistant_transcript: result.assistantTranscript ?? null,
        user_transcript: result.userTranscript ?? null,
        task_id: result.taskId ?? null,
      }
    },
  } : new FallbackJobClient({
    baseUrl: CONFIG.audio_realtime_gateway_url ?? 'http://127.0.0.1:8444',
    secret: process.env[CONFIG.fallback_hmac_secret_env ?? 'FALLBACK_JOB_HMAC_SECRET'] ?? '',
    pollMs: CONFIG.fallback_job_poll_ms ?? 100,
    timeoutMs: CONFIG.fallback_job_wait_ms ?? 35_000,
    log,
  }))
  // D1 主路径（ESS-34）：本会话 Realtime WS 上的权限请求即会话级归属证明
  // （网关只下发 sessionId 匹配的任务权限事件），写开关关闭时定向 reject。
  supervisor.onPermissionRequested = task => watcher.denyRealtimePermission(task)
  let streamDownlink = null
  const streamNegotiator = new VoiceStreamingNegotiator({
    serverEnabled: CONFIG.voice_streaming_v2 === true,
    log,
  })
  const streamUplink = new VoiceStreamUplink({
    enabled: CONFIG.voice_streaming_v2 === true,
    maxPayloadBytes: CONFIG.voice_stream_max_payload_bytes ?? 64 * 1024,
    maxBufferedBytes: CONFIG.voice_stream_max_buffered_bytes ?? 256 * 1024,
    maxSequenceWindow: CONFIG.voice_stream_max_sequence_window ?? 32,
    onChunk: ({ requestId, payload, chunk }) => log({
      evt: 'voice_uplink_chunk_received', request_id: requestId,
      stream_id: chunk.stream_id, sequence: chunk.sequence, bytes: payload.length,
    }),
    log,
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
    // Realtime media may omit task.accepted and first expose the delegated task
    // in a later lifecycle event. Bind that task to the active request before an
    // announcement can race in; the ledger mapping remains valid after terminal.
    if (event.startsWith('task.') && rest.task?.id && supervisor.mediaSession?.label) {
      const requestId = supervisor.mediaSession.label
      const turn = ledger.get(requestId)
      if (turn && !turn.task_id && !['failed', 'cancelled'].includes(turn.state)) {
        ledger.update(requestId, {
          task_id: String(rest.task.id), path: 'background',
          state: turn.state === 'completed' ? 'completed' : 'processing',
          detail: 'background_accepted',
        })
        log({ evt: 'realtime_media_task_bound', request_id: requestId, task_id: String(rest.task.id), cause: event })
      }
    }
    // ESS-234：Gateway 侧偶发不发 announcement，导致 background turn 卡在
    // "有 interim 没 result_audio_attached" 的非终态。task.completed 到达时启
    // 5s 兜底计时；到期仍无 announcement 就从 realtime salvage 合成 final result。
    if (event === 'task.completed' && rest.task?.id) {
      const turn = ledger.byTaskId(String(rest.task.id))
      if (turn?.request_id) armRealtimeFallbackTimer(turn.request_id, 'task.completed')
    }
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
    if (interim.audio) interim.audio.kind = 'interim'
    interimPayloads.set(requestId, interim)
    if (interim.audio) ledger.markFirstAudioReady(requestId, { source: 'interim' })
    const event = {
      type: 'turn.interim',
      interim,
    }
    for (const client of eventClients) {
      const turn = ledger.get(requestId)
      if (turn && client.deviceId === turn.device_id && client.ws.readyState === client.ws.OPEN) {
        client.ws.send(JSON.stringify(prepareDownlinkMessage(event, log)))
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
  // ESS-234：background turn 从 supervisor 侧 injectTurn 返回时聚合的 24kHz PCM
  // （turn.result.audio24k）在此暂存，等 task.completed 后 5s 无 announcement 触发
  // 兜底合成 final result（Gateway 侧偶发不发 announcement 的必现路径）。
  const realtimeAudioSalvage = new Map() // request_id → { pcm24k: Buffer, taskId, at }
  // ESS-234：已启动 task.completed 5s 兜底计时的 request_id，防止重复触发。
  const realtimeFallbackTimers = new Map() // request_id → Timeout
  // ESS-542：上游 Qwen 偶发不携带 taskId 的 announcement。暂存于 orphan 池，
  // 等待 ledger 新 turn 投影到达时尝试通过 turnId / task_id 重新绑定。
  const orphanAnnouncements = new Map() // response_id → { announcement, at }
  let orphanAnnouncementBytes = 0
  const ORPHAN_ANNOUNCEMENT_TTL_MS = 30_000           // orphan 最长等待窗口
  const MAX_ORPHAN_ANNOUNCEMENTS = 16                  // 远小于正常 pending 池
  const MAX_ORPHAN_ANNOUNCEMENT_BYTES = 2 * 1024 * 1024 // 2 MB PCM
  // ESS-542：announcement_unmatched 计数，供运维观测频率与趋势。
  let announcementUnmatchedCount = 0
  const REALTIME_FALLBACK_WAIT_MS = CONFIG.realtime_fallback_wait_ms ?? 5_000
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

  // ESS-234：从 realtime salvage 里的 24kHz PCM 合成 final result 兜底。
  // 只在 task.completed 后 5s 仍无 result_audio_attached 时被调用；如 Gateway
  // announcement 迟到，attachPendingResultAudio 的 turn.state 幂等分支 + 先删
  // 再 setResult 的顺序保证不会二次覆盖已合成的音频。
  async function synthesizeRealtimeFallback(requestId, reason) {
    const salvage = realtimeAudioSalvage.get(requestId)
    if (!salvage) return false
    // 已被 announcement 走通了：无需兜底，清理即可。
    const turn = ledger.get(requestId)
    if (turn?.result?.audio) {
      realtimeAudioSalvage.delete(requestId)
      return false
    }
    // 空 PCM 无从合成：仅诊断留痕，让 turn 保持"无音频完成"状态。
    if (!salvage.pcm24k?.length) {
      log({ evt: 'realtime_fallback_skipped', request_id: requestId, reason: 'empty_pcm24k' })
      realtimeAudioSalvage.delete(requestId)
      return false
    }
    try {
      const m4a = await audio.encode24kToM4a(salvage.pcm24k)
      const meta = {
        kind: 'result',
        sha256: sha256hex(m4a),
        codec: 'm4a',
        duration_ms: Math.round(salvage.pcm24k.length / 48), // 24kHz mono PCM16
        size_bytes: m4a.length,
      }
      resultAudio.put(requestId, m4a)
      pendingResultAudio.set(requestId, {
        meta,
        base64: m4a.length <= CONFIG.max_result_audio_bytes ? m4a.toString('base64') : null,
        speechText: null,
        at: Date.now(),
      })
      log({
        evt: 'result_synthesized_from_realtime', request_id: requestId,
        task_id: salvage.taskId, pcm_bytes: salvage.pcm24k.length, m4a_bytes: m4a.length,
        cause: reason,
      })
      log({
        evt: 'l1_audio_ready', request_id: requestId, task_id: salvage.taskId,
        source: 'realtime_fallback', response_id: null, codec: 'm4a',
        duration_ms: meta.duration_ms, size_bytes: meta.size_bytes, sha256: meta.sha256,
      })
      ledger.markFirstAudioReady(requestId, { source: 'realtime_fallback' })
      attachPendingResultAudio(requestId)
      realtimeAudioSalvage.delete(requestId)
      return true
    } catch (error) {
      log({
        evt: 'realtime_fallback_encode_failed', request_id: requestId,
        err: String(error.message), cause: reason,
      })
      realtimeAudioSalvage.delete(requestId)
      return false
    }
  }

  // ESS-234：任一路径观察到 task.completed 后调用；5s 窗口内 announcement 未到
  // 就触发合成。幂等：同一 requestId 已有定时器则跳过；已合成 / 已被 announcement
  // 走通的 requestId 由 synthesizeRealtimeFallback 内部 early-return 保护。
  function armRealtimeFallbackTimer(requestId, cause) {
    if (realtimeFallbackTimers.has(requestId)) return
    if (!realtimeAudioSalvage.has(requestId)) return
    const timer = setTimeout(() => {
      realtimeFallbackTimers.delete(requestId)
      Promise.resolve(synthesizeRealtimeFallback(requestId, cause)).catch(error => {
        log({ evt: 'realtime_fallback_error', request_id: requestId, err: String(error.message) })
      })
    }, REALTIME_FALLBACK_WAIT_MS)
    timer.unref?.()
    realtimeFallbackTimers.set(requestId, timer)
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
        kind: 'result',
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
      ledger.markFirstAudioReady(requestId, { source: 'background' })
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

  function queueOrphanAnnouncement(announcement) {
    const { responseId, pcm24k, turnId } = announcement
    announcementUnmatchedCount += 1
    // Capacity guard
    while (orphanAnnouncements.size >= MAX_ORPHAN_ANNOUNCEMENTS
      || orphanAnnouncementBytes + pcm24k.length > MAX_ORPHAN_ANNOUNCEMENT_BYTES) {
      const oldestKey = orphanAnnouncements.keys().next().value
      if (oldestKey === undefined) break
      const dropped = orphanAnnouncements.get(oldestKey)
      orphanAnnouncements.delete(oldestKey)
      orphanAnnouncementBytes -= dropped.announcement.pcm24k.length
      log({ evt: 'announcement_orphan_evicted', response_id: oldestKey, reason: 'capacity' })
    }
    if (pcm24k.length > MAX_ORPHAN_ANNOUNCEMENT_BYTES) {
      log({ evt: 'announcement_orphan_too_large', response_id: responseId, pcm_bytes: pcm24k.length })
      return
    }
    orphanAnnouncements.set(responseId, { announcement, at: Date.now() })
    orphanAnnouncementBytes += pcm24k.length
    log({
      evt: 'announcement_orphan_pending', response_id: responseId,
      turn_id: turnId ?? null,
      pcm_bytes: pcm24k.length,
      orphan_total: orphanAnnouncements.size,
      orphan_bytes: orphanAnnouncementBytes,
      unmatched_total: announcementUnmatchedCount,
      ttl_ms: ORPHAN_ANNOUNCEMENT_TTL_MS,
    })
    log({ evt: 'l1_audio_failed', request_id: null, task_id: null, response_id: responseId, source: 'background', stage: 'ownership', reason: 'missing_task_id_orphan_pending' })
  }

  // ESS-542：当 ledger 新增 turn 时，尝试将 orphan 池中的无 taskId 公告
  // 绑定到新 turn。匹配策略：优先 task_id 直接命中（标准路径已在
  // attachPendingAnnouncement 中覆盖），次选 responseId 前缀或 turnId 命中。
  function attachOrphanAnnouncements(projection) {
    if (orphanAnnouncements.size === 0) return
    if (projection.task_id) {
      for (const [responseId, entry] of orphanAnnouncements) {
        const { announcement } = entry
        // ESS-542: try turn_id match from injected realtime turn
        if (announcement.turnId && projection.turn_id && String(announcement.turnId) === String(projection.turn_id)) {
          const turn = ledger.get(projection.request_id)
          if (turn) {
            orphanAnnouncements.delete(responseId)
            orphanAnnouncementBytes -= announcement.pcm24k.length
            log({
              evt: 'announcement_orphan_rebound',
              request_id: turn.request_id,
              response_id: announcement.responseId,
              matched_by: 'turn_id',
              turn_id: announcement.turnId,
              unmatched_total: announcementUnmatchedCount,
            })
            void bindAnnouncement(announcement, turn)
            return // one binding per projection tick; others stay for next turn
          }
        }
      }
    }
  }

  function queueAnnouncement(announcement) {
    const { taskId, responseId, pcm24k } = announcement
    if (!taskId) {
      log({ evt: 'announcement_unmatched', task_id: null, response_id: responseId, pcm_bytes: pcm24k.length, reason: 'missing_task_id' })
      queueOrphanAnnouncement(announcement)
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
    // ESS-542: taskId is the primary key, but Qwen sometimes omits it.
    // Try turnId as a fallback correlation before queueing.
    let turn = announcement.taskId ? ledger.byTaskId(announcement.taskId) : null
    if (!turn && announcement.turnId) {
      // turnId from Qwen may appear in injected realtime turns as turn_id
      for (const t of ledger.turns.values()) {
        if (t.turn_id && String(t.turn_id) === String(announcement.turnId)) {
          turn = t
          log({ evt: 'announcement_matched_by_turn_id', response_id: announcement.responseId, turn_id: announcement.turnId, request_id: t.request_id })
          break
        }
      }
    }
    if (!turn) return queueAnnouncement(announcement)
    await bindAnnouncement(announcement, turn)
  }

  // task 终态先于 announcement 落账时，completed 投影触发补挂
  ledger.on('turn', projection => {
    attachPendingAnnouncement(projection)
    attachOrphanAnnouncements(projection)
    if (['completed', 'failed', 'cancelled'].includes(projection.status)) {
      clearInterim(projection.request_id)
    }
    if (projection.status === 'completed' && pendingResultAudio.has(projection.request_id)) {
      attachPendingResultAudio(projection.request_id)
    }
  })

  const pendingAudioSweeper = setInterval(() => {
    const cutoff = Date.now() - PENDING_AUDIO_TTL_MS
    const orphanCutoff = Date.now() - ORPHAN_ANNOUNCEMENT_TTL_MS
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
    // ESS-542：过期的 orphan announcement 清理
    for (const [responseId, entry] of orphanAnnouncements) {
      if (entry.at < orphanCutoff) {
        orphanAnnouncements.delete(responseId)
        orphanAnnouncementBytes -= entry.announcement.pcm24k.length
        log({
          evt: 'announcement_orphan_expired', response_id: responseId,
          pcm_bytes: entry.announcement.pcm24k.length,
          unmatched_total: announcementUnmatchedCount,
        })
      }
    }
    // ESS-234：过期未被 task.completed 触发的 salvage 条目清理（一般不会发生——
    // 5s 窗口远短于 10min TTL；此为异常防御）。
    for (const [requestId, entry] of realtimeAudioSalvage) {
      if (entry.at < cutoff) {
        realtimeAudioSalvage.delete(requestId)
        log({ evt: 'realtime_salvage_expired', request_id: requestId, task_id: entry.taskId })
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

  async function processTurn(requestId, audioBuf, audioMeta, context = {}) {
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
      ledger.update(requestId, { state: 'processing', detail: 'fallback_job_queued' })
      if (CONFIG.fallback_jobs_enabled !== true && CONFIG.allow_test_pcm !== true) {
        throw Object.assign(new Error('fallback jobs disabled'), { code: 'gateway_unavailable' })
      }
      log({ evt: 'fallback_job_submitting', request_id: requestId, audio_sha256: sha256hex(pcm16k) })
      const fallbackResult = await fallbackJobs.submitAndWait({
        requestId, audio: pcm16k, audioSha256: sha256hex(pcm16k), context,
      })
      const result = {
        taskId: fallbackResult?.task_id ?? null,
        assistantTranscript: fallbackResult?.assistant_transcript ?? null,
        userTranscript: fallbackResult?.user_transcript ?? null,
        audio24k: fallbackResult?.audio24k_base64 ? Buffer.from(fallbackResult.audio24k_base64, 'base64') : null,
        responseIds: [`${requestId}:fallback`],
      }
      log({ evt: 'fallback_job_completed', request_id: requestId })

      if (ledger.get(requestId)?.state === 'cancelled') {
        // Result arrived after a cancel during injection — do not overwrite.
        return
      }

      if (result.taskId) {
        // Realtime 在委派前生成的口头确认已经随当前 turn 聚合在 result 中。
        // 先下发 interim，再推进 background_accepted，保证 Watch 先看到/听到回执。
        // Realtime 的自由生成内容不属于产品定义的 interim。尤其在 session rebuild
        // 后，模型可能先输出自我介绍；旧实现会把这段任意音频包装成 interim 播放。
        // 受理回执只允许固定文案 + 预生成资产，保证内容与用户请求有确定因果。
        const interimText = '收到，正在处理，请稍后'
        let interimAudio = null
        // Realtime 自由生成的音频不是产品下行资产，直接忽略；只有下面固定文案
        // 的预生成音频进入出口门禁，避免把“未发送内容”误记为下行拒绝。
        if (!interimAudio && fallbackInterimAudio) {
          interimAudio = {
            kind: 'interim',
            base64: fallbackInterimAudio.toString('base64'),
            sha256: sha256hex(fallbackInterimAudio),
            codec: 'm4a',
            duration_ms: null,
            size_bytes: fallbackInterimAudio.length,
          }
          log({ evt: 'l1_audio_ready', request_id: requestId, task_id: result.taskId, source: 'interim', response_id: null, codec: 'm4a', duration_ms: null, size_bytes: interimAudio.size_bytes, sha256: interimAudio.sha256, fallback: true })
        }
        emitInterim(requestId, { text: interimText, audio: interimAudio })
        // ESS-234：把 realtime 阶段聚合的 24kHz PCM 存到 salvage map——若 Gateway
        // 侧 task.completed 后 5s 内没发 announcement（必现 bug），server 侧就用这
        // 段音频合成 final result 兜底，避免 Watch 卡在"分身处理中"永久挂起。
        if (result.audio24k?.length) {
          realtimeAudioSalvage.set(requestId, {
            pcm24k: result.audio24k, taskId: result.taskId, at: Date.now(),
          })
        }
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
            kind: 'result',
            sha256: sha256hex(m4a),
            codec: 'm4a',
            duration_ms: Math.round(result.audio24k.length / 48),
            size_bytes: m4a.length,
          }
          resultAudio.put(requestId, m4a)
          audioBase64 = m4a.toString('base64')
          log({ evt: 'l1_audio_ready', request_id: requestId, task_id: null, source: 'direct', response_id: result.responseIds?.[0] ?? null, codec: 'm4a', duration_ms: resultAudioMeta.duration_ms, size_bytes: resultAudioMeta.size_bytes, sha256: resultAudioMeta.sha256 })
          ledger.markFirstAudioReady(requestId, { source: 'direct' })
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
      fallbackOutbox.settle(requestId, 'completed')
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
      } else if (error.code === 'gateway_unavailable' || error.code === 'ERR_NOT_FOUND') {
        log({ evt: 'fallback_job_failed', request_id: requestId, reason: 'gateway_unavailable' })
        ledger.fail(requestId, 'ERR_UPSTREAM_UNAVAILABLE')
      } else if (error.code === 'queue_timeout') {
        log({ evt: 'fallback_job_failed', request_id: requestId, reason: 'queue_timeout' })
        ledger.fail(requestId, 'ERR_WORK_TIMEOUT')
      } else if (error.code) {
        log({ evt: 'fallback_job_failed', request_id: requestId, reason: String(error.code).slice(0, 80) })
        ledger.fail(requestId, 'ERR_PROCESSING_FAILED')
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
      const finalState = ledger.get(requestId)?.state
      if (['completed', 'failed', 'cancelled'].includes(finalState)) fallbackOutbox.settle(requestId, finalState)
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
    const parentRequestId = optionalBoundedString(body.parent_request_id, 'parent_request_id', 128)
    const contextSummary = optionalBoundedString(body.context_summary, 'context_summary', 8_000)

    const bodySha = sha256hex(rawBody)

    // Replay/conflict check must precede payload validation so a byte-identical
    // retry of an accepted turn replays even if limits later changed (§6).
    const existing = ledger.get(requestId)
    if (existing) {
      if (existing.body_sha256 !== bodySha) throw new ApiError(ERR.IDEMPOTENCY_CONFLICT)
      log({ evt: 'turn_replayed', request_id: requestId })
      return {
        status: 202,
        body: {
          ...ledger.projection(existing),
          streaming: streamNegotiator.decision(requestId),
          idempotent_replay: true,
        },
      }
    }

    // Validate the payload BEFORE the ledger entry exists — a rejected request
    // must leave no persistent state behind.
    if (meta.duration_ms > CONFIG.max_duration_ms) throw new ApiError(ERR.DURATION_TOO_LONG)
    let audioBuf
    try { audioBuf = Buffer.from(body.audio_base64, 'base64') } catch { throw new ApiError(ERR.AUDIO_INVALID) }
    if (audioBuf.length === 0) throw new ApiError(ERR.AUDIO_INVALID)
    if (audioBuf.length > CONFIG.max_audio_bytes) throw new ApiError(ERR.AUDIO_TOO_LARGE)
    if (sha256hex(audioBuf) !== meta.sha256) throw new ApiError(ERR.AUDIO_HASH_MISMATCH)

    const persisted = fallbackOutbox.accept({
      requestId, audio: audioBuf, meta, context: { parentRequestId, contextSummary },
    })
    if (persisted.status === 'conflict') throw new ApiError(ERR.IDEMPOTENCY_CONFLICT)
    const { turn } = ledger.create({
      requestId,
      deviceId: authInfo.deviceId,
      bodySha256: bodySha,
      sessionId: supervisor.sessionId,
      watchCreatedAt: body.created_at,
    })
    const streaming = streamNegotiator.negotiate({
      requestId,
      sessionId: typeof body.session_id === 'string' ? body.session_id : supervisor.sessionId,
      streaming: body.streaming,
    })
    log({ evt: 'turn_accepted', request_id: requestId, device_id: authInfo.deviceId, audio_bytes: audioBuf.length })
    // Snapshot the `accepted` receipt before processing starts mutating state;
    // the 202 returns immediately, execution continues asynchronously.
    const receipt = { ...ledger.projection(turn), streaming }
    processTurn(requestId, audioBuf, meta, { parentRequestId, contextSummary }).catch(err =>
      log({ evt: 'process_turn_crashed', request_id: requestId, err: String(err) }))
    return { status: 202, body: receipt }
  }

  function handleGetTurn(requestId, authInfo) {
    const turn = ledger.get(requestId)
    if (!turn || turn.device_id !== authInfo.deviceId) throw new ApiError(ERR.NOT_FOUND)
    return { status: 200, body: ledger.projection(turn) }
  }

  function handleDeliverTurn(requestId, authInfo) {
    const turn = ledger.get(requestId)
    if (!turn || turn.device_id !== authInfo.deviceId) throw new ApiError(ERR.NOT_FOUND)
    const due = ledger.isTerminalDeliveryDue(turn, {
      terminalTtlMs: CONFIG.result_delivery_ttl_ms ?? 30 * 60 * 1000,
      maxDeliveryAttempts: CONFIG.result_delivery_max_attempts ?? 5,
    })
    if (!due) return { status: 204, body: null }

    // Build the same envelope as the WSS `turn.state` event before advancing
    // the shared delivery ledger. The projection includes the bounded inline
    // audio payload when one is present, so HTTP remains a complete fallback.
    const body = { type: 'turn.state', turn: ledger.projection(turn) }
    const delivery = ledger.markResultRedelivered(requestId, {
      baseDelayMs: CONFIG.result_delivery_backoff_base_ms ?? 2_000,
      maxDelayMs: CONFIG.result_delivery_backoff_max_ms ?? 300_000,
    })
    log({
      evt: 'result_redelivered', request_id: requestId, device_id: authInfo.deviceId,
      status: turn.state, attempt: delivery?.attempt, retry_after_ms: delivery?.delay_ms,
      cause: 'http_poll',
    })
    return { status: 200, body }
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

  // ---- ESS-184/207 下行链路探针注入 + 回执 -------------------------------
  //
  // /v1/probe/inject（loopback-only，不校 HMAC）：把一段预生成的短音频以
  //   kind=probe 直接落到账本 completed，走真实 WSS 出口 → iPhone Relay →
  //   Watch。语义上等价于用户说了一句话且立刻得到语音回执，但不经过
  //   qwen-audio-realtime，也不会往用户对话历史里塞真 turn。
  //
  // /v1/probe/ack（需 HMAC，iPhone Relay 转发 Watch 的 probe_playback_ack）：
  //   只落日志 evt=probe_acked，供 downlink-probe.mjs 判定 H5；顺手把探针
  //   turn 标 acknowledged 以停掉持久重投 sweep。

  function pickProbeDevice() {
    const devices = auth.state?.devices ?? {}
    for (const [deviceId] of Object.entries(devices)) return deviceId
    return null
  }

  function handleProbeInject(rawBody) {
    let body
    try { body = JSON.parse(rawBody.toString('utf8')) } catch { throw new ApiError(ERR.BAD_JSON) }
    const requestId = body.request_id
    const audioBase64 = body.audio_base64
    const sha = typeof body.sha256 === 'string' ? body.sha256.toLowerCase() : null
    if (!requestId || typeof audioBase64 !== 'string' || !sha) {
      throw new ApiError(ERR.MISSING_FIELD, 'request_id, audio_base64, sha256')
    }
    let audioBuf
    try { audioBuf = Buffer.from(audioBase64, 'base64') } catch { throw new ApiError(ERR.AUDIO_INVALID) }
    if (audioBuf.length === 0) throw new ApiError(ERR.AUDIO_INVALID)
    if (audioBuf.length > CONFIG.max_audio_bytes) throw new ApiError(ERR.AUDIO_TOO_LARGE)
    if (sha256hex(audioBuf) !== sha) throw new ApiError(ERR.AUDIO_HASH_MISMATCH)

    const deviceId = pickProbeDevice()
    if (!deviceId) throw new ApiError(ERR.DEVICE_UNKNOWN, 'no paired device')

    // 幂等：同 request_id 已在账本，且是 probe，直接重发终态（H1 事件再落一次）；
    // 不是 probe（比如生产 request_id 撞车）→ 拒绝，宁缺毋滥。
    const existing = ledger.get(requestId)
    if (existing) {
      const isProbe = existing.result?.audio?.kind === 'probe'
      if (!isProbe) throw new ApiError(ERR.IDEMPOTENCY_CONFLICT, 'request_id belongs to a non-probe turn')
    } else {
      ledger.create({
        requestId,
        deviceId,
        bodySha256: sha256hex(rawBody),
        sessionId: supervisor.sessionId,
      })
    }

    resultAudio.put(requestId, audioBuf)
    const meta = {
      kind: 'probe',
      sha256: sha,
      codec: 'm4a',
      duration_ms: Number.isFinite(body.duration_ms) ? body.duration_ms : null,
      size_bytes: audioBuf.length,
    }
    // H1 事件：与生产 direct 结果同事件名 `l1_audio_ready`；`kind: meta.kind`
    // 必须落上，`downlink-probe.mjs` 的 H1 分类严格要求 `entry.kind === 'probe'`
    // 才认。毕玄 2026-08-03 22:04Z 复审接受 —— 之前只写 `probe: true` 属于事件
    // 契约缺口，真实 CLI 会稳定停在 ERR_PROBE_STOPPED_AT_H1。
    log({
      evt: 'l1_audio_ready', request_id: requestId, task_id: null,
      source: 'direct', response_id: null, codec: 'm4a',
      duration_ms: meta.duration_ms, size_bytes: meta.size_bytes,
      sha256: meta.sha256, kind: meta.kind, probe: true,
    })

    // path=direct + setResult(completed) → ledger emit → allowDownlinkMessage
    // 因为 PR #59 已把 'probe' 加入 AUDIO_KINDS，本条不会被拒；随后经 WSS
    // 抵达 iPhone Relay，Relay 认 kind=probe 走 transferProbe → Watch。
    ledger.update(requestId, { path: 'direct' })
    ledger.setResult(requestId, {
      text: typeof body.text === 'string' ? body.text : null,
      audioBase64,
      audio: meta,
      extra: { source: 'probe' },
    }, 'completed')

    return { status: 202, body: { request_id: requestId, device_id: deviceId, size_bytes: audioBuf.length, sha256: sha } }
  }

  function handleProbeAck(rawBody, authInfo) {
    let body
    try { body = JSON.parse(rawBody.toString('utf8')) } catch { throw new ApiError(ERR.BAD_JSON) }
    const requestId = typeof body.request_id === 'string' ? body.request_id : null
    if (!requestId) throw new ApiError(ERR.MISSING_FIELD, 'request_id')

    // 毕玄 2026-08-03 15:33Z 复审 §2：`/v1/probe/ack` 之前只验 HMAC 就落
    // `evt=probe_acked`，任一已配对客户端可对任意 rid 发假 ACK 骗过 H5——
    // 五跳「假 PASS」直接绕过门禁。强校验四条不过就拒收、不落事件：
    // (a) turn 必须存在；
    // (b) 必须是探针 turn（kind=probe）；
    // (c) ACK 的 device_id 必须等于该 probe turn 的目标设备；
    // (d) ACK 的 sha 必须等于 H1 注入音频 sha（bit-perfect 到手播）。
    const turn = ledger.get(requestId)
    if (!turn) throw new ApiError(ERR.NOT_FOUND, 'unknown request_id')
    if (turn.result?.audio?.kind !== 'probe') {
      throw new ApiError(ERR.NOT_FOUND, 'not a probe turn')
    }
    if (turn.device_id !== authInfo.deviceId) {
      // 用 NOT_FOUND 复用生产 get-turn 的跨设备语义（不暴露 turn 存在与否）。
      throw new ApiError(ERR.NOT_FOUND, 'device mismatch')
    }
    const ackSha = typeof body.sha256 === 'string' ? body.sha256.toLowerCase() : null
    const injectSha = turn.result?.audio?.sha256?.toLowerCase() ?? null
    if (!ackSha || !injectSha || ackSha !== injectSha) {
      throw new ApiError(ERR.AUDIO_HASH_MISMATCH, 'ack sha does not match injected audio')
    }

    // H5 事件——只在四条强校验都过之后才落，避免历史事件被伪造。
    log({
      evt: 'probe_acked',
      request_id: requestId,
      device_id: authInfo.deviceId,
      played_ok: Boolean(body.played_ok),
      played_at_ms: Number.isFinite(body.played_at_ms) ? body.played_at_ms : null,
      duration_ms: Number.isFinite(body.duration_ms) ? body.duration_ms : null,
      sha256: ackSha,
      error_code: typeof body.error_code === 'string' ? body.error_code.slice(0, 80) : null,
    })

    ledger.acknowledgeResult(requestId, { source: 'probe' })
    return { status: 200, body: { request_id: requestId, acknowledged: true } }
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

      if (pathName === '/v1/voice/streams/chunks') {
        if (req.method !== 'POST') throw new ApiError(ERR.METHOD_NOT_ALLOWED)
        const authInfo = verify()
        let chunk
        try { chunk = JSON.parse(rawBody.toString('utf8')) } catch { throw new ApiError(ERR.BAD_JSON) }
        if (chunk?.request_id !== authInfo.requestId) {
          throw new ApiError(ERR.MISSING_FIELD, 'x-request-id must match stream request_id')
        }
        const result = streamUplink.ingest(chunk)
        return reply(202, { request_id: chunk.request_id, ...result })
      }

      if (pathName === '/v1/client-logs') {
        if (req.method !== 'POST') throw new ApiError(ERR.METHOD_NOT_ALLOWED)
        const r = handleClientLogs(rawBody, verify())
        return reply(r.status, r.body)
      }

      // ESS-184/207 探针注入：loopback-only（不校 HMAC——本机唯一进入路径
      // 是本机用户 curl/脚本；生产 tailscale/公网 sourceAllowed 就把非 CGNAT
      // 拦在门外，probe 白名单探针只用于门禁自检，不外放）。
      if (pathName === '/v1/probe/inject') {
        if (req.method !== 'POST') throw new ApiError(ERR.METHOD_NOT_ALLOWED)
        if (ip !== '127.0.0.1' && ip !== '::1') throw new ApiError(ERR.SOURCE_NOT_ALLOWED)
        const r = handleProbeInject(rawBody)
        return reply(r.status, r.body)
      }

      // ESS-184/207 探针回执：iPhone Relay 转发 Watch 侧 probe_playback_ack。
      // 走 HMAC 与其余北向端点一致——auth 的 device_id 就是 log evt=probe_acked
      // 的 device_id，跨端可对账。
      if (pathName === '/v1/probe/ack') {
        if (req.method !== 'POST') throw new ApiError(ERR.METHOD_NOT_ALLOWED)
        const r = handleProbeAck(rawBody, verify())
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

      m = pathName.match(/^\/v1\/voice\/turns\/([A-Za-z0-9_-]+)\/deliver$/)
      if (m) {
        if (req.method !== 'POST') throw new ApiError(ERR.METHOD_NOT_ALLOWED)
        const authInfo = verify()
        if (authInfo.requestId !== m[1]) throw new ApiError(ERR.MISSING_FIELD, 'x-request-id must match turn id')
        const r = handleDeliverTurn(m[1], authInfo)
        return r.status === 204 ? (res.writeHead(204), res.end()) : reply(r.status, r.body)
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

  // ESS-744：帧级硬上限。没有 maxPayload 时，ws 会把任意大小的帧完整收进内存
  // 后才交给业务层校验——一条声明 500MB 的帧足以在校验发生前打爆堆。
  // 下限由合法音频帧反推：解码后 maxFrameBytes → base64 膨胀 4/3 + JSON 信封余量，
  // 配置值低于它会误杀正常上行，因此取两者较大值。
  const realtimeMaxFrameBytes = CONFIG.realtime_media_max_frame_bytes ?? 64 * 1024
  const wsMaxPayloadBytes = Math.max(
    CONFIG.ws_max_payload_bytes ?? 256 * 1024,
    Math.ceil(realtimeMaxFrameBytes * 4 / 3) + 4 * 1024,
  )
  const wss = new WebSocketServer({ noServer: true, maxPayload: wsMaxPayloadBytes })
  const eventClients = new Set() // { ws, deviceId }
  const mediaClients = new Set()
  const eventsHeartbeatMs = CONFIG.events_heartbeat_ms ?? 20_000
  const resultDeliverySweepMs = CONFIG.result_delivery_sweep_ms ?? 1_000
  const announcementBindingTtlMs = CONFIG.voice_stream_announcement_binding_ttl_ms ?? 10 * 60 * 1000

  streamDownlink = new VoiceStreamDownlink({
    enabled: CONFIG.voice_streaming_v2 === true,
    maxPayloadBytes: CONFIG.voice_stream_max_payload_bytes ?? 64 * 1024,
    maxBufferedBytes: CONFIG.voice_stream_max_buffered_bytes ?? 256 * 1024,
    maxSequenceWindow: CONFIG.voice_stream_max_sequence_window ?? 32,
    gapTimeoutMs: CONFIG.voice_stream_gap_timeout_ms ?? 1_500,
    isAllowed: requestId => streamNegotiator.decision(requestId),
    send: (requestId, message) => {
      const turn = ledger.get(requestId)
      if (!turn) return false
      const client = [...eventClients].find(candidate =>
        candidate.deviceId === turn.device_id && candidate.ws.readyState === candidate.ws.OPEN)
      if (!client) return false
      client.ws.send(JSON.stringify(message))
      return true
    },
    log,
  })
  const pendingAnnouncementStreams = new PendingAnnouncementStreams({
    enabled: CONFIG.voice_streaming_v2 === true,
    maxEntries: CONFIG.voice_stream_pending_max_entries ?? 64,
    maxBufferedBytes: CONFIG.voice_stream_pending_max_buffered_bytes ?? 256 * 1024,
    ttlMs: CONFIG.voice_stream_pending_ttl_ms ?? 1_500,
    append: item => streamDownlink.append(item),
    finish: requestId => streamDownlink.finish(requestId),
    fallback: (requestId, reason) => streamDownlink.fallback(requestId, reason),
    log,
  })
  supervisor.onTurnAudioDelta = ({ requestId, event }) => {
    streamDownlink.append({ requestId, responseId: event.responseId, audio: event.audio, sampleRate: event.sampleRate ?? 24_000 })
  }
  supervisor.onTurnAudioDone = ({ requestId }) => streamDownlink.finish(requestId)
  supervisor.onAnnouncementAudioDelta = ({ capture, event }) => {
    const turn = capture.taskId ? ledger.byTaskId(capture.taskId) : null
    if (!turn) {
      pendingAnnouncementStreams.push({
        taskId: capture.taskId, responseId: capture.responseId,
        audio: event.audio, sampleRate: event.sampleRate ?? 24_000,
      })
      return
    }
    streamDownlink.append({
      requestId: turn.request_id, responseId: capture.responseId,
      audio: event.audio, sampleRate: event.sampleRate ?? 24_000,
    })
  }
  supervisor.onAnnouncementAudioDone = ({ capture }) => {
    const turn = capture.taskId ? ledger.byTaskId(capture.taskId) : null
    if (turn) {
      streamDownlink.finish(turn.request_id)
      streamNegotiator.release(turn.request_id)
    }
    else pendingAnnouncementStreams.end(capture.taskId)
  }

  ledger.on('turn', projection => {
    if (!projection.task_id) return
    const turn = ledger.byTaskId(String(projection.task_id))
    if (turn) pendingAnnouncementStreams.bind(projection.task_id, turn.request_id)
  })

  function sendTerminalDelivery(turn, client, cause) {
    const event = { type: 'turn.state', turn: ledger.projection(turn) }
    // ESS-181 契约：不达标就剥音频保文字，永远不静默丢弃投影。
    client.ws.send(JSON.stringify(prepareDownlinkMessage(event, log)))
    const delivery = ledger.markResultRedelivered(turn.request_id, {
      baseDelayMs: CONFIG.result_delivery_backoff_base_ms ?? 2_000,
      maxDelayMs: CONFIG.result_delivery_backoff_max_ms ?? 300_000,
    })
    log({
      evt: 'result_redelivered', request_id: turn.request_id, device_id: client.deviceId,
      status: turn.state, attempt: delivery?.attempt, retry_after_ms: delivery?.delay_ms, cause,
    })
    return true
  }

  // Real task steps are a text-only event and never enter the audio pipeline.
  watcher.onProgress = progress => {
    const turn = ledger.get(progress.requestId)
    if (!turn || ['completed', 'failed', 'cancelled'].includes(turn.state)) return
    const message = JSON.stringify({
      type: 'turn.progress',
      progress: {
        kind: 'progress', request_id: progress.requestId,
        sequence: progress.sequence, text: progress.text,
        occurred_at: progress.occurredAt,
      },
    })
    for (const client of eventClients) {
      if (client.deviceId === turn.device_id && client.ws.readyState === client.ws.OPEN) {
        client.ws.send(message)
      }
    }
  }

  ledger.on('turn', projection => {
    const event = { type: 'turn.state', turn: projection }
    const clients = [...eventClients].filter(client =>
      client.deviceId === projection.device_id && client.ws.readyState === client.ws.OPEN)
    if (['completed', 'failed', 'cancelled'].includes(projection.status)) {
      // 初次终态发送也推进同一份持久退避账本，避免 1s sweep 把快乐路径
      // 误判成“尚未投递”并立即向 iPhone/Watch 再发一遍。
      const client = clients[0]
      const turn = ledger.get(projection.request_id)
      if (client && turn) sendTerminalDelivery(turn, client, 'state_change')
      // A background announcement is allowed to arrive after task.completed.
      // Keep its negotiated request ownership for the same bounded window used
      // by the durable announcement binder; EOS releases it immediately.
      if (projection.path === 'background' && projection.status === 'completed') {
        streamNegotiator.releaseAfter(projection.request_id, announcementBindingTtlMs)
      } else {
        streamNegotiator.release(projection.request_id)
      }
      return
    }
    for (const client of clients) {
      client.ws.send(JSON.stringify(prepareDownlinkMessage(event, log)))
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
      const isMedia = pathName === '/v1/voice/realtime'
      if (pathName !== '/v1/voice/events' && !isMedia) return refuse(404, 'ERR_NOT_FOUND')
      if (isMedia && CONFIG.realtime_media_v1 !== true) return refuse(404, 'ERR_NOT_FOUND')
      const { deviceId, requestId } = auth.verify({ headers: req.headers, method: 'GET', pathName, rawBody: Buffer.alloc(0) })
      if (isMedia) {
        const url = new URL(req.url, 'https://x')
        const queryRequestId = url.searchParams.get('request_id')
        const sessionId = url.searchParams.get('session_id')
        if (!queryRequestId || queryRequestId !== requestId || !sessionId || sessionId.length > 128) {
          return refuse(400, 'ERR_STREAM_OWNERSHIP')
        }
        return wss.handleUpgrade(req, socket, head, ws => {
          const client = {
            ws, deviceId, requestId, sessionId, media: null, opened: false,
            accepted: false, pendingResult: null, disconnected: false,
          }
          mediaClients.add(client)
          const maxBuffered = CONFIG.realtime_media_max_buffered_bytes ?? 256 * 1024
          const sendDownstream = event => {
            if (ws.readyState !== ws.OPEN) throw Object.assign(new Error('client disconnected'), { code: 'ERR_STREAM_CLOSED' })
            if (ws.bufferedAmount > maxBuffered) throw Object.assign(new Error('client backpressure limit exceeded'), { code: 'ERR_STREAM_BACKPRESSURE' })
            ws.send(JSON.stringify(event))
          }
          // ESS-797：终止是单一、幂等的状态。第一个失败定调，之后既不再报错也不再
          // 执行任何已排队的消息——否则过载判定之后仍会有帧继续打到上游，
          // 而它们撞上已关闭的 socket 又会刷出二次 ERR_STREAM_CLOSED 噪声。
          let terminated = false
          const fail = error => {
            if (terminated) return
            terminated = true
            const code = error?.code ?? 'ERR_STREAM_PROTOCOL'
            log({ evt: 'realtime_media_error', request_id: requestId, device_id: deviceId, code })
            if (ws.readyState === ws.OPEN) ws.send(JSON.stringify({ type: 'error', code, request_id: requestId, session_id: sessionId }))
            ws.close(1008, String(code).slice(0, 123))
          }
          let chain = Promise.resolve()
          const completeRealtimeTurn = result => {
            if (!client.accepted) {
              client.pendingResult = result
              return
            }
            const turn = ledger.get(requestId)
            if (!turn || ['completed', 'failed', 'cancelled'].includes(turn.state)) return
            if (result.taskId) {
              ledger.update(requestId, {
                task_id: result.taskId,
                path: 'background',
                state: 'processing',
                detail: 'background_accepted',
              })
              watcher.watch(requestId).catch(error => {
                log({ evt: 'realtime_media_taskwatch_failed', request_id: requestId, err: String(error) })
                if (!['completed', 'failed', 'cancelled'].includes(ledger.get(requestId)?.state)) {
                  ledger.fail(requestId, 'ERR_PROCESSING_FAILED')
                }
              })
              return
            }
            ledger.update(requestId, { path: 'direct' })
            ledger.setResult(requestId, {
              text: result.assistantTranscript || null,
              extra: { source: 'realtime_media', response_id: result.responseId },
            }, 'completed')
          }
          const acceptRealtimeTurn = () => {
            if (client.accepted) return
            const existing = ledger.get(requestId)
            if (!existing) {
              ledger.create({
                requestId,
                deviceId,
                bodySha256: sha256hex(Buffer.from(`realtime:${sessionId}`)),
                sessionId: supervisor.sessionId,
              })
              log({
                evt: 'turn_accepted', request_id: requestId, device_id: deviceId,
                transport: 'realtime_media', audio_frames: client.media?.nextInputSequence ?? 0,
              })
            }
            ledger.update(requestId, { state: 'processing', detail: 'realtime_processing' })
            client.accepted = true
            if (client.pendingResult) completeRealtimeTurn(client.pendingResult)
          }
          // ESS-744：串行 chain 本身是无界的——帧一到就挂上 Promise 链，raw buffer
          // 被闭包持有到轮到它处理为止；突发上行会在 chain 追平前全部堆在内存里。
          // 双上限（条数 + 字节）+ 半满暂停读取形成真实背压；仍然超限说明对端
          // 无视背压，按结构化失败断链，绝不静默丢帧。
          const maxQueuedMessages = CONFIG.realtime_media_max_queued_messages ?? 64
          const maxQueuedBytes = CONFIG.realtime_media_max_queued_bytes ?? 4 * 1024 * 1024
          const pauseAt = Math.max(1, Math.ceil(maxQueuedMessages / 2))
          const resumeAt = Math.max(0, Math.floor(pauseAt / 2))
          let queuedMessages = 0
          let queuedBytes = 0
          let readPaused = false
          ws.on('message', raw => {
            if (terminated) return // 已进入终止态，迟到的帧不再入队
            const size = Buffer.isBuffer(raw) ? raw.length : Buffer.byteLength(String(raw))
            if (queuedMessages >= maxQueuedMessages || queuedBytes + size > maxQueuedBytes) {
              log({
                evt: 'realtime_media_inbound_overload', request_id: requestId, device_id: deviceId,
                queued_messages: queuedMessages, queued_bytes: queuedBytes, frame_bytes: size,
                max_messages: maxQueuedMessages, max_bytes: maxQueuedBytes,
              })
              fail(Object.assign(new Error('inbound queue limit exceeded'), { code: 'ERR_STREAM_OVERLOAD' }))
              return
            }
            queuedMessages += 1
            queuedBytes += size
            if (!readPaused && queuedMessages >= pauseAt) {
              readPaused = true
              ws.pause()   // 背压：停止从 socket 读取，直到积压回落
            }
            chain = chain.then(async () => {
              // 终止态在这里兑现：排队中的消息轮到自己时若已终止，连解析都不做，
              // 更不会调用 client.media / supervisor 产生上游副作用（fail-close）。
              if (terminated) return
              let message
              try { message = JSON.parse(raw.toString()) } catch { throw Object.assign(new Error('invalid JSON'), { code: 'ERR_BAD_JSON' }) }
              if (!client.opened) {
                if (message.type !== 'start' || message.protocol_version !== CONFIG.protocol_version
                  || message.request_id !== requestId || message.session_id !== sessionId) {
                  throw Object.assign(new Error('invalid media start'), { code: 'ERR_STREAM_OWNERSHIP' })
                }
                client.media = new RealtimeMediaSession({
                  requestId, sessionId,
                  sendUpstream: event => supervisor.sendMediaEvent(requestId, event),
                  sendDownstream,
                  maxFrameBytes: CONFIG.realtime_media_max_frame_bytes ?? 64 * 1024,
                  log: item => log({ evt: 'realtime_media', device_id: deviceId, ...item }),
                  onFirstAudio: ({ responseId, bytes }) => log({
                    evt: 'voice_stream_first_chunk', request_id: requestId,
                    response_id: responseId, bytes, source: 'realtime_media',
                  }),
                  onResponseComplete: completeRealtimeTurn,
                })
                await supervisor.openMediaSession({ label: requestId, onEvent: event => client.media?.handleAgentEvent(event) })
                client.opened = true
                sendDownstream({ type: 'ready', request_id: requestId, session_id: sessionId })
                return
              }
              if (message.request_id && message.request_id !== requestId) throw Object.assign(new Error('request ownership mismatch'), { code: 'ERR_STREAM_OWNERSHIP' })
              if (message.session_id && message.session_id !== sessionId) throw Object.assign(new Error('session ownership mismatch'), { code: 'ERR_STREAM_OWNERSHIP' })
              if (message.type === 'audio.append') client.media.appendInput(message)
              else if (message.type === 'audio.commit') {
                client.media.endInput()
                acceptRealtimeTurn()
              }
              else if (message.type === 'playback.started') client.media.playbackStarted(message.response_id)
              else if (message.type === 'playback.ended') {
                client.media.playbackEnded(message.response_id)
                const delivered = ledger.recordPlaybackEnded(requestId, {
                  responseId: message.response_id,
                  bytesPlayed: message.bytes_played,
                })
                log({
                  evt: 'playback_render_receipt', request_id: requestId,
                  response_id: message.response_id, bytes_played: message.bytes_played,
                  delivered: Boolean(delivered?.delivered_ack),
                })
              }
              else if (message.type === 'barge_in') client.media.bargeIn()
              else if (message.type === 'close') {
                terminated = true // 客户端主动收口，同样是终止态：后面的排队消息不再执行
                ws.close(1000, 'completed')
              }
              else throw Object.assign(new Error('unknown media event'), { code: 'ERR_STREAM_PROTOCOL' })
            }).catch(fail).finally(() => {
              queuedMessages -= 1
              queuedBytes -= size
              if (readPaused && queuedMessages <= resumeAt) {
                readPaused = false
                ws.resume()
              }
            })
          })
          const cleanup = (reason, code = null) => {
            if (client.disconnected) return
            client.disconnected = true
            terminated = true // 连接已断，媒体会话即将关闭，排队消息不得再打上游
            mediaClients.delete(client)
            client.media?.close('cancelled')
            supervisor.closeMediaSession(requestId, { cancel: client.opened })
            log({
              evt: 'realtime_media_disconnected', request_id: requestId, device_id: deviceId,
              reason, ...(code === null ? {} : { close_code: code }),
            })
          }
          ws.once('close', (code, reason) => cleanup(reason?.toString() || 'peer_closed', code))
          ws.once('error', error => cleanup(`socket_error:${error.message}`))
        })
      }
      wss.handleUpgrade(req, socket, head, ws => {
        const client = { ws, deviceId, alive: true }
        eventClients.add(client)
        log({ evt: 'events_client_connected', device_id: deviceId })
        ws.on('pong', () => { client.alive = true })
        ws.on('message', raw => {
          let message
          try { message = JSON.parse(raw.toString()) } catch { return }
          if (message.type === 'voice.stream.fallback' && typeof message.request_id === 'string') {
            const turn = ledger.get(message.request_id)
            if (turn?.device_id === deviceId) streamDownlink.fallback(message.request_id, 'client_requested')
          }
        })
        // Reconnect recovery: replay live turns plus recent terminal results until
        // the Watch explicitly confirms durable storage.
        const replayTurns = ledger.replayable({
          terminalTtlMs: CONFIG.result_delivery_ttl_ms ?? 30 * 60 * 1000,
          maxDeliveryAttempts: CONFIG.result_delivery_max_attempts ?? 5,
        }).filter(t => t.device_id === deviceId)
        const snapshot = {
          type: 'snapshot',
          turns: replayTurns.map(t => ledger.projection(t)),
        }
        // ESS-181 契约：不达标就剥音频保文字，永远不静默丢弃投影。
        ws.send(JSON.stringify(prepareDownlinkMessage(snapshot, log)))
        // 快照已经承载本轮终态投递，发送成功后推进同一份持久退避账本。
        for (const turn of replayTurns) {
          if (['completed', 'failed', 'cancelled'].includes(turn.state)) {
            const delivery = ledger.markResultRedelivered(turn.request_id, {
              baseDelayMs: CONFIG.result_delivery_backoff_base_ms ?? 2_000,
              maxDelayMs: CONFIG.result_delivery_backoff_max_ms ?? 300_000,
            })
            log({
              evt: 'result_redelivered', request_id: turn.request_id, device_id: deviceId,
              status: turn.state, attempt: delivery?.attempt, retry_after_ms: delivery?.delay_ms,
              cause: 'connect_snapshot',
            })
          }
        }
        // interim 不改变账本状态，但非终态回合重连时仍须重放；客户端用
        // request_id + delivery_sequence 去重，已持久入 Watch 队列的不会重复播。
        for (const [requestId, interim] of interimPayloads) {
          const turn = ledger.get(requestId)
          if (turn?.device_id === deviceId && !['completed', 'failed', 'cancelled'].includes(turn.state)) {
            const event = { type: 'turn.interim', interim }
            ws.send(JSON.stringify(prepareDownlinkMessage(event, log)))
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

  // 未 ACK 终态不能只等下一次 reconnect/turn_accepted。只要 iPhone events
  // 通道仍在线，就按账本退避主动补投；ACK 到达后 due 集合立即消失。
  const resultDeliverySweep = setInterval(() => {
    const due = ledger.dueTerminalDeliveries({
      terminalTtlMs: CONFIG.result_delivery_ttl_ms ?? 30 * 60 * 1000,
      maxDeliveryAttempts: CONFIG.result_delivery_max_attempts ?? 5,
    })
    for (const turn of due) {
      const client = [...eventClients].find(candidate =>
        candidate.deviceId === turn.device_id && candidate.ws.readyState === candidate.ws.OPEN)
      if (client) sendTerminalDelivery(turn, client, 'connected_sweep')
    }
  }, resultDeliverySweepMs)
  resultDeliverySweep.unref?.()

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
    for (const record of fallbackOutbox.pending()) {
      const turn = ledger.get(record.request_id)
      if (turn && !turn.task_id && !['completed', 'failed', 'cancelled'].includes(turn.state)) {
        processTurn(record.request_id, fallbackOutbox.readAudio(record), record.meta, record.context).catch(error =>
          log({ evt: 'fallback_recovery_failed', request_id: record.request_id, reason: String(error.message) }))
      }
    }
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
    clearInterval(resultDeliverySweep)
    for (const client of eventClients) client.ws.close()
    for (const client of mediaClients) client.ws.close()
    for (const timer of workTimers.values()) clearTimeout(timer)
    // ESS-234：清 in-flight 兜底计时器 + 释放 salvage PCM 引用
    for (const timer of realtimeFallbackTimers.values()) clearTimeout(timer)
    realtimeFallbackTimers.clear()
    realtimeAudioSalvage.clear()
    pendingAnnouncementStreams.close()
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
