// ESS-1071 — assertion engine (collector) tests.

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { ChainCollector } from '../observability/collector.mjs'

function base(fields = {}) {
  return { session_id: 's-1', ...fields }
}

test('a healthy turn has no violations', () => {
  const collector = new ChainCollector()
  collector.ingest([
    base({ evt: 'uplink_committed', request_id: 'r-1', generation: 1, t: 0 }),
    base({ evt: 'downlink_first_frame', request_id: 'r-1', generation: 1, sequence: 0, t: 40 }),
    base({ evt: 'downlink_done', request_id: 'r-1', generation: 1, final_sequence: 0, t: 80 }),
    base({ evt: 'session_ended', request_id: 'r-1', generation: 1, t: 90 }),
  ])
  const result = collector.summarize()
  assert.equal(result.passed, true)
  assert.deepEqual(result.violations, [])
})

test('silent_end: committed turn closes with no terminal event', () => {
  const collector = new ChainCollector()
  collector.ingest([
    base({ evt: 'uplink_committed', request_id: 'r-1', generation: 1, t: 0 }),
    base({ evt: 'session_ended', request_id: 'r-1', generation: 1, t: 100 }),
  ])
  const violations = collector.violationsFor('silent_end')
  assert.equal(violations.length, 1)
  assert.equal(violations[0].request_id, 'r-1')
})

test('silent_end is not raised when the turn errored', () => {
  const collector = new ChainCollector()
  collector.ingest([
    base({ evt: 'uplink_committed', request_id: 'r-1', generation: 1, t: 0 }),
    base({ evt: 'session_error', request_id: 'r-1', generation: 1, code: 'ERR_UPSTREAM_UNAVAILABLE', t: 100 }),
    base({ evt: 'session_ended', request_id: 'r-1', generation: 1, t: 110 }),
  ])
  assert.equal(collector.violationsFor('silent_end').length, 0)
})

test('silent_end is not raised after a cancel', () => {
  const collector = new ChainCollector()
  collector.ingest([
    base({ evt: 'uplink_committed', request_id: 'r-1', generation: 1, t: 0 }),
    base({ evt: 'cancel_ack_sent', request_id: 'r-1', generation: 1, t: 50 }),
    base({ evt: 'session_ended', request_id: 'r-1', generation: 1, t: 60 }),
  ])
  assert.equal(collector.violationsFor('silent_end').length, 0)
})

test('client-initiated disconnect is not a silent end', () => {
  const collector = new ChainCollector()
  collector.ingest([
    base({ evt: 'uplink_committed', request_id: 'r-1', generation: 1, t: 0 }),
    base({ evt: 'session_ended', request_id: 'r-1', generation: 1, close_code: 1006, reason: 'peer_closed', t: 60 }),
  ])
  assert.equal(collector.violationsFor('silent_end').length, 0)
})

test('premature_done: audio_done while a flushed segment has not drained', () => {
  const collector = new ChainCollector()
  collector.ingest([
    base({ evt: 'uplink_committed', request_id: 'r-1', generation: 1, t: 0 }),
    base({ evt: 'codex.first_chunk', request_id: 'r-1', generation: 1, t: 10 }),
    base({ evt: 'segment.flush', request_id: 'r-1', generation: 1, t: 20 }),
    // no first_audio for this segment, then done
    base({ evt: 'downlink_done', request_id: 'r-1', generation: 1, final_sequence: 0, t: 30 }),
  ])
  const violations = collector.violationsFor('premature_done')
  assert.equal(violations.length, 1)
  assert.equal(violations[0].pending_segments, 1)
})

test('premature_done is cleared when every flushed segment drains before done', () => {
  const collector = new ChainCollector()
  collector.ingest([
    base({ evt: 'uplink_committed', request_id: 'r-1', generation: 1, t: 0 }),
    base({ evt: 'segment.flush', request_id: 'r-1', generation: 1, t: 10 }),
    base({ evt: 'downlink_first_frame', request_id: 'r-1', generation: 1, sequence: 0, t: 40 }),
    base({ evt: 'downlink_done', request_id: 'r-1', generation: 1, final_sequence: 0, t: 50 }),
  ])
  assert.equal(collector.violationsFor('premature_done').length, 0)
})

test('a follow-on segment draining via segment_first_audio clears the pending segment', () => {
  const collector = new ChainCollector()
  collector.ingest([
    base({ evt: 'uplink_committed', request_id: 'r-1', generation: 1, t: 0 }),
    base({ evt: 'downlink_first_frame', request_id: 'r-1', generation: 1, sequence: 0, t: 5 }),
    base({ evt: 'segment.flush', request_id: 'r-1', generation: 1, t: 10 }),
    base({ evt: 'segment_first_frame', request_id: 'r-1', generation: 1, sequence: 1, t: 40 }),
    base({ evt: 'downlink_done', request_id: 'r-1', generation: 1, final_sequence: 1, t: 50 }),
  ])
  assert.equal(collector.violationsFor('premature_done').length, 0)
})

test('cross_session_mixing: task result observed under a different session', () => {
  const collector = new ChainCollector()
  collector.ingest([
    base({ evt: 'tool.started', request_id: 'r-1', generation: 1, task_id: 'task-9', session_id: 's-1', t: 0 }),
    base({ evt: 'tool.result', request_id: 'r-2', generation: 1, task_id: 'task-9', session_id: 's-2', t: 50 }),
  ])
  const violations = collector.violationsFor('cross_session_mixing')
  assert.equal(violations.length, 1)
  assert.equal(violations[0].task_id, 'task-9')
  assert.equal(violations[0].owning_session, 's-1')
  assert.equal(violations[0].observed_session, 's-2')
})

test('missing_correlation: task event missing generation is flagged', () => {
  const collector = new ChainCollector()
  collector.ingest([
    base({ evt: 'tool.started', request_id: 'r-1', task_id: 'task-9' }), // no generation
  ])
  const violations = collector.violationsFor('missing_correlation')
  assert.equal(violations.length, 1)
  assert.deepEqual(violations[0].missing.sort(), ['generation'])
})

test('missing_correlation: task event missing task_id is flagged', () => {
  const collector = new ChainCollector()
  collector.ingest([
    base({ evt: 'tool.started', request_id: 'r-1', generation: 1 }), // no task_id
  ])
  const violations = collector.violationsFor('missing_correlation')
  assert.equal(violations.length, 1)
  assert.deepEqual(violations[0].missing.sort(), ['task_id'])
})

test('missing_correlation: turn event lacking request_id is flagged', () => {
  const collector = new ChainCollector()
  collector.ingest([
    base({ evt: 'uplink_committed', generation: 1 }), // no request_id
  ])
  const violations = collector.violationsFor('missing_correlation')
  assert.equal(violations.length, 1)
  assert.deepEqual(violations[0].missing.sort(), ['request_id'])
})

test('a well-formed task event produces no missing_correlation', () => {
  const collector = new ChainCollector()
  collector.ingest([
    base({ evt: 'tool.started', request_id: 'r-1', generation: 1, task_id: 'task-9' }),
  ])
  assert.equal(collector.violationsFor('missing_correlation').length, 0)
})

// ESS-1071 阻断 2 regression: two sessions reusing a request_id must not
// pollute each other's committed / pendingSegments / terminal state.
test('two sessions sharing a request_id do not cross-pollute turn state', () => {
  const collector = new ChainCollector()
  collector.ingest([
    // Session A: commits, then ends silently (would be silent_end).
    base({ evt: 'uplink_committed', request_id: 'r-1', session_id: 's-a', generation: 1, t: 0 }),
    // Session B: commits, flushes a segment, then closes without done —
    // a separate pending segment that must not leak into A.
    base({ evt: 'uplink_committed', request_id: 'r-1', session_id: 's-b', generation: 1, t: 10 }),
    base({ evt: 'segment.flush', request_id: 'r-1', session_id: 's-b', generation: 1, t: 20 }),
    // A ends: no terminal → its own silent_end.
    base({ evt: 'session_ended', request_id: 'r-1', session_id: 's-a', generation: 1, t: 30 }),
    // B ends: its flushed segment never drained → premature_done at its close.
    base({ evt: 'downlink_done', request_id: 'r-1', session_id: 's-b', generation: 1, final_sequence: 0, t: 40 }),
  ])

  const silent = collector.violationsFor('silent_end')
  assert.equal(silent.length, 1)
  assert.equal(silent[0].session_id, 's-a')

  const premature = collector.violationsFor('premature_done')
  assert.equal(premature.length, 1)
  assert.equal(premature[0].session_id, 's-b')
  assert.equal(premature[0].pending_segments, 1)
})

test('token events never trigger missing_correlation', () => {
  const collector = new ChainCollector()
  collector.ingest([
    { evt: 'token_issued', jti: 'abcdef01' },
  ])
  assert.equal(collector.violationsFor('missing_correlation').length, 0)
})

test('service-level events (no turn scope) never trigger missing_correlation', () => {
  const collector = new ChainCollector()
  collector.ingest([
    { evt: 'gateway_ready', bind: '127.0.0.1', port: 1 },
    { evt: 'http_rejected', code: 'ERR_NONCE_REPLAYED', path: '/v1/realtime/session-token' },
  ])
  assert.equal(collector.violationsFor('missing_correlation').length, 0)
  assert.equal(collector.summarize().passed, true)
})

test('collector feeds the metrics accumulator for the same stream', () => {
  const collector = new ChainCollector()
  collector.ingest([
    base({ evt: 'uplink_committed', request_id: 'r-1', generation: 1, t: 100 }),
    base({ evt: 'codex.first_chunk', request_id: 'r-1', generation: 1, t: 300 }),
  ])
  const { metrics } = collector.summarize()
  assert.equal(metrics.turns[0].codex_first_chunk_ms, 200)
})
