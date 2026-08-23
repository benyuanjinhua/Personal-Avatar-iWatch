#!/usr/bin/env node
// ESS-1071 — one-command Realtime E2E gate.
//
// Drives the three fixed scenarios plus the six fault-injection scenarios
// through the REAL Gateway surface (HTTP token mint → WSS upgrade →
// session.start → audio.append → audio.commit → downstream frames), with a
// scripted upstream agent so the whole thing runs with zero live
// dependencies and asserts deterministically.
//
// Every scenario produces end-to-end timing plus assertions. The structured
// log stream (gateway) and the injected upstream events (agent side) are fed
// into the ChainCollector, which enforces the three cross-component
// invariants: no silent end, no cross-session mixing, no premature done.
//
// Usage:
//   node smoke/realtime-e2e-gate.mjs [--scenario all|time|weather|knowledge]
//         [--faults] [--json] [--live]
//
//   --scenario   which fixed scenario(s) to run (default: all three)
//   --faults     also run the six fault-injection scenarios
//   --json       print the machine-readable report to stdout
//
// Exit: 0 = every assertion passed, 1 = at least one assertion failed,
//       2 = usage error.

import crypto from 'node:crypto'
import { performance } from 'node:perf_hooks'
import WebSocket from 'ws'

import { createGateway } from '../server.mjs'
import { signRequest } from '../device-auth.mjs'
import { ScriptedAgentTransport } from '../agent-transport.mjs'
import { ChainCollector } from '../observability/collector.mjs'

const argv = process.argv.slice(2)
const flag = (name, fallback = null) => {
  const at = argv.indexOf(`--${name}`)
  return at >= 0 && argv[at + 1] !== undefined ? argv[at + 1] : fallback
}
const has = name => argv.includes(`--${name}`)

const SCENARIO = flag('scenario', 'all')
const RUN_FAULTS = has('faults')
const AS_JSON = has('json')

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
const rand = n => crypto.randomBytes(n).toString('hex')
// 4 zero bytes = one silent PCM16 sample; non-empty yet below every budget.
const SILENT = Buffer.from([0, 0, 0, 0]).toString('base64')

const SCENARIO_NAMES = ['time', 'weather', 'knowledge']
const FAULT_NAMES = ['provider-4xx', 'late-completion', 'tts-failure', 'wss-disconnect', 'queue-backlog', 'barge-in']

function captureLogs() {
  const lines = []
  const original = process.stdout.write.bind(process.stdout)
  // Swallow (capture only) so the gateway's structured log stream never
  // pollutes the gate's own stdout report, especially in --json mode.
  process.stdout.write = chunk => {
    const text = typeof chunk === 'string' ? chunk : chunk.toString()
    if (text.startsWith('{"ts"')) {
      try { lines.push(JSON.parse(text.trim())) } catch { /* ignore */ }
    }
    return true
  }
  return { lines, restore: () => { process.stdout.write = original } }
}

// Gateway logs carry ISO `ts`, injected upstream events carry numeric `t`.
// The collector must see them in true chronological order or a flushed
// segment would be processed after its own first audio frame.
function mergeByTime(...arrays) {
  const all = []
  for (const arr of arrays) {
    for (const record of arr) {
      const t = typeof record.t === 'number'
        ? record.t
        : (typeof record.ts === 'string' ? Date.parse(record.ts) : 0)
      all.push({ t, record })
    }
  }
  all.sort((a, b) => a.t - b.t)
  return all.map(x => x.record)
}

// ---------------------------------------------------------------------------
// Low-level client + scripted-upstream driver
// ---------------------------------------------------------------------------
class Driver {
  constructor(gateway, transport, deviceId, tokenRaw) {
    this.gateway = gateway
    this.transport = transport
    this.deviceId = deviceId
    this.tokenRaw = tokenRaw
    this.injected = [] // agent-side canonical events (epoch-ms stamped)
    this.port = null
  }

  mark(requestId, sessionId, generation, evt, extra = {}) {
    this.injected.push({
      evt, t: Date.now(), request_id: requestId, session_id: sessionId, generation, ...extra,
    })
  }

  async mint(sessionId, requestId, generation) {
    const body = {
      protocol_version: 1, device_id: this.deviceId,
      session_id: sessionId, request_id: requestId, generation, ttl_ms: 30_000,
    }
    const { rawBody, headers } = signRequest({
      tokenRaw: this.tokenRaw, deviceId: this.deviceId,
      method: 'POST', pathName: '/v1/realtime/session-token',
      requestId, body, nonce: rand(8), timestamp: Date.now(),
    })
    const response = await fetch(`http://127.0.0.1:${this.port}/v1/realtime/session-token`, {
      method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: rawBody,
    })
    if (response.status !== 201) throw new Error(`token mint failed: ${response.status}`)
    return (await response.json()).token
  }

  async connect(sessionId, requestId, generation) {
    const token = await this.mint(sessionId, requestId, generation)
    const url = `ws://127.0.0.1:${this.port}/api/realtime`
      + `?device_id=${this.deviceId}&session_id=${sessionId}`
      + `&request_id=${requestId}&generation=${generation}`
    const ws = new WebSocket(url, { headers: { authorization: 'Bearer ' + token } })
    const frames = []
    ws.on('message', raw => { try { frames.push(JSON.parse(raw.toString())) } catch { /* ignore */ } })
    await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject) })
    return { ws, frames }
  }

  async start(ws, frames, sessionId, requestId, generation) {
    ws.send(JSON.stringify({
      type: 'session.start', session_id: sessionId, request_id: requestId,
      generation, protocol_version: 1,
    }))
    return this.waitFrame(frames, 'ready', 2_000)
  }

  async commit(ws, sessionId, requestId, generation) {
    ws.send(JSON.stringify({
      type: 'audio.append', session_id: sessionId, request_id: requestId,
      generation, sequence: 0, audio: SILENT,
    }))
    ws.send(JSON.stringify({
      type: 'audio.commit', session_id: sessionId, request_id: requestId,
      generation, sequence: 0,
    }))
    await this.waitCommit(requestId)
  }

  emitter(requestId, generation) {
    const responseId = `${requestId}:gen${generation}`
    const emit = (type, fields) => this.transport.emit(requestId, { type, response_id: responseId, ...fields })
    return {
      delta: (sequence, audio = SILENT) => emit('agent.audio.delta', {
        sequence, sample_rate: 24_000, codec: 'pcm_s16le', audio,
      }),
      segmentDone: (final_sequence, segment_index) => emit('agent.audio.segment_done', {
        segment_index, final_sequence,
      }),
      done: final_sequence => emit('agent.audio.done', { final_sequence }),
      error: (code, detail = null, retriable = false) => emit('agent.error', { code, detail, retriable }),
    }
  }

  async waitFrame(frames, type, timeoutMs) {
    let hit = frames.find(f => f.type === type)
    if (hit) return hit
    const deadline = performance.now() + timeoutMs
    while (performance.now() < deadline) {
      await sleep(10)
      hit = frames.find(f => f.type === type)
      if (hit) return hit
    }
    throw new Error(`timed out waiting for ${type}`)
  }

  async waitCommit(requestId) {
    const deadline = Date.now() + 2_000
    while (Date.now() < deadline) {
      if (this.transport.commits.some(c => c.requestId === requestId)) return
      await sleep(5)
    }
    throw new Error('gateway never forwarded audio.commit to the upstream transport')
  }
}

// ---------------------------------------------------------------------------
// Fixed scenarios
// ---------------------------------------------------------------------------
const scripts = {
  time: async ({ emit, mark }) => {
    await sleep(30); mark('segment.flush'); await sleep(15)
    emit.delta(0); await sleep(15)
    emit.delta(1); await sleep(15)
    emit.done(1)
  },
  weather: async ({ emit, mark }) => {
    await sleep(20); emit.delta(0); emit.segmentDone(0, 0)
    await sleep(40); mark('tool.started', { task_id: 'task-weather' }); mark('codex.first_chunk')
    await sleep(25); mark('codex.chunk'); await sleep(25); mark('segment.flush')
    await sleep(20); emit.delta(1); await sleep(15); emit.delta(2); await sleep(15)
    mark('tool.result', { task_id: 'task-weather' }); emit.done(2)
  },
  knowledge: async ({ emit, mark }) => {
    await sleep(20); emit.delta(0); emit.segmentDone(0, 0)
    await sleep(40); mark('tool.started', { task_id: 'task-knowledge' }); mark('codex.first_chunk')
    await sleep(25); mark('codex.chunk'); await sleep(25); mark('segment.flush')
    await sleep(20); emit.delta(1); await sleep(15); emit.delta(2); await sleep(15); emit.delta(3)
    await sleep(15); mark('tool.result', { task_id: 'task-knowledge' }); emit.done(3)
  },
}

async function runScenario(driver, name) {
  const sessionId = `s_${name}_${rand(3)}`
  const requestId = `r_${name}_${rand(3)}`
  const generation = 1
  const t0 = performance.now()
  const { ws, frames } = await driver.connect(sessionId, requestId, generation)
  await driver.start(ws, frames, sessionId, requestId, generation)
  await driver.commit(ws, sessionId, requestId, generation)
  const emit = driver.emitter(requestId, generation)
  await scripts[name]({
    emit,
    mark: (evt, extra) => driver.mark(requestId, sessionId, generation, evt, extra),
  })
  const terminal = await driver.waitFrame(frames, 'audio.done', 8_000)
  ws.send(JSON.stringify({ type: 'close', reason: 'gate_done' }))
  await new Promise(resolve => ws.once('close', resolve))
  await sleep(50)
  return {
    name, requestId, sessionId, generation, frames, terminal,
    duration_ms: Math.round(performance.now() - t0),
  }
}

function assertScenario(name, run, summary) {
  const { frames, terminal } = run
  const checks = []
  const check = (label, pass, detail = '') => checks.push({ name: label, pass, detail })
  const doneFrame = frames.find(f => f.type === 'audio.done')
  const segmentDoneFrames = frames.filter(f => f.type === 'audio.segment_done')
  const errorFrame = frames.find(f => f.type === 'error')
  const deltaFrames = frames.filter(f => f.type === 'audio.delta')
  const turn = summary.metrics.turns.find(t =>
    t.request_id === run.requestId && t.session_id === run.sessionId) ?? {}

  check('turn_terminated', Boolean(doneFrame || errorFrame), `done=${Boolean(doneFrame)} error=${Boolean(errorFrame)}`)
  check('all_invariants_pass', summary.passed === true,
    JSON.stringify(summary.violations))
  check('no_silent_end', !summary.violations.some(v => v.invariant === 'silent_end'))
  check('no_premature_done', !summary.violations.some(v => v.invariant === 'premature_done'))

  if (name === 'time') {
    check('direct_answer_no_codex', turn.codex_first_chunk_ms == null, 'direct turn must not enter Codex')
    check('single_segment_terminal', doneFrame != null && segmentDoneFrames.length === 0,
      'direct answer ends in one terminal segment')
  } else {
    check('tool_streams_across_segments', segmentDoneFrames.length >= 1 && doneFrame != null,
      `segment_done=${segmentDoneFrames.length} before final done`)
    check('final_answer_present', deltaFrames.length >= 2,
      `deltas=${deltaFrames.length} (must exceed the lone acknowledgement)`)
    check('codex_was_entered', turn.codex_first_chunk_ms != null, 'tool turn must produce a Codex first chunk')
    check('commit_to_first_tool_audio_present', turn.commit_to_first_tool_audio_ms != null,
      'first tool audio latency must be measurable')
  }
  return checks
}

// ---------------------------------------------------------------------------
// Fault-injection scenarios
// ---------------------------------------------------------------------------
async function runFault(driver, name) {
  const sessionId = `s_${name}_${rand(3)}`
  const requestId = `r_${name}_${rand(3)}`
  const generation = 1
  const { ws, frames } = await driver.connect(sessionId, requestId, generation)
  await driver.start(ws, frames, sessionId, requestId, generation)
  await driver.commit(ws, sessionId, requestId, generation)
  const emit = driver.emitter(requestId, generation)

  if (name === 'provider-4xx') {
    await sleep(20); emit.error('ERR_UPSTREAM_UNAVAILABLE', 'provider 4xx', false)
  } else if (name === 'tts-failure') {
    await sleep(20); emit.error('ERR_TTS_FAILURE', 'synthesis failed', false)
  } else if (name === 'late-completion') {
    // The turn closes after the acknowledgement; the tool result arrives
    // late and must be dropped, not re-open the turn or cross sessions.
    await sleep(20); emit.delta(0); emit.done(0)
    await sleep(60); emit.delta(1) // late post-done frame
  } else if (name === 'queue-backlog') {
    for (let i = 0; i < 64; i += 1) emit.delta(i)
  } else if (name === 'barge-in') {
    await sleep(20); emit.delta(0)
    await sleep(20)
    ws.send(JSON.stringify({
      type: 'cancel', session_id: sessionId, request_id: requestId, generation, reason: 'barge_in',
    }))
    await driver.waitFrame(frames, 'cancel.ack', 2_000)
    await sleep(20); emit.delta(1) // late frame for the cancelled generation
  } else if (name === 'wss-disconnect') {
    await sleep(20); emit.delta(0)
    ws.terminate() // abrupt client loss, no graceful close
  }

  await sleep(120)
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type: 'close', reason: 'gate_done' }))
    await new Promise(resolve => ws.once('close', resolve))
  }
  await sleep(50)
  return { name, requestId, sessionId, generation, frames }
}

function assertFault(name, run, summary) {
  const { frames } = run
  const checks = []
  const check = (label, pass, detail = '') => checks.push({ name: label, pass, detail })
  const errorFrame = frames.find(f => f.type === 'error')
  const doneFrame = frames.find(f => f.type === 'audio.done')
  const cancelAck = frames.find(f => f.type === 'cancel.ack')
  const turn = summary.metrics.turns.find(t =>
    t.request_id === run.requestId && t.session_id === run.sessionId) ?? {}

  check('all_invariants_pass', summary.passed === true,
    JSON.stringify(summary.violations))
  check('no_silent_end', !summary.violations.some(v => v.invariant === 'silent_end'))
  check('no_cross_session_mixing', !summary.violations.some(v => v.invariant === 'cross_session_mixing'))

  switch (name) {
    case 'provider-4xx':
      check('explicit_error', Boolean(errorFrame), `error=${errorFrame?.code ?? 'none'}`)
      check('no_final_done', !doneFrame, 'a failed turn must not emit a terminal done')
      break
    case 'tts-failure':
      check('explicit_error', Boolean(errorFrame), `error=${errorFrame?.code ?? 'none'}`)
      break
    case 'late-completion':
      check('turn_already_terminal', Boolean(doneFrame), 'acknowledgement turn closed normally')
      check('late_frame_dropped', turn.stale_generation_dropped > 0,
        `stale_dropped=${turn.stale_generation_dropped ?? 0}`)
      break
    case 'queue-backlog':
      check('explicit_error', Boolean(errorFrame), 'budget overflow must fail closed')
      check('bounded_error',
        errorFrame?.code === 'ERR_DOWNLINK_BUDGET' || errorFrame?.code === 'ERR_UPSTREAM_BUDGET_EXCEEDED',
        `code=${errorFrame?.code ?? 'none'}`)
      break
    case 'barge-in':
      check('cancel_acked', Boolean(cancelAck), 'client barge-in must be acknowledged')
      check('late_frame_dropped', turn.stale_generation_dropped > 0,
        `stale_dropped=${turn.stale_generation_dropped ?? 0}`)
      break
    case 'wss-disconnect':
      check('no_error_flood', !errorFrame, 'a client disconnect is not an upstream error')
      break
    default:
      break
  }
  return checks
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  if (SCENARIO !== 'all' && !SCENARIO_NAMES.includes(SCENARIO)) {
    console.error(`unknown scenario: ${SCENARIO} (expected all|${SCENARIO_NAMES.join('|')})`)
    process.exit(2)
  }

  const transport = new ScriptedAgentTransport({ log: () => {} })
  const gateway = createGateway({
    port: 0, bind: '127.0.0.1', state_dir: '/tmp/gw-e2e-gate-' + rand(4),
    dev_allow_plain_ws: true,
    heartbeat_interval_ms: 0, idle_disconnect_ms: 0,
    max_token_ttl_ms: 60_000, default_token_ttl_ms: 30_000,
    token_sweep_interval_ms: 0,
    max_downlink_frames: 32, // small window so queue-backlog fails fast
    agentTransport: transport,
  })
  const deviceId = 'gate-device'
  const tokenRaw = rand(32)
  gateway.devices.register(deviceId, tokenRaw)

  const driver = new Driver(gateway, transport, deviceId, tokenRaw)
  const capture = captureLogs()
  const report = { scenarios: [], faults: [], passed: true }

  try {
    await gateway.start()
    driver.port = gateway.server.address().port
    const names = SCENARIO === 'all' ? SCENARIO_NAMES : [SCENARIO]
    for (const name of names) {
      const run = await runScenario(driver, name)
      const collector = new ChainCollector()
      collector.ingest(mergeByTime(capture.lines, driver.injected))
      const summary = collector.summarize()
      const checks = assertScenario(name, run, summary)
      const pass = checks.every(c => c.pass)
      report.passed = report.passed && pass
      report.scenarios.push({
        name, request_id: run.requestId, duration_ms: run.duration_ms,
        terminal: run.terminal?.type ?? null,
        metrics: summary.metrics.turns.find(t => t.request_id === run.requestId) ?? null,
        checks, pass,
      })
      capture.lines.length = 0
      driver.injected.length = 0
    }

    if (RUN_FAULTS) {
      for (const name of FAULT_NAMES) {
        const run = await runFault(driver, name)
        const collector = new ChainCollector()
        collector.ingest(mergeByTime(capture.lines, driver.injected))
        const summary = collector.summarize()
        const checks = assertFault(name, run, summary)
        const pass = checks.every(c => c.pass)
        report.passed = report.passed && pass
        report.faults.push({ name, request_id: run.requestId, checks, pass })
        capture.lines.length = 0
        driver.injected.length = 0
      }
    }
  } finally {
    capture.restore()
    await gateway.stop()
  }

  if (AS_JSON) {
    process.stdout.write(JSON.stringify(report, null, 2) + '\n')
  } else {
    for (const s of report.scenarios) {
      console.log(`scenario ${s.name}: ${s.pass ? 'PASS' : 'FAIL'} (${s.duration_ms}ms)`)
      for (const c of s.checks) console.log(`  - ${c.pass ? 'ok' : 'FAIL'} ${c.name}${c.detail ? ' — ' + c.detail : ''}`)
    }
    for (const f of report.faults) {
      console.log(`fault ${f.name}: ${f.pass ? 'PASS' : 'FAIL'}`)
      for (const c of f.checks) console.log(`  - ${c.pass ? 'ok' : 'FAIL'} ${c.name}${c.detail ? ' — ' + c.detail : ''}`)
    }
    console.log(report.passed ? 'ALL PASS' : 'FAILURES PRESENT')
  }
  process.exit(report.passed ? 0 : 1)
}

main().catch(error => {
  console.error('gate crashed:', error)
  process.exit(2)
})
