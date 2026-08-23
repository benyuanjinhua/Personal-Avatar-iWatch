// ESS-1071 — metrics accumulator tests.

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { MetricsAccumulator } from '../observability/metrics.mjs'

test('codex_first_chunk_ms = first Codex chunk − commit', () => {
  const acc = new MetricsAccumulator()
  acc.push({ evt: 'uplink_committed', request_id: 'r-1', session_id: 's-1', generation: 1, t: 100 })
  acc.push({ evt: 'codex.first_chunk', turnId: 'r-1', sessionId: 's-1', t: 350 })
  const summary = acc.summarize('r-1')
  assert.equal(summary.codex_first_chunk_ms, 250)
})

test('chunk_to_segment_ms and segment_to_first_audio_ms accumulate per segment', () => {
  const acc = new MetricsAccumulator()
  acc.push({ evt: 'uplink_committed', request_id: 'r-1', session_id: 's-1', generation: 1, t: 0 })
  acc.push({ evt: 'codex.first_chunk', request_id: 'r-1', session_id: 's-1', t: 100 })
  acc.push({ evt: 'codex.chunk', request_id: 'r-1', session_id: 's-1', t: 200 })
  acc.push({ evt: 'segment.flush', request_id: 'r-1', session_id: 's-1', t: 250 })
  acc.push({ evt: 'downlink_first_frame', request_id: 'r-1', session_id: 's-1', generation: 1, sequence: 0, t: 400 })
  acc.push({ evt: 'segment.flush', request_id: 'r-1', session_id: 's-1', t: 500 })
  acc.push({ evt: 'downlink_first_frame', request_id: 'r-1', session_id: 's-1', generation: 1, sequence: 1, t: 620 })

  const summary = acc.summarize('r-1')
  // segment 1: flush(250) − last chunk(200) = 50; audio(400) − flush(250) = 150
  // segment 2: flush(500) − last chunk(200) = 300; audio(620) − flush(500) = 120
  assert.deepEqual(summary.chunk_to_segment_ms, [50, 300])
  assert.deepEqual(summary.segment_to_first_audio_ms, [150, 120])
})

test('commit_to_first_tool_audio_ms measures from commit to first tool audio', () => {
  const acc = new MetricsAccumulator()
  acc.push({ evt: 'uplink_committed', request_id: 'r-1', session_id: 's-1', generation: 1, t: 1000 })
  acc.push({ evt: 'tool.started', request_id: 'r-1', session_id: 's-1', task_id: 'task-1', t: 1200 })
  acc.push({ evt: 'codex.first_chunk', request_id: 'r-1', session_id: 's-1', t: 1500 })
  acc.push({ evt: 'segment.flush', request_id: 'r-1', session_id: 's-1', t: 1600 })
  acc.push({ evt: 'downlink_first_frame', request_id: 'r-1', session_id: 's-1', generation: 1, sequence: 0, t: 1900 })
  const summary = acc.summarize('r-1')
  assert.equal(summary.commit_to_first_tool_audio_ms, 900)
})

test('direct answer (no Codex) leaves codex_first_chunk_ms null', () => {
  const acc = new MetricsAccumulator()
  acc.push({ evt: 'uplink_committed', request_id: 'r-1', session_id: 's-1', generation: 1, t: 0 })
  acc.push({ evt: 'downlink_first_frame', request_id: 'r-1', session_id: 's-1', generation: 1, sequence: 0, t: 50 })
  acc.push({ evt: 'downlink_done', request_id: 'r-1', session_id: 's-1', generation: 1, t: 80 })
  const summary = acc.summarize('r-1')
  assert.equal(summary.codex_first_chunk_ms, null)
  assert.equal(summary.commit_to_first_tool_audio_ms, null)
  assert.equal(summary.audio_done, true)
})

test('counters: dedup, stale-generation, merge accumulate per turn and globally', () => {
  const acc = new MetricsAccumulator()
  for (let i = 0; i < 3; i += 1) {
    acc.push({ evt: 'duplicate_sequence', request_id: 'r-1', session_id: 's-1', generation: 1, sequence: 0, t: i })
  }
  acc.push({ evt: 'stale_generation_dropped', request_id: 'r-1', session_id: 's-1', t: 10 })
  acc.push({ evt: 'stale_generation_dropped', request_id: 'r-1', session_id: 's-1', t: 11 })
  acc.push({ evt: 'merged_segment', request_id: 'r-1', session_id: 's-1', t: 12 })

  const summary = acc.summarize('r-1')
  assert.equal(summary.duplicate_sequences, 3)
  assert.equal(summary.stale_generation_dropped, 2)
  assert.equal(summary.merged_segments, 1)

  const all = acc.summarizeAll()
  assert.equal(all.duplicate_sequences, 3)
  assert.equal(all.stale_generation_dropped, 2)
  assert.equal(all.merged_segments, 1)
})

test('queue depth tracks the max per turn and globally', () => {
  const acc = new MetricsAccumulator()
  acc.push({ evt: 'queue_depth', request_id: 'r-1', session_id: 's-1', depth: 3, t: 0 })
  acc.push({ evt: 'queue_depth', request_id: 'r-1', session_id: 's-1', depth: 7, t: 1 })
  acc.push({ evt: 'queue_depth', request_id: 'r-2', session_id: 's-2', depth: 2, t: 2 })
  assert.equal(acc.summarize('r-1').max_queue_depth, 7)
  assert.equal(acc.summarize('r-2').max_queue_depth, 2)
  assert.equal(acc.summarizeAll().max_queue_depth, 7)
})

test('ISO ts is parsed when numeric t is absent', () => {
  const acc = new MetricsAccumulator()
  acc.push({ evt: 'uplink_committed', request_id: 'r-1', session_id: 's-1', generation: 1, ts: '2026-08-22T00:00:00.000Z' })
  acc.push({ evt: 'codex.first_chunk', request_id: 'r-1', session_id: 's-1', ts: '2026-08-22T00:00:00.250Z' })
  assert.equal(acc.summarize('r-1').codex_first_chunk_ms, 250)
})

test('records without a timeline are skipped, not thrown', () => {
  const acc = new MetricsAccumulator()
  acc.push({ evt: 'codex.first_chunk', request_id: 'r-1', session_id: 's-1' })
  assert.equal(acc.summarize('r-1'), null)
})
