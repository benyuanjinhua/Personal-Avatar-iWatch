// ProjectionLedger — ESS-27
//
// 投影恢复账本：request_id → { taskId, settled, terminalState }。
//
// 边界说明：Bridge 的完整幂等账本（request_id → sessionId → task_id →
// Codex Session，含北向 turn 状态）属于 ESS-26；本账本只覆盖投影层的
// 最小恢复语义 —— Bridge 重启 / Watch 重开页面后，找回所有未终结的
// task_id 并重建只读投影，绝不重放任务创建。ESS-26 集成时可用其持久化
// 账本替换本文件，只要保留 upsert/markSettled/unsettled 三个语义。

import { readFileSync, writeFileSync, mkdirSync, renameSync } from 'node:fs'
import { dirname } from 'node:path'

export class ProjectionLedger {
  constructor({ path = null } = {}) {
    this.path = path
    this.entries = new Map()
    if (path) this.loadSync()
  }

  loadSync() {
    try {
      const raw = JSON.parse(readFileSync(this.path, 'utf8'))
      for (const [requestId, entry] of Object.entries(raw.entries || {})) {
        this.entries.set(requestId, entry)
      }
    } catch { /* 首次运行 / 文件缺失：空账本 */ }
  }

  persistSync() {
    if (!this.path) return
    mkdirSync(dirname(this.path), { recursive: true })
    const tmp = `${this.path}.tmp`
    writeFileSync(tmp, JSON.stringify({ version: 1, entries: Object.fromEntries(this.entries) }, null, 2))
    renameSync(tmp, this.path)   // 原子替换，避免半写状态
  }

  // 幂等：同一 request_id 重复登记返回既有映射（不覆盖 taskId）
  upsert(requestId, { taskId }) {
    const existing = this.entries.get(requestId)
    if (existing) return { ...existing, duplicate: existing.taskId !== taskId ? 'conflict' : true }
    const entry = { taskId, settled: false, terminalState: null, createdAt: new Date().toISOString() }
    this.entries.set(requestId, entry)
    this.persistSync()
    return { ...entry, duplicate: false }
  }

  markSettled(requestId, terminalState) {
    const entry = this.entries.get(requestId)
    if (!entry || entry.settled) return false
    entry.settled = true
    entry.terminalState = terminalState
    entry.settledAt = new Date().toISOString()
    this.persistSync()
    return true
  }

  get(requestId) {
    return this.entries.get(requestId) || null
  }

  // 重启恢复入口：所有未终结的投影
  unsettled() {
    return [...this.entries.entries()]
      .filter(([, entry]) => !entry.settled)
      .map(([requestId, entry]) => ({ requestId, ...entry }))
  }
}
