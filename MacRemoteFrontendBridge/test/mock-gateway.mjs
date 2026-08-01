// Mock qwen-audio-agent gateway for acceptance tests. Emulates the v0.9.1
// surfaces the bridge touches, including the real gateway's quirk of serving
// HTML for unknown routes (defensive-parsing tests).

import http from 'node:http'
import { EventEmitter } from 'node:events'
import { WebSocketServer } from 'ws'

export class MockGateway extends EventEmitter {
  // preHolder: 预置的语音所有权持有者 descriptor（模拟残留 Bridge 实例或
  //   Mac 本机/web 前台占用）。真实网关对非 owner 的 audio.append 静默丢弃，
  //   mock 复刻该行为（ESS-36 回归的关键语义）。
  constructor({ scenario = 'direct', preHolder = null } = {}) {
    super()
    this.scenario = scenario
    this.tasks = new Map()
    this.permissionDecisions = []
    this.deleteCalls = []
    this.realtimeTurns = 0
    this.sseClients = new Map() // taskId → Set(res)
    this.server = null
    this.port = null
    this.holder = preHolder ? { descriptor: preHolder, ws: null } : null
    this.connects = []          // { descriptor, takeover }
    this.playbackReceipts = []  // { type, responseId }
    this.droppedFrames = 0
    this.voiceClients = new Set()
    this.announceSeq = 0
  }

  setTask(task) {
    this.tasks.set(task.id, task)
  }

  // ESS-38：向当前语音持有者（Bridge 的 Realtime 连接）推送一条后台任务播报
  // （origin=announcement），事件序列与真实网关同构：response.started(taskId)
  // → audio.delta* → transcript.final → audio.done → voice.state idle。
  announce({ taskId, responseId = `resp_ann_${++this.announceSeq}`, transcript = '任务完成。', pcm = Buffer.alloc(4800, 3), deltaBytes = 2400 } = {}) {
    const target = [...this.voiceClients].find(c => this.holder?.ws === c.ws) || [...this.voiceClients][0]
    if (!target) throw new Error('no realtime client connected for announcement')
    target.send({ type: 'response.started', responseId, origin: 'announcement', taskId })
    for (let offset = 0; offset < (pcm?.length || 0); offset += deltaBytes) {
      target.send({
        type: 'audio.delta',
        responseId,
        audio: pcm.subarray(offset, offset + deltaBytes).toString('base64'),
        sampleRate: 24000,
      })
    }
    if (transcript) {
      target.send({ type: 'transcript.final', role: 'assistant', content: transcript, origin: 'announcement', responseId })
    }
    target.send({ type: 'audio.done', responseId })
    target.send({ type: 'voice.state', state: 'idle', origin: 'announcement' })
  }

  // Push an SSE event to subscribers and keep the store in sync.
  emitTask(type, task) {
    this.setTask(task)
    for (const res of this.sseClients.get(task.id) || []) {
      res.write(`data: ${JSON.stringify({ type, task })}\n\n`)
    }
  }

  start() {
    this.server = http.createServer((req, res) => this.route(req, res))
    const wss = new WebSocketServer({ server: this.server, path: '/api/realtime' })
    wss.on('connection', ws => this.handleRealtime(ws))
    return new Promise(resolve => {
      this.server.listen(0, '127.0.0.1', () => {
        this.port = this.server.address().port
        resolve(`http://127.0.0.1:${this.port}`)
      })
    })
  }

  stop() {
    for (const set of this.sseClients.values()) for (const res of set) res.end()
    return new Promise(resolve => this.server.close(resolve))
  }

  // 所有权仲裁与真实网关同构：connect 时 takeover=false 且已有持有者 →
  // voice.ownership busy 且不下发 voice.ready；takeover=true → 顶掉旧持有者
  // （旧连接收到 voice.deactivated）；非 owner 的 audio.append 静默丢弃。
  handleRealtime(ws) {
    const send = obj => ws.readyState === ws.OPEN && ws.send(JSON.stringify(obj))
    const client = { ws, send, descriptor: null }
    this.voiceClients.add(client)
    const broadcast = () => {
      const holderDesc = this.holder?.descriptor || null
      for (const c of this.voiceClients) {
        c.send({
          type: 'voice.ownership',
          state: this.holder?.ws === c.ws ? 'active' : holderDesc ? 'busy' : 'available',
          holder: holderDesc,
        })
      }
    }
    let turnScheduled = false
    ws.on('close', () => {
      this.voiceClients.delete(client)
      if (this.holder?.ws === ws) { this.holder = null; broadcast() }
    })
    ws.on('message', raw => {
      let msg
      try { msg = JSON.parse(raw.toString()) } catch { return }
      if (msg.type === 'connect') {
        client.descriptor = { type: msg.clientType, label: msg.clientLabel, instanceId: msg.clientInstanceId }
        this.connects.push({ descriptor: client.descriptor, takeover: msg.takeover === true })
        if (this.holder && this.holder.ws !== ws && msg.takeover !== true) {
          broadcast() // 未获授权：只广播 busy，不下发 voice.ready
          return
        }
        const previous = this.holder
        this.holder = { descriptor: client.descriptor, ws }
        if (previous?.ws && previous.ws !== ws) {
          const prev = [...this.voiceClients].find(c => c.ws === previous.ws)
          prev?.send({ type: 'voice.deactivated', holder: client.descriptor })
        }
        broadcast()
        send({ type: 'voice.ready', inputSampleRate: 16000 })
        return
      }
      if (msg.type === 'mute' && this.holder?.ws === ws) {
        this.holder = null
        broadcast()
        return
      }
      if (msg.type === 'unmute') {
        // 真实网关对 unmute 总是回播 voice.ownership（activateVoiceClient →
        // broadcastVoiceOwnership）——Bridge 的注入前活性预检依赖这一点。
        send({ type: 'voice.ownership', state: 'active', holder: { label: 'watch-bridge' } })
        return
      }
      if (msg.type === 'playback.started' || msg.type === 'playback.ended') {
        this.playbackReceipts.push({ type: msg.type, responseId: msg.responseId })
        return
      }
      if (msg.type === 'audio.append') {
        if (this.holder?.ws !== ws) {
          this.droppedFrames += 1 // 真实网关行为：非 owner 的帧静默丢弃
          return
        }
        if (turnScheduled) return
        turnScheduled = true
        this.realtimeTurns += 1
        const turnIndex = this.realtimeTurns
        setTimeout(() => {
          if (this.scenario === 'no-events-once' && turnIndex === 1) {
            // 第一轮完全静默（模拟上游掉线导致帧被丢）：驱动注入回执 watchdog
            turnScheduled = false
            return
          }
          send({ type: 'turn.started', turnId: `turn_${turnIndex}` })
          if (this.scenario === 'discard') {
            // ASR 判定语音无效：真实网关在 speech_stopped(turn_invalid) 或空
            // 转写时下发 discard + idle，不会再有任何响应
            send({ type: 'transcript.discard', role: 'user', turnId: `turn_${turnIndex}`, reason: 'turn_invalid' })
            send({ type: 'voice.state', state: 'idle', turnId: `turn_${turnIndex}`, origin: 'model' })
            turnScheduled = false
            return
          }
          send({ type: 'transcript.final', role: 'user', content: '现在几点了？' })
          if (this.scenario === 'agent-origin') {
            // 后端 Agent 应答呈现路径（origin=agent）：这是 turn 结果本体
            send({ type: 'response.started', responseId: 'resp_agent', origin: 'agent' })
            send({ type: 'transcript.final', role: 'assistant', content: '今天是星期五。', origin: 'agent', responseId: 'resp_agent' })
            send({ type: 'audio.done', responseId: 'resp_agent' })
            send({ type: 'voice.state', state: 'idle', origin: 'agent' })
            turnScheduled = false
            return
          }
          if (['background', 'background-no-ack', 'queued', 'queued-announcement-first'].includes(this.scenario)) {
            const taskId = ['background', 'background-no-ack'].includes(this.scenario) ? 'task_bg' : 'task_queued'
            const queued = !['background', 'background-no-ack'].includes(this.scenario)
            const task = this.tasks.get(taskId) || {
              id: taskId, status: queued ? 'queued' : 'running', authorization: null, resultMetadata: null,
            }
            this.setTask(task)
            if (this.scenario !== 'background-no-ack') {
              const interimPcm = Buffer.alloc(9_600, 4) // 200ms，模拟委派前口头回执
              send({ type: 'response.started', responseId: 'resp_interim', origin: 'model' })
              send({ type: 'audio.delta', responseId: 'resp_interim', audio: interimPcm.toString('base64'), sampleRate: 24000 })
              send({ type: 'transcript.final', role: 'assistant', content: '收到，正在处理，请稍后', origin: 'model', responseId: 'resp_interim' })
            }
            if (this.scenario === 'queued-announcement-first') {
              const pcm = Buffer.alloc(24_000, 6)
              send({ type: 'response.started', responseId: 'resp_queued', origin: 'announcement', taskId })
              send({ type: 'audio.delta', responseId: 'resp_queued', audio: pcm.toString('base64'), sampleRate: 24000 })
              send({ type: 'transcript.final', role: 'assistant', content: '排队任务完成。', origin: 'announcement', responseId: 'resp_queued' })
              send({ type: 'audio.done', responseId: 'resp_queued' })
            }
            send({ type: queued ? 'task.accepted' : 'task.running', task })
            send({ type: 'voice.state', state: 'idle' })
          } else if (this.scenario === 'silent') {
            // Never answers: exercises the bridge-side hard timeout.
          } else { // direct / no-events-once 第二轮
            if (this.scenario === 'announcement') {
              // turn 响应前插入一条后台任务播报：音频不得混入 turn 结果
              const noise = Buffer.alloc(2400, 7)
              send({ type: 'response.started', responseId: 'resp_ann', origin: 'announcement', taskId: 'task_ann' })
              send({ type: 'audio.delta', responseId: 'resp_ann', audio: noise.toString('base64'), sampleRate: 24000 })
              send({ type: 'transcript.final', role: 'assistant', content: '后台任务已完成。', origin: 'announcement', responseId: 'resp_ann' })
              send({ type: 'audio.done', responseId: 'resp_ann' })
              send({ type: 'voice.state', state: 'idle', origin: 'announcement' })
            }
            const pcm = Buffer.alloc(4800) // 100ms of 24k silence
            send({ type: 'response.started', responseId: 'resp_1', origin: 'model' })
            send({ type: 'audio.delta', responseId: 'resp_1', audio: pcm.toString('base64'), sampleRate: 24000 })
            send({ type: 'transcript.final', role: 'assistant', content: '现在是上午九点。' })
            send({ type: 'audio.done', responseId: 'resp_1' })
            send({ type: 'voice.state', state: 'idle' })
          }
          turnScheduled = false
        }, 150)
      }
    })
  }

  route(req, res) {
    const url = new URL(req.url, 'http://x')
    const json = (status, body) => {
      res.writeHead(status, { 'content-type': 'application/json' })
      res.end(JSON.stringify(body))
    }

    let m = url.pathname.match(/^\/api\/tasks\/([^/]+)\/events$/)
    if (m && req.method === 'GET') {
      const task = this.tasks.get(m[1])
      if (!task) return json(404, { error: 'task not found' })
      if (this.scenario === 'sse-html') {
        res.writeHead(200, { 'content-type': 'text/html' })
        return res.end('<html>not sse</html>')
      }
      res.writeHead(200, { 'content-type': 'text/event-stream' })
      res.write(`data: ${JSON.stringify({ type: 'task.snapshot', task })}\n\n`)
      if (!this.sseClients.has(m[1])) this.sseClients.set(m[1], new Set())
      this.sseClients.get(m[1]).add(res)
      req.on('close', () => this.sseClients.get(m[1])?.delete(res))
      return
    }

    if (url.pathname === '/api/tasks' && req.method === 'GET') {
      return json(200, { tasks: [...this.tasks.values()] })
    }

    m = url.pathname.match(/^\/api\/tasks\/([^/]+)$/)
    if (m && req.method === 'GET') {
      if (this.scenario === 'html-task') {
        res.writeHead(200, { 'content-type': 'text/html' })
        return res.end('<html><body>web ui</body></html>')
      }
      const task = this.tasks.get(m[1])
      return task ? json(200, task) : json(404, { error: 'task not found' })
    }
    if (m && req.method === 'DELETE') {
      this.deleteCalls.push(m[1])
      const task = this.tasks.get(m[1])
      if (!task) return json(404, { error: 'task not found' })
      if (['completed', 'failed', 'cancelled'].includes(task.status)) {
        return json(409, { error: 'task is no longer active', task })
      }
      const cancelled = { ...task, status: 'cancelled', authorization: null }
      this.emitTask('task.cancelled', cancelled)
      return json(200, cancelled)
    }

    m = url.pathname.match(/^\/api\/permissions\/([^/]+)$/)
    if (m && req.method === 'POST') {
      let body = ''
      req.on('data', c => { body += c })
      req.on('end', () => {
        let decision = null
        try { decision = JSON.parse(body).decision } catch { /* ignore */ }
        if (!['always', 'reject'].includes(decision)) return json(400, { error: 'decision must be always or reject' })
        const task = [...this.tasks.values()].find(t => t.authorization?.id === m[1])
        if (!task) return json(404, { error: 'permission not found' })
        this.permissionDecisions.push({ id: m[1], decision })
        const updated = {
          ...task,
          authorization: null,
          status: decision === 'reject' ? 'cancelled' : 'running',
        }
        this.emitTask(decision === 'reject' ? 'task.cancelled' : 'task.running', updated)
        json(200, { id: m[1], status: decision === 'reject' ? 'rejected' : 'approved' })
      })
      return
    }

    // Real-gateway quirk: everything else gets the web UI as HTML.
    res.writeHead(200, { 'content-type': 'text/html' })
    res.end('<html><body>qwen web ui</body></html>')
  }
}
