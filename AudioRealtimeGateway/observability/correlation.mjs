// ESS-1071 — unified event correlation contract.
//
// The Realtime chain is Watch → iPhone → AudioRealtimeGateway →
// qwen-audio-agent → Codex. Two components log with two vocabularies:
//
//   Gateway (AudioRealtimeGateway): request_id, session_id, response_id,
//       generation, sequence. `request_id` IS the turn id.
//   qwen-audio-agent: sessionId, turnId, taskId, turnGeneration.
//
// This module is the single source of truth that:
//   1. names the canonical correlation fields every event must carry when
//      applicable;
//   2. normalizes a raw structured-log record from either vocabulary into
//      those canonical fields;
//   3. maps component event names onto a shared canonical event vocabulary
//      so one collector can compute the same latency metrics regardless of
//      which component emitted the record.
//
// The qwen-audio-agent side of the map covers the events the Stage-3
// streaming projector (ESS-1069) will emit; the canonical names are pinned
// here FIRST so the projector plugs in without a second contract negotiation.

/** Canonical correlation fields. `request_id` is the turn id. */
export const CORRELATION_FIELDS = [
  'request_id', 'session_id', 'response_id', 'generation', 'sequence', 'task_id',
]

/**
 * Fields that alias `request_id` in the agent vocabulary. Normalized onto
 * `request_id` so a turn is greppable by one key end-to-end.
 */
const REQUEST_ID_ALIASES = ['request_id', 'requestId', 'turn_id', 'turnId']

const SESSION_ID_ALIASES = ['session_id', 'sessionId']
const RESPONSE_ID_ALIASES = ['response_id', 'responseId', 'responseId']
const GENERATION_ALIASES = ['generation', 'turnGeneration', 'generation_id']
const SEQUENCE_ALIASES = ['sequence', 'seq']
const TASK_ID_ALIASES = ['task_id', 'taskId', 'task_ids', 'taskIds']

function firstDefined(record, keys) {
  for (const key of keys) {
    const value = record[key]
    if (value !== undefined && value !== null && value !== '') return value
  }
  return undefined
}

/**
 * Normalize a raw log record into canonical correlation fields plus the
 * original event name and payload. Returns a new object; never mutates input.
 *
 * @param {object} record raw structured-log line (already JSON-parsed)
 * @returns {{evt: string|null, request_id: *, session_id: *, response_id: *,
 *            generation: *, sequence: *, task_id: *, raw: object}}
 */
export function normalize(record = {}) {
  const raw = { ...record }
  return {
    evt: typeof raw.evt === 'string' ? raw.evt : (typeof raw.event === 'string' ? raw.event : null),
    request_id: firstDefined(raw, REQUEST_ID_ALIASES),
    session_id: firstDefined(raw, SESSION_ID_ALIASES),
    response_id: firstDefined(raw, RESPONSE_ID_ALIASES),
    generation: firstDefined(raw, GENERATION_ALIASES),
    sequence: firstDefined(raw, SEQUENCE_ALIASES),
    task_id: firstDefined(raw, TASK_ID_ALIASES),
    ts: raw.ts ?? raw.t ?? null,
    raw,
  }
}

/**
 * Which canonical correlation fields a record of a given event kind is
 * required to carry. Turn-scoped events must carry request_id + session_id;
 * audio-frame events additionally carry generation + sequence. Task-scoped
 * events carry task_id. Token lifecycle events carry none (they precede the
 * socket), matching the existing structured-logs acceptance.
 */
export function requiredFields(kind) {
  switch (kind) {
    case 'token': return []
    case 'handshake': return ['session_id', 'request_id']
    case 'turn': return ['session_id', 'request_id', 'generation']
    case 'frame': return ['session_id', 'request_id', 'generation', 'sequence']
    case 'task': return ['session_id', 'task_id']
    default: return ['session_id', 'request_id']
  }
}

/**
 * Assert a normalized record carries its required correlation fields.
 * Returns `{ok, missing}` — never throws, so a collector can report every
 * violation in one pass instead of dying on the first one.
 */
export function assertCorrelated(normalized, kind = 'turn') {
  const missing = requiredFields(kind)
    .filter(field => normalized[field] === undefined || normalized[field] === null)
  return { ok: missing.length === 0, missing }
}

/**
 * Canonical event vocabulary. Maps component event names to shared names so
 * a single collector can compute latency + violation invariants regardless of
 * emitter. Gateway names are live today; the qwen-audio-agent names are the
 * contract the Stage-3 CodexStreamProjector (ESS-1069) emits into.
 */
export const CANONICAL_EVENTS = {
  // ---- turn / audio lifecycle (gateway, live) ----
  commit: 'commit',                                     // uplink_committed
  first_audio: 'first_audio',                           // downlink_first_frame
  audio_done: 'audio_done',                             // downlink_done
  turn_error: 'turn_error',                             // session_error
  session_ended: 'session_ended',                       // session_ended / ws_close
  cancel_received: 'cancel_received',
  cancel_ack_sent: 'cancel_ack_sent',

  // ---- streaming pipeline (qwen-audio-agent, Stage-3 contract) ----
  codex_first_chunk: 'codex_first_chunk',
  codex_chunk: 'codex_chunk',
  segment_flush: 'segment_flush',
  tts_first_audio: 'tts_first_audio',
  tool_start: 'tool_start',
  tool_result: 'tool_result',

  // ---- counters (both) ----
  stale_generation_dropped: 'stale_generation_dropped',
  duplicate_sequence: 'duplicate_sequence',
  merged_segment: 'merged_segment',
  announcement_audio_dropped: 'announcement_audio_dropped',
  queue_depth: 'queue_depth',
}

/** Gateway event name → canonical name (the live half of the map). */
export const GATEWAY_EVENT_MAP = {
  uplink_committed: 'commit',
  downlink_first_frame: 'first_audio',
  segment_first_frame: 'first_audio',
  downlink_done: 'audio_done',
  session_error: 'turn_error',
  session_ended: 'session_ended',
  ws_close: 'session_ended',
  cancel_received: 'cancel_received',
  cancel_ack_sent: 'cancel_ack_sent',
  stale_generation_dropped: 'stale_generation_dropped',
  duplicate_sequence: 'duplicate_sequence',
  announcement_audio_dropped: 'announcement_audio_dropped',
}

/**
 * qwen-audio-agent event name → canonical name. The Stage-3 projector
 * (ESS-1069) must emit these exact event names with the canonical fields;
 * see Docs/realtime-ci-gate.md for the contract.
 */
export const AGENT_EVENT_MAP = {
  'codex.first_chunk': 'codex_first_chunk',
  'codex.chunk': 'codex_chunk',
  'segment.flush': 'segment_flush',
  'tts.first_audio': 'tts_first_audio',
  'tool.started': 'tool_start',
  'tool.result': 'tool_result',
  'task.created': 'tool_start',
  'task.completed': 'tool_result',
  'stale.generation.dropped': 'stale_generation_dropped',
  'duplicate.sequence': 'duplicate_sequence',
}

/** Map a raw event name to its canonical name, falling back to the raw name. */
export function canonicalEvent(evt) {
  if (!evt) return null
  return GATEWAY_EVENT_MAP[evt] ?? AGENT_EVENT_MAP[evt] ?? evt
}
