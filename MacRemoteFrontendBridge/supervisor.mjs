// QwenRealtimeSessionSupervisor — ESS-25 PoC, extended for ESS-26
// (abortCurrentTurn for northbound cancel; text-only direct answers finish too)
//
// 以伪前端身份常驻连接 qwen-audio-agent v0.9.1 的 loopback WS /api/realtime，
// 单会话 sessionId=watch-bridge-v1-<device-id>，turn 串行注入。
//
// 监督职责（上游 WS 无应用层心跳，全部由 Bridge 侧实现）：
// - WebSocket 协议层 ping/pong 存活检测（pingIntervalMs / pingTimeoutMs）
// - 断线指数退避 + 抖动重连（backoffBaseMs..backoffMaxMs）
// - 空闲 idleDisconnectMs（默认 15 分钟，配置化）主动断开，下一 turn 按需重建
// - 语音所有权：默认不抢占；仅当持有者是自身旧连接（同 label 的僵尸）
//   且无其他活跃本地前台时才允许 takeover
// - 播放回执：收到 audio.delta 即上报 playback.started，audio.done 后上报
//   playback.ended —— 否则网关不会下发 assistant transcript / 确认播报

import WebSocket from 'ws'
import { randomUUID } from 'node:crypto'

const CLIENT_LABEL = 'watch-bridge'

export class QwenRealtimeSessionSupervisor {
  constructor({
    gatewayUrl = 'ws://127.0.0.1:3101/api/realtime',
    deviceId = 'poc-device',
    idleDisconnectMs = 15 * 60 * 1000,
    pingIntervalMs = 10_000,
    pingTimeoutMs = 5_000,
    backoffBaseMs = 500,
    backoffMaxMs = 30_000,
    frameMs = 100,               // audio.append 帧长
    paceMs = 40,                 // 帧注入间隔（快于实时，留服务端缓冲余量）
    trailingSilenceMs = 1200,    // 触发 smart_turn 停止判定的尾部静音
    turnTimeoutMs = 120_000,
    log = (...args) => console.error(new Date().toISOString(), ...args),
  } = {}) {
    this.cfg = {
      gatewayUrl, deviceId, idleDisconnectMs, pingIntervalMs, pingTimeoutMs,
      backoffBaseMs, backoffMaxMs, frameMs, paceMs, trailingSilenceMs, turnTimeoutMs,
    }
    this.sessionId = `watch-bridge-v1-${deviceId}`
    this.instanceId = `bridge_${randomUUID()}`
    this.log = log
    this.ws = null
    this.state = 'disconnected'   // disconnected|connecting|ready|zombie
    this.ownership = 'unknown'    // unknown|active|busy|available
    this.ownershipHolder = null
    this.voiceReady = false
    this.reconnectAttempt = 0
    this.closedByUs = false
    this.turnQueue = Promise.resolve()
    this.listeners = new Set()
    this.journal = []
    this.idleTimer = null
    this.pingTimer = null
    this.pongTimer = null
    this.suspectZombie = false    // 上一连接因 ping 超时被判僵尸
  }

  record(entry) {
    const item = { ts: new Date().toISOString(), ...entry }
    this.journal.push(item)
    for (const fn of this.listeners) fn(item)
  }

  // ---- 连接生命周期 -------------------------------------------------------

  connect({ takeover = false } = {}) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN && this.voiceReady) {
      return Promise.resolve()
    }
    if (this.connectPromise) return this.connectPromise
    this.closedByUs = false
    this.connectPromise = new Promise((resolve, reject) => {
      const url = `${this.cfg.gatewayUrl}?sessionId=${encodeURIComponent(this.sessionId)}`
      this.state = 'connecting'
      this.record({ event: 'ws.connecting', url, takeover })
      const ws = new WebSocket(url)   // loopback、无 Origin → CLI 通道
      this.ws = ws
      const connectTimeout = setTimeout(() => {
        reject(new Error('connect timeout'))
        ws.terminate()
      }, 10_000)

      ws.on('open', () => {
        this.record({ event: 'ws.open' })
        ws.send(JSON.stringify({
          type: 'connect',
          clientType: 'cli',
          clientLabel: CLIENT_LABEL,
          clientInstanceId: this.instanceId,
          voiceEnabled: true,
          takeover: takeover === true,
          timeZone: 'Asia/Shanghai',
          locale: 'zh-CN',
        }))
        this.startPing()
      })
      ws.on('pong', () => this.onPong())
      ws.on('message', raw => {
        let event
        try { event = JSON.parse(raw.toString()) } catch { return }
        this.handleServerEvent(event)
        if (event.type === 'voice.ready') {
          clearTimeout(connectTimeout)
          this.state = 'ready'
          this.voiceReady = true
          this.reconnectAttempt = 0
          this.suspectZombie = false
          this.touchIdle()
          resolve()
        }
        if (event.type === 'voice.ownership' && event.state === 'busy') {
          // 未获授权：不重试抢占，交由 takeover 规则判定
          clearTimeout(connectTimeout)
          resolve()
        }
      })
      ws.on('close', (code, reason) => {
        clearTimeout(connectTimeout)
        this.stopPing()
        this.voiceReady = false
        const wasReady = this.state === 'ready'
        this.state = 'disconnected'
        this.record({ event: 'ws.close', code, reason: String(reason || '') })
        if (!this.closedByUs) this.scheduleReconnect(wasReady)
      })
      ws.on('error', error => {
        this.record({ event: 'ws.error', message: error.message })
        reject(error)
      })
    }).finally(() => { this.connectPromise = null })
    return this.connectPromise
  }

  scheduleReconnect() {
    if (this.reconnectTimer) return
    const n = this.reconnectAttempt++
    const base = Math.min(this.cfg.backoffMaxMs, this.cfg.backoffBaseMs * 2 ** n)
    const delay = Math.round(base / 2 + Math.random() * base / 2) // 抖动
    this.record({ event: 'ws.reconnect.scheduled', attempt: n + 1, delayMs: delay })
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null
      // 自身旧连接可能仍占有所有权（服务端未感知断开）→ 僵尸恢复场景。
      // 规则：仅当怀疑僵尸为自身实例且当前无其他活跃本地前台时 takeover。
      const takeover = this.takeoverAllowed()
      this.connect({ takeover }).catch(error => {
        this.record({ event: 'ws.reconnect.failed', message: error.message })
        this.scheduleReconnect()
      })
    }, delay)
  }

  takeoverAllowed() {
    if (!this.suspectZombie) return false
    const holder = this.ownershipHolder
    // 持有者未知（可能是我们的僵尸连接）或明确是本 Bridge 的旧实例 → 允许；
    // 持有者是其他类型前台（Mac 本机 UI 等）→ 绝不抢占。
    const holderIsSelf = !holder || holder.label === CLIENT_LABEL
    this.record({ event: 'takeover.decision', suspectZombie: this.suspectZombie, holder, allowed: holderIsSelf })
    return holderIsSelf
  }

  // ---- 应用层存活（上游无心跳，用 WS 协议层 ping/pong） -------------------

  startPing() {
    this.stopPing()
    this.pingTimer = setInterval(() => {
      if (this.ws?.readyState !== WebSocket.OPEN) return
      this.ws.ping()
      this.pongTimer = setTimeout(() => {
        this.record({ event: 'ping.timeout', verdict: 'zombie-connection' })
        this.state = 'zombie'
        this.suspectZombie = true
        this.ws.terminate()   // 半开连接：本端强制关闭并走重连
      }, this.cfg.pingTimeoutMs)
    }, this.cfg.pingIntervalMs)
  }

  onPong() {
    clearTimeout(this.pongTimer)
    this.pongTimer = null
  }

  stopPing() {
    clearInterval(this.pingTimer)
    clearTimeout(this.pongTimer)
    this.pingTimer = null
    this.pongTimer = null
  }

  // ---- 空闲断开 -----------------------------------------------------------

  touchIdle() {
    clearTimeout(this.idleTimer)
    this.idleTimer = setTimeout(() => {
      this.record({ event: 'idle.disconnect', idleMs: this.cfg.idleDisconnectMs })
      this.close('idle')
    }, this.cfg.idleDisconnectMs)
    this.idleTimer.unref?.()
  }

  close(reason = 'manual') {
    this.closedByUs = true
    clearTimeout(this.idleTimer)
    clearTimeout(this.reconnectTimer)
    this.reconnectTimer = null
    this.stopPing()
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({ type: 'mute' }))  // 释放语音所有权
      this.ws.close()
    }
    this.record({ event: 'ws.closed-by-bridge', reason })
  }

  // ---- 服务端事件 ---------------------------------------------------------

  handleServerEvent(event) {
    if (event.type === 'audio.delta') {
      // 24kHz PCM base64 → 聚合缓冲；日志不落原始音频
      this.currentTurn?.onAudioDelta(event)
      this.record({ event: 'audio.delta', responseId: event.responseId, bytes: Buffer.from(event.audio || '', 'base64').length, sampleRate: event.sampleRate })
      return
    }
    if (event.type === 'voice.ownership') {
      this.ownership = event.state
      this.ownershipHolder = event.holder
    }
    this.record({ event: event.type, ...summarize(event) })
    this.currentTurn?.onEvent(event)
    if (event.type === 'voice.deactivated') {
      // 被其他前台 takeover：立即停止注入，不反抢
      this.record({ event: 'ownership.lost', holder: event.holder })
      this.currentTurn?.fail(new Error('voice ownership lost'))
    }
  }

  // F2 watchdog（ESS-30）：turn 超时意味着 Realtime 会话已停摆——连接层仍然
  // 存活（ping/pong 正常），仅靠僵尸检测发现不了，必须强制回收重建 WS，
  // 否则停摆状态不自愈、后续 turn 连续失败。旧连接可能仍占有语音所有权，
  // 按既有僵尸规则允许条件 takeover。
  recycleAfterTurnTimeout() {
    if (!this.ws || this.closedByUs) return
    this.record({ event: 'ws.recycle.turn-timeout' })
    this.state = 'zombie'
    this.suspectZombie = true
    this.ws.terminate()   // close 事件触发既有 scheduleReconnect 退避流程
  }

  // 北向 cancel：中止当前注入中的 turn（后台任务的取消走 DELETE /api/tasks/:id）
  abortCurrentTurn(reason = 'cancelled') {
    const turn = this.currentTurn
    if (!turn || turn.settled) return false
    turn.fail(Object.assign(new Error(reason), { cancelled: reason === 'cancelled' }))
    return true
  }

  // ---- turn 串行注入 ------------------------------------------------------

  // pcm16k: Buffer（16kHz mono PCM16LE）。串行：上一 turn 完成前不注入下一条。
  injectTurn(pcm16k, { label = '' } = {}) {
    const run = async () => {
      await this.connect()
      if (!this.voiceReady) throw new Error(`voice not ready (ownership=${this.ownership})`)
      this.touchIdle()
      return await this.runTurn(pcm16k, label)
    }
    const next = this.turnQueue.then(run, run)
    this.turnQueue = next.catch(() => {})
    return next
  }

  runTurn(pcm16k, label) {
    const frameBytes = Math.round(16000 * this.cfg.frameMs / 1000) * 2
    const silence = Buffer.alloc(Math.round(16000 * this.cfg.trailingSilenceMs / 1000) * 2)
    const payload = Buffer.concat([pcm16k, silence])
    const turn = new TurnCapture(this, label)
    this.currentTurn = turn
    this.record({ event: 'turn.inject.start', label, pcmBytes: pcm16k.length, frames: Math.ceil(payload.length / frameBytes) })

    const sendFrames = async () => {
      for (let offset = 0; offset < payload.length; offset += frameBytes) {
        if (turn.settled) return
        if (this.ws?.readyState !== WebSocket.OPEN) throw new Error('ws closed during injection')
        const frame = payload.subarray(offset, offset + frameBytes)
        this.ws.send(JSON.stringify({ type: 'audio.append', audio: frame.toString('base64') }))
        await sleep(this.cfg.paceMs)
      }
      this.record({ event: 'turn.inject.done', label })
    }
    const timeout = setTimeout(() => {
      turn.fail(new Error(`turn timeout after ${this.cfg.turnTimeoutMs}ms`))
      this.recycleAfterTurnTimeout()
    }, this.cfg.turnTimeoutMs)
    return Promise.all([sendFrames(), turn.promise])
      .then(([, result]) => result)
      .finally(() => {
        clearTimeout(timeout)
        if (this.currentTurn === turn) this.currentTurn = null
      })
  }
}

// 单个 turn 的事件捕获：直答（无 task_id）或 spawn_thinking（task.* 事件）
class TurnCapture {
  constructor(supervisor, label) {
    this.supervisor = supervisor
    this.label = label
    this.settled = false
    this.audioChunks = []
    this.result = {
      label,
      path: 'unknown',            // direct | background
      state: 'injecting',         // → realtime_processing → background_accepted/…
      turnId: null,
      userTranscript: null,
      assistantTranscript: null,
      responseIds: new Set(),
      taskId: null,
      taskEvents: [],
      audioBytes24k: 0,
    }
    this.promise = new Promise((resolve, reject) => {
      this.resolve = resolve
      this.reject = reject
    })
  }

  ws() { return this.supervisor.ws }

  onAudioDelta(event) {
    if (this.settled) return
    if (event.audio) {
      this.audioChunks.push(Buffer.from(event.audio, 'base64'))
      this.result.audioBytes24k += Buffer.from(event.audio, 'base64').length
    }
    // 播放回执：首个 delta 即视为开始"播放"（Bridge 即转码转发）
    if (event.responseId && !this.result.responseIds.has(event.responseId)) {
      this.result.responseIds.add(event.responseId)
      this.ws()?.send(JSON.stringify({ type: 'playback.started', responseId: event.responseId }))
    }
  }

  onEvent(event) {
    if (this.settled) return
    const r = this.result
    switch (event.type) {
      case 'turn.started':
        r.turnId = event.turnId
        r.state = 'realtime_processing'
        break
      case 'transcript.final':
        if (event.role === 'user') r.userTranscript = event.content
        if (event.role === 'assistant') {
          r.assistantTranscript = (r.assistantTranscript || '') + event.content
        }
        break
      case 'response.started':
        if (event.responseId) {
          // 无音频的响应也要补 playback 回执占位（文本路径）
        }
        break
      case 'task.running':
      case 'task.delegated': {
        const task = event.task
        if (task?.id && !r.taskId) {
          r.taskId = task.id
          r.path = 'background'
          r.state = 'background_accepted'
        }
        r.taskEvents.push({ type: event.type, taskId: task?.id, status: task?.status })
        break
      }
      case 'task.progress':
      case 'task.finalizing':
      case 'task.completed':
      case 'task.failed':
      case 'task.cancelled':
        r.taskEvents.push({ type: event.type, taskId: event.task?.id, status: event.task?.status })
        break
      case 'audio.done': {
        if (event.responseId && this.result.responseIds.has(event.responseId)) {
          this.ws()?.send(JSON.stringify({ type: 'playback.ended', responseId: event.responseId }))
        }
        break
      }
      case 'voice.state':
        // 回到 idle 且已拿到用户转写 + （直答音频 或 已受理后台任务）→ turn 完成
        if (event.state === 'idle' && r.userTranscript) {
          if (r.taskId) return this.finish()
          // 直答完成：有音频或有文本转写即可（纯文本回复也要能结束 turn）
          if (r.audioBytes24k > 0 || r.assistantTranscript !== null) {
            r.path = 'direct'
            return this.finish()
          }
        }
        break
      case 'error':
        this.supervisor.record({ event: 'turn.error', message: event.message })
        break
      default:
        break
    }
  }

  finish() {
    if (this.settled) return
    this.settled = true
    this.result.state = this.result.taskId ? 'background_accepted' : 'completed_direct'
    this.result.responseIds = [...this.result.responseIds]
    this.result.audio24k = Buffer.concat(this.audioChunks)
    this.resolve(this.result)
  }

  fail(error) {
    if (this.settled) return
    this.settled = true
    this.result.responseIds = [...this.result.responseIds]
    this.result.error = error.message
    this.reject(Object.assign(error, { partial: this.result }))
  }
}

function summarize(event) {
  const copy = {}
  for (const [key, value] of Object.entries(event)) {
    if (key === 'type') continue
    if (key === 'audio') { copy.audioBytes = Buffer.from(value || '', 'base64').length; continue }
    if (key === 'task' && value) {
      copy.task = { id: value.id, status: value.status, kind: value.kind, title: value.title }
      continue
    }
    if (typeof value === 'string' && value.length > 200) { copy[key] = value.slice(0, 200) + '…'; continue }
    copy[key] = value
  }
  return copy
}

export const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
