import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { FallbackJobQueue } from '../fallback-job-queue.mjs'
import { createFallbackExecutor } from '../fallback-executor.mjs'

const audio = Buffer.from('safe full-file audio')
const hash = createHash('sha256').update(audio).digest('hex')
const dir = () => mkdtempSync(join(tmpdir(), 'ess949-'))

test('active -> queued -> released -> executes once during normal operation', async () => {
  let state = 'active'; let calls = 0
  const q = new FallbackJobQueue({ stateDir: dir(), turnState: () => state,
    execute: async () => { calls++; return { text: 'ok' } } })
  assert.equal(q.submit({ requestId: 'r1', audio, audioSha256: hash }).status, 'accepted')
  await q.drain(); assert.equal(calls, 0)
  state = 'failed'; await q.drain()
  assert.equal(calls, 1); assert.equal(q.get('r1').state, 'completed')
  await q.drain(); assert.equal(calls, 1)
})

test('global owner lease blocks a different fallback request until release', async () => {
  let ownerBusy = true; let calls = 0
  const q = new FallbackJobQueue({ stateDir: dir(), turnState: () => 'failed',
    ownerBusy: () => ownerBusy, execute: async () => { calls++; return { text: 'ok' } } })
  q.submit({ requestId: 'fallback-B', audio, audioSha256: hash })
  await q.drain(); assert.equal(calls, 0)
  ownerBusy = false; await q.drain()
  assert.equal(calls, 1); assert.equal(q.get('fallback-B').state, 'completed')
})

test('completed turn is rejected with explicit reason', () => {
  const q = new FallbackJobQueue({ stateDir: dir(), turnState: () => 'playback_ended', execute: async () => {} })
  assert.deepEqual(q.submit({ requestId: 'r2', audio, audioSha256: hash }),
    { status: 'rejected', reason: 'turn_already_completed' })
})

test('completed turn rejection survives a Gateway restart', () => {
  const stateDir = dir()
  const first = new FallbackJobQueue({ stateDir, execute: async () => {} })
  first.markTurnState('r-complete', 'downlink_done')
  const restarted = new FallbackJobQueue({ stateDir, execute: async () => {} })
  assert.equal(restarted.submit({ requestId: 'r-complete', audio, audioSha256: hash }).reason, 'turn_already_completed')
})

test('duplicate is idempotent and conflicting hash is rejected', () => {
  const q = new FallbackJobQueue({ stateDir: dir(), turnState: () => 'active', execute: async () => {} })
  q.submit({ requestId: 'r3', audio, audioSha256: hash })
  assert.equal(q.submit({ requestId: 'r3', audio, audioSha256: hash }).status, 'duplicate')
  const other = Buffer.from('other'); const otherHash = createHash('sha256').update(other).digest('hex')
  assert.equal(q.submit({ requestId: 'r3', audio: other, audioSha256: otherHash }).reason, 'idempotency_conflict')
})

test('gateway restart recovers queued job without duplicate execution', async () => {
  const stateDir = dir(); let calls = 0
  const first = new FallbackJobQueue({ stateDir, turnState: () => 'active', execute: async () => { calls++ } })
  first.submit({ requestId: 'r4', audio, audioSha256: hash }); await first.drain()
  const second = new FallbackJobQueue({ stateDir, turnState: () => 'failed', execute: async () => { calls++ } })
  await second.drain(); await second.drain()
  assert.equal(calls, 1); assert.equal(second.get('r4').state, 'completed')
})

test('gateway restart autonomously resumes queued work without an external event', async () => {
  const stateDir = dir(); let calls = 0
  const first = new FallbackJobQueue({ stateDir, turnState: () => 'active', execute: async () => { calls++ } })
  first.submit({ requestId: 'r-autokick', audio, audioSha256: hash }); await first.drain(); first.dispose()
  const restarted = new FallbackJobQueue({ stateDir, turnState: () => 'failed', execute: async () => { calls++ } })
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(calls, 1); assert.equal(restarted.get('r-autokick').state, 'completed')
  restarted.dispose()
})

test('gateway restart requeues an execution with unknown outcome under at-least-once policy', async () => {
  const stateDir = dir(); let calls = 0
  const first = new FallbackJobQueue({ stateDir, execute: () => new Promise(() => { calls++ }) })
  first.submit({ requestId: 'r-crashed-executing', audio, audioSha256: hash })
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(first.get('r-crashed-executing').state, 'executing')
  const restarted = new FallbackJobQueue({ stateDir, execute: async () => { calls++ } })
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(calls, 2)
  assert.equal(restarted.get('r-crashed-executing').state, 'completed')
  assert.equal(restarted.get('r-crashed-executing').attempts, 2)
  restarted.dispose()
})

test('queued job times out autonomously when no owner event arrives', async () => {
  let calls = 0
  const q = new FallbackJobQueue({ stateDir: dir(), queueTimeoutMs: 15,
    ownerBusy: () => true, execute: async () => { calls++ } })
  q.submit({ requestId: 'r-autotimeout', audio, audioSha256: hash })
  await new Promise(resolve => setTimeout(resolve, 30))
  assert.equal(calls, 0); assert.equal(q.get('r-autotimeout').state, 'timed_out')
  q.dispose()
})

test('queue timeout settles explicitly without upstream execution', async () => {
  let now = 1_000; let calls = 0
  const q = new FallbackJobQueue({ stateDir: dir(), now: () => now, queueTimeoutMs: 50,
    turnState: () => 'owner_busy', execute: async () => { calls++ } })
  q.submit({ requestId: 'r5', audio, audioSha256: hash }); now += 51; await q.drain()
  assert.equal(calls, 0); assert.equal(q.get('r5').state, 'timed_out')
  assert.equal(q.get('r5').reason, 'queue_timeout')
})

test('upstream disconnect settles failed and never silently retries', async () => {
  let calls = 0
  const q = new FallbackJobQueue({ stateDir: dir(), turnState: () => 'failed', execute: async () => {
    calls++; throw Object.assign(new Error('disconnect'), { code: 'gateway_disconnected' })
  } })
  q.submit({ requestId: 'r6', audio, audioSha256: hash }); await q.drain(); await q.drain()
  assert.equal(calls, 1); assert.equal(q.get('r6').reason, 'gateway_disconnected')
})

test('cancel aborts an executing upstream job and records a terminal state', async () => {
  let release
  const q = new FallbackJobQueue({ stateDir: dir(), execute: ({ signal }) => new Promise((resolve, reject) => {
    release = () => resolve({ text: 'too late' })
    signal.addEventListener('abort', () => reject(Object.assign(new Error('cancelled'), { code: 'cancelled' })))
  }) })
  q.submit({ requestId: 'r-cancel', audio, audioSha256: hash })
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(q.cancel('r-cancel').status, 'cancelled')
  await q.drain(); release?.()
  assert.equal(q.get('r-cancel').state, 'cancelled')
})

test('executor preserves transcript and background task identity', async () => {
  let firstAppend
  const transport = { openTurn: ({ responseId, onEvent }) => ({
    appendAudio(frame) { firstAppend ??= frame }, commit() {
      onEvent({ type: 'agent.transcript.final', response_id: responseId, role: 'user', content: '问题' })
      onEvent({ type: 'agent.audio.delta', response_id: responseId, sequence: 0, audio: Buffer.from('ack').toString('base64') })
      onEvent({ type: 'agent.transcript.final', response_id: responseId, role: 'assistant', content: '处理中' })
      onEvent({ type: 'agent.task', response_id: responseId, task: { id: 'task-1' } })
    }, close() {},
  }) }
  const result = await createFallbackExecutor({ agentTransport: transport })({ requestId: 'r-task', audio,
    parentRequestId: 'parent-1', contextSummary: 'prior context' })
  assert.equal(result.task_id, 'task-1'); assert.equal(result.assistant_transcript, '处理中')
  assert.equal(result.user_transcript, '问题'); assert.equal(Buffer.from(result.audio24k_base64, 'base64').toString(), 'ack')
  assert.equal(firstAppend.parentRequestId, 'parent-1'); assert.equal(firstAppend.contextSummary, 'prior context')
})
