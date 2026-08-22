// ESS-1004 —— 回合终态：唯一性、可产出性，以及不得被调到段间隔以下。
//
// 事故：多段回合答完后 `downlink_done` 一次都没下发过（真机 4/4），客户端在
// 45 s 后误报「回答超时」并自动挂断，下一问落进一个正在重启的 App。
//
// 取证结论（详见 `qwen-agent-transport.mjs` 的 `turnIdleBackstopMs` 注释）：
// 上游的 `voice.state {state:'idle'}` 对本客户端形态**不可达**，所以
// `agent_turn_idle_backstop_ms` 事实上是多段回合**唯一**的终态来源。
//
// ⚠️ 已撤回的一条断言（R-04.5 / R-04.6）：本文件最初还钉了「兜底必须显著
// 小于客户端 45 s 硬超时、且两者不得相等」。毕玄-cx 在 PR #378 上用同一份
// L1 反证了它，反证成立：两个计时器不同时起跑 —— 兜底在音频**投递完**武装
// （10:34:35.112），客户端在音频**播完**武装（10:35:02.657），45 s 的兜底
// 本应在 10:35:20.112 触发，比客户端的 10:35:47.740 早 27.6 s。它没触发是因为
// socket 在段落关闭后 0.534 s 就 1006 断开（ESS-1008），`onSocketClose` →
// `agentTurn.close()` 把这个计时器清掉了。那两条上界断言据此**全部删除**，
// 常数也退回 ESS-969 的 45 s —— 改它对本故障零增益。
//
// 现在只钉三件仍然成立的事：
//   1. 兜底不得被调到实测段间隔以下（下界，这是真实的截断风险）；
//   2. 上游只发段落、永不发终态时，兜底路径**确实**产出回合终态，且只产出一次；
//   3. 回合终态到达 `RealtimeSession` 时，`downlink_done` 必然出现且只出现一次
//      —— 这就是真机上 0 次的那条日志。
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterEach, describe, it, test } from 'node:test'
import { WebSocketServer } from 'ws'

import { QwenAgentTransport } from '../qwen-agent-transport.mjs'
import { RealtimeSession } from '../realtime-session.mjs'
import { ScriptedAgentTransport } from '../agent-transport.mjs'

const BASE = dirname(fileURLToPath(import.meta.url))

// L1 实测下界。数据窗口：`AudioRealtimeGateway/logs/gateway.log`，2026-08-22；
// 样本量 n=4（该窗口内**全部**多段回合，非抽样）；统计口径：
// `upstream_segment_closed` → 紧随其后的 `upstream_response_started`：
//   03:28:51.418→03:29:06.472 = 15.054 s
//   05:37:12.138→05:37:27.295 = 15.157 s
//   06:57:40.573→06:57:55.527 = 14.954 s
//   10:34:29.309→10:34:29.672 =  0.363 s
// 最慢 15.157 s。兜底必须 ≥ 它的 2 倍，否则会在上游还要继续说话时提前收口 ——
// 那就是 ESS-969 存在的理由本身。n=4 偏薄（R-04.4），故仍是配置项。
const OBSERVED_SLOWEST_SEGMENT_GAP_MS = 15_157

describe('ESS-1004 · 回合终态下界', () => {
  it('出厂兜底值不得被调到实测段间隔以下', () => {
    const config = JSON.parse(readFileSync(join(BASE, '..', 'config.json'), 'utf8'))
    const backstop = config.agent_turn_idle_backstop_ms
    assert.equal(typeof backstop, 'number', 'agent_turn_idle_backstop_ms 必须出厂就有值')
    assert.ok(backstop > 0, '兜底为 0 等于关掉多段回合唯一的终态来源')
    assert.ok(
      backstop >= 2 * OBSERVED_SLOWEST_SEGMENT_GAP_MS,
      `兜底(${backstop}ms) 必须 ≥ 实测最慢段间隔 ${OBSERVED_SLOWEST_SEGMENT_GAP_MS}ms 的 2 倍，`
      + '否则会在上游还要说下一段时提前收口 —— 这正是 ESS-969 要修的那个 bug',
    )
  })

  it('server.mjs 的兜底默认值与出厂配置一致', () => {
    const source = readFileSync(join(BASE, '..', 'server.mjs'), 'utf8')
    const config = JSON.parse(readFileSync(join(BASE, '..', 'config.json'), 'utf8'))
    const match = source.match(/agent_turn_idle_backstop_ms \?\? ([\d_]+)/)
    assert.ok(match, 'server.mjs 必须显式给出兜底默认值')
    assert.equal(
      Number(match[1].replaceAll('_', '')),
      config.agent_turn_idle_backstop_ms,
      '默认值与出厂配置漂移时，删掉一行配置就会静默换掉唯一的终态来源',
    )
  })
})

// ---------------------------------------------------------------------------
// 兜底路径确实产出回合终态
// ---------------------------------------------------------------------------

const servers = []
afterEach(async () => {
  await Promise.all(servers.splice(0).map(server => new Promise(resolve => server.close(resolve))))
})

async function upstream(onMessage) {
  const server = new WebSocketServer({ port: 0 })
  servers.push(server)
  server.on('connection', ws => {
    ws.on('message', raw => onMessage(ws, JSON.parse(raw.toString())))
  })
  await new Promise(resolve => server.once('listening', resolve))
  return `ws://127.0.0.1:${server.address().port}/api/realtime`
}

function waitFor(predicate, timeoutMs = 3_000) {
  const started = Date.now()
  return new Promise((resolve, reject) => {
    const poll = () => {
      if (predicate()) return resolve()
      if (Date.now() - started > timeoutMs) return reject(new Error('waitFor timeout'))
      setTimeout(poll, 5)
    }
    poll()
  })
}

const send = (ws, event) => ws.send(JSON.stringify(event))
const audioDelta = (ws, sequence, text) => send(ws, {
  type: 'audio.delta', sequence, audio: Buffer.from(text).toString('base64'), sampleRate: 24_000,
})

// 真机形状：上游宣告过 `voice.state`（所以走 multi_segment），两段音频都发完，
// 然后**永远不发终态** —— 这正是 2026-08-22 四个回合的实际行为。
test('ESS-1004 · 上游永不发终态时，兜底仍然产出 agent.audio.done', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'up-1', origin: 'model' })
      audioDelta(ws, 0, 'seg1')
      send(ws, { type: 'audio.done' })
      setTimeout(() => {
        send(ws, { type: 'response.started', responseId: 'up-2', origin: 'model' })
        audioDelta(ws, 1, 'seg2')
        send(ws, { type: 'audio.done' })
        // 终态永不到来 —— 与真机一致。
      }, 300)
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url,
    // 出厂值是 45 s；用例只验证「兜底路径成立」，不验证它的长度。
    turnIdleBackstopMs: 400,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r-1004', sessionId: 's-1004', deviceId: 'd-1004', generation: 1,
    responseId: 'r-1004:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))

  assert.deepEqual(events.map(e => e.type), [
    'agent.audio.delta',        // 第一段
    'agent.audio.segment_done', // 段落边界
    'agent.audio.delta',        // 第二段
    'agent.audio.done',         // 兜底产出的回合终态
  ])
  const done = events.at(-1)
  assert.equal(done.final_sequence, 1, '终态覆盖两段的全部序号')
  assert.equal(done.segments, 2)
  assert.ok(
    logs.some(l => l.evt === 'upstream_turn_terminal' && l.reason === 'idle_backstop'),
    '终态必须如实标注来自兜底，而不是伪装成上游信号',
  )
  assert.equal(
    logs.filter(l => l.evt === 'upstream_turn_terminal').length, 1,
    '回合终态只能有一次',
  )
  turn.close()
})

// 终态必须一路走到 `downlink_done` —— 这就是真机上 0 次的那条日志。
test('ESS-1004 · 回合终态必然产出 downlink_done', () => {
  const sent = []; const logs = []
  const agent = new ScriptedAgentTransport()
  const scope = { device_id: 'd-1004', session_id: 's-1004', request_id: 'r-1004', generation: 1 }
  const session = new RealtimeSession({
    scope,
    send: text => sent.push(JSON.parse(text)),
    close: () => {},
    agentTransport: agent,
    log: (evt, extra) => logs.push({ evt, ...extra }),
    heartbeatIntervalMs: 0,
    idleDisconnectMs: 0,
    commitDeadlineMs: 0,
  })
  session.onFrame(JSON.stringify({
    type: 'session.start',
    session_id: scope.session_id, request_id: scope.request_id,
    generation: scope.generation, protocol_version: 1,
  }))
  const responseId = 'r-1004:gen1'
  const delta = sequence => ({
    type: 'agent.audio.delta', response_id: responseId, sequence,
    sample_rate: 24_000, codec: 'pcm_s16le',
    audio: Buffer.from([sequence, sequence, sequence, sequence]).toString('base64'),
  })
  agent.emit('r-1004', delta(0))
  agent.emit('r-1004', {
    type: 'agent.audio.segment_done', response_id: responseId,
    segment_index: 0, final_sequence: 0,
  })
  agent.emit('r-1004', delta(1))
  agent.emit('r-1004', {
    type: 'agent.audio.done', response_id: responseId, final_sequence: 1, segments: 2,
  })

  assert.equal(
    logs.filter(l => l.evt === 'downlink_done').length, 1,
    'downlink_done 是真机上 0 次的那条日志：终态到达时它必须出现，且只出现一次',
  )
  assert.equal(sent.filter(f => f.type === 'audio.done').length, 1)
  assert.equal(sent.find(f => f.type === 'audio.done').final_sequence, 1)
})
