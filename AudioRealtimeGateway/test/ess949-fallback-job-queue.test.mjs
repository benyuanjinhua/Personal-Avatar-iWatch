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

test('active -> queued -> released -> executed exactly once', async () => {
  let state = 'active'; let calls = 0
  const q = new FallbackJobQueue({ stateDir: dir(), turnState: () => state,
    execute: async () => { calls++; return { text: 'ok' } } })
  assert.equal(q.submit({ requestId: 'r1', audio, audioSha256: hash }).status, 'accepted')
  await q.drain(); assert.equal(calls, 0)
  state = 'failed'; await q.drain()
  assert.equal(calls, 1); assert.equal(q.get('r1').state, 'completed')
  await q.drain(); assert.equal(calls, 1)
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

test('executor preserves transcript and background task identity', async () => {
  const transport = { openTurn: ({ responseId, onEvent }) => ({
    appendAudio() {}, commit() {
      onEvent({ type: 'agent.transcript.final', response_id: responseId, role: 'user', content: '问题' })
      onEvent({ type: 'agent.audio.delta', response_id: responseId, sequence: 0, audio: Buffer.from('ack').toString('base64') })
      onEvent({ type: 'agent.transcript.final', response_id: responseId, role: 'assistant', content: '处理中' })
      onEvent({ type: 'agent.task', response_id: responseId, task: { id: 'task-1' } })
    }, close() {},
  }) }
  const result = await createFallbackExecutor({ agentTransport: transport })({ requestId: 'r-task', audio })
  assert.equal(result.task_id, 'task-1'); assert.equal(result.assistant_transcript, '处理中')
  assert.equal(result.user_transcript, '问题'); assert.equal(Buffer.from(result.audio24k_base64, 'base64').toString(), 'ack')
})
