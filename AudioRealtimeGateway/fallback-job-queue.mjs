import { createHash } from 'node:crypto'
import { mkdirSync, readFileSync, readdirSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'

const TERMINAL = new Set(['completed', 'rejected', 'failed', 'timed_out', 'cancelled'])
const sha256 = value => createHash('sha256').update(value).digest('hex')

// Durable, single-consumer queue for full-file fallback turns. Records are
// intentionally one file per job: an atomic rename settles each transition,
// and a process restart can recover queued/executing work without replaying a
// terminal job. The upstream request id remains stable across recovery.
export class FallbackJobQueue {
  constructor({ stateDir, execute, turnState = () => null, maxJobs = 64,
    queueTimeoutMs = 30_000, ownerBusy = () => false, now = () => Date.now(), log = () => {},
    setTimer = (fn, ms) => setTimeout(fn, ms), clearTimer = timer => clearTimeout(timer) }) {
    if (!stateDir || typeof execute !== 'function') throw new Error('stateDir and execute are required')
    this.dir = join(stateDir, 'fallback-jobs')
    this.turnStatesPath = join(stateDir, 'fallback-turn-states.json')
    this.execute = execute; this.turnState = turnState
    this.ownerBusy = ownerBusy; this.setTimer = setTimer; this.clearTimer = clearTimer
    this.maxJobs = maxJobs; this.queueTimeoutMs = queueTimeoutMs
    this.now = now; this.log = log; this.jobs = new Map(); this.turnStates = new Map()
    this.drainPromise = null; this.deadlineTimer = null; this.controllers = new Map()
    mkdirSync(this.dir, { recursive: true })
    try { this.turnStates = new Map(Object.entries(JSON.parse(readFileSync(this.turnStatesPath, 'utf8')))) } catch { /* first boot */ }
    this.#load()
    queueMicrotask(() => { void this.drain() })
  }

  submit({ requestId, audio, audioSha256, parentRequestId = null, contextSummary = null }) {
    if (!requestId || !Buffer.isBuffer(audio) || !/^[a-f0-9]{64}$/.test(audioSha256 ?? '')) {
      return { status: 'rejected', reason: 'invalid_job' }
    }
    if (sha256(audio) !== audioSha256) return { status: 'rejected', reason: 'audio_hash_mismatch' }
    const prior = this.jobs.get(requestId)
    if (prior) {
      const same = prior.audio_sha256 === audioSha256
      return same ? { status: 'duplicate', state: prior.state }
        : { status: 'rejected', reason: 'idempotency_conflict' }
    }
    const state = this.#turnState(requestId)
    if (state === 'downlink_done' || state === 'playback_ended' || state === 'completed') {
      this.log('fallback_job_rejected', { request_id: requestId, reason: 'turn_already_completed' })
      return { status: 'rejected', reason: 'turn_already_completed' }
    }
    if ([...this.jobs.values()].filter(j => !TERMINAL.has(j.state)).length >= this.maxJobs) {
      this.log('fallback_job_rejected', { request_id: requestId, reason: 'queue_full' })
      return { status: 'rejected', reason: 'queue_full' }
    }
    const job = { request_id: requestId, audio_sha256: audioSha256,
      audio_base64: audio.toString('base64'), parent_request_id: parentRequestId,
      context_summary: contextSummary, state: 'queued', accepted_at: this.now(), attempts: 0 }
    this.jobs.set(requestId, job); this.#persist(job)
    this.log('fallback_job_accepted', { request_id: requestId, audio_sha256: audioSha256 })
    void this.drain()
    return { status: 'accepted', state: 'queued' }
  }

  async drain() {
    // A caller that arrives while a drain is active must observe a fresh pass,
    // not merely wait for the pass that may already have inspected the queue.
    // This matters when an owner-release event races the startup/submit kick.
    if (this.drainPromise) {
      await this.drainPromise
      return this.drain()
    }
    this.drainPromise = this.#drainOnce()
    try { await this.drainPromise } finally { this.drainPromise = null; this.#scheduleDeadline() }
  }

  async #drainOnce() {
    if (this.deadlineTimer !== null) { this.clearTimer(this.deadlineTimer); this.deadlineTimer = null }
    try {
      for (const job of this.jobs.values()) {
        if (job.state !== 'queued') continue
        if (this.now() - job.accepted_at >= this.queueTimeoutMs) {
          this.#settle(job, 'timed_out', 'queue_timeout'); continue
        }
        const state = this.#turnState(job.request_id)
        if (state === 'active' || state === 'owner_busy' || this.ownerBusy()) continue
        if (state === 'downlink_done' || state === 'playback_ended' || state === 'completed') {
          this.#settle(job, 'rejected', 'turn_already_completed'); continue
        }
        job.state = 'executing'; job.attempts += 1; this.#persist(job)
        this.log('fallback_job_executing', { request_id: job.request_id, attempt: job.attempts })
        const controller = new AbortController(); this.controllers.set(job.request_id, controller)
        try {
          const result = await this.execute({ requestId: job.request_id,
            audio: Buffer.from(job.audio_base64, 'base64'), audioSha256: job.audio_sha256,
            parentRequestId: job.parent_request_id, contextSummary: job.context_summary,
            signal: controller.signal })
          if (!controller.signal.aborted) this.#settle(job, 'completed', null, result)
        } catch (error) {
          this.#settle(job, controller.signal.aborted ? 'cancelled' : 'failed',
            controller.signal.aborted ? 'cancelled' : (error.code ?? 'upstream_failed'))
        } finally { this.controllers.delete(job.request_id) }
      }
    } finally { /* outer drain installs the next deadline */ }
  }

  dispose() { if (this.deadlineTimer !== null) this.clearTimer(this.deadlineTimer); this.deadlineTimer = null }

  isExecuting() { return [...this.jobs.values()].some(job => job.state === 'executing') }
  cancel(requestId) {
    const job = this.jobs.get(requestId)
    if (!job) return { status: 'not_found' }
    if (TERMINAL.has(job.state)) return { status: 'duplicate', state: job.state }
    if (job.state === 'executing') this.controllers.get(requestId)?.abort()
    else this.#settle(job, 'cancelled', 'cancelled')
    return { status: 'cancelled', state: 'cancelled' }
  }

  get(requestId) { const job = this.jobs.get(requestId); return job ? { ...job, audio_base64: undefined } : null }
  markTurnState(requestId, state) {
    this.turnStates.set(requestId, state)
    const temp = `${this.turnStatesPath}.tmp`; writeFileSync(temp, JSON.stringify(Object.fromEntries(this.turnStates))); renameSync(temp, this.turnStatesPath)
  }
  #turnState(requestId) { return this.turnStates.get(requestId) ?? this.turnState(requestId) }
  #scheduleDeadline() {
    if (this.deadlineTimer !== null) this.clearTimer(this.deadlineTimer)
    const deadlines = [...this.jobs.values()].filter(job => job.state === 'queued')
      .map(job => job.accepted_at + this.queueTimeoutMs)
    if (!deadlines.length) { this.deadlineTimer = null; return }
    const delay = Math.max(0, Math.min(...deadlines) - this.now())
    this.deadlineTimer = this.setTimer(() => { this.deadlineTimer = null; void this.drain() }, delay)
    this.deadlineTimer?.unref?.()
  }
  #settle(job, state, reason, result = null) {
    job.state = state; job.reason = reason; job.result = result; job.settled_at = this.now(); this.#persist(job)
    this.log(`fallback_job_${state}`, { request_id: job.request_id, reason })
  }
  #persist(job) {
    const path = join(this.dir, `${encodeURIComponent(job.request_id)}.json`); const temp = `${path}.tmp`
    writeFileSync(temp, JSON.stringify(job)); renameSync(temp, path)
  }
  #load() {
    let names = []
    try { names = readdirSync(this.dir) } catch { names = [] }
    for (const name of names) {
      if (!name.endsWith('.json')) continue
      try {
        const job = JSON.parse(readFileSync(join(this.dir, name), 'utf8'))
        // The upstream has no idempotency-result lookup. Replaying an
        // interrupted execution could duplicate an already-produced side
        // effect, so fail closed and surface the uncertainty for retry policy
        // rather than falsely claiming exactly-once.
        if (job.state === 'executing') {
          job.state = 'failed'; job.reason = 'execution_outcome_unknown'; job.settled_at = this.now()
          this.#persist(job)
        }
        this.jobs.set(job.request_id, job)
      } catch { /* malformed records fail closed and are not executed */ }
    }
  }
}
