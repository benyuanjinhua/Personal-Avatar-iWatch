// Mock qwen-audio-agent gateway for acceptance tests. Emulates the v0.9.1
// surfaces the bridge touches, including the real gateway's quirk of serving
// HTML for unknown routes (defensive-parsing tests).

import http from 'node:http'
import { EventEmitter } from 'node:events'
import { WebSocketServer } from 'ws'

export class MockGateway extends EventEmitter {
  constructor({ scenario = 'direct' } = {}) {
    super()
    this.scenario = scenario
    this.tasks = new Map()
    this.permissionDecisions = []
    this.deleteCalls = []
    this.realtimeTurns = 0
    this.sseClients = new Map() // taskId → Set(res)
    this.server = null
    this.port = null
  }

  setTask(task) {
    this.tasks.set(task.id, task)
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

  handleRealtime(ws) {
    const send = obj => ws.readyState === ws.OPEN && ws.send(JSON.stringify(obj))
    let turnScheduled = false
    ws.on('message', raw => {
      let msg
      try { msg = JSON.parse(raw.toString()) } catch { return }
      if (msg.type === 'connect') {
        send({ type: 'voice.ready' })
        return
      }
      if (msg.type === 'unmute') {
        // 真实网关对 unmute 总是回播 voice.ownership（activateVoiceClient →
        // broadcastVoiceOwnership）——Bridge 的注入前活性预检依赖这一点。
        send({ type: 'voice.ownership', state: 'active', holder: { label: 'watch-bridge' } })
        return
      }
      if (msg.type === 'audio.append' && !turnScheduled) {
        turnScheduled = true
        this.realtimeTurns += 1
        setTimeout(() => {
          send({ type: 'turn.started', turnId: `turn_${this.realtimeTurns}` })
          send({ type: 'transcript.final', role: 'user', content: '现在几点了？' })
          if (this.scenario === 'direct') {
            const pcm = Buffer.alloc(4800) // 100ms of 24k silence
            send({ type: 'audio.delta', responseId: 'resp_1', audio: pcm.toString('base64'), sampleRate: 24000 })
            send({ type: 'transcript.final', role: 'assistant', content: '现在是上午九点。' })
            send({ type: 'audio.done', responseId: 'resp_1' })
            send({ type: 'voice.state', state: 'idle' })
          } else if (this.scenario === 'background') {
            const task = this.tasks.get('task_bg') || {
              id: 'task_bg', status: 'running', authorization: null, resultMetadata: null,
            }
            this.setTask(task)
            send({ type: 'task.running', task })
            send({ type: 'voice.state', state: 'idle' })
          } else if (this.scenario === 'silent') {
            // Never answers: exercises the bridge-side hard timeout.
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
