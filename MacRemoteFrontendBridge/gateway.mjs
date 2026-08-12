// Defensive client for the qwen-audio-agent gateway REST/SSE surface (ESS-26).
//
// The gateway serves its web UI for every unknown route (`app.get('*')` →
// index.html), so an unknown /api/* path returns 200 text/html. Every response
// here is therefore validated on HTTP status, Content-Type AND minimal schema
// before being treated as JSON (§4.1 defensive validation).
//
// Red line: only the task-query/cancel/permission endpoints are used. The
// bridge never calls the Codex CLI and never exposes gateway admin APIs
// northbound.

export class GatewayError extends Error {
  constructor(code, detail) {
    super(code)
    this.code = code
    this.detail = detail
  }
}

const TASK_STATUSES = new Set([
  'queued', 'running', 'delegated', 'finalizing', 'completed', 'failed', 'cancelling', 'cancelled',
])

export function validTask(task) {
  return Boolean(task && typeof task === 'object'
    && typeof task.id === 'string'
    && typeof task.status === 'string'
    && TASK_STATUSES.has(task.status))
}

async function parseJson(response, what) {
  const contentType = response.headers.get('content-type') || ''
  if (!/application\/json/.test(contentType)) {
    // HTML (or anything else) must never be parsed as JSON.
    throw new GatewayError('ERR_UPSTREAM_SCHEMA', `${what}: content-type ${contentType || 'missing'}`)
  }
  try {
    return await response.json()
  } catch {
    throw new GatewayError('ERR_UPSTREAM_SCHEMA', `${what}: invalid JSON body`)
  }
}

export class GatewayClient {
  constructor({
    baseUrl, fetchImpl = fetch, requestTimeoutMs = 10_000, log = () => {},
    // ESS-744：SSE 入站缓冲上限。上游是本机网关但仍是外部输入——不设上限时
    // 一条无 `\n\n` 分隔符的流会把整条连接的字节全部堆在 `buffer` 里直到 OOM。
    // 单事件上限管“一帧太大”，总缓冲上限管“一个 chunk 里塞太多”。
    sseMaxEventBytes = 256 * 1024,
    sseMaxBufferBytes = 1024 * 1024,
  }) {
    this.baseUrl = baseUrl.replace(/\/$/, '')
    this.fetch = fetchImpl
    this.requestTimeoutMs = requestTimeoutMs
    this.sseMaxEventBytes = sseMaxEventBytes
    this.sseMaxBufferBytes = Math.max(sseMaxBufferBytes, sseMaxEventBytes)
    this.log = log
  }

  // timeoutMs: 0 disables the per-request timeout (SSE streams are bounded by
  // the caller's work deadline via `signal`, never left waiting forever).
  async request(method, path, { body, accept = 'application/json', signal, timeoutMs = this.requestTimeoutMs } = {}) {
    const controller = new AbortController()
    const timer = timeoutMs > 0 ? setTimeout(() => controller.abort(), timeoutMs) : null
    signal?.addEventListener('abort', () => controller.abort(), { once: true })
    try {
      return await this.fetch(this.baseUrl + path, {
        method,
        headers: {
          accept,
          ...(body !== undefined ? { 'content-type': 'application/json' } : {}),
        },
        body: body !== undefined ? JSON.stringify(body) : undefined,
        signal: controller.signal,
      })
    } catch (error) {
      throw new GatewayError('ERR_UPSTREAM_UNAVAILABLE', `${method} ${path}: ${error.message}`)
    } finally {
      if (timer) clearTimeout(timer)
    }
  }

  // GET /api/tasks — 全量列表。仅供 D1 权限清扫器使用：上游存在 authorization
  // 挂错 task 的已知缺陷（ESS-24/27 实测），必须全局发现 pending 权限。
  async listTasks() {
    const response = await this.request('GET', '/api/tasks')
    if (!response.ok) throw new GatewayError('ERR_UPSTREAM_STATUS', `listTasks: HTTP ${response.status}`)
    const body = await parseJson(response, 'listTasks')
    const tasks = Array.isArray(body?.tasks) ? body.tasks : Array.isArray(body) ? body : null
    if (!tasks) throw new GatewayError('ERR_UPSTREAM_SCHEMA', 'listTasks: no task array')
    return tasks.filter(validTask)
  }

  // GET /api/tasks/:id — safe, idempotent query (used for recovery too).
  async getTask(taskId) {
    const response = await this.request('GET', `/api/tasks/${encodeURIComponent(taskId)}`)
    if (response.status === 404) return null
    if (!response.ok) throw new GatewayError('ERR_UPSTREAM_STATUS', `getTask: HTTP ${response.status}`)
    const task = await parseJson(response, 'getTask')
    if (!validTask(task)) throw new GatewayError('ERR_UPSTREAM_SCHEMA', 'getTask: not a task object')
    return task
  }

  // DELETE /api/tasks/:id — cancel. 409 means already terminal; both count as
  // "cancel settled" for the caller.
  async cancelTask(taskId) {
    const response = await this.request('DELETE', `/api/tasks/${encodeURIComponent(taskId)}`)
    if (response.status === 404) return { ok: false, reason: 'not_found' }
    if (response.status === 409) {
      const body = await parseJson(response, 'cancelTask').catch(() => null)
      return { ok: true, alreadyTerminal: true, task: validTask(body?.task) ? body.task : null }
    }
    if (!response.ok) throw new GatewayError('ERR_UPSTREAM_STATUS', `cancelTask: HTTP ${response.status}`)
    const task = await parseJson(response, 'cancelTask')
    if (!validTask(task)) throw new GatewayError('ERR_UPSTREAM_SCHEMA', 'cancelTask: not a task object')
    return { ok: true, task }
  }

  // POST /api/permissions/:id  { decision: always | reject }
  async respondPermission(permissionId, decision) {
    if (!['always', 'reject'].includes(decision)) {
      throw new GatewayError('ERR_PERMISSION_DECISION_INVALID', String(decision))
    }
    const response = await this.request('POST', `/api/permissions/${encodeURIComponent(permissionId)}`, {
      body: { decision },
    })
    if (response.status === 404) return { ok: false, reason: 'not_found' }
    if (!response.ok) throw new GatewayError('ERR_UPSTREAM_STATUS', `respondPermission: HTTP ${response.status}`)
    return { ok: true, permission: await parseJson(response, 'respondPermission') }
  }

  // SSE /api/tasks/:id/events — yields parsed events; validates the stream
  // really is an event stream before consuming it.
  async *taskEvents(taskId, { signal } = {}) {
    const response = await this.request('GET', `/api/tasks/${encodeURIComponent(taskId)}/events`, {
      accept: 'text/event-stream',
      signal,
      timeoutMs: 0,
    })
    if (response.status === 404) throw new GatewayError('ERR_TASK_NOT_FOUND', taskId)
    if (!response.ok) throw new GatewayError('ERR_UPSTREAM_STATUS', `taskEvents: HTTP ${response.status}`)
    const contentType = response.headers.get('content-type') || ''
    if (!/text\/event-stream/.test(contentType)) {
      throw new GatewayError('ERR_UPSTREAM_SCHEMA', `taskEvents: content-type ${contentType || 'missing'}`)
    }
    const decoder = new TextDecoder()
    let buffer = ''
    // 与 `buffer` 同步维护的字节数：每次只对新增/消费的片段做一次 byteLength，
    // 总代价与流量线性相关，不会在大缓冲上退化成 O(n²)。
    let bufferBytes = 0
    // 抛出即离开 for-await：async iterator 的 return() 会取消上游流并断链，
    // 调用方（TaskWatcher）按既有路径记 `sse_interrupted` 并退避到 REST 轮询。
    const overflow = (code, detail) => new GatewayError(code, `taskEvents ${taskId}: ${detail}`)
    for await (const chunk of response.body) {
      const text = decoder.decode(chunk, { stream: true })
      buffer += text
      bufferBytes += Buffer.byteLength(text)
      if (bufferBytes > this.sseMaxBufferBytes) {
        throw overflow('ERR_UPSTREAM_STREAM_OVERFLOW', `buffer ${bufferBytes}B > ${this.sseMaxBufferBytes}B`)
      }
      let idx
      while ((idx = buffer.indexOf('\n\n')) >= 0) {
        const block = buffer.slice(0, idx)
        const blockBytes = Buffer.byteLength(buffer.slice(0, idx + 2)) - 2
        buffer = buffer.slice(idx + 2)
        bufferBytes -= blockBytes + 2
        if (blockBytes > this.sseMaxEventBytes) {
          throw overflow('ERR_UPSTREAM_EVENT_TOO_LARGE', `event ${blockBytes}B > ${this.sseMaxEventBytes}B`)
        }
        const dataLine = block.split('\n').find(l => l.startsWith('data:'))
        if (!dataLine) continue
        let payload
        try { payload = JSON.parse(dataLine.slice(5).trim()) } catch { continue } // skip malformed frames
        if (payload && typeof payload.type === 'string') yield payload
      }
      // 无分隔符的流永远走不到上面的 while，未成帧的残留同样受单事件上限约束。
      if (bufferBytes > this.sseMaxEventBytes) {
        throw overflow('ERR_UPSTREAM_EVENT_TOO_LARGE', `unterminated event ${bufferBytes}B > ${this.sseMaxEventBytes}B`)
      }
    }
  }
}
