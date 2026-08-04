export class PendingAnnouncementStreams {
  constructor({
    enabled = false,
    maxEntries = 64,
    maxBufferedBytes = 256 * 1024,
    ttlMs = 1_500,
    append,
    finish,
    fallback,
    log = () => {},
    now = Date.now,
    setTimer = setTimeout,
    clearTimer = clearTimeout,
  } = {}) {
    this.enabled = enabled
    this.maxEntries = maxEntries
    this.maxBufferedBytes = maxBufferedBytes
    this.ttlMs = ttlMs
    this.append = append
    this.finish = finish
    this.fallback = fallback
    this.log = log
    this.now = now
    this.setTimer = setTimer
    this.clearTimer = clearTimer
    this.entries = new Map()
    this.bufferedBytes = 0
  }

  push({ taskId, responseId, audio, sampleRate = 24_000 }) {
    if (!this.enabled) return { status: 'disabled' }
    const key = taskId == null ? null : String(taskId)
    if (!key) return { status: 'unmatched' }
    const bytes = Buffer.byteLength(audio ?? '', 'base64')
    let entry = this.entries.get(key)
    if (!entry) {
      if (this.entries.size >= this.maxEntries || bytes > this.maxBufferedBytes - this.bufferedBytes) {
        entry = this.makeFallbackEntry(key, responseId, 'pending_capacity_exceeded')
        return { status: 'fallback_pending', reason: entry.reason }
      }
      entry = { taskId: key, responseId, chunks: [], ended: false, bytes: 0, at: this.now(), timer: null }
      this.entries.set(key, entry)
      this.arm(entry)
    }
    if (entry.reason) return { status: 'fallback_pending', reason: entry.reason }
    if (bytes > this.maxBufferedBytes - this.bufferedBytes) {
      this.markFallback(entry, 'pending_capacity_exceeded')
      return { status: 'fallback_pending', reason: entry.reason }
    }
    entry.chunks.push({ responseId, audio, sampleRate })
    entry.bytes += bytes
    this.bufferedBytes += bytes
    this.log({ evt: 'voice_stream_announcement_pending', task_id: key, response_id: responseId, bytes, ttl_ms: this.ttlMs })
    return { status: 'pending' }
  }

  end(taskId) {
    if (!this.enabled || taskId == null) return { status: this.enabled ? 'unmatched' : 'disabled' }
    const entry = this.entries.get(String(taskId))
    if (!entry) return { status: 'unmatched' }
    entry.ended = true
    return { status: entry.reason ? 'fallback_pending' : 'pending' }
  }

  bind(taskId, requestId) {
    const key = taskId == null ? null : String(taskId)
    const entry = key ? this.entries.get(key) : null
    if (!entry) return { status: 'empty' }
    this.remove(entry)
    if (entry.reason) {
      this.fallback(requestId, entry.reason)
      return { status: 'fallback', reason: entry.reason }
    }
    for (const chunk of entry.chunks) this.append({ requestId, ...chunk })
    if (entry.ended) this.finish(requestId)
    this.log({ evt: 'voice_stream_announcement_rebound', request_id: requestId, task_id: key, response_id: entry.responseId, chunks: entry.chunks.length, bytes: entry.bytes })
    return { status: 'replayed', chunks: entry.chunks.length, ended: entry.ended }
  }

  close() {
    for (const entry of this.entries.values()) if (entry.timer) this.clearTimer(entry.timer)
    this.entries.clear()
    this.bufferedBytes = 0
  }

  makeFallbackEntry(taskId, responseId, reason) {
    // Keep a bounded tombstone so a later ledger binding can emit fallback with request_id.
    if (this.entries.size >= this.maxEntries) {
      const oldest = this.entries.values().next().value
      if (oldest) this.remove(oldest)
    }
    const entry = { taskId, responseId, chunks: [], ended: false, bytes: 0, at: this.now(), timer: null, reason }
    this.entries.set(taskId, entry)
    this.log({ evt: 'voice_stream_announcement_fallback_pending', task_id: taskId, response_id: responseId, reason })
    return entry
  }

  markFallback(entry, reason) {
    this.bufferedBytes -= entry.bytes
    entry.bytes = 0
    entry.chunks = []
    entry.reason = reason
    if (entry.timer) this.clearTimer(entry.timer)
    entry.timer = null
    this.log({ evt: 'voice_stream_announcement_fallback_pending', task_id: entry.taskId, response_id: entry.responseId, reason })
  }

  arm(entry) {
    entry.timer = this.setTimer(() => {
      entry.timer = null
      if (this.entries.get(entry.taskId) === entry && !entry.reason) this.markFallback(entry, 'pending_binding_timed_out')
    }, this.ttlMs)
    entry.timer?.unref?.()
  }

  remove(entry) {
    if (entry.timer) this.clearTimer(entry.timer)
    this.entries.delete(entry.taskId)
    this.bufferedBytes -= entry.bytes
  }
}
