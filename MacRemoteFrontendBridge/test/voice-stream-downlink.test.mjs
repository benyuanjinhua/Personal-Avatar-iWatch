import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { VoiceStreamDownlink } from '../voice-stream-downlink.mjs'
import { QwenRealtimeSessionSupervisor } from '../supervisor.mjs'
import { PendingAnnouncementStreams } from '../pending-announcement-streams.mjs'

const requestId = 'req_test'
const delta = n => Buffer.from(`delta-${n}`)

function harness(overrides = {}) {
  const messages = []
  const logs = []
  const stream = new VoiceStreamDownlink({
    enabled: true,
    now: () => 1_800_000_000_000,
    send: (_, message) => { messages.push(message); return true },
    log: entry => logs.push(entry),
    ...overrides,
  })
  return { stream, messages, logs }
}

describe('VoiceStreamDownlink', () => {
  it('is default-off and emits nothing', () => {
    const messages = []
    const stream = new VoiceStreamDownlink({ send: (_, m) => { messages.push(m); return true } })
    assert.deepEqual(stream.append({ requestId, audio: delta(0) }), { status: 'disabled' })
    assert.equal(messages.length, 0)
  })

  it('sends the first and subsequent deltas immediately, then EOS', () => {
    const { stream, messages, logs } = harness()
    assert.equal(stream.append({ requestId, responseId: 'resp-1', audio: delta(0) }).status, 'sent')
    assert.equal(stream.append({ requestId, audio: delta(1) }).status, 'sent')
    assert.equal(stream.finish(requestId).status, 'ended')
    assert.deepEqual(messages.map(m => m.chunk.sequence), [0, 1, 2])
    assert.deepEqual(messages.map(m => m.chunk.end_of_stream), [false, false, true])
    assert.equal(messages[0].chunk.payload, delta(0).toString('base64'))
    assert.equal(logs.filter(l => l.evt === 'voice_stream_first_chunk').length, 1)
  })

  it('reorders within the window and de-duplicates', () => {
    const { stream, messages } = harness()
    assert.equal(stream.append({ requestId, sequence: 1, audio: delta(1) }).status, 'accepted')
    assert.equal(stream.append({ requestId, sequence: 1, audio: delta(1) }).status, 'duplicate')
    assert.equal(stream.append({ requestId, sequence: 0, audio: delta(0) }).sent, 2)
    assert.deepEqual(messages.map(m => m.chunk.sequence), [0, 1])
  })

  it('falls back once for gaps, backpressure, interruption, and unavailable downlink', () => {
    const gap = harness({ maxSequenceWindow: 1 })
    assert.equal(gap.stream.append({ requestId, sequence: 2, audio: delta(2) }).status, 'fallback')
    assert.equal(gap.stream.append({ requestId, audio: delta(0) }).status, 'already_fell_back')

    const pressure = harness({ maxBufferedBytes: 2 })
    assert.equal(pressure.stream.append({ requestId, sequence: 1, audio: delta(1) }).reason, 'backpressure')

    const interrupted = harness()
    interrupted.stream.append({ requestId, sequence: 1, audio: delta(1) })
    assert.equal(interrupted.stream.finish(requestId).reason, 'stream_ended_with_gap')
    assert.equal(interrupted.logs.filter(l => l.evt === 'voice_stream_fallback').length, 1)

    const unavailable = harness({ send: () => false })
    assert.equal(unavailable.stream.append({ requestId, audio: delta(0) }).reason, 'downlink_unavailable')
  })

  it('accepts explicit client-requested per-turn fallback only once', () => {
    const { stream, logs } = harness()
    assert.equal(stream.fallback(requestId).retry, 1)
    assert.equal(stream.fallback(requestId).status, 'already_fell_back')
    assert.equal(logs.length, 1)
  })

  it('arms a bounded gap timer and falls back exactly once on timeout', () => {
    let callback = null
    let cleared = 0
    const { stream, logs } = harness({
      gapTimeoutMs: 25,
      setTimer: fn => { callback = fn; return { timer: true } },
      clearTimer: () => { cleared += 1 },
    })
    assert.equal(stream.append({ requestId, sequence: 1, audio: delta(1) }).status, 'accepted')
    assert.equal(typeof callback, 'function')
    callback()
    assert.equal(logs.filter(l => l.reason === 'gap_timed_out').length, 1)
    assert.equal(stream.gapTimedOut(requestId).status, 'already_fell_back')
    assert.equal(cleared, 0, 'fired timer clears its own handle before fallback')
  })

  it('cancels the gap timer when the missing chunk arrives', () => {
    let cleared = 0
    const { stream, messages } = harness({
      setTimer: () => ({ timer: true }),
      clearTimer: () => { cleared += 1 },
    })
    stream.append({ requestId, sequence: 1, audio: delta(1) })
    assert.equal(stream.append({ requestId, sequence: 0, audio: delta(0) }).sent, 2)
    assert.equal(cleared, 1)
    assert.deepEqual(messages.map(m => m.chunk.sequence), [0, 1])
  })
})

describe('Realtime audio.delta ownership routing', () => {
  it('routes direct turn deltas and EOS with the current request_id', () => {
    const supervisor = new QwenRealtimeSessionSupervisor({ log: () => {} })
    const seen = []
    supervisor.currentTurn = { label: 'req_direct', onAudioDelta: () => {}, onEvent: () => {} }
    supervisor.onTurnAudioDelta = item => seen.push(['delta', item.requestId])
    supervisor.onTurnAudioDone = item => seen.push(['done', item.requestId])
    supervisor.handleServerEvent({ type: 'audio.delta', responseId: 'resp_direct', audio: delta(0).toString('base64'), sampleRate: 24_000 })
    supervisor.handleServerEvent({ type: 'audio.done', responseId: 'resp_direct' })
    assert.deepEqual(seen, [['delta', 'req_direct'], ['done', 'req_direct']])
  })

  it('routes announcement deltas only through their task capture', () => {
    const supervisor = new QwenRealtimeSessionSupervisor({ log: () => {}, announcementIdleMs: 60_000 })
    const seen = []
    supervisor.onAnnouncementAudioDelta = ({ capture }) => seen.push(['delta', capture.taskId])
    supervisor.onAnnouncementAudioDone = ({ capture }) => seen.push(['done', capture.taskId])
    supervisor.handleServerEvent({ type: 'response.started', origin: 'announcement', responseId: 'resp_ann', taskId: 'task_42' })
    supervisor.handleServerEvent({ type: 'audio.delta', responseId: 'resp_ann', audio: delta(0).toString('base64'), sampleRate: 24_000 })
    supervisor.handleServerEvent({ type: 'audio.done', responseId: 'resp_ann' })
    assert.deepEqual(seen, [['delta', 'task_42'], ['done', 'task_42']])
  })
})

describe('announcement stream late ledger binding', () => {
  it('replays the first delta and EOS in order after task.accepted binds request_id', () => {
    const events = []
    const pending = new PendingAnnouncementStreams({
      enabled: true,
      append: item => events.push(['delta', item.requestId, Buffer.from(item.audio, 'base64').toString()]),
      finish: requestId => events.push(['done', requestId]),
      fallback: (requestId, reason) => events.push(['fallback', requestId, reason]),
    })
    // Exact regression order: audio.delta -> no ledger task binding -> task.accepted.
    assert.equal(pending.push({ taskId: 'task_late', responseId: 'resp_ann', audio: delta(0).toString('base64') }).status, 'pending')
    assert.equal(pending.end('task_late').status, 'pending')
    assert.deepEqual(events, [])
    assert.deepEqual(pending.bind('task_late', 'req_late'), { status: 'replayed', chunks: 1, ended: true })
    assert.deepEqual(events, [['delta', 'req_late', 'delta-0'], ['done', 'req_late']])
    pending.close()
  })

  it('falls back exactly once with request_id when pending binding times out', () => {
    let timeout
    const events = []
    const logs = []
    const pending = new PendingAnnouncementStreams({
      enabled: true,
      ttlMs: 25,
      setTimer: fn => { timeout = fn; return { unref() {} } },
      clearTimer: () => {},
      append: () => assert.fail('expired chunk must not be replayed'),
      finish: () => assert.fail('expired EOS must not be replayed'),
      fallback: (requestId, reason) => events.push([requestId, reason]),
      log: entry => logs.push(entry),
    })
    pending.push({ taskId: 'task_late', responseId: 'resp_ann', audio: delta(0).toString('base64') })
    timeout()
    assert.equal(pending.bind('task_late', 'req_late').status, 'fallback')
    assert.deepEqual(events, [['req_late', 'pending_binding_timed_out']])
    assert.equal(logs.find(item => item.reason === 'pending_binding_timed_out').task_id, 'task_late')
    assert.equal(pending.bind('task_late', 'req_late').status, 'empty')
  })

  it('is a no-op while streaming is disabled', () => {
    const pending = new PendingAnnouncementStreams({ append: () => assert.fail(), finish: () => assert.fail(), fallback: () => assert.fail() })
    assert.equal(pending.push({ taskId: 'task', audio: delta(0).toString('base64') }).status, 'disabled')
    assert.equal(pending.end('task').status, 'disabled')
    assert.equal(pending.bind('task', 'req').status, 'empty')
  })
})
