// ResultAudioStore — ESS-38 结果语音文件仓。
//
// Bridge 把 Qwen Audio Realtime 聚合出的 24kHz PCM 转码成 AAC/M4A 后落在
// 这里（state/result-audio/<request_id>.m4a，0600），北向经
// GET /v1/voice/turns/:id/audio 有界取回（支持 Range 断点续传）。
//
// 约束：
// - 单文件即单请求结果，request_id 已由路由正则限定为 [A-Za-z0-9_-]+，
//   本仓再做一次白名单校验，杜绝路径拼接逃逸。
// - 保留期（retentionMs）内可重复取回（iPhone 断点续传/重装恢复）；
//   到期由 sweeper 清理。文件内容永不进日志。

import { mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const SAFE_ID = /^[A-Za-z0-9_-]+$/

export class ResultAudioStore {
  constructor({ stateDir, retentionMs = 24 * 60 * 60 * 1000, sweepIntervalMs = 60 * 60 * 1000, log = () => {} }) {
    this.dir = join(stateDir, 'result-audio')
    this.retentionMs = retentionMs
    this.sweepIntervalMs = sweepIntervalMs
    this.log = log
    mkdirSync(this.dir, { recursive: true, mode: 0o700 })
  }

  pathFor(requestId) {
    if (!SAFE_ID.test(requestId)) throw new Error('invalid request id')
    return join(this.dir, `${requestId}.m4a`)
  }

  put(requestId, buffer) {
    const target = this.pathFor(requestId)
    const tmp = target + '.tmp'
    writeFileSync(tmp, buffer, { mode: 0o600 })
    renameSync(tmp, target)
  }

  // Buffer | null（不存在/已清理）。
  read(requestId) {
    try {
      return readFileSync(this.pathFor(requestId))
    } catch {
      return null
    }
  }

  remove(requestId) {
    rmSync(this.pathFor(requestId), { force: true })
  }

  sweep(now = Date.now()) {
    let removed = 0
    let entries
    try { entries = readdirSync(this.dir) } catch { return 0 }
    for (const name of entries) {
      const full = join(this.dir, name)
      try {
        if (now - statSync(full).mtimeMs > this.retentionMs) {
          rmSync(full, { force: true })
          removed += 1
        }
      } catch { /* raced with concurrent removal */ }
    }
    if (removed > 0) this.log({ evt: 'result_audio_swept', removed })
    return removed
  }

  startSweeper() {
    if (this.sweeper) return
    this.sweeper = setInterval(() => this.sweep(), this.sweepIntervalMs)
    this.sweeper.unref?.()
  }

  stopSweeper() {
    clearInterval(this.sweeper)
    this.sweeper = null
  }
}
