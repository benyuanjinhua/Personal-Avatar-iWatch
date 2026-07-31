// QwenTaskProjection — ESS-27
//
// 后台 Work 的 SSE/REST 事件投影与结果回传（TECHNICAL_DESIGN_V2_1 §4.1 / §7 / §9）。
//
// 职责边界：
// - 输入永远是 Realtime 层捕获的既有 task_id（/api/tasks 无创建能力，
//   本模块绝不伪造 Work，也不重放创建动作 —— 恢复只做只读查询）。
// - 首选 SSE `GET /api/tasks/:id/events`；中断后立刻 REST 快照恢复，
//   并按指数退避+抖动交替「REST 轮询 / SSE 重试」，任一路径拿到终态即交付。
// - 终态对同一 request_id 恰好交付一次（settled 闸门），SSE/REST 竞争安全。
// - 交付不依赖 Qwen Realtime 的安全播报窗口：用户（Watch/手机）离线、
//   Realtime WS 已断开时结果仍经本投影送达 Bridge 北向队列。
// - 结果裁剪：presentation.speech/inline 超限截断（长文本只留摘要），
//   错误信息同样限长；进度事件限流+总量上限。
// - 300s 硬超时（配置化）：到期 DELETE /api/tasks/:id 并交付稳定错误
//   code=work_timeout，不允许无期限等待。
// - 北向 cancel → DELETE /api/tasks/:id；北向 permission →
//   POST /api/permissions/:id（按 authorization id 关联，勿按 taskId —
//   ESS-24 实测上游固定 Session 下第二个 Work 的权限会挂错 taskId）。
// - 防御性校验：HTTP 状态、Content-Type（网关对未知 GET 路径的 catch-all
//   会返回 200 + HTML，绝不能当 JSON/SSE 解析）、最小响应 Schema。
//
// 网关契约（qwen-audio-agent v0.9.1，server/src/app/bootstrap.mjs）：
// - GET  /api/tasks/:id          → task JSON（无包装）；404 {error}
// - GET  /api/tasks/:id/events   → SSE，首条 {type:'task.snapshot', task}，
//                                  其后 {type:'task.*', task}；无 Last-Event-ID
// - DELETE /api/tasks/:id        → task；409 {error, task}（已非活跃）；404
// - POST /api/permissions/:id    → {decision:'always'|'reject'}；400/404
// - task.status ∈ queued|running|delegated|finalizing|cancelling
//                 |completed|failed|cancelled
// - 最终结果 task.resultMetadata.presentation.{speech,inline}；
//   运行中摘要 task.delegation.presentation；权限 task.authorization.{id,…}

const ACTIVE_STATUS = new Set(['queued', 'running', 'delegated', 'finalizing', 'cancelling'])
const TERMINAL_STATUS = new Set(['completed', 'failed', 'cancelled'])
const KNOWN_STATUS = new Set([...ACTIVE_STATUS, ...TERMINAL_STATUS])

export const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

export class QwenTaskProjection {
  constructor({
    gatewayHttp = 'http://127.0.0.1:3101',
    taskId,
    requestId,
    deliver,                        // (event) => void — Bridge 北向队列（WSS/HTTPS → iPhone）
    hardTimeoutMs = 300_000,        // §4.1 单 Work 硬超时
    maxProjectedEvents = 200,       // 单请求投影事件数上限
    progressMinIntervalMs = 2_000,  // 进度事件限流
    speechMaxChars = 600,           // 语音文本上限（网关自身已裁到 1200）
    inlineMaxChars = 2_000,         // inline 摘要上限（长文本只留摘要）
    errorMaxChars = 300,
    backoffBaseMs = 500,
    backoffMaxMs = 30_000,
    fetchImpl = fetch,
    log = () => {},
  } = {}) {
    if (!taskId) throw new Error('taskId is required (projection never creates work)')
    if (!requestId) throw new Error('requestId is required (idempotency key)')
    if (typeof deliver !== 'function') throw new Error('deliver callback is required')
    this.cfg = {
      gatewayHttp, hardTimeoutMs, maxProjectedEvents, progressMinIntervalMs,
      speechMaxChars, inlineMaxChars, errorMaxChars, backoffBaseMs, backoffMaxMs,
    }
    this.taskId = taskId
    this.requestId = requestId
    this._deliver = deliver
    this.fetch = fetchImpl
    this.log = log
    this.settled = false
    this.stopped = false
    this.seq = 0
    this.projectedEvents = 0
    this.progressSuppressed = 0
    this.lastState = null
    this.lastProgressAt = 0
    this.lastAuthorizationId = null
    this.everSeenTask = false
    this.transport = 'none'         // none | sse | rest
    this.sseDisabled = false        // 测试钩子：强制 REST-only 恢复路径
    this.journal = []
    this.sseAbort = null
    this.timeoutTimer = null
    this.runPromise = null
    this.cancelRequested = false
  }

  record(entry) {
    const item = { ts: new Date().toISOString(), taskId: this.taskId, ...entry }
    this.journal.push(item)
    this.log(item)
  }

  // ---- 北向交付 -----------------------------------------------------------

  deliver(event) {
    if (this.settled) return false
    if (TERMINAL_STATUS.has(event.state) === false && this.projectedEvents >= this.cfg.maxProjectedEvents) {
      // 事件上限：非终态事件丢弃（计数），终态永远放行
      this.progressSuppressed += 1
      return false
    }
    const payload = {
      type: 'turn.background',
      request_id: this.requestId,
      task_id: this.taskId,
      seq: ++this.seq,
      at: new Date().toISOString(),
      transport: this.transport,
      ...event,
    }
    if (TERMINAL_STATUS_NORTH.has(event.state)) this.settled = true
    this.projectedEvents += 1
    try {
      this._deliver(payload)
    } catch (error) {
      this.record({ event: 'deliver.error', message: error.message })
    }
    this.record({ event: 'deliver', state: event.state, seq: payload.seq, transport: this.transport })
    if (this.settled) this.stop('settled')
    return true
  }

  // ---- REST（防御性校验） -------------------------------------------------

  async restJson(method, path, body) {
    const response = await this.fetch(`${this.cfg.gatewayHttp}${path}`, {
      method,
      headers: body ? { 'Content-Type': 'application/json' } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    })
    const contentType = response.headers.get('content-type') || ''
    if (!/application\/json/.test(contentType)) {
      // catch-all 对未知 GET 返回 200 + HTML —— 视为协议错误而非任务状态
      throw Object.assign(
        new Error(`non-JSON response from ${path} (${response.status}, ${contentType || 'no content-type'})`),
        { code: 'bad_content_type', status: response.status },
      )
    }
    let json = null
    try { json = await response.json() } catch {
      throw Object.assign(new Error(`invalid JSON from ${path}`), { code: 'bad_json', status: response.status })
    }
    return { status: response.status, json }
  }

  validateTask(task, { source }) {
    if (!task || typeof task !== 'object' || task.id !== this.taskId) {
      throw Object.assign(new Error(`task schema mismatch from ${source}`), { code: 'bad_schema' })
    }
    if (typeof task.status !== 'string' || !KNOWN_STATUS.has(task.status)) {
      // 未知状态：保守当 processing 处理，但记录以便升级回归发现
      this.record({ event: 'task.unknown-status', status: String(task.status), source })
      return { ...task, status: 'running' }
    }
    return task
  }

  // ---- 状态投影（§6 状态机 → 北向状态） -----------------------------------

  projectTask(task, { source }) {
    if (this.settled) return
    this.everSeenTask = true

    // 权限请求：按 authorization.id 关联（不是 taskId）
    const auth = task.authorization
    if (auth?.id && auth.id !== this.lastAuthorizationId && ACTIVE_STATUS.has(task.status)) {
      this.lastAuthorizationId = auth.id
      this.lastState = 'permission_required'
      this.deliver({
        state: 'permission_required',
        authorization: {
          id: auth.id,
          summary: trim(String(auth.command || auth.title || auth.description || '权限确认'), 200),
        },
      })
      return
    }
    if (!auth?.id) this.lastAuthorizationId = null

    if (TERMINAL_STATUS.has(task.status)) return this.deliverTerminal(task, { source })

    // 活跃状态 → background_processing（进度限流）
    const now = Date.now()
    const stateChanged = this.lastState !== 'background_processing'
    if (stateChanged || now - this.lastProgressAt >= this.cfg.progressMinIntervalMs) {
      this.lastState = 'background_processing'
      this.lastProgressAt = now
      this.deliver({
        state: 'background_processing',
        status: task.status,
        progress: trim(String(latestActivity(task) || ''), 200) || null,
      })
    } else {
      this.progressSuppressed += 1
    }
  }

  deliverTerminal(task, { source }) {
    const result = this.projectResult(task)
    const state = task.status === 'completed' ? 'completed'
      : task.status === 'cancelled' ? 'cancelled'
      : 'failed'
    this.record({ event: 'terminal', state, source, suppressedProgress: this.progressSuppressed })
    this.deliver({ state, ...result })
  }

  // 结果裁剪：speech/inline 提取 + 长文本只留摘要
  projectResult(task) {
    const presentation = task.resultMetadata?.presentation
      || task.delegation?.presentation
      || null
    const out = {}
    if (task.status === 'completed') {
      const speech = trim(clean(presentation?.speech) || clean(task.result) || '任务已完成', this.cfg.speechMaxChars)
      const inline = presentation?.inline && typeof presentation.inline === 'object'
        ? {
            title: trim(clean(presentation.inline.title) || '', 120) || null,
            content: trim(clean(presentation.inline.content) || '', this.cfg.inlineMaxChars),
            truncated: (clean(presentation.inline.content) || '').length > this.cfg.inlineMaxChars,
          }
        : null
      out.result = { speech, inline }
    } else if (task.status === 'cancelled') {
      out.error = { code: 'cancelled', message: this.cancelRequested ? '任务已按请求取消' : '任务被取消' }
    } else {
      out.error = {
        code: 'work_failed',
        message: trim(clean(task.error) || clean(presentation?.speech) || '后台任务失败', this.cfg.errorMaxChars),
      }
    }
    return out
  }

  // ---- 主循环：SSE 首选，断线退避回退 REST --------------------------------

  start() {
    if (this.runPromise) return this.runPromise
    this.timeoutTimer = setTimeout(() => {
      this.onHardTimeout().catch(error => this.record({ event: 'timeout.error', message: error.message }))
    }, this.cfg.hardTimeoutMs)
    this.timeoutTimer.unref?.()
    this.deliver({ state: 'background_accepted' })
    this.lastState = 'background_accepted'
    this.runPromise = this.runLoop().finally(() => this.stopTimers())
    return this.runPromise
  }

  async runLoop() {
    let attempt = 0
    while (!this.settled && !this.stopped) {
      if (!this.sseDisabled) {
        const sseResult = await this.runSse()
        if (this.settled || this.stopped) break
        this.record({ event: 'sse.interrupted', ...sseResult, attempt })
        if (sseResult.opened) attempt = 0   // SSE 曾恢复 → 新一轮中断从基准退避重来
      }
      // SSE 中断/不可用：REST 快照立即恢复（不丢已到达的终态）。
      // 注意：REST 成功不重置退避 —— 降级轮询本身按指数退避放缓，直到 SSE 恢复。
      try {
        this.transport = 'rest'
        await this.pollOnce()
      } catch (error) {
        this.record({ event: 'rest.error', code: error.code || null, message: error.message })
        if (error.code === 'task_lost') {
          this.deliver({ state: 'failed', error: { code: 'task_lost', message: '网关已不存在该任务，结果未知，请人工确认' } })
          break
        }
      }
      if (this.settled || this.stopped) break
      attempt += 1
      const backoff = backoffDelay(attempt, this.cfg.backoffBaseMs, this.cfg.backoffMaxMs)
      this.record({ event: 'retry.wait', attempt, delayMs: backoff })
      await sleep(backoff)
    }
    return { settled: this.settled, journal: this.journal.length }
  }

  // SSE 消费：返回中断原因；终态在流内直接投影并 settle
  async runSse() {
    const controller = new AbortController()
    this.sseAbort = controller
    this.transport = 'sse'
    let response
    try {
      response = await this.fetch(`${this.cfg.gatewayHttp}/api/tasks/${this.taskId}/events`, {
        headers: { Accept: 'text/event-stream' },
        signal: controller.signal,
      })
    } catch (error) {
      return { reason: 'connect-failed', message: error.message }
    }
    if (response.status === 404) {
      // 任务不存在：见过 → 状态丢失；没见过 → 直接失败
      const code = this.everSeenTask ? 'task_lost' : 'task_not_found'
      this.deliver({ state: 'failed', error: { code, message: code === 'task_lost' ? '网关任务状态丢失，结果未知，请人工确认' : '任务不存在' } })
      return { reason: '404' }
    }
    const contentType = response.headers.get('content-type') || ''
    if (!response.ok || !/text\/event-stream/.test(contentType)) {
      try { controller.abort() } catch {}
      return { reason: 'not-sse', status: response.status, contentType }
    }
    this.record({ event: 'sse.open' })
    const decoder = new TextDecoder()
    let buffer = ''
    try {
      for await (const chunk of response.body) {
        buffer += decoder.decode(chunk, { stream: true })
        let idx
        while ((idx = buffer.indexOf('\n\n')) >= 0) {
          const block = buffer.slice(0, idx)
          buffer = buffer.slice(idx + 2)
          const dataLine = block.split('\n').find(line => line.startsWith('data:'))
          if (!dataLine) continue
          let payload
          try { payload = JSON.parse(dataLine.slice(5).trim()) } catch { continue }
          if (!payload?.task) continue
          let task
          try { task = this.validateTask(payload.task, { source: `sse:${payload.type}` }) } catch (error) {
            this.record({ event: 'sse.bad-schema', message: error.message })
            continue
          }
          this.projectTask(task, { source: `sse:${payload.type}` })
          if (this.settled) { try { controller.abort() } catch {}; return { reason: 'settled', opened: true } }
        }
      }
    } catch (error) {
      if (error.name === 'AbortError') return { reason: 'aborted', opened: true }
      return { reason: 'stream-error', message: error.message, opened: true }
    } finally {
      this.sseAbort = null
    }
    return { reason: 'stream-ended', opened: true }
  }

  // REST 单次快照；返回是否成功拿到任务
  async pollOnce() {
    const { status, json } = await this.restJson('GET', `/api/tasks/${this.taskId}`)
    if (status === 404) {
      if (this.everSeenTask) throw Object.assign(new Error('task disappeared'), { code: 'task_lost' })
      this.deliver({ state: 'failed', error: { code: 'task_not_found', message: '任务不存在' } })
      return true
    }
    if (status !== 200) throw Object.assign(new Error(`unexpected status ${status}`), { code: 'bad_status' })
    const task = this.validateTask(json, { source: 'rest' })
    this.record({ event: 'rest.snapshot', status: task.status })
    this.projectTask(task, { source: 'rest' })
    return true
  }

  // ---- 硬超时与取消 -------------------------------------------------------

  async onHardTimeout() {
    if (this.settled) return
    this.record({ event: 'hard-timeout', afterMs: this.cfg.hardTimeoutMs })
    await this.requestGatewayCancel('timeout')
    // 稳定错误码：无论网关侧终态如何，北向都交付 work_timeout
    this.deliver({
      state: 'failed',
      error: { code: 'work_timeout', message: `任务超过 ${Math.round(this.cfg.hardTimeoutMs / 1000)} 秒未完成，已取消` },
    })
  }

  // 北向 cancel 链路：DELETE /api/tasks/:id
  async cancel() {
    if (this.settled) return { ok: true, alreadySettled: true }
    this.cancelRequested = true
    const outcome = await this.requestGatewayCancel('northbound')
    if (outcome.terminalTask) {
      // 409：任务已非活跃 —— 交付真实终态，不丢结果
      this.projectTask(outcome.terminalTask, { source: 'cancel:409' })
    }
    // 其余情况由 SSE/REST 主循环投影 task.cancelled
    return outcome
  }

  async requestGatewayCancel(reason) {
    try {
      const { status, json } = await this.restJson('DELETE', `/api/tasks/${this.taskId}`)
      this.record({ event: 'cancel.request', reason, status })
      if (status === 200) return { ok: true }
      if (status === 409 && json?.task) {
        const task = this.validateTask(json.task, { source: 'cancel:409' })
        return { ok: true, terminalTask: task }
      }
      if (status === 404) return { ok: false, code: 'task_not_found' }
      return { ok: false, code: `status_${status}` }
    } catch (error) {
      this.record({ event: 'cancel.error', reason, message: error.message })
      return { ok: false, code: error.code || 'cancel_failed' }
    }
  }

  // ---- 收尾 ---------------------------------------------------------------

  stop(reason = 'manual') {
    if (this.stopped) return
    this.stopped = true
    this.stopTimers()
    try { this.sseAbort?.abort() } catch {}
    this.record({ event: 'stop', reason })
  }

  stopTimers() {
    clearTimeout(this.timeoutTimer)
    this.timeoutTimer = null
  }

  // 测试钩子：模拟 SSE 中断（可选择永久禁用 SSE，逼出 REST-only 恢复路径）
  killSse({ disable = false } = {}) {
    if (disable) this.sseDisabled = true
    try { this.sseAbort?.abort() } catch {}
  }
}

// 北向 permission 链路：POST /api/permissions/:id（按 authorization id 关联）
export async function respondPermission({
  gatewayHttp = 'http://127.0.0.1:3101',
  authorizationId,
  decision,
  fetchImpl = fetch,
}) {
  if (!authorizationId) return { ok: false, code: 'missing_authorization_id' }
  if (!['always', 'reject'].includes(decision)) return { ok: false, code: 'invalid_decision' }
  const response = await fetchImpl(`${gatewayHttp}/api/permissions/${encodeURIComponent(authorizationId)}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ decision }),
  })
  const contentType = response.headers.get('content-type') || ''
  if (!/application\/json/.test(contentType)) {
    return { ok: false, code: 'bad_content_type', status: response.status }
  }
  let json = null
  try { json = await response.json() } catch { return { ok: false, code: 'bad_json', status: response.status } }
  if (response.status === 404) return { ok: false, code: 'permission_not_found', status: 404 }
  if (response.status === 400) return { ok: false, code: 'invalid_decision', status: 400 }
  if (!response.ok) return { ok: false, code: `status_${response.status}`, status: response.status }
  return { ok: true, permission: json }
}

const TERMINAL_STATUS_NORTH = new Set(['completed', 'failed', 'cancelled'])

function backoffDelay(attempt, baseMs, maxMs) {
  const base = Math.min(maxMs, baseMs * 2 ** Math.min(attempt, 16))
  return Math.round(base / 2 + Math.random() * base / 2)   // 抖动
}

function clean(value) {
  return typeof value === 'string' ? value.trim() : ''
}

function trim(text, max) {
  if (typeof text !== 'string') return ''
  return text.length > max ? `${text.slice(0, max - 1)}…` : text
}

function latestActivity(task) {
  const activity = Array.isArray(task.activity) ? task.activity : []
  const last = activity[activity.length - 1]
  if (!last) return null
  return typeof last === 'string' ? last : (last.summary || last.title || last.message || null)
}
