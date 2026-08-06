#!/usr/bin/env node
// ESS-423 — deployment smoke for the server-side half of the ESS-388 direct
// link. Unlike test/wss-e2e.test.mjs (in-process `createGateway`, plain ws,
// ephemeral port) this drives the ACTUAL deployment surface:
//
//   • spawns `node server.mjs` as a separate process, cwd = module dir
//   • uses the committed config.json, overriding only ephemeral smoke state
//     and port through the deployment-supported GATEWAY_CONFIG_PATH entrypoint
//   • speaks real TLS: https:// for the control API, wss:// for the media plane
//   • asserts on the server process's own stdout (structured log contract)
//
// Rationale (from the issue): the old Bridge's three deployment failures —
// feature flag off in config.json, deployed tip 34 commits behind, process
// not restarted for 15 h — were all invisible to unit tests and only showed
// up on-device. This exercises "can it actually be started and talked to".
//
// Scope: server side only. Never touches the Mac Bridge (8443) / qwen-agent
// (3101), never edits config.json, runs with `agent_transport: "mock"`.
//
// Usage:  node smoke/deploy-smoke.mjs
// Exit:   0 = all checks PASS, 1 = at least one FAIL.

import crypto from 'node:crypto'
import https from 'node:https'
import { spawn, spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import WebSocket from 'ws'

import { DeviceStore, signRequest } from '../device-auth.mjs'

const GW_DIR = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const CONFIG = JSON.parse(readFileSync(join(GW_DIR, 'config.json'), 'utf8'))
// ESS-447 B2: `config.bind` is now `0.0.0.0` so the Gateway accepts
// connections from the Tailnet, but this smoke script deliberately drives
// the loopback path — the reachability question ("does the Tailnet
// hostname route to the Mac mini") is deployment infra, not application
// behaviour. We still generate the cert SAN for `public_host` so real
// device clients (on the Tailnet) validate the same cert this smoke
// exercises. The Gateway's own source-allowlist accepts loopback
// unconditionally, so the smoke never touches `allowed_peer_ips`.
const HOST = CONFIG.bind === '0.0.0.0' ? '127.0.0.1' : CONFIG.bind
let port = null
const wsBase = () => `wss://${HOST}:${port}/api/realtime`

// Self-signed cert => the smoke client must not verify the chain. This is the
// ONLY TLS relaxation; the server still runs full TLS. Scoped per-request via
// node:https rather than NODE_TLS_REJECT_UNAUTHORIZED so it can't leak.
const TLS_INSECURE = { rejectUnauthorized: false }

function httpsJson(pathName, { method = 'GET', headers = {}, body = null } = {}) {
  return new Promise((res, rej) => {
    const req = https.request({
      host: HOST, port, path: pathName, method, headers, rejectUnauthorized: false,
    }, response => {
      const chunks = []
      response.on('data', c => chunks.push(c))
      response.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8')
        let json = {}
        try { json = JSON.parse(text) } catch { /* non-JSON body */ }
        res({ status: response.statusCode, body: json, text })
      })
    })
    req.on('error', rej)
    if (body) req.write(body)
    req.end()
  })
}

// Sentinel we can grep the server log for. `agent_transport: mock` does not
// use it, but the process still reads the env var, so its absence from the
// log is a real assertion about redaction.
const PROVIDER_KEY_SENTINEL = 'SMOKE_PROVIDER_KEY_' + crypto.randomBytes(12).toString('hex')

const DEVICE_ID = 'ess423-smoke-device'
const SESSION_ID = 'sess_ess423_' + crypto.randomBytes(4).toString('hex')

const results = []
const issuedTokens = []
let logLines = []

// `advisory` checks report but do not gate the exit code: they cover
// deployment properties the issue did not ask for and the README does not
// promise. They still print so a regression is visible.
function check(id, name, ok, detail = '', advisory = false) {
  results.push({ id, name, ok, detail, advisory })
  const tag = ok ? 'PASS' : (advisory ? 'WARN' : 'FAIL')
  process.stdout.write(`${tag}  ${id}  ${name}${detail ? '\n        ' + detail : ''}\n`)
}
const advise = (id, name, ok, detail) => check(id, name, ok, detail, true)
const sleep = ms => new Promise(r => setTimeout(r, ms))

// ---------------------------------------------------------------- setup ----

// ESS-506: TLS cert + key are generated into an ephemeral temp dir, NOT the
// deploy dir's `certs/`. Writing to `<GW_DIR>/certs/gateway.crt|key` would
// clobber the trusted Let's Encrypt cert (ESS-457) with the smoke's
// `O=ESS-423 smoke` self-signed cert on every run — invisible to `curl -k`
// smoke but fatal to a real iPhone `wss://` handshake. The smoke config
// (written below) points `tls_cert` / `tls_key` at the returned absolute
// paths, so the spawned server.mjs never touches the deploy `certs/`.
function ensureCerts() {
  const certDir = mkdtempSync(join(tmpdir(), 'deploy-smoke-certs-'))
  const crt = join(certDir, 'gateway.crt')
  const key = join(certDir, 'gateway.key')
  // ESS-447 B2: include `public_host` in the SAN so real-device clients that
  // resolve the Multica magic-workspace hostname also validate the cert.
  // Loopback remains listed so the smoke itself keeps working from the same
  // machine that runs the Gateway.
  const sans = ['IP:127.0.0.1', 'DNS:localhost']
  if (typeof CONFIG.public_host === 'string' && CONFIG.public_host.length > 0) {
    sans.push('DNS:' + CONFIG.public_host)
  }
  const cn = typeof CONFIG.public_host === 'string' && CONFIG.public_host.length > 0
    ? CONFIG.public_host : 'localhost'
  const r = spawnSync('openssl', [
    'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
    '-keyout', key, '-out', crt, '-days', '30',
    '-subj', `/CN=${cn}/O=ESS-423 smoke`,
    '-addext', 'subjectAltName=' + sans.join(','),
  ], { encoding: 'utf8' })
  if (r.status !== 0) throw new Error('openssl failed: ' + (r.stderr || r.stdout))
  return { crt, key, dir: certDir }
}

function sha256File(path) {
  return crypto.createHash('sha256').update(readFileSync(path)).digest('hex')
}

// Deployment quickstart step 2: a registered device. Only sha256(secret) is
// persisted; the raw secret lives in this process's memory and is never
// written to disk.
function bootstrapDevice(stateDir) {
  rmSync(stateDir, { recursive: true, force: true })
  mkdirSync(stateDir, { recursive: true })
  const secret = crypto.randomBytes(32).toString('hex')
  new DeviceStore({ stateDir }).register(DEVICE_ID, secret)
  return { stateDir, secret }
}

function startGateway(logPath, configPath) {
  const child = spawn(process.execPath, ['server.mjs'], {
    cwd: GW_DIR,
    env: {
      ...process.env,
      [CONFIG.provider_key_env]: PROVIDER_KEY_SENTINEL,
      GATEWAY_CONFIG_PATH: configPath,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  const chunks = []
  child.stdout.on('data', d => chunks.push(d.toString()))
  child.stderr.on('data', d => chunks.push(d.toString()))
  child.on('exit', () => writeFileSync(logPath, chunks.join('')))
  return {
    child,
    dump: () => chunks.join(''),
    flush: () => writeFileSync(logPath, chunks.join('')),
  }
}

// Race the health probe against the child process dying. Without this, a
// child that fails to bind (e.g. EADDRINUSE because a stale gateway holds
// the port) goes unnoticed and the probe ends up talking to WHATEVER else is
// on the port — every downstream check then fails for the wrong reason
// (ESS-444: the bogus 401 at token mint).
async function waitForHealth(child, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs
  let last = null
  let exited = null
  child.once('exit', (code, signal) => { exited = { code, signal } })
  while (Date.now() < deadline) {
    if (exited) {
      throw new Error(
        `gateway process exited during startup (code=${exited.code} signal=${exited.signal}) — `
        + `refusing to probe whatever else is on ${HOST}:${port}. Child output:\n`
        + gateway.dump().slice(0, 800))
    }
    try { return await httpsJson('/v1/health') }
    catch (e) { last = e; await sleep(150) }
  }
  throw new Error('gateway never became healthy: ' + String(last?.message ?? last))
}

// The health probe returning 200 and Node delivering the child's stdout
// chunks are two independent async events with no ordering guarantee, so a
// one-shot read of the captured output can legitimately miss gateway_ready
// (ESS-444 S1b). Poll until the event shows up or the deadline passes —
// gateway_ready is emitted synchronously on listen(), so this settles well
// within the timeout on a healthy boot.
async function waitForBootEvent(evtName, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const found = gateway.dump().split('\n').filter(Boolean).map(safeParse).filter(Boolean)
      .find(l => l.evt === evtName)
    if (found) return found
    await sleep(50)
  }
  return null
}

// -------------------------------------------------------------- helpers ----

async function mintToken(secret, { requestId, generation, ttlMs = 30_000 }) {
  const body = {
    protocol_version: CONFIG.protocol_version,
    device_id: DEVICE_ID,
    session_id: SESSION_ID,
    request_id: requestId,
    generation,
    ttl_ms: ttlMs,
  }
  const { rawBody, headers } = signRequest({
    tokenRaw: secret, deviceId: DEVICE_ID,
    method: 'POST', pathName: '/v1/realtime/session-token',
    requestId, body,
    nonce: crypto.randomBytes(8).toString('hex'),
    timestamp: Date.now(),
  })
  const r = await httpsJson('/v1/realtime/session-token', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'content-length': String(rawBody.length),
      ...headers,
    },
    body: rawBody,
  })
  if (r.body?.token) issuedTokens.push(r.body.token)
  return r
}

function wsUrl({ requestId, generation }) {
  return `${wsBase()}?device_id=${DEVICE_ID}&session_id=${SESSION_ID}`
    + `&request_id=${requestId}&generation=${generation}`
}

// Opens a socket and returns a small driver: `frames` accumulates every
// server frame with the wall-clock time it arrived, so "no delta AFTER
// cancel.ack" can be asserted on timestamps rather than on a race.
function connect(token, scope) {
  const ws = new WebSocket(wsUrl(scope), {
    headers: { authorization: 'Bearer ' + token },
    ...TLS_INSECURE,
  })
  const frames = []
  ws.on('message', raw => {
    try { frames.push({ at: Date.now(), msg: JSON.parse(raw.toString()) }) } catch { /* ignore */ }
  })
  const opened = new Promise((res, rej) => {
    ws.once('open', res)
    ws.once('error', rej)
    ws.once('unexpected-response', (_, r) => rej(new Error('upgrade ' + r.statusCode)))
  })
  return {
    ws, frames, opened,
    send: obj => ws.send(JSON.stringify(obj)),
    of: type => frames.filter(f => f.msg.type === type).map(f => f.msg),
    firstAt: type => frames.find(f => f.msg.type === type)?.at ?? null,
    waitFor(type, timeoutMs = 3_000) {
      return new Promise((res, rej) => {
        const hit = frames.find(f => f.msg.type === type)
        if (hit) return res(hit.msg)
        const timer = setTimeout(() => rej(new Error(`timeout waiting for ${type}`)), timeoutMs)
        const onMsg = raw => {
          let m; try { m = JSON.parse(raw.toString()) } catch { return }
          if (m.type === type) { clearTimeout(timer); ws.off('message', onMsg); res(m) }
        }
        ws.on('message', onMsg)
      })
    },
    async close() {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'close', reason: 'smoke_done' }))
        await new Promise(res => { ws.once('close', res); setTimeout(res, 500) })
      }
      ws.terminate()
    },
  }
}

// 100 ms of silence-ish PCM16LE @16 kHz = 3200 bytes — a realistic uplink frame.
function pcmFrame(i) {
  const buf = Buffer.alloc(3200)
  buf.writeInt16LE((i * 37) % 32767, 0)
  return buf.toString('base64')
}

async function startSession(conn, scope) {
  conn.send({
    type: 'session.start',
    session_id: SESSION_ID, request_id: scope.requestId,
    generation: scope.generation, protocol_version: CONFIG.protocol_version,
  })
  return conn.waitFor('ready')
}

function appendFrames(conn, scope, n) {
  for (let seq = 0; seq < n; seq += 1) {
    conn.send({
      type: 'audio.append',
      session_id: SESSION_ID, request_id: scope.requestId,
      generation: scope.generation, sequence: seq,
      audio: pcmFrame(seq), sample_rate: 16_000, codec: 'pcm_s16le',
    })
  }
  return n - 1
}

// ----------------------------------------------------------------- main ----

const logPath = join(GW_DIR, 'smoke', 'gateway-smoke.log')
let gateway = null
let stateDir = null
let smokeConfigPath = null
let certDir = null

// ESS-506 safety fingerprint. Capture the digest of the deploy dir's TLS
// material BEFORE any smoke work; a matching digest after we clean up proves
// the smoke did not clobber it. Missing files at either end are treated as
// digest `null` — a fresh clone has no `certs/` yet, and that's fine as long
// as nothing materialized.
const deployCertPath = join(GW_DIR, 'certs', 'gateway.crt')
const deployKeyPath = join(GW_DIR, 'certs', 'gateway.key')
const beforeCertHash = existsSync(deployCertPath) ? sha256File(deployCertPath) : null
const beforeKeyHash = existsSync(deployKeyPath) ? sha256File(deployKeyPath) : null

try {
  const certs = ensureCerts()
  certDir = certs.dir
  const runId = crypto.randomBytes(8).toString('hex')
  stateDir = join(GW_DIR, 'smoke', `.deploy-smoke-${runId}-state`)
  smokeConfigPath = join(GW_DIR, 'smoke', `.deploy-smoke-${runId}-config.json`)
  writeFileSync(smokeConfigPath, JSON.stringify({
    ...CONFIG,
    port: 0,
    state_dir: stateDir,
    // ESS-506: force the spawned server.mjs to load TLS material from the
    // ephemeral temp dir, not `./certs/` (which in a deploy is the trusted
    // Let's Encrypt cert). server.mjs resolves these against its module dir
    // only when the path is relative; absolute paths pass through unchanged.
    tls_cert: certs.crt,
    tls_key: certs.key,
  }, null, 2))
  const boot = bootstrapDevice(stateDir)
  stateDir = boot.stateDir
  process.stdout.write(
    `# ESS-423 gateway deployment smoke\n`
    + `# node ${process.version}  base config ${join(GW_DIR, 'config.json')}\n`
    + `# tls ${certs.crt}  bind ${HOST}:ephemeral  transport ${CONFIG.agent_transport}\n\n`,
  )

  gateway = startGateway(logPath, smokeConfigPath)

  // `gateway_ready` is proof that this exact child owns the listener. Only
  // after reading its OS-assigned port do probes begin, so an old service on
  // committed port 8444 can never be mistaken for this run (ESS-503).
  const ready = await waitForBootEvent('gateway_ready')
  if (!ready || !Number.isInteger(ready.port) || ready.port <= 0) {
    throw new Error(`gateway_ready with assigned port not captured; output: ${gateway.dump().slice(0, 800)}`)
  }
  port = ready.port

  // --- 1. process starts + health ------------------------------------------
  const health = await waitForHealth(gateway.child)
  check('S1', 'server.mjs 起进程 + GET /v1/health 200',
    health.status === 200 && health.body?.ok === true,
    `status=${health.status} body=${JSON.stringify(health.body)}`)

  check('S1b', 'gateway_ready 日志：TLS 生效、provider key 从 env 读入',
    Boolean(ready) && ready.tls === true && ready.provider_key_present === true,
    JSON.stringify(ready))

  // --- 2. token 签发 --------------------------------------------------------
  const t1 = { requestId: 'req_ess423_a_' + crypto.randomBytes(3).toString('hex'), generation: 1 }
  const mint1 = await mintToken(boot.secret, t1)
  check('S2', 'POST /v1/realtime/session-token 用 HMAC 设备签名签出 token',
    mint1.status === 201
      && /^rtk_[a-f0-9]{64}$/.test(mint1.body.token ?? '')
      && mint1.body.scope?.request_id === t1.requestId
      && mint1.body.scope?.generation === 1
      && mint1.body.ttl_ms <= CONFIG.max_token_ttl_ms,
    `status=${mint1.status} err=${mint1.body.error ?? 'n/a'} jti=${mint1.body.jti} ttl_ms=${mint1.body.ttl_ms} scope=${JSON.stringify(mint1.body.scope)}`)

  // --- 3. WSS 升级 + token 单次使用 -----------------------------------------
  const c1 = connect(mint1.body.token, t1)
  let upgraded = true, upgradeErr = ''
  try { await c1.opened } catch (e) { upgraded = false; upgradeErr = String(e.message) }
  check('S3a', 'WSS /api/realtime 用该 token 升级成功（真实 TLS）', upgraded, upgradeErr || `${wsBase()}`)

  const replay = new WebSocket(wsUrl(t1), {
    headers: { authorization: 'Bearer ' + mint1.body.token }, ...TLS_INSECURE,
  })
  const replayStatus = await new Promise(res => {
    replay.on('unexpected-response', (_, r) => res(r.statusCode))
    replay.on('open', () => res('OPENED'))
    replay.on('error', () => res(null))
    setTimeout(() => res('TIMEOUT'), 3_000)
  })
  replay.terminate()
  check('S3b', 'token 单次使用：第二次升级被拒', replayStatus === 401,
    `second upgrade => ${replayStatus} (expect 401 / ERR_TOKEN_CONSUMED)`)

  // --- 4. session.start → ready --------------------------------------------
  const readyMsg = await startSession(c1, t1)
  check('S4', 'session.start → ready',
    readyMsg.type === 'ready'
      && readyMsg.request_id === t1.requestId
      && readyMsg.session_id === SESSION_ID
      && readyMsg.generation === 1,
    `response_id=${readyMsg.response_id} heartbeat_interval_ms=${readyMsg.heartbeat_interval_ms}`)

  // --- 5. audio.append × N + audio.commit ----------------------------------
  const N = 20
  const lastSeq = appendFrames(c1, t1, N)
  c1.send({
    type: 'audio.commit',
    session_id: SESSION_ID, request_id: t1.requestId,
    generation: 1, sequence: lastSeq,
  })
  await sleep(200)
  const uplinkError = c1.of('error')[0]
  check('S5', `audio.append × ${N}（单调密集 sequence）+ audio.commit 被接受`,
    !uplinkError,
    uplinkError ? `unexpected error frame: ${JSON.stringify(uplinkError)}`
      : `sent seq 0..${lastSeq}, ${N * 3200} bytes uplink, no error frame`)

  // --- 6/7. audio.delta … audio.done + barrier ------------------------------
  const done = await c1.waitFor('audio.done', 5_000).catch(e => ({ error: String(e.message) }))
  const deltas = c1.of('audio.delta')
  const seqs = deltas.map(d => d.sequence).sort((a, b) => a - b)
  check('S6', '收到 audio.delta，随后 audio.done 且带 final_sequence',
    deltas.length > 0 && done?.type === 'audio.done' && Number.isInteger(done.final_sequence),
    `deltas=${deltas.length} seqs=[${seqs.join(',')}] done=${JSON.stringify(done)}`)

  let densePrefix = -1
  const seqSet = new Set(seqs)
  while (seqSet.has(densePrefix + 1)) densePrefix += 1
  check('S7', 'final_sequence == 已发出的密集前缀（README barrier 语义）',
    done?.final_sequence === densePrefix && densePrefix === Math.max(-1, ...seqs),
    `final_sequence=${done?.final_sequence} dense_prefix=${densePrefix} max_seq=${seqs.length ? seqs[seqs.length - 1] : 'n/a'}`)

  // response_id / generation stamped on every media frame (ESS-388 强制契约)
  const stamped = [...deltas, done].filter(Boolean).every(f =>
    f.session_id === SESSION_ID && f.request_id === t1.requestId
    && f.response_id === readyMsg.response_id && f.generation === 1)
  check('S7b', '每个媒体帧都带 session/request/response/generation',
    stamped, `response_id=${readyMsg.response_id}`)

  await c1.close()

  // --- 8a. cancel before commit（确定性：本代不应产生任何 delta）--------------
  const t2 = { requestId: 'req_ess423_b_' + crypto.randomBytes(3).toString('hex'), generation: 2 }
  const mint2 = await mintToken(boot.secret, t2)
  const c2 = connect(mint2.body.token, t2)
  await c2.opened
  await startSession(c2, t2)
  appendFrames(c2, t2, 5)
  c2.send({ type: 'cancel', session_id: SESSION_ID, request_id: t2.requestId, generation: 2, reason: 'smoke_bargein' })
  const ack2 = await c2.waitFor('cancel.ack', 3_000).catch(e => ({ error: String(e.message) }))
  await sleep(500)
  const after2 = c2.frames.filter(f => f.msg.type === 'audio.delta' || f.msg.type === 'audio.done')
  check('S8a', 'cancel（未 commit）→ cancel.ack，且该 generation 全程无 delta/done',
    ack2?.type === 'cancel.ack' && ack2.generation === 2 && after2.length === 0,
    `ack=${JSON.stringify(ack2)} media_frames_after_cancel=${after2.length}`)
  await c2.close()

  // --- 8b. cancel mid-stream（commit 之后，收到首个 delta 立刻取消）----------
  const t3 = { requestId: 'req_ess423_c_' + crypto.randomBytes(3).toString('hex'), generation: 3 }
  const mint3 = await mintToken(boot.secret, t3)
  const c3 = connect(mint3.body.token, t3)
  await c3.opened
  await startSession(c3, t3)
  const last3 = appendFrames(c3, t3, 5)
  c3.send({ type: 'audio.commit', session_id: SESSION_ID, request_id: t3.requestId, generation: 3, sequence: last3 })
  await c3.waitFor('audio.delta', 3_000).catch(() => null)
  c3.send({ type: 'cancel', session_id: SESSION_ID, request_id: t3.requestId, generation: 3, reason: 'smoke_bargein_midstream' })
  const ack3 = await c3.waitFor('cancel.ack', 3_000).catch(e => ({ error: String(e.message) }))
  await sleep(500)
  const ackAt = c3.firstAt('cancel.ack')
  const mediaAfterAck = c3.frames.filter(f =>
    (f.msg.type === 'audio.delta' || f.msg.type === 'audio.done') && ackAt !== null && f.at > ackAt)
  const doneBeforeAck = c3.firstAt('audio.done') !== null && c3.firstAt('audio.done') <= ackAt
  check('S8b', 'commit 后 cancel → cancel.ack，ack 之后不再有该 generation 的 delta/done',
    ack3?.type === 'cancel.ack' && mediaAfterAck.length === 0,
    `ack=${JSON.stringify(ack3)} media_after_ack=${mediaAfterAck.length} `
    + `race=${doneBeforeAck ? 'mock 已在 cancel 到达前 done（mock setImmediate 比 loopback RTT 快）' : 'cancel 抢在 done 之前'}`)
  await c3.close()

  await sleep(300)

  // --- 9. 结构化日志 --------------------------------------------------------
  const raw = gateway.dump()
  logLines = raw.split('\n').filter(Boolean).map(safeParse).filter(Boolean)

  const turn = logLines.filter(l => l.request_id === t1.requestId)
  const CHAIN = ['token_issued', 'ws_upgrade', 'session_ready', 'uplink_first_frame',
    'uplink_committed', 'downlink_first_frame', 'downlink_done', 'session_ended']
  const missing = CHAIN.filter(e => !turn.some(l => l.evt === e))
  check('S9a', '按单个 request_id grep 可还原整轮（token→upgrade→ready→uplink→downlink→done→end）',
    missing.length === 0,
    missing.length ? `missing: ${missing.join(', ')}`
      : `${turn.length} lines, chain: ${CHAIN.join(' → ')}`)

  // 冒烟项 9 的另一半：request 级日志必须同时带 session_id，否则按 session 聚合
  // 一轮 barge-in（同 session、多 request/generation）会漏掉记录。
  // 例外：ws_upgrade_rejected 发生在 session 建立之前（S3b 的重放探测必然
  // 产生一条），README 的日志契约也写明 id 是 "when applicable" 才携带，
  // 因此它不属于「session 内事件缺 session_id」这个不变式的约束对象。
  const PRE_SESSION_EVENTS = new Set(['ws_upgrade_rejected'])
  const unscoped = turn.filter(l => typeof l.session_id !== 'string' && !PRE_SESSION_EVENTS.has(l.evt))
  check('S9f', '每条带 request_id 的日志同时带 session_id',
    unscoped.length === 0,
    unscoped.length
      ? `${unscoped.length} 条缺 session_id: ` + unscoped.map(l => l.evt).join(', ')
        + ' | ' + JSON.stringify(unscoped[0])
      : `${turn.length} lines all carry both ids`)

  const cancelLogs = logLines.filter(l => l.request_id === t2.requestId).map(l => l.evt)
  check('S9b', 'cancel 路径有 cancel_received + cancel_ack_sent 日志',
    cancelLogs.includes('cancel_received') && cancelLogs.includes('cancel_ack_sent'),
    cancelLogs.join(' → '))

  const leakedToken = issuedTokens.find(t => raw.includes(t))
  check('S9c', '日志不含任何已签发 token 明文',
    !leakedToken, leakedToken ? `LEAKED ${leakedToken.slice(0, 12)}…` : `${issuedTokens.length} tokens checked`)

  check('S9d', '日志不含 provider key',
    !raw.includes(PROVIDER_KEY_SENTINEL),
    `sentinel ${PROVIDER_KEY_SENTINEL.slice(0, 22)}… not present`)

  const leakedAudio = logLines.some(l => 'audio' in l || 'raw_audio' in l || 'signature' in l || 'token' in l)
  check('S9e', '日志不含 audio / signature / token 字段（logger 白名单外字段被裁掉）',
    !leakedAudio, `${logLines.length} log records scanned`)

  // --- 10. 部署面观察（advisory：issue 未列、README 未承诺，但属部署坑）------
  // README 的 quickstart 是 `npm start`（cwd = 模块目录）。server.mjs 现在把
  // state_dir 和 tls_cert/tls_key 统一按模块目录解析（ESS-428）——部署脚本
  // 用绝对路径从任意 cwd 拉起进程也必须能起来。
  //
  // 主 smoke 与 cwd 探针都使用 port 0，因此它们可并行存活，
  // 也不会与已部署在 8444 的 Gateway 互相干扰。
  gateway.flush()
  const fromRepoRoot = spawnSync(process.execPath, [join(GW_DIR, 'server.mjs')], {
    cwd: resolve(GW_DIR, '..'), encoding: 'utf8', timeout: 8_000,
    env: {
      ...process.env,
      [CONFIG.provider_key_env]: PROVIDER_KEY_SENTINEL,
      GATEWAY_CONFIG_PATH: smokeConfigPath,
    },
  })
  // spawnSync timeout kills a healthy (still-listening) server => status null.
  // A clean exit (0) also counts; only a crash exit is a failure.
  const startedFromOtherCwd = fromRepoRoot.status === null || fromRepoRoot.status === 0
  advise('S10a', '从模块目录以外的 cwd 启动 server.mjs 也能起来（tls 路径按模块目录解析）',
    startedFromOtherCwd,
    `status=${fromRepoRoot.status} ${(fromRepoRoot.stderr || '').split('\n').find(l => l.includes('Error:') || l.includes('startup_failed')) ?? ''}`)
  // startup_failed 打在 stderr（见 server.mjs 末尾），合并两路输出再判。
  const probeOutput = (fromRepoRoot.stdout || '') + (fromRepoRoot.stderr || '')
  advise('S10b', '启动失败走结构化 startup_failed 日志而非裸栈',
    startedFromOtherCwd || probeOutput.includes('startup_failed'),
    startedFromOtherCwd ? 'n/a' : 'createGateway() 的抛错未被 server.mjs 末尾的 .catch 覆盖，输出是裸 stack')
} catch (error) {
  check('S0', 'smoke harness', false, String(error?.stack ?? error))
} finally {
  if (gateway) {
    gateway.flush()
    gateway.child.kill('SIGTERM')
    await sleep(300)
    gateway.child.kill('SIGKILL')
  }
  // Leave nothing behind: the smoke device registration is not production state.
  if (stateDir) rmSync(stateDir, { recursive: true, force: true })
  if (smokeConfigPath) rmSync(smokeConfigPath, { force: true })
  if (certDir) rmSync(certDir, { recursive: true, force: true })
}

// ESS-506 safety gate. Runs after cleanup so it observes the final state of
// the deploy dir. Any digest change here means the smoke clobbered Gateway
// TLS material — a silent regression of ESS-457 that would surface on the
// next service restart as an iPhone `wss://` handshake failure. Must gate
// the exit code so CI catches a re-introduction.
const afterCertHash = existsSync(deployCertPath) ? sha256File(deployCertPath) : null
const afterKeyHash = existsSync(deployKeyPath) ? sha256File(deployKeyPath) : null
check('S0-safety', 'smoke does not touch certs/gateway.crt|key in the deploy dir',
  beforeCertHash === afterCertHash && beforeKeyHash === afterKeyHash,
  `crt before=${beforeCertHash?.slice(0, 12) ?? 'absent'} `
  + `after=${afterCertHash?.slice(0, 12) ?? 'absent'} `
  + `key before=${beforeKeyHash?.slice(0, 12) ?? 'absent'} `
  + `after=${afterKeyHash?.slice(0, 12) ?? 'absent'}`)

const gating = results.filter(r => !r.advisory)
const failed = gating.filter(r => !r.ok)
const warned = results.filter(r => r.advisory && !r.ok)
process.stdout.write(
  `\n---\n${gating.length - failed.length}/${gating.length} gating checks passed`
  + `${failed.length ? '  FAILED: ' + failed.map(f => f.id).join(', ') : ''}\n`
  + `${warned.length ? warned.length + ' advisory warning(s): ' + warned.map(w => w.id).join(', ') + '\n' : ''}`
  + `gateway stdout → ${logPath}\n`,
)
process.exit(failed.length ? 1 : 0)

function safeParse(line) {
  try { return JSON.parse(line) } catch { return null }
}
