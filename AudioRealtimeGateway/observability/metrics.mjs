// ESS-1071 — metric registry + accumulator for the Realtime chain.
//
// The four latency metrics named in the issue are computed from the canonical
// events pinned in correlation.mjs:
//
//   codex_first_chunk_ms      t(codex_first_chunk) − t(commit)
//   chunk_to_segment_ms       t(segment_flush) − t(codex_chunk)   (per segment)
//   segment_to_first_audio_ms t(first_audio) − t(segment_flush)   (per segment)
//   commit_to_first_tool_audio_ms t(first tool audio) − t(commit)
//
// Plus the non-latency counters the issue also names: queue depth, and
// merge / dedup / old-generation discard counts.
//
// The accumulator is deliberately clock-agnostic: callers feed it records
// that carry a numeric `t` (ms on any monotonic timeline) or an ISO `ts`,
// so the same engine runs against gateway logs (ISO ts), live smoke output
// (performance.now()), or the E2E gate's injected clock.

import { canonicalEvent, normalize } from './correlation.mjs'

export const LATENCY_METRICS = [
  'codex_first_chunk_ms',
  'chunk_to_segment_ms',
  'segment_to_first_audio_ms',
  'commit_to_first_tool_audio_ms',
]

export const COUNTER_METRICS = [
  'max_queue_depth',
  'merged_segments',
  'duplicate_sequences',
  'stale_generation_dropped',
]

function toEpochMs(record) {
  // Prefer an injected numeric timestamp; fall back to ISO ts parsing.
  if (typeof record.t === 'number') return record.t
  if (typeof record.ts === 'number') return record.ts
  if (typeof record.ts === 'string') {
    const epoch = Date.parse(record.ts)
    if (!Number.isNaN(epoch)) return epoch
  }
  return null
}

// ESS-1071 阻断 2：state 必须以 session + request + generation 复合键隔离。
// 两个 session 复用同一个 request_id 时（既有测试已支持）互不污染。
export function turnKey(requestId, sessionId, generation) {
  return [sessionId ?? '', requestId ?? '', generation ?? ''].join('\u0000')
}

/**
 * Stream accumulator. Feed it `push(rawRecord)` for every structured-log line
 * across the chain (gateway + agent), then `summarize()` per turn.
 */
export class MetricsAccumulator {
  constructor({ now = () => Date.now() } = {}) {
    this.now = now
    this.turns = new Map() // session \u0000 request \u0000 generation → per-turn state
    this.queueDepthSamples = []
    this.globalCounters = {
      merged_segments: 0,
      duplicate_sequences: 0,
      stale_generation_dropped: 0,
    }
  }

  _turn(requestId, sessionId, generation) {
    const key = turnKey(requestId, sessionId, generation)
    let turn = this.turns.get(key)
    if (!turn) {
      turn = {
        request_id: requestId,
        session_id: sessionId ?? null,
        generation: generation ?? null,
        commitAt: null,
        codexFirstChunkAt: null,
        lastCodexChunkAt: null,
        segmentFlushAt: null,
        firstAudioAt: null,
        toolStartedAt: null,
        audioDone: false,
        errored: false,
        chunk_to_segment_ms: [],
        segment_to_first_audio_ms: [],
        maxQueueDepth: 0,
        mergedSegments: 0,
        duplicateSequences: 0,
        staleGenerationDropped: 0,
      }
      this.turns.set(key, turn)
    }
    if (sessionId != null && turn.session_id == null) turn.session_id = sessionId
    return turn
  }

  push(rawRecord) {
    const record = normalize(rawRecord)
    const evt = canonicalEvent(record.evt)
    const t = toEpochMs(record)
    if (t == null) return // cannot place on the timeline; skip, don't throw
    const turn = this._turn(record.request_id, record.session_id, record.generation)

    switch (evt) {
      case 'commit':
        turn.commitAt = t
        break

      case 'codex_first_chunk':
        if (turn.codexFirstChunkAt == null) turn.codexFirstChunkAt = t
        turn.lastCodexChunkAt = t
        break

      case 'codex_chunk':
        if (turn.codexFirstChunkAt == null) turn.codexFirstChunkAt = t
        turn.lastCodexChunkAt = t
        break

      case 'segment_flush':
        turn.segmentFlushAt = t
        if (turn.lastCodexChunkAt != null) {
          turn.chunk_to_segment_ms.push(Math.max(0, t - turn.lastCodexChunkAt))
        }
        break

      case 'first_audio':
        if (turn.firstAudioAt == null) turn.firstAudioAt = t
        if (turn.segmentFlushAt != null) {
          turn.segment_to_first_audio_ms.push(Math.max(0, t - turn.segmentFlushAt))
          turn.segmentFlushAt = null // one delta per flushed segment
        }
        break

      case 'tts_first_audio':
        if (turn.firstAudioAt == null) turn.firstAudioAt = t
        break

      case 'tool_start':
        if (turn.toolStartedAt == null) turn.toolStartedAt = t
        break

      case 'audio_done':
        turn.audioDone = true
        break

      case 'turn_error':
        turn.errored = true
        break

      case 'merged_segment':
        turn.mergedSegments += 1
        this.globalCounters.merged_segments += 1
        break

      case 'duplicate_sequence':
        turn.duplicateSequences += 1
        this.globalCounters.duplicate_sequences += 1
        break

      case 'stale_generation_dropped':
        turn.staleGenerationDropped += 1
        this.globalCounters.stale_generation_dropped += 1
        break

      case 'queue_depth': {
        const depth = Number(rawRecord.depth ?? rawRecord.queue_depth ?? record.raw.depth)
        if (Number.isFinite(depth)) {
          this.queueDepthSamples.push(depth)
          turn.maxQueueDepth = Math.max(turn.maxQueueDepth, depth)
        }
        break
      }

      default:
        break
    }
  }

  /** Per-turn latency summary. `codex_first_chunk_ms` is null when the turn
   *  produced no Codex chunk (direct answer). `sessionId` disambiguates when
   *  two sessions reuse the same request_id. */
  summarize(requestId, sessionId = null) {
    const turn = [...this.turns.values()].find(t =>
      t.request_id === requestId && (sessionId == null || t.session_id === sessionId))
    if (!turn) return null
    return {
      request_id: turn.request_id,
      session_id: turn.session_id,
      generation: turn.generation,
      codex_first_chunk_ms: turn.commitAt != null && turn.codexFirstChunkAt != null
        ? Math.max(0, turn.codexFirstChunkAt - turn.commitAt)
        : null,
      chunk_to_segment_ms: [...turn.chunk_to_segment_ms],
      segment_to_first_audio_ms: [...turn.segment_to_first_audio_ms],
      commit_to_first_tool_audio_ms: turn.commitAt != null && turn.toolStartedAt != null && turn.firstAudioAt != null
        ? Math.max(0, turn.firstAudioAt - turn.commitAt)
        : null,
      max_queue_depth: turn.maxQueueDepth,
      merged_segments: turn.mergedSegments,
      duplicate_sequences: turn.duplicateSequences,
      stale_generation_dropped: turn.staleGenerationDropped,
      audio_done: turn.audioDone,
      errored: turn.errored,
    }
  }

  /** All summarized turns plus the global counters. */
  summarizeAll() {
    const turns = [...this.turns.values()].map(turn => this.summarize(turn.request_id, turn.session_id))
    return {
      turns,
      max_queue_depth: this.queueDepthSamples.reduce((a, b) => Math.max(a, b), 0),
      ...this.globalCounters,
    }
  }
}
