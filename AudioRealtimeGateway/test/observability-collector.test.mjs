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

test('cross_session_mixing: task result observed under a different session', () => {
  const collector = new ChainCollector()
  collector.ingest([
    base({ evt: 'tool.started', request_id: 'r-1', task_id: 'task-9', session_id: 's-1', t: 0 }),
    base({ evt: 'tool.result', request_id: 'r-2', task_id: 'task-9', session_id: 's-2', t: 50 }),
  ])
  const violations = collector.violationsFor('cross_session_mixing')
  assert.equal(violations.length, 1)
  assert.equal(violations[0].task_id, 'task-9')
  assert.equal(violations[0].owning_session, 's-1')
  assert.equal(violations[0].observed_session, 's-2')
})

test('missing_correlation: turn event lacking generation is flagged', () => {
  const collector = new ChainCollector()
  collector.ingest([
    base({ evt: 'uplink_committed', request_id: 'r-1' }), // no generation
  ])
  const violations = collector.violationsFor('missing_correlation')
  assert.equal(violations.length, 1)
  assert.deepEqual(violations[0].missing.sort(), ['generation'])
})

test('token events never trigger missing_correlation', () => {
  const collector = new ChainCollector()
  collector.ingest([
    { evt: 'token_issued', jti: 'abcdef01' },
  ])
  assert.equal(collector.violationsFor('missing_correlation').length, 0)
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
