// Background-work lifecycle (ESS-26): tracks a gateway task until terminal
// under a hard wall-clock deadline, projects its state into the ledger, and
// enforces the per-request event budget.
//
// - Prefers SSE /api/tasks/:id/events; on stream failure falls back to REST
//   polling with exponential backoff, then retries SSE. Never an unbounded
//   `agent.wait`: everything runs under the turn's 300s deadline.
// - On deadline: DELETE /api/tasks/:id (cancel), then project `failed` with
//   the stable ERR_WORK_TIMEOUT code.
// - Recovery rule (§4.1): a task is a provably-safe thing to re-query, so
//   restart re-attaches watchers to turns that already have a task_id. Turns
//   whose injection outcome is unknown are NOT re-run (non-idempotent).

const TERMINAL_TASK = new Set(['completed', 'failed', 'cancelled'])

// D1 拒写后的用户可读收尾文案（ESS-34）：Watch 只对 completed 渲染
// result.text，failed/cancelled 只会露裸错误码，所以拒写 turn 以
// completed + 本文案收尾。
export const READ_ONLY_DENY_TEXT = '只读模式：写操作已被拒绝，未做任何修改。'

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

// Gateway v0.9.x does not consistently populate `delegation`, but the Codex
// session owner is also exposed on real tasks as resultMetadata.backendRef.
// Treat both spellings as the same request-scoped ownership signal.
export function taskSessionId(task) {
  return task?.delegation?.sessionId
    || task?.delegation?.session_id
    || task?.resultMetadata?.backendRef?.sessionId
    || task?.resultMetadata?.backendRef?.session_id
    || null
}

// Bounded, client-safe summary of a permission request. Never forwards the
// raw payload (§8: logs/clients don't get full permission internals).
export function permissionSummary(authorization) {
  if (!authorization || typeof authorization !== 'object') return null
  const title = typeof authorization.title === 'string' ? authorization.title.slice(0, 200) : null
  const description = typeof authorization.description === 'string' ? authorization.description.slice(0, 400) : null
  return {
    id: String(authorization.id || ''),
    status: typeof authorization.status === 'string' ? authorization.status : null,
    title,
    description,
  }
}

export function extractPresentation(task, maxChars) {
  const presentation = task?.resultMetadata?.presentation
  const speech = typeof presentation?.speech === 'string' ? presentation.speech : null
  const inline = typeof presentation?.inline?.content === 'string' ? presentation.inline.content : null
  // presentation is only populated by some flows; the plain `result` string is
  // the canonical fallback (verified against a live v0.9.1 codex task).
  const plain = typeof task?.result === 'string' && task.result ? task.result : null
  let text = speech || inline || plain || null
  if (typeof text === 'string' && maxChars && text.length > maxChars) text = text.slice(0, maxChars) + '…'
  return { text, speech, hasInline: inline !== null }
}

export class TaskWatcher {
  constructor({ gateway, ledger, config, log = () => {} }) {
    this.gateway = gateway
    this.ledger = ledger
    this.cfg = config
    this.log = log
    this.active = new Map() // request_id → { controller, deadlineTimer }
  }

  // D1 权限清扫（ESS-30，收窄于 ESS-34）：上游会把 authorization 挂到错误的
  // task 上（ESS-24/27 已实测的缺陷），仅盯自身 task 会漏掉写权限请求，写任务
  // 只能烧满 300s 硬超时。写开关关闭时周期清扫 pending authorization，只
  // reject 满足以下任一归属证据的：
  //   - task_id：task.id 命中在途 turn 的 task_id（正常挂载）；
  //   - codex_session：task 的 delegation/backendRef session 命中在途 turn 的
  //     codex_session_id（真网关 v0.9.x 运行期两者均为 null——ESS-34 两轮实测，
  //     此通道留作上游修复后的兜底，不再是主路径）；
  //   - terminal_orphan：pending authorization 挂在 completed/failed/cancelled
  //     终态 task 上。终态宿主定义上不可能有活跃执行在等这份授权——任何无关
  //     活任务的 authorization 都挂在它自己 running 的宿主上（两轮真机实测
  //     均符合），因此「宿主终态 + 本 Bridge 有在途后台 turn」即可安全 reject，
  //     不破坏任务隔离。这是真网关错挂缺陷的实测主路径（ESS-34 第三轮）。
  // 无法归属的 authorization（running 宿主且非本 Bridge 的）一律不动——
  // Mac UI、其他 Agent/会话/人工任务的权限请求不归本 Bridge 管。
  startDenySweeper() {
    if (this.cfg.write_actions_enabled !== false || this.denySweeper) return
    const interval = this.cfg.deny_sweep_interval_ms || 5000
    this.deniedAuths ??= new Set()
    this.denySweeper = setInterval(async () => {
      if (this.active.size === 0) return   // 只在有在途后台 turn 时清扫
      const owned = this.activeOwnership()
      if (owned.taskIds.size === 0 && owned.sessionIds.size === 0) return
      let tasks
      try { tasks = await this.gateway.listTasks() } catch { return }
      for (const task of tasks) {
        const auth = task.authorization
        if (!auth?.id || auth.status !== 'pending') continue
        const ownedVia = this.ownershipOf(task, owned)
        if (!ownedVia) continue
        const authId = String(auth.id)
        if (this.deniedAuths.has(authId)) continue
        this.deniedAuths.add(authId)
        this.log({ evt: 'write_permission_auto_denied', task_id: task.id, authorization_id: authId, via: 'sweeper', owned_via: ownedVia })
        this.markActiveTurnsWriteDenied()
        this.gateway.respondPermission(authId, 'reject').catch(error => {
          this.log({ evt: 'auto_deny_failed', authorization_id: authId, err: String(error.message) })
        })
      }
    }, interval)
    this.denySweeper.unref?.()
  }

  // D1 主路径（ESS-34 第三轮）：经本 Bridge 自己的 Realtime WS 到达的
  // task.permission.requested。网关按 task.sessionId === 本会话 过滤后才下发
  // （网关源码契约），事件到达本身就是会话级归属证明——不依赖宿主 task 挂载
  // 正确，也不依赖 GET /api/tasks 能列出宿主（真机实测错挂宿主可为 list 之外
  // 的幽灵任务）。写开关关闭即定向 reject；写开关打开走既有 permission_required
  // 投影，不经此路径。
  denyRealtimePermission(task) {
    if (this.cfg.write_actions_enabled !== false) return
    const auth = task?.authorization
    if (!auth?.id || (auth.status && auth.status !== 'pending')) return
    const authId = String(auth.id)
    this.deniedAuths ??= new Set()
    if (this.deniedAuths.has(authId)) return
    this.deniedAuths.add(authId)
    this.log({ evt: 'write_permission_auto_denied', task_id: task?.id ?? null, authorization_id: authId, via: 'realtime_session', owned_via: 'realtime_session' })
    this.markActiveTurnsWriteDenied()
    this.gateway.respondPermission(authId, 'reject').catch(error => {
      this.log({ evt: 'auto_deny_failed', authorization_id: authId, err: String(error.message) })
    })
  }

  // 代答了一份归属本 Bridge 的写授权后（realtime_session / 清扫器任一路径），
  // 把在途后台 turn 标记为拒写嫌疑：上游随后若以 cancelled 收尾（Codex 收到
  // reject 的常见路径之一），投影层凭该标记把裸 cancelled 升级为用户可读的
  // 拒写收尾（READ_ONLY_DENY_TEXT）。错挂 authorization 无法映射到具体 turn，
  // 只能标记全部在途 turn；标记只影响收尾文案、不改变任何任务的执行与状态。
  markActiveTurnsWriteDenied() {
    for (const requestId of this.active.keys()) {
      const turn = this.ledger.get(requestId)
      if (!turn || TERMINAL_TASK.has(turn.state)) continue
      this.ledger.update(requestId, { detail: 'write_denied_read_only', permission: null }, { persist: true })
    }
  }

  // 本 Bridge 在途 turn 的归属标识：task_id（正常挂载）与 codex_session_id
  // （上游错挂 task 时可信的会话级 owner 标记，来自 delegation 或 backendRef）。
  activeOwnership() {
    const taskIds = new Set()
    const sessionIds = new Set()
    for (const requestId of this.active.keys()) {
      const turn = this.ledger.get(requestId)
      if (!turn) continue
      if (turn.task_id) taskIds.add(String(turn.task_id))
      if (turn.codex_session_id) sessionIds.add(String(turn.codex_session_id))
    }
    return { taskIds, sessionIds }
  }

  // 返回归属证据（'task_id' | 'codex_session' | 'terminal_orphan'），
  // 归属不了返回 null。
  ownershipOf(task, { taskIds, sessionIds }) {
    if (taskIds.has(String(task.id))) return 'task_id'
    const session = taskSessionId(task)
    if (session && sessionIds.has(String(session))) return 'codex_session'
    if (TERMINAL_TASK.has(task.status)) return 'terminal_orphan'
    return null
  }

  stopDenySweeper() {
    clearInterval(this.denySweeper)
    this.denySweeper = null
  }

  deadlineRemaining(turn) {
    const elapsed = Date.now() - Date.parse(turn.created_at)
    return this.cfg.max_work_ms - elapsed
  }

  // Attach a watcher for a turn that has a task_id. Resolves when the turn
  // reaches a terminal projection (result already in the ledger).
  watch(requestId) {
    if (this.active.has(requestId)) return this.active.get(requestId).done
    const turn = this.ledger.get(requestId)
    if (!turn?.task_id) return Promise.resolve()

    const controller = new AbortController()
    const entry = { controller }
    entry.done = this.run(requestId, turn.task_id, controller)
      .catch(error => {
        this.log({ evt: 'taskwatch_error', request_id: requestId, code: error.code || String(error) })
        this.ledger.fail(requestId, error.code === 'ERR_WORK_TIMEOUT' ? 'ERR_WORK_TIMEOUT' : 'ERR_UPSTREAM_UNAVAILABLE')
      })
      .finally(() => this.active.delete(requestId))
    this.active.set(requestId, entry)
    return entry.done
  }

  async run(requestId, taskId, controller) {
    const turn = this.ledger.get(requestId)
    let remaining = this.deadlineRemaining(turn)
    if (remaining <= 0) return this.timeout(requestId, taskId)

    const deadlineTimer = setTimeout(() => controller.abort('deadline'), remaining)
    let backoff = this.cfg.sse_backoff_base_ms

    try {
      while (true) {
        if (this.deadlineRemaining(this.ledger.get(requestId)) <= 0) return await this.timeout(requestId, taskId)

        // 1) SSE preferred
        try {
          for await (const event of this.gateway.taskEvents(taskId, { signal: controller.signal })) {
            backoff = this.cfg.sse_backoff_base_ms // healthy stream resets backoff
            if (this.onEvent(requestId, taskId, event)) return
          }
          // Stream ended without a terminal event → fall through to REST.
        } catch (error) {
          if (controller.signal.aborted) {
            if (controller.signal.reason === 'deadline') return await this.timeout(requestId, taskId)
            return // cancelled externally; caller already projected state
          }
          this.log({ evt: 'sse_interrupted', request_id: requestId, code: error.code || String(error.message) })
        }

        // 2) REST fallback with backoff — safe idempotent queries only.
        await sleep(Math.min(backoff, this.cfg.sse_backoff_max_ms))
        backoff = Math.min(backoff * 2, this.cfg.sse_backoff_max_ms)
        try {
          const task = await this.gateway.getTask(taskId)
          if (!task) {
            this.ledger.fail(requestId, 'ERR_TASK_NOT_FOUND')
            return
          }
          if (this.projectTask(requestId, task)) return
        } catch (error) {
          if (controller.signal.aborted && controller.signal.reason === 'deadline') return await this.timeout(requestId, taskId)
          this.log({ evt: 'poll_failed', request_id: requestId, code: error.code || String(error.message) })
        }
      }
    } finally {
      clearTimeout(deadlineTimer)
    }
  }

  // Returns true when the turn reached a terminal state.
  //
  // ESS-41 B1（P0 回归修复）：预算只统计 SSE/task 生命周期事件——Realtime
  // 观测计数走 ledger.bumpEvents 单独分账，一轮正常语音的数百条逐字/音频
  // delta 不再喂爆熔断。预算耗尽的降级动作是收敛投影 + 降采样取证日志，
  // 绝不取消仍在健康推进的任务（失控 SSE 的最终兜底是 300s 硬超时）。
  onEvent(requestId, taskId, event) {
    const count = this.ledger.bumpTaskEvents(requestId)
    const task = event.task
    const hasTask = task && typeof task.status === 'string'
    if (count > this.cfg.max_turn_events) {
      if (count === this.cfg.max_turn_events + 1) {
        this.log({ evt: 'event_budget_exhausted', request_id: requestId, task_id: taskId, count, action: 'degrade' })
      } else if ((count - this.cfg.max_turn_events) % 100 === 0) {
        this.log({ evt: 'event_budget_over', request_id: requestId, task_id: taskId, count })
      }
      // 超预算后只投影仍然必要的转折点（终态 / pending 权限），进度噪声丢弃。
      if (!hasTask) return false
      const pivotal = TERMINAL_TASK.has(task.status)
        || (task.authorization?.id && task.authorization.status === 'pending')
      if (!pivotal) return false
    }
    if (!hasTask) return false
    return this.projectTask(requestId, task, event.type)
  }

  // Map gateway task state → northbound projection. Returns true if terminal.
  projectTask(requestId, task, eventType = null) {
    const codexSessionId = taskSessionId(task)
    const patch = codexSessionId ? { codex_session_id: codexSessionId } : {}

    if (task.authorization?.id && task.authorization.status === 'pending') {
      // D1（ESS-30）：写动作总开关关闭时，一切上游权限请求（写/越权升级）
      // 自动拒绝，不投影给用户——demo 口径下写路径整体关闭，杜绝静默执行
      // 与无人应答挂起两种失败模式。拒绝后任务由 Codex 以文本收尾或失败，
      // 均走既有终态投影。
      if (this.cfg.write_actions_enabled === false) {
        const authId = String(task.authorization.id)
        this.deniedAuths ??= new Set()
        if (!this.deniedAuths.has(authId)) {
          this.deniedAuths.add(authId)
          this.log({ evt: 'write_permission_auto_denied', request_id: requestId, authorization_id: authId })
          this.gateway.respondPermission(authId, 'reject').catch(error => {
            this.log({ evt: 'auto_deny_failed', request_id: requestId, err: String(error.message) })
          })
        }
        this.ledger.update(requestId, {
          ...patch,
          state: 'processing',
          detail: 'write_denied_read_only',
          permission: null,
        }, { persist: true })
        return false
      }
      this.ledger.update(requestId, {
        ...patch,
        state: 'permission_required',
        detail: 'background_permission',
        permission: permissionSummary(task.authorization),
      }, { persist: true })
      return false
    }

    if (TERMINAL_TASK.has(task.status)) {
      if (task.status === 'completed') {
        const { text } = extractPresentation(task, this.cfg.max_result_chars)
        this.ledger.setResult(requestId, { text, extra: { source: 'task_presentation' } }, 'completed')
      } else if (task.status === 'cancelled') {
        // 拒写后的 cancelled 不是用户取消：以可读文案 completed 收尾（Watch 只
        // 对 completed 渲染 result.text，裸 cancelled/failed 只露状态与错误码）。
        if (this.ledger.get(requestId)?.detail === 'write_denied_read_only') {
          this.ledger.setResult(requestId, { text: READ_ONLY_DENY_TEXT, extra: { source: 'write_denied_read_only' } }, 'completed')
        } else {
          this.ledger.update(requestId, { ...patch, state: 'cancelled', permission: null })
        }
      } else {
        this.ledger.fail(requestId, 'ERR_TASK_FAILED', task.statusReason || null)
      }
      return true
    }

    this.ledger.update(requestId, {
      ...patch,
      state: 'processing',
      detail: `background_${task.status}`,
      permission: null,
    }, { persist: eventType !== 'task.progress' }) // progress ticks are frequent; don't fsync each one
    return false
  }

  async timeout(requestId, taskId) {
    this.log({ evt: 'work_timeout', request_id: requestId, task_id: taskId, max_work_ms: this.cfg.max_work_ms })
    await this.cancelUpstream(taskId)
    this.ledger.fail(requestId, 'ERR_WORK_TIMEOUT')
  }

  async cancelUpstream(taskId) {
    try {
      await this.gateway.cancelTask(taskId)
    } catch (error) {
      this.log({ evt: 'cancel_upstream_failed', task_id: taskId, code: error.code || String(error.message) })
    }
  }

  // Client-requested cancel. Terminal projection happens via the watcher (or
  // directly if the upstream already finished).
  async cancel(requestId) {
    const turn = this.ledger.get(requestId)
    if (!turn?.task_id) return false
    const result = await this.gateway.cancelTask(turn.task_id)
    if (result.ok && result.task && TERMINAL_TASK.has(result.task.status)) {
      this.projectTask(requestId, result.task)
    } else if (result.ok) {
      // The ledger's terminal guard makes this a no-op if a final state landed.
      this.ledger.update(requestId, { state: 'cancelled', permission: null })
    }
    return result.ok
  }

  stop(requestId, reason = 'stopped') {
    this.active.get(requestId)?.controller.abort(reason)
  }

  stopAll() {
    for (const [, entry] of this.active) entry.controller.abort('shutdown')
  }
}
