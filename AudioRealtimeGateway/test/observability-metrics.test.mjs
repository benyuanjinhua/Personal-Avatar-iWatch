// ESS-1071 — metrics accumulator tests.

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { MetricsAccumulator, turnKey } from '../observability/metrics.mjs'

test('turnKey is a composite of session + request + generation', () => {
  assert.notEqual(turnKey('r-1', 's-1', 1), turnKey('r-1', 's-2', 1))
  assert.notEqual(turnKey('r-1', 's-1', 1), turnKey('r-1', 's-1', 2))
  assert.equal(turnKey('r-1', 's-1', 1), turnKey('r-1', 's-1', 1))
})

test('codex_first_chunk_ms = first Codex chunk − commit', () => {
  const acc = new MetricsAccumulator()
  acc.push({ evt: 'uplink_committed', request_id: 'r-1', session_id: 's-1', generation: 1, t: 100 })
  acc.push({ evt: 'codex.first_chunk', turnId: 'r-1', sessionId: 's-1', turnGeneration: 1, t: 350 })
  const summary = acc.summarize('r-1')
  assert.equal(summary.codex_first_chunk_ms, 250)
})

test('chunk_to_segment_ms and segment_to_first_audio_ms accumulate per segment', () => {
  const acc = new MetricsAccumulator()
  acc.push({ evt: 'uplink_committed', request_id: 'r-1', session_id: 's-1', generation: 1, t: 0 })
  acc.push({ evt: 'codex.first_chunk', request_id: 'r-1', session_id: 's-1', generation: 1, t: 100 })
  acc.push({ evt: 'codex.chunk', request_id: 'r-1', session_id: 's-1', generation: 1, t: 200 })
  acc.push({ evt: 'segment.flush', request_id: 'r-1', session_id: 's-1', generation: 1, t: 250 })
  acc.push({ evt: 'downlink_first_frame', request_id: 'r-1', session_id: 's-1', generation: 1, sequence: 0, t: 400 })
  acc.push({ evt: 'segment.flush', request_id: 'r-1', session_id: 's-1', generation: 1, t: 500 })
  acc.push({ evt: 'segment_first_frame', request_id: 'r-1', session_id: 's-1', generation: 1, sequence: 1, t: 620 })

  const summary = acc.summarize('r-1')
  // segment 1: flush(250) − last chunk(200) = 50; audio(400) − flush(250) = 150
  // segment 2: flush(500) − last chunk(200) = 300; audio(620) − flush(500) = 120
  assert.deepEqual(summary.chunk_to_segment_ms, [50, 300])
  assert.deepEqual(summary.segment_to_first_audio_ms, [150, 120])
})

test('commit_to_first_tool_audio_ms measures commit → first tool-answer audio, not the ack', () => {
  const acc = new MetricsAccumulator()
  acc.push({ evt: 'uplink_committed', request_id: 'r-1', session_id: 's-1', generation: 1, t: 1000 })
  // acknowledgement segment: turn's first frame, before the tool starts.
  acc.push({ evt: 'downlink_first_frame', request_id: 'r-1', session_id: 's-1', generation: 1, sequence: 0, t: 1050 })
  acc.push({ evt: 'tool.started', request_id: 'r-1', session_id: 's-1', generation: 1, task_id: 'task-1', t: 1200 })
  acc.push({ evt: 'codex.first_chunk', request_id: 'r-1', session_id: 's-1', generation: 1, t: 1500 })
  acc.push({ evt: 'segment.flush', request_id: 'r-1', session_id: 's-1', generation: 1, t: 1600 })
  // tool answer's first frame (follow-on segment), not the acknowledgement.
  acc.push({ evt: 'segment_first_frame', request_id: 'r-1', session_id: 's-1', generation: 1, sequence: 1, t: 1900 })
  const summary = acc.summarize('r-1')
  assert.equal(summary.commit_to_first_tool_audio_ms, 900) // 1900 − 1000
})

// ESS-1082 阻断 1 反例：普通多段回答（无 tool.started）不得产出工具首音频指标。
test('a non-tool multi-segment answer leaves commit_to_first_tool_audio_ms null', () => {
  const acc = new MetricsAccumulator()
  acc.push({ evt: 'uplink_committed', request_id: 'r-1', session_id: 's-1', generation: 1, t: 0 })
  acc.push({ evt: 'downlink_first_frame', request_id: 'r-1', session_id: 's-1', generation: 1, sequence: 0, t: 20 })
  acc.push({ evt: 'segment_first_frame', request_id: 'r-1', session_id: 's-1', generation: 1, sequence: 1, t: 80 })
  const summary = acc.summarize('r-1')
  assert.equal(summary.commit_to_first_tool_audio_ms, null)
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
  acc.push({ evt: 'stale_generation_dropped', request_id: 'r-1', session_id: 's-1', generation: 1, t: 10 })
  acc.push({ evt: 'stale_generation_dropped', request_id: 'r-1', session_id: 's-1', generation: 1, t: 11 })
  acc.push({ evt: 'merged_segment', request_id: 'r-1', session_id: 's-1', generation: 1, t: 12 })

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
  acc.push({ evt: 'queue_depth', request_id: 'r-1', session_id: 's-1', generation: 1, depth: 3, t: 0 })
  acc.push({ evt: 'queue_depth', request_id: 'r-1', session_id: 's-1', generation: 1, depth: 7, t: 1 })
  acc.push({ evt: 'queue_depth', request_id: 'r-2', session_id: 's-2', generation: 1, depth: 2, t: 2 })
  assert.equal(acc.summarize('r-1').max_queue_depth, 7)
  assert.equal(acc.summarize('r-2').max_queue_depth, 2)
  assert.equal(acc.summarizeAll().max_queue_depth, 7)
})

test('ISO ts is parsed when numeric t is absent', () => {
  const acc = new MetricsAccumulator()
  acc.push({ evt: 'uplink_committed', request_id: 'r-1', session_id: 's-1', generation: 1, ts: '2026-08-22T00:00:00.000Z' })
  acc.push({ evt: 'codex.first_chunk', request_id: 'r-1', session_id: 's-1', generation: 1, ts: '2026-08-22T00:00:00.250Z' })
  assert.equal(acc.summarize('r-1').codex_first_chunk_ms, 250)
})

test('records without a timeline are skipped, not thrown', () => {
  const acc = new MetricsAccumulator()
  acc.push({ evt: 'codex.first_chunk', request_id: 'r-1', session_id: 's-1' })
  assert.equal(acc.summarize('r-1'), null)
})

// ESS-1071 阻断 2 regression: two sessions sharing a request_id keep
// independent turn state, metrics and terminal flags.
test('two sessions sharing a request_id keep independent turns', () => {
  const acc = new MetricsAccumulator()
  // Session A commits and streams a tool answer.
  acc.push({ evt: 'uplink_committed', request_id: 'r-1', session_id: 's-a', generation: 1, t: 0 })
  acc.push({ evt: 'downlink_first_frame', request_id: 'r-1', session_id: 's-a', generation: 1, sequence: 0, t: 5 })
  acc.push({ evt: 'tool.started', request_id: 'r-1', session_id: 's-a', generation: 1, task_id: 'task-a', t: 10 })
  acc.push({ evt: 'codex.first_chunk', request_id: 'r-1', session_id: 's-a', generation: 1, t: 20 })
  acc.push({ evt: 'segment_first_frame', request_id: 'r-1', session_id: 's-a', generation: 1, sequence: 1, t: 30 })
  acc.push({ evt: 'downlink_done', request_id: 'r-1', session_id: 's-a', generation: 1, t: 40 })

  // Session B reuses request_id but is a plain direct answer.
  acc.push({ evt: 'uplink_committed', request_id: 'r-1', session_id: 's-b', generation: 1, t: 100 })
  acc.push({ evt: 'downlink_first_frame', request_id: 'r-1', session_id: 's-b', generation: 1, sequence: 0, t: 110 })
  acc.push({ evt: 'downlink_done', request_id: 'r-1', session_id: 's-b', generation: 1, t: 120 })

  const a = acc.summarize('r-1', 's-a')
  const b = acc.summarize('r-1', 's-b')

  assert.equal(a.codex_first_chunk_ms, 20)
  assert.equal(a.commit_to_first_tool_audio_ms, 30)
  assert.equal(a.audio_done, true)

  assert.equal(b.codex_first_chunk_ms, null)
  assert.equal(b.commit_to_first_tool_audio_ms, null)
  assert.equal(b.audio_done, true)

  assert.equal(acc.summarizeAll().turns.length, 2)
})

// ESS-1082 阻断 2（多代汇总）：同一 session/request 的多个 generation 各自独立，
// summarizeAll 不得重复第一代、遗漏后续代次。
test('multiple generations of the same session/request are summarized independently', () => {
  const acc = new MetricsAccumulator()
  acc.push({ evt: 'uplink_committed', request_id: 'r-1', session_id: 's-1', generation: 1, t: 0 })
  acc.push({ evt: 'downlink_first_frame', request_id: 'r-1', session_id: 's-1', generation: 1, sequence: 0, t: 10 })
  acc.push({ evt: 'downlink_done', request_id: 'r-1', session_id: 's-1', generation: 1, t: 20 })

  acc.push({ evt: 'uplink_committed', request_id: 'r-1', session_id: 's-1', generation: 2, t: 100 })
  acc.push({ evt: 'downlink_first_frame', request_id: 'r-1', session_id: 's-1', generation: 2, sequence: 0, t: 110 })
  acc.push({ evt: 'downlink_done', request_id: 'r-1', session_id: 's-1', generation: 2, t: 120 })

  const g1 = acc.summarize('r-1', 's-1', 1)
  const g2 = acc.summarize('r-1', 's-1', 2)
  assert.equal(g1.audio_done, true)
  assert.equal(g2.audio_done, true)
  assert.equal(g1.codex_first_chunk_ms, null)
  assert.equal(g2.codex_first_chunk_ms, null)

  const all = acc.summarizeAll()
  assert.equal(all.turns.length, 2)
  const gens = all.turns.map(t => t.generation).sort((a, b) => a - b)
  assert.deepEqual(gens, [1, 2])
})
