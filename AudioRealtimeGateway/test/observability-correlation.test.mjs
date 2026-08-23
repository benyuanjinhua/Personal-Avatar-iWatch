// ESS-1071 — correlation contract tests.

import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  AGENT_EVENT_MAP,
  assertCorrelated,
  canonicalEvent,
  CORRELATION_FIELDS,
  GATEWAY_EVENT_MAP,
  normalize,
  requiredFields,
} from '../observability/correlation.mjs'

test('normalize maps gateway vocabulary onto canonical fields', () => {
  const normalized = normalize({
    evt: 'uplink_committed',
    request_id: 'r-1', session_id: 's-1', generation: 1,
  })
  assert.equal(normalized.request_id, 'r-1')
  assert.equal(normalized.session_id, 's-1')
  assert.equal(normalized.generation, 1)
  assert.equal(normalized.evt, 'uplink_committed')
})

test('normalize maps qwen-audio-agent vocabulary onto canonical fields', () => {
  const normalized = normalize({
    evt: 'task.completed',
    turnId: 'voice-100-1', sessionId: 'main', taskId: 'task-42', turnGeneration: 2,
  })
  assert.equal(normalized.request_id, 'voice-100-1')
  assert.equal(normalized.session_id, 'main')
  assert.equal(normalized.task_id, 'task-42')
  assert.equal(normalized.generation, 2)
})

test('request_id aliases: turn_id and turnId both normalize to request_id', () => {
  assert.equal(normalize({ turn_id: 't-1' }).request_id, 't-1')
  assert.equal(normalize({ turnId: 't-2' }).request_id, 't-2')
  assert.equal(normalize({ requestId: 't-3' }).request_id, 't-3')
})

test('normalize never mutates its input', () => {
  const input = { evt: 'x', request_id: 'r' }
  normalize(input)
  assert.deepEqual(input, { evt: 'x', request_id: 'r' })
})

test('assertCorrelated flags missing turn fields', () => {
  const normalized = normalize({ evt: 'uplink_committed', request_id: 'r-1' })
  const result = assertCorrelated(normalized, 'turn')
  assert.equal(result.ok, false)
  assert.deepEqual(result.missing.sort(), ['generation', 'session_id'])
})

test('assertCorrelated passes when all turn fields present', () => {
  const normalized = normalize({
    evt: 'uplink_committed', request_id: 'r-1', session_id: 's-1', generation: 1,
  })
  assert.equal(assertCorrelated(normalized, 'turn').ok, true)
})

test('token lifecycle events require no correlation fields', () => {
  const normalized = normalize({ evt: 'token_issued', jti: 'abc' })
  assert.equal(assertCorrelated(normalized, 'token').ok, true)
})

test('frame events require sequence as well as turn fields', () => {
  const missing = normalize({ evt: 'audio.append', request_id: 'r', session_id: 's', generation: 1 })
  const result = assertCorrelated(missing, 'frame')
  assert.equal(result.ok, false)
  assert.deepEqual(result.missing, ['sequence'])
})

test('canonicalEvent maps gateway + agent names, falls back to raw', () => {
  assert.equal(canonicalEvent('uplink_committed'), 'commit')
  assert.equal(canonicalEvent('downlink_done'), 'audio_done')
  assert.equal(canonicalEvent('codex.first_chunk'), 'codex_first_chunk')
  assert.equal(canonicalEvent('segment.flush'), 'segment_flush')
  assert.equal(canonicalEvent('some.unknown.event'), 'some.unknown.event')
  assert.equal(canonicalEvent(null), null)
})

test('CORRELATION_FIELDS lists the six canonical fields', () => {
  assert.deepEqual(CORRELATION_FIELDS, [
    'request_id', 'session_id', 'response_id', 'generation', 'sequence', 'task_id',
  ])
})

test('requiredFields returns the documented shapes', () => {
  assert.deepEqual(requiredFields('token'), [])
  assert.deepEqual(requiredFields('handshake'), ['session_id', 'request_id'])
  assert.deepEqual(requiredFields('task'), ['session_id', 'request_id', 'generation', 'task_id'])
})

test('GATEWAY_EVENT_MAP and AGENT_EVENT_MAP share the canonical vocabulary', () => {
  for (const value of Object.values(GATEWAY_EVENT_MAP)) {
    assert.ok(value in { commit: 1, first_audio: 1, audio_done: 1, turn_error: 1, session_ended: 1, cancel_received: 1, cancel_ack_sent: 1, stale_generation_dropped: 1, duplicate_sequence: 1, announcement_audio_dropped: 1 }, `unknown gateway canonical ${value}`)
  }
  for (const value of Object.values(AGENT_EVENT_MAP)) {
    assert.ok(value in { codex_first_chunk: 1, codex_chunk: 1, segment_flush: 1, tts_first_audio: 1, tool_start: 1, tool_result: 1, stale_generation_dropped: 1, duplicate_sequence: 1 }, `unknown agent canonical ${value}`)
  }
})
