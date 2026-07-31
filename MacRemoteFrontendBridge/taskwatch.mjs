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

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

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

  // D1 全局权限清扫（ESS-30）：上游会把 authorization 挂到错误的 task 上
  // （ESS-24/27 已实测的缺陷），仅盯自身 task 会漏掉写权限请求，写任务只能
  // 烧满 300s 硬超时。写开关关闭时周期清扫全部 pending authorization 并一律
  // reject——写请求被快速、确定地拒绝，Codex 收到拒绝后以文本收尾。
  startDenySweeper() {
    if (this.cfg.write_actions_enabled !== false || this.denySweeper) return
    const interval = this.cfg.deny_sweep_interval_ms || 5000
    this.deniedAuths ??= new Set()
    this.denySweeper = setInterval(async () => {
      if (this.active.size === 0) return   // 只在有在途后台 turn 时清扫
      let tasks
      try { tasks = await this.gateway.listTasks() } catch { return }
      for (const task of tasks) {
        const auth = task.authorization
        if (!auth?.id || auth.status !== 'pending') continue
        const authId = String(auth.id)
        if (this.deniedAuths.has(authId)) continue
        this.deniedAuths.add(authId)
        this.log({ evt: 'write_permission_auto_denied', task_id: task.id, authorization_id: authId, via: 'sweeper' })
        this.gateway.respondPermission(authId, 'reject').catch(error => {
          this.log({ evt: 'auto_deny_failed', authorization_id: authId, err: String(error.message) })
        })
      }
    }, interval)
    this.denySweeper.unref?.()
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
  onEvent(requestId, taskId, event) {
    const count = this.ledger.bumpEvents(requestId)
    if (count > this.cfg.max_turn_events) {
      // Event budget exhausted: cancel the work and fail with a stable code.
      this.log({ evt: 'event_budget_exhausted', request_id: requestId, count })
      this.cancelUpstream(taskId)
      this.ledger.fail(requestId, 'ERR_EVENT_LIMIT')
      return true
    }
    const task = event.task
    if (!task || typeof task.status !== 'string') return false
    return this.projectTask(requestId, task, event.type)
  }

  // Map gateway task state → northbound projection. Returns true if terminal.
  projectTask(requestId, task, eventType = null) {
    const codexSessionId = task.delegation?.sessionId || task.delegation?.session_id || null
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
        this.ledger.update(requestId, { ...patch, state: 'cancelled', permission: null })
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
