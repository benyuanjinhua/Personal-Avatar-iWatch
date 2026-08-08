// QwenRealtimeSessionSupervisor — ESS-25 PoC, extended for ESS-26/ESS-30/ESS-36
// (abortCurrentTurn for northbound cancel; text-only direct answers finish too)
//
// 以伪前端身份常驻连接 qwen-audio-agent v0.9.1 的 loopback WS /api/realtime，
// 单会话 sessionId=watch-bridge-v1-<device-id>，turn 串行注入。
//
// 监督职责（上游 WS 无应用层心跳，全部由 Bridge 侧实现）：
// - WebSocket 协议层 ping/pong 存活检测（pingIntervalMs / pingTimeoutMs）
// - 断线指数退避 + 抖动重连（backoffBaseMs..backoffMaxMs）
// - 空闲 idleDisconnectMs（默认 15 分钟，配置化）主动断开，下一 turn 按需重建
// - 语音所有权（ESS-36）：网关对非 owner 的 audio.append 是静默丢弃——所有权
//   不是可选项而是注入的前置条件。规则：
//     * 持有者是另一个 watch-bridge 实例（上一进程的残留连接）→ 自动 takeover，
//       否则 Bridge 重启后永久死锁在 busy；
//     * 持有者是其他前台（Mac 本机 UI / web）→ 仅当 takeoverFromFrontends=true
//       才抢占（Watch 按键说话是显式用户意图），否则快速失败 ERR_VOICE_BUSY，
//       绝不让 turn 白烧 120s 超时；
//     * 会话中被 takeover（voice.deactivated）→ 立即置 voiceReady=false 并失败
//       当前 turn；旧实现只失败 turn 不清 ready 标志，后续 turn 全部注入进
//       被静默丢弃的黑洞（ESS-36 真机 0 事件超时的根因之一）。
// - 注入回执 watchdog（ESS-36）：帧全部发出后 injectAckTimeoutMs 内一个 turn
//   相关事件都没有（上游 dashscope 掉线重连时帧被网关 pendingAudio 截尾丢弃
//   的典型表现）→ 回收会话并重试一次；重试仅在 0 事件时安全（模型从未开始
//   处理，不会产生重复回答）。
// - 播放回执：收到 audio.delta 即上报 playback.started，audio.done 后上报
//   playback.ended —— 否则网关不会下发 assistant transcript / 确认播报。
//   回执在 supervisor 层发送（不挂在 turn 上）：turn 间隙到达的后台任务播报
//   （announcement）也必须回执，否则网关播报窗口阻塞后续 turn 响应。
// - announcement 隔离（ESS-36）：origin=announcement 的响应是后台任务播报，
//   不属于当前 turn——其音频/转写不得混入 turn 结果，其 idle 状态不得提前
//   结束 turn。
// - announcement 归属与聚合（ESS-38）：announcement 不只是要隔离，还是后台
//   任务结果语音的唯一来源（Qwen Audio Realtime 生成的人物状态/口气播报）。
//   response.started 携带 taskId —— 按 responseId 聚合 24kHz PCM delta 与
//   assistant transcript，audio.done / 播报窗口 idle 时整体交给 onAnnouncement
//   回调（server 侧按 taskId → request_id 绑定回原请求）。聚合有上限
//   （maxAnnouncementPcmBytes），超限截断；孤儿聚合由 announcementIdleMs
//   兜底回收，绝不无界持有 PCM。
//
// ESS-37（会话自愈，真机停摆修复）：
// - 注入前健康预检 probeSession()：unmute → 等 voice.ownership 回播；死会话
//   先重建再注入，禁止盲注（网关对非活跃客户端的 audio.append 是静默丢弃的）
// - 零事件 watchdog：注入后 firstEventTimeoutMs 内一个网关事件都没有 → 判停摆，
//   销毁重建 WS（网关侧随连接关闭同步销毁上游 DashScope frontend）并以同一
//   幂等键重放当前 turn，最多 maxTurnAttempts 次，不等 120s/300s 超时
// - WS 中途断链（掐线）同样走重建+重放；voice.deactivated（真实用户抢占）不重放

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
    trailingSilenceMs = 2500,    // 触发 smart_turn 停止判定的尾部静音
                                 // （真机实测 1.2s 边缘化：VAD 收不到停止判定
                                 //   → 60s 后 transcript.discard，ESS-36）
    turnGapMs = 1500,            // turn 间最小间隔：连续注入无停顿会让网关把
                                 // 相邻 turn 语音合并/错关联（ESS-36 真机实测）
    turnTimeoutMs = 120_000,
    injectAckTimeoutMs = 15_000, // 注入完成后等待首个 turn 事件的上限
    takeoverFromFrontends = false,
    maxAnnouncementPcmBytes = 5_760_000, // ≈120s @ 24kHz mono PCM16（ESS-38）
    announcementIdleMs = 30_000,         // 孤儿 announcement 聚合的回收兜底
    probeTimeoutMs = 3_000,      // 注入前活性预检：unmute → voice.ownership 回播时限
    firstEventTimeoutMs = 12_000, // 注入后零事件停摆判定时限
    maxTurnAttempts = 2,         // 停摆/断链后同幂等键重放的总尝试次数上限
    rebuildDelayMs = 250,        // 重建前留给网关跑完旧连接 close 清理的时间
    log = (...args) => console.error(new Date().toISOString(), ...args),
  } = {}) {
    this.cfg = {
      gatewayUrl, deviceId, idleDisconnectMs, pingIntervalMs, pingTimeoutMs,
      backoffBaseMs, backoffMaxMs, frameMs, paceMs, trailingSilenceMs, turnGapMs,
      turnTimeoutMs, injectAckTimeoutMs, takeoverFromFrontends,
      maxAnnouncementPcmBytes, announcementIdleMs,
      probeTimeoutMs, firstEventTimeoutMs, maxTurnAttempts, rebuildDelayMs,
    }
    this.lastTurnEndedAt = 0
    this.sessionId = `watch-bridge-v1-${deviceId}`
    this.instanceId = `bridge_${randomUUID()}`
    this.log = log
    this.ws = null
    this.state = 'disconnected'   // disconnected|connecting|ready|busy|zombie
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
    this.announcements = new Map() // responseId → 聚合中的 announcement 捕获（ESS-38）
    this.playbackStarted = new Set()       // 已回执 playback.started 的 responseId
    this.mediaSession = null               // ESS-322: northbound frame-by-frame owner
    this.onAnnouncement = null    // (capture) => void — 后台播报聚合完成的交付回调
    this.onPermissionRequested = null // (task) => void — 本会话权限请求（D1/ESS-34）
    this.onTurnAudioDelta = null // ({requestId,event}) => void — L1 debug downlink
    this.onTurnAudioDone = null // ({requestId,event}) => void — L1 debug downlink EOS
    this.onAnnouncementAudioDelta = null // ({capture,event}) => void — taskId-bound L1 debug downlink
    this.onAnnouncementAudioDone = null // ({capture,event}) => void — taskId-bound L1 debug downlink EOS
  }

  record(entry) {
    const item = { ts: new Date().toISOString(), label: this.currentTurn?.label, ...entry }
    if (item.label === undefined) delete item.label
    this.journal.push(item)
    for (const fn of this.listeners) fn(item)
  }

  // ---- 连接生命周期 -------------------------------------------------------

  // takeover 判定（ESS-36）：另一个 watch-bridge 实例必然是本 Bridge 的残留
  // （单机只应有一个 Bridge），无条件可回收；其他前台仅在配置允许时抢占。
  takeoverEligible(holder) {
    if (!holder) return this.suspectZombie // 持有者未知：仅僵尸恢复场景抢占
    if (holder.label === CLIENT_LABEL) return true
    return this.cfg.takeoverFromFrontends === true
  }

  connect({ takeover = false } = {}) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN && this.voiceReady) {
      return Promise.resolve()
    }
    if (this.connectPromise) return this.connectPromise
    this.closedByUs = false
    this.connectPromise = (async () => {
      let withTakeover = takeover
      for (let attempt = 0; attempt < 2; attempt++) {
        const outcome = await this.connectOnce(withTakeover)
        if (outcome.ready) return
        // busy：持有者可回收且尚未 takeover → 立即带 takeover 重试一次
        if (!withTakeover && this.takeoverEligible(outcome.holder)) {
          this.record({ event: 'takeover.retry', holder: outcome.holder })
          withTakeover = true
          continue
        }
        this.state = 'busy'
        return // 保持 busy：voiceReady=false，由调用方决定失败语义
      }
    })().finally(() => { this.connectPromise = null })
    return this.connectPromise
  }

  // 单次连接尝试：resolve {ready:true} | {ready:false, holder}；网络失败 reject。
  connectOnce(takeover) {
    return new Promise((resolve, reject) => {
      // 旧 socket（busy 残留 / 半开）先显式回收，绝不悬挂第二条连接
      if (this.ws && this.ws.readyState !== WebSocket.CLOSED) {
        this.ws.abandoned = true
        this.ws.terminate()
      }
      const url = `${this.cfg.gatewayUrl}?sessionId=${encodeURIComponent(this.sessionId)}`
      this.state = 'connecting'
      this.record({ event: 'ws.connecting', url, takeover })
      const ws = new WebSocket(url)   // loopback、无 Origin → CLI 通道
      this.ws = ws
      let settled = false
      const settle = (fn, value) => {
        if (settled) return
        settled = true
        clearTimeout(connectTimeout)
        fn(value)
      }
      const connectTimeout = setTimeout(() => {
        settle(reject, new Error('connect timeout'))
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
          manualTurnDetection: true,
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
          this.state = 'ready'
          this.voiceReady = true
          this.reconnectAttempt = 0
          this.suspectZombie = false
          this.touchIdle()
          settle(resolve, { ready: true })
        }
        if (event.type === 'voice.ownership' && event.state === 'busy' && !this.voiceReady) {
          // 未获授权：所有权被他人持有，本连接不可注入
          settle(resolve, { ready: false, holder: event.holder || null })
        }
      })
      ws.on('close', (code, reason) => {
        clearTimeout(connectTimeout)
        // 取证：close code/reason 永远入日志（1006=异常断开，4xxx=网关自定义）
        this.record({ event: 'ws.close', code, reason: String(reason || ''), stale: this.ws !== ws })
        if (ws.abandoned || this.ws !== ws) return // 旧连接迟到的 close 不得污染新连接状态
        this.stopPing()
        this.voiceReady = false
        this.state = 'disconnected'
        settle(reject, new Error(`ws closed during connect (code=${code})`))
        // 断链即失败当前 turn（可重放），不等 turn 超时
        this.currentTurn?.fail(Object.assign(
          new Error(`ws closed mid-turn (code ${code})`), { connectionLost: true }))
        if (!this.closedByUs) this.scheduleReconnect()
      })
      ws.on('error', error => {
        this.record({ event: 'ws.error', message: error.message, stale: this.ws !== ws })
        settle(reject, error)
      })
    })
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
      const takeover = this.suspectZombie && this.takeoverEligible(this.ownershipHolder)
      if (takeover) {
        this.record({ event: 'takeover.decision', suspectZombie: this.suspectZombie, holder: this.ownershipHolder, allowed: true })
      }
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

  // ---- 会话健康预检 / 重建（ESS-37） --------------------------------------

  // 应用层活性探测：unmute 幂等（已持有所有权时网关仅回播 voice.ownership，
  // 不触发模型调用），回播在时限内到达 → 网关事件环路存活。
  probeSession() {
    if (this.ws?.readyState !== WebSocket.OPEN || !this.voiceReady) return Promise.resolve(false)
    const started = Date.now()
    return new Promise(resolve => {
      const finish = ok => {
        clearTimeout(timer)
        this.listeners.delete(onItem)
        this.record({ event: ok ? 'session.probe.ok' : 'session.probe.timeout', rttMs: Date.now() - started })
        resolve(ok)
      }
      const timer = setTimeout(() => finish(false), this.cfg.probeTimeoutMs)
      const onItem = item => {
        if (item.event === 'voice.ownership' || item.event === 'ws.close') finish(item.event === 'voice.ownership')
      }
      this.listeners.add(onItem)
      this.ws.send(JSON.stringify({ type: 'unmute' }))
    })
  }

  // 销毁当前 WS 并同步重建：网关在客户端连接关闭时同步销毁上游 DashScope
  // frontend 并释放语音所有权，因此重建 = 全新上游会话，这是停摆自愈的关键。
  async rebuildSession(reason) {
    this.record({ event: 'session.rebuild', reason })
    clearTimeout(this.reconnectTimer)
    this.reconnectTimer = null
    this.suspectZombie = true      // 自己的旧会话可能仍占有所有权 → 允许条件 takeover
    this.closedByUs = true         // 重连由本方法驱动，不走退避重连
    const old = this.ws
    this.ws = null
    this.voiceReady = false
    this.state = 'disconnected'
    try { old?.terminate() } catch { /* already dead */ }
    await sleep(this.cfg.rebuildDelayMs)
    await this.connect({ takeover: this.takeoverAllowed() })
  }

  // 注入前置检查：死会话先重建；重建后仍无响应 → 快速失败（sessionDead），
  // 绝不向未证明存活的会话盲注音频。
  async ensureLiveSession() {
    await this.connect()
    if (!this.voiceReady) return   // 交由调用方抛出 voice-not-ready
    if (await this.probeSession()) return
    await this.rebuildSession('probe-failed')
    if (!this.voiceReady) return
    if (!(await this.probeSession())) {
      throw Object.assign(new Error('realtime session unresponsive after rebuild'), { sessionDead: true })
    }
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
    this.voiceReady = false
    // 关闭前交付聚合中的 announcement（能交多少交多少），同时释放兜底定时器
    for (const responseId of [...this.announcements.keys()]) {
      this.finishAnnouncement(responseId, `close:${reason}`)
    }
    this.record({ event: 'ws.closed-by-bridge', reason })
  }

  // ---- 服务端事件 ---------------------------------------------------------

  handleServerEvent(event) {
    // ESS-322 media mode owns the realtime response stream. Forward raw deltas
    // immediately and, critically, do not synthesize playback receipts here;
    // only the northbound player's explicit receipts are relayed upstream.
    if (this.mediaSession && [
      'audio.delta', 'audio.done', 'response.started', 'response.interrupted',
      'transcript.delta', 'transcript.final', 'transcript.discard', 'playback.clear',
      'task.accepted', 'voice.state',
    ].includes(event.type)) {
      this.mediaSession.onEvent(event)
      this.record({ event: `media.${event.type}`, label: this.mediaSession.label, ...summarize(event) })
      return
    }
    // D1 主路径（ESS-34 第三轮）：网关只把 sessionId 等于本连接会话的任务的
    // 权限事件下发到本 WS（realtime-gateway 源码 `task.sessionId !== sessionId
    // → return`）——事件到达本连接即为会话级归属证明，与宿主 task 挂对挂错
    // 无关（错挂宿主可能根本不在 GET /api/tasks 里，list 清扫永远看不到）。
    // 完整 authorization 就在事件的 task 上，交给 Bridge 侧回调裁决。
    if (event.type === 'task.permission.requested') {
      this.onPermissionRequested?.(event.task ?? null)
    }
    // origin=announcement 的响应登记在册并开始聚合（ESS-38）：其音频回执、
    // 不进 turn 结果，但要按 responseId 聚合后绑定回后台任务的 request_id。
    // 注意 origin 有三种：model（Realtime 直答）、agent（后端 Agent 对本 turn
    // 的应答呈现）、announcement（无关后台任务播报）——只有最后一种要隔离，
    // agent 应答是 turn 结果本体（ESS-36 真机实测）。
    if (event.type === 'response.started' && event.responseId
      && event.origin === 'announcement') {
      this.beginAnnouncement(event)
    }
    if (event.type === 'transcript.final' && event.role === 'assistant'
      && event.responseId && this.announcements.has(event.responseId)) {
      this.appendAnnouncementTranscript(event)
    }
    if (event.type === 'audio.delta') {
      const capture = this.announcements.get(event.responseId)
      // 播放回执：Bridge 即转码转发，收到即视为开始"播放"。turn 间隙的
      // announcement 音频同样回执，否则网关播报窗口卡死。
      if (event.responseId && !this.playbackStarted.has(event.responseId)) {
        this.playbackStarted.add(event.responseId)
        this.wsSend({ type: 'playback.started', responseId: event.responseId })
      }
      // 24kHz PCM base64 → 聚合缓冲；日志不落原始音频
      this.record({ event: 'audio.delta', responseId: event.responseId, bytes: Buffer.from(event.audio || '', 'base64').length, sampleRate: event.sampleRate, announcement: Boolean(capture) })
      if (capture) {
        this.appendAnnouncementAudio(capture, event)
        this.onAnnouncementAudioDelta?.({ capture, event })
      }
      else {
        const requestId = this.currentTurn?.label
        this.currentTurn?.onAudioDelta(event)
        if (requestId) this.onTurnAudioDelta?.({ requestId, event })
      }
      return
    }
    if (event.type === 'audio.done') {
      if (event.responseId && this.playbackStarted.has(event.responseId)) {
        this.playbackStarted.delete(event.responseId)
        this.wsSend({ type: 'playback.ended', responseId: event.responseId })
      }
      if (this.announcements.has(event.responseId)) {
        const capture = this.announcements.get(event.responseId)
        this.onAnnouncementAudioDone?.({ capture, event })
        this.finishAnnouncement(event.responseId, 'audio.done')
      } else if (this.currentTurn?.label) {
        this.onTurnAudioDone?.({ requestId: this.currentTurn.label, event })
      }
    }
    // 播报窗口收尾：还没等到 audio.done 的聚合（纯文本播报等）就此交付
    if (event.type === 'voice.state' && event.state === 'idle'
      && event.origin === 'announcement') {
      for (const responseId of [...this.announcements.keys()]) {
        this.finishAnnouncement(responseId, 'announcement-idle')
      }
    }
    if (event.type === 'voice.ownership') {
      this.ownership = event.state
      this.ownershipHolder = event.holder || null
      // 不再是 owner → 本会话的注入会被网关静默丢弃，ready 标志必须同步失效
      if (event.state !== 'active') this.voiceReady = false
    }
    this.record({ event: event.type, ...summarize(event) })
    const announcementEvent = event.origin === 'announcement'
      && event.type !== 'voice.deactivated'
    if (!announcementEvent) this.currentTurn?.onEvent(event)
    if (event.type === 'voice.deactivated') {
      // 被其他前台 takeover：立即停止注入，不反抢
      this.voiceReady = false
      this.record({ event: 'ownership.lost', holder: event.holder })
      this.currentTurn?.fail(Object.assign(new Error('voice ownership lost'), { code: 'ERR_VOICE_BUSY' }))
    }
  }

  // ---- announcement 聚合（ESS-38） -----------------------------------------

  beginAnnouncement(event) {
    if (this.announcements.has(event.responseId)) return
    // ESS-542: Qwen sometimes omits taskId on announcement response.started.
    // Walk every available path to extract it before falling back to null.
    const resolvedTaskId = event.taskId
      ?? event.task?.id
      ?? event.task?.taskId
      ?? event.turn?.taskId
      ?? null
    const capture = {
      responseId: event.responseId,
      taskId: resolvedTaskId,
      turnId: event.turnId ?? event.turn?.id ?? null,
      chunks: [],
      pcmBytes: 0,
      truncated: false,
      transcript: null,
      startedAt: Date.now(),
      idleTimer: null,
    }
    this.announcements.set(event.responseId, capture)
    this.touchAnnouncement(capture)
    this.record({ event: 'announcement.started', responseId: capture.responseId, taskId: capture.taskId })
  }

  appendAnnouncementAudio(capture, event) {
    this.touchAnnouncement(capture)
    if (!event.audio) return
    const chunk = Buffer.from(event.audio, 'base64')
    // 有界聚合：超限只截断，不丢整段——短摘要语音仍可交付
    const room = this.cfg.maxAnnouncementPcmBytes - capture.pcmBytes
    if (room <= 0) {
      if (!capture.truncated) {
        capture.truncated = true
        this.record({ event: 'announcement.truncated', responseId: capture.responseId, pcmBytes: capture.pcmBytes })
      }
      return
    }
    const kept = chunk.length > room ? chunk.subarray(0, room) : chunk
    if (kept.length < chunk.length) capture.truncated = true
    capture.chunks.push(kept)
    capture.pcmBytes += kept.length
  }

  appendAnnouncementTranscript(event) {
    const capture = this.announcements.get(event.responseId)
    if (!capture || typeof event.content !== 'string') return
    this.touchAnnouncement(capture)
    capture.transcript = (capture.transcript || '') + event.content
  }

  touchAnnouncement(capture) {
    clearTimeout(capture.idleTimer)
    capture.idleTimer = setTimeout(() => {
      // 兜底：audio.done / 播报 idle 丢失时也不无界持有 PCM
      this.finishAnnouncement(capture.responseId, 'idle-timeout')
    }, this.cfg.announcementIdleMs)
    capture.idleTimer.unref?.()
  }

  finishAnnouncement(responseId, reason) {
    const capture = this.announcements.get(responseId)
    if (!capture) return
    this.announcements.delete(responseId)
    clearTimeout(capture.idleTimer)
    const payload = {
      responseId: capture.responseId,
      taskId: capture.taskId,
      turnId: capture.turnId,
      transcript: capture.transcript,
      pcm24k: Buffer.concat(capture.chunks),
      truncated: capture.truncated,
      reason,
    }
    this.record({
      event: 'announcement.finished', responseId, taskId: capture.taskId,
      pcmBytes: payload.pcm24k.length, truncated: capture.truncated, reason,
      transcriptChars: capture.transcript?.length ?? 0,
    })
    try {
      // 回调可能是 async（转码 + 落盘）：同步异常和 rejection 都不炸事件循环
      Promise.resolve(this.onAnnouncement?.(payload)).catch(error => {
        this.record({ event: 'announcement.deliver-failed', responseId, message: error.message })
      })
    } catch (error) {
      this.record({ event: 'announcement.deliver-failed', responseId, message: error.message })
    }
  }

  wsSend(obj) {
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify(obj))
  }

  async openMediaSession({ label, onEvent }) {
    if (!label || typeof onEvent !== 'function') throw new Error('media session label and listener are required')
    if (this.mediaSession || this.currentTurn) {
      throw Object.assign(new Error('realtime media owner is busy'), { code: 'ERR_VOICE_BUSY' })
    }
    await this.ensureLiveSession()
    if (this.mediaSession || this.currentTurn) {
      throw Object.assign(new Error('realtime media owner is busy'), { code: 'ERR_VOICE_BUSY' })
    }
    if (!this.voiceReady) throw Object.assign(new Error('voice not ready'), { code: 'ERR_VOICE_BUSY' })
    this.mediaSession = { label, onEvent }
    this.touchIdle()
  }

  sendMediaEvent(label, event) {
    if (!this.mediaSession || this.mediaSession.label !== label) {
      throw Object.assign(new Error('media session is not active'), { code: 'ERR_STREAM_CLOSED' })
    }
    if (this.ws?.readyState !== WebSocket.OPEN || !this.voiceReady) {
      throw Object.assign(new Error('realtime upstream unavailable'), { code: 'ERR_UPSTREAM_UNAVAILABLE' })
    }
    this.touchIdle()
    this.ws.send(JSON.stringify(event))
  }

  closeMediaSession(label, { cancel = false } = {}) {
    if (!this.mediaSession || this.mediaSession.label !== label) return false
    if (cancel) this.wsSend({ type: 'response.cancel' })
    this.mediaSession = null
    return true
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
    this.voiceReady = false
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
  // opts.onStart：轮到本 turn 真正开始注入时回调（server 用它把 work deadline
  //   从"受理时刻"改为"开始处理时刻"起算——串行积压下按受理起算必然团灭）。
  // opts.shouldRun：注入前询问是否仍需执行（排队期间被取消/判死的 turn 直接跳过）。
  // 停摆（零事件）/ 断链 → 销毁重建会话并以同一幂等键重放，最多 maxTurnAttempts
  // 次；其余失败（超时、所有权被真实用户抢占、cancel）不重放，保持原语义。
  injectTurn(pcm16k, {
    label = '', onStart, shouldRun, parentRequestId = null, contextSummary = null,
  } = {}) {
    const run = async () => {
      if (this.mediaSession) {
        throw Object.assign(new Error('realtime media owner is busy'), { code: 'ERR_VOICE_BUSY' })
      }
      if (shouldRun && !shouldRun()) {
        throw Object.assign(new Error('turn skipped before injection'), { skipped: true })
      }
      // turn 间最小间隔：给网关留出上一响应作用域的收尾时间
      const sinceLast = Date.now() - this.lastTurnEndedAt
      if (this.lastTurnEndedAt && sinceLast < this.cfg.turnGapMs) {
        await sleep(this.cfg.turnGapMs - sinceLast)
      }
      onStart?.()
      for (let attempt = 1; ; attempt++) {
        await this.ensureLiveSession()
        if (!this.voiceReady) {
          throw Object.assign(
            new Error(`voice not ready (ownership=${this.ownership})`),
            { code: 'ERR_VOICE_BUSY', holder: this.ownershipHolder },
          )
        }
        this.touchIdle()
        try {
          return await this.runTurn(pcm16k, label, attempt, { parentRequestId, contextSummary })
        } catch (error) {
          const retryable = (error.stalled === true || error.connectionLost === true
            || error.retryable === true) && !this.closedByUs
          this.record({ event: 'turn.attempt.failed', label, attempt, retryable, message: error.message })
          if (!retryable || attempt >= this.cfg.maxTurnAttempts) throw error
          await this.rebuildSession(error.stalled ? 'turn-stalled'
            : error.connectionLost ? 'connection-lost' : 'no-events')
        }
      }
    }
    const next = this.turnQueue.then(run, run)
    this.turnQueue = next.catch(() => {})
    return next
  }

  runTurn(pcm16k, label, attempt = 1, { parentRequestId = null, contextSummary = null } = {}) {
    const frameBytes = Math.round(16000 * this.cfg.frameMs / 1000) * 2
    const silence = Buffer.alloc(Math.round(16000 * this.cfg.trailingSilenceMs / 1000) * 2)
    const payload = Buffer.concat([pcm16k, silence])
    const turn = new TurnCapture(this, label)
    this.currentTurn = turn
    this.record({ event: 'turn.inject.start', label, attempt, pcmBytes: pcm16k.length, frames: Math.ceil(payload.length / frameBytes) })

    let ackTimer = null
    const sendFrames = async () => {
      for (let offset = 0; offset < payload.length; offset += frameBytes) {
        if (turn.settled) return
        if (this.ws?.readyState !== WebSocket.OPEN) {
          const error = Object.assign(new Error('ws closed during injection'), { connectionLost: true })
          turn.fail(error)
          throw error
        }
        const frame = payload.subarray(offset, offset + frameBytes)
        const context = offset === 0 ? {
          ...(parentRequestId ? { parent_request_id: parentRequestId } : {}),
          ...(contextSummary ? { context_summary: contextSummary } : {}),
        } : {}
        this.ws.send(JSON.stringify({
          type: 'audio.append', audio: frame.toString('base64'), ...context,
        }))
        await sleep(this.cfg.paceMs)
      }
      this.record({ event: 'turn.inject.done' })
      // 注入回执 watchdog：帧发完后限时等待首个 turn 事件；0 事件说明音频
      // 在网关侧被丢弃（非 owner 静默丢弃 / 上游断线 pendingAudio 截尾）
      if (!turn.settled && !turn.sawTurnEvent) {
        ackTimer = setTimeout(() => {
          if (turn.settled || turn.sawTurnEvent) return
          this.record({ event: 'turn.no-events', afterMs: this.cfg.injectAckTimeoutMs })
          turn.fail(Object.assign(
            new Error(`no realtime events within ${this.cfg.injectAckTimeoutMs}ms after injection`),
            { code: 'ERR_REALTIME_NO_EVENTS', retryable: true },
          ))
          this.recycleAfterTurnTimeout()
        }, this.cfg.injectAckTimeoutMs)
      }
    }
    // 零事件 watchdog：注入开始后时限内网关一个事件都没回 → 会话停摆，
    // 立即失败（可重放），不烧 turnTimeoutMs / 北向 300s 死等。
    const stallTimer = setTimeout(() => {
      if (turn.settled || turn.eventCount > 0) return
      this.record({ event: 'turn.stall.zero-events', label, attempt, waitedMs: this.cfg.firstEventTimeoutMs })
      turn.fail(Object.assign(
        new Error(`realtime stalled: zero events within ${this.cfg.firstEventTimeoutMs}ms`), { stalled: true }))
    }, this.cfg.firstEventTimeoutMs)
    const timeout = setTimeout(() => {
      turn.fail(new Error(`turn timeout after ${this.cfg.turnTimeoutMs}ms`))
      this.recycleAfterTurnTimeout()
    }, this.cfg.turnTimeoutMs)
    return Promise.all([sendFrames(), turn.promise])
      .then(([, result]) => result)
      .finally(() => {
        clearTimeout(stallTimer)
        clearTimeout(timeout)
        clearTimeout(ackTimer)
        this.lastTurnEndedAt = Date.now()
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
    this.sawTurnEvent = false   // 注入后是否收到过任何 turn 相关事件
    this.eventCount = 0           // 本 turn 收到的网关事件数（零事件 watchdog 依据）
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

  onAudioDelta(event) {
    this.sawTurnEvent = true
    if (this.settled) return
    this.eventCount += 1
    if (event.audio) {
      this.audioChunks.push(Buffer.from(event.audio, 'base64'))
      this.result.audioBytes24k += Buffer.from(event.audio, 'base64').length
    }
    if (event.responseId) this.result.responseIds.add(event.responseId)
  }

  onEvent(event) {
    const TURN_EVENTS = [
      'turn.started', 'transcript.delta', 'transcript.final', 'response.started',
      'task.accepted', 'task.running', 'task.delegated', 'task.progress',
    ]
    if (TURN_EVENTS.includes(event.type)
      || (event.type === 'voice.state' && event.state !== 'idle')) {
      this.sawTurnEvent = true
    }
    if (this.settled) return
    // voice.ownership 是连接级广播（其他客户端连接也会触发），不算会话活性证据
    if (event.type !== 'voice.ownership') this.eventCount += 1
    const r = this.result
    // turnId 关联守卫：本 turn 已绑定 turnId 后，其他 turn 的残留事件
    //（上一响应作用域的收尾）不得影响本 turn 的状态/完成判定
    if (r.turnId && event.turnId && event.turnId !== r.turnId
      && event.type !== 'turn.started') return
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
      case 'transcript.discard':
        // ASR 判定本段语音无效（空转写 / turn_invalid）：立即失败，
        // 不再白等 120s turn 超时（ESS-36 真机实测 60s 后才 discard）。
        // 仅当本 turn 已 turn.started（turnId 已绑定）才认领 discard——
        // 上一 turn 的迟到 discard 不得误杀刚排到队首的新 turn。
        if (event.role === 'user' && !r.userTranscript && r.turnId) {
          this.fail(Object.assign(
            new Error(`user transcript discarded (${event.reason || 'unrecognized speech'})`),
            { code: 'ERR_TRANSCRIPT_DISCARDED' },
          ))
        }
        break
      case 'task.accepted':
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
      case 'voice.state':
        // 回到 idle 且（已受理后台任务 或 已有直答内容）→ turn 完成。
        // 不再要求 userTranscript：网关可能把相邻 turn 的语音合并（上一段被
        // discard、应答挂在旧 turnId 上，ESS-36 真机实测）——只要拿到了应答
        // 内容就应交付，而不是白等 120s 超时。
        if (event.state === 'idle') {
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
    this.result.eventCount = this.eventCount
    this.result.audio24k = Buffer.concat(this.audioChunks)
    this.resolve(this.result)
  }

  fail(error) {
    if (this.settled) return
    this.settled = true
    this.result.responseIds = [...this.result.responseIds]
    this.result.eventCount = this.eventCount
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
