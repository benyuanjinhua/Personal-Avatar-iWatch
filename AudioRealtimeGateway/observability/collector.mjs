// ESS-1071 — assertion engine for the Realtime chain.
//
// Ingest a structured-log stream (gateway + qwen-audio-agent) and report the
// three cross-component invariants named in the acceptance criteria, so the
// E2E gate and CI can fail on them mechanically:
//
//   1. silent_end          — a committed turn closed with no audio_done, no
//                            turn_error and no cancel (no silent termination).
//   2. cross_session_mixing — a task result/event observed under a different
//                            session than the one that owned the task.
//   3. premature_done      — audio_done emitted while a flushed segment had
//                            not yet drained to its first audio frame.
//
// Plus the correlation-fields invariant from the issue scope: every event
// must carry request/session/turn/task/generation as applicable.

import {
  assertCorrelated,
  canonicalEvent,
  normalize,
} from './correlation.mjs'
import { MetricsAccumulator, turnKey } from './metrics.mjs'

/** Guess the correlation "kind" of a normalized event for required-fields
 *  checks. Events with no turn/session/task scope at all are service-level
 *  (`gateway_ready`, `http_rejected`, …) and require no correlation fields. */
function kindFor(record) {
  const evt = String(record.evt ?? record.event ?? '')
  const scoped = record.request_id != null || record.session_id != null || record.task_id != null
  if (!scoped) return 'service'
  if (/token|token_issued|token_rejected|token_consumed|token_expired|token_revoked/.test(evt)) return 'token'
  if (/ws_upgrade|session_ready|ready|handshake/.test(evt)) return 'handshake'
  if (/delta|append|sequence|frame|audio\./.test(evt) && !/done|segment/.test(evt)) return 'frame'
  // Genuine task/tool events must carry request + generation + task_id;
  // `announcement_*` events carry the turn scope (request/session/generation)
  // via scopeLog but not necessarily a task_id, so they stay 'turn'.
  if (/task\.|tool\.|task_|tool_/.test(evt)) return 'task'
  return 'turn'
}

export class ChainCollector {
  constructor({ now = () => Date.now() } = {}) {
    this.metrics = new MetricsAccumulator({ now })
    this.records = []
    this.violations = []
    // task_id → owning session_id
    this.taskOwner = new Map()
    // per-request turn state for the three invariants — keyed by
    // session \u0000 request \u0000 generation so two sessions reusing a
    // request_id never share committed/pendingSegments state.
    this.turns = new Map()
    // session_id → closed flag
    this.sessions = new Map()
  }

  _turn(record) {
    if (record.request_id == null) return null
    const key = turnKey(record.request_id, record.session_id, record.generation)
    let turn = this.turns.get(key)
    if (!turn) {
      turn = {
        request_id: record.request_id,
        session_id: record.session_id ?? null,
        committed: false,
        audioDone: false,
        errored: false,
        cancelled: false,
        hasTool: false,
        toolResultSeen: false,
        pendingSegments: 0,
      }
      this.turns.set(key, turn)
    }
    if (record.session_id != null && turn.session_id == null) turn.session_id = record.session_id
    return turn
  }

  push(rawRecord) {
    const record = normalize(rawRecord)
    this.records.push(record)
    this.metrics.push(rawRecord)
    const evt = canonicalEvent(record.evt)
    if (!evt) return

    // ---- correlation-fields invariant -------------------------------
    const kind = kindFor(record)
    const correlated = assertCorrelated(record, kind)
    if (!correlated.ok) {
      this.violations.push({
        invariant: 'missing_correlation',
        evt: record.evt,
        missing: correlated.missing,
        request_id: record.request_id ?? null,
        session_id: record.session_id ?? null,
      })
    }

    const turn = this._turn(record)

    // ---- cross-session mixing (task ownership) ----------------------
    if (record.task_id != null && record.session_id != null) {
      const owner = this.taskOwner.get(record.task_id)
      if (owner === undefined) {
        this.taskOwner.set(record.task_id, record.session_id)
      } else if (owner !== record.session_id) {
        this.violations.push({
          invariant: 'cross_session_mixing',
          task_id: record.task_id,
          owning_session: owner,
          observed_session: record.session_id,
          evt: record.evt,
        })
      }
    }

    if (!turn) return
    switch (evt) {
      case 'commit':
        turn.committed = true
        break
      case 'audio_done':
        turn.audioDone = true
        if (turn.pendingSegments > 0) {
          this.violations.push({
            invariant: 'premature_done',
            request_id: turn.request_id,
            session_id: turn.session_id,
            pending_segments: turn.pendingSegments,
          })
        }
        break
      case 'turn_error':
        turn.errored = true
        break
      case 'cancel_ack_sent':
        turn.cancelled = true
        break
      case 'tool_start':
        turn.hasTool = true
        break
      case 'tool_result':
        turn.toolResultSeen = true
        break
      case 'segment_flush':
        turn.pendingSegments += 1
        break
      case 'first_audio':
      case 'segment_first_audio':
      case 'tts_first_audio':
        if (turn.pendingSegments > 0) turn.pendingSegments -= 1
        break
      case 'session_ended': {
        if (record.session_id != null) this.sessions.set(record.session_id, true)
        // A committed turn that ended without a terminal event is a silent end
        // — unless the client itself tore the connection down (peer_closed / idle
        // timeout / graceful client_close). Those are client-initiated ends, not
        // the system going quiet mid-turn.
        const closeCode = record.raw.close_code ?? record.raw.code
        const reason = record.raw.reason ?? record.raw.close_reason
        const clientInitiated = closeCode === 1000 || closeCode === 1001 || closeCode === 1006
          || reason === 'peer_closed' || reason === 'client_close'
        if (turn.committed && !turn.audioDone && !turn.errored && !turn.cancelled && !clientInitiated) {
          this.violations.push({
            invariant: 'silent_end',
            request_id: turn.request_id,
            session_id: turn.session_id,
            has_tool: turn.hasTool,
            tool_result_seen: turn.toolResultSeen,
            close_code: closeCode ?? null,
          })
        }
        break
      }
      default:
        break
    }
  }

  /** Feed many raw records at once. */
  ingest(records) {
    for (const record of records) this.push(record)
    return this
  }

  /** Every violation found so far, grouped by invariant. */
  summarize() {
    const metrics = this.metrics.summarizeAll()
    return {
      violations: this.violations,
      metrics,
      passed: this.violations.length === 0,
    }
  }

  violationsFor(invariant) {
    return this.violations.filter(v => v.invariant === invariant)
  }
}
