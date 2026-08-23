// ESS-1097（服务端义务） — 上游任务生命周期必须投影到客户端。
//
// 事故（ESS-1095 真机证据）：工具回合里，客户端判「这一轮完了没有」只有音频
// 侧的两个输入（`audio.done` 屏障 + 本地播放终局）。「工具还在跑」这件事只有
// 网关知道，所以客户端只能信网关的有界空闲窗（ESS-1043 `toolCallWindowMs`
// = 30 s，按实测 8–16 s 工具耗时标定）。一次更慢的工具跑穿窗口 → 客户端提前
// 回「正在听」→ 用户开口 → 新 request 把工具回合 supersede 掉 → 结果丢失。
//
// 客户端侧的闸门在 PR #403（`Shared/ToolTurnAggregate.swift`），它的
// README 契约把两件事写成**服务端义务**：
//   1. 任务帧 `{task_id, status}` —— status 原样透传，解释权在客户端；
//   2. 闩锁帧 `{status: 'tool_call_pending' | 'tool_call_resolved'}` —— 无
//      `task_id`，覆盖「宣告了工具调用却从未产生任务号」的残余情形。
// 本文件钉住的就是这两条义务，以及它们不得触碰任何播放屏障。

import assert from 'node:assert/strict'
import { describe, it, test } from 'node:test'
import { WebSocketServer } from 'ws'

import { RealtimeSession } from '../realtime-session.mjs'
import { ScriptedAgentTransport } from '../agent-transport.mjs'
import { QwenAgentTransport } from '../qwen-agent-transport.mjs'

function harness() {
  const sent = []
  const logs = []
  const agent = new ScriptedAgentTransport()
  const scope = { device_id: 'd-1', session_id: 's-1', request_id: 'r-1', generation: 2 }
  const session = new RealtimeSession({
    scope,
    send: text => sent.push(JSON.parse(text)),
    close: () => {},
    agentTransport: agent,
    log: (evt, extra) => logs.push({ evt, ...extra }),
    heartbeatIntervalMs: 0, idleDisconnectMs: 0, commitDeadlineMs: 0,
  })
  session.onFrame(JSON.stringify({
    type: 'session.start',
    session_id: scope.session_id, request_id: scope.request_id,
    generation: scope.generation, protocol_version: 1,
  }))
  return { session, sent, logs, agent }
}

const taskEvent = (id, status) => ({
  type: 'agent.task', response_id: 'r-1:gen2', task: { id, status },
})

describe('ESS-1097 · task.state 下行', () => {
  it('任务帧带 task_id 与原样 status，并带回合身份', () => {
    const { sent, agent } = harness()

    agent.emit('r-1', taskEvent('work_1', 'running'))

    assert.deepEqual(sent.filter(f => f.type === 'task.state'), [{
      type: 'task.state',
      session_id: 's-1', request_id: 'r-1', generation: 2,
      task_id: 'work_1', status: 'running',
    }])
  })

  /// status 原样透传，网关不做终态判定——判定权在客户端，两侧各维护一份
  /// 白名单就是两次漂移的机会。
  it('status 原样透传，网关不翻译也不裁剪', () => {
    const { sent, agent } = harness()

    agent.emit('r-1', taskEvent('work_1', 'accepted'))
    agent.emit('r-1', taskEvent('work_1', 'some_未来_status'))
    agent.emit('r-1', taskEvent('work_1', 'completed'))

    assert.deepEqual(
      sent.filter(f => f.type === 'task.state').map(f => f.status),
      ['accepted', 'some_未来_status', 'completed'],
    )
  })

  it('闩锁帧不带 task_id', () => {
    const { sent, agent } = harness()

    agent.emit('r-1', {
      type: 'agent.tool_call_state', response_id: 'r-1:gen2', status: 'tool_call_pending',
    })

    const frame = sent.find(f => f.type === 'task.state')
    assert.equal(frame.status, 'tool_call_pending')
    assert.ok(!('task_id' in frame), '闩锁帧必须**没有** task_id——客户端据此区分两种形态')
  })

  /// 回合终态之后到达的任务终态**必须**照样下发：它正是客户端解除闸门的
  /// 那条事件。在这里按 `doneEmitted` 丢掉它，等于把本单要防的死锁亲手造出来。
  it('回合已 done 之后的任务终态仍然下发', () => {
    const { sent, logs, agent } = harness()
    agent.emit('r-1', taskEvent('work_1', 'running'))
    agent.emit('r-1', {
      type: 'agent.audio.done', response_id: 'r-1:gen2', final_sequence: -1,
    })
    agent.emit('r-1', taskEvent('work_1', 'completed'))

    const last = sent.filter(f => f.type === 'task.state').at(-1)
    assert.equal(last.task_id, 'work_1')
    assert.equal(last.status, 'completed')
    assert.ok(
      logs.some(l => l.evt === 'downlink_task_state' && l.status === 'completed'),
      'downlink_task_state 必须留证，真机复盘要靠它把 UI 状态与任务对上',
    )
  })

  it('既没有 task_id 也没有 status 的事件不产生下行帧', () => {
    const { sent, agent } = harness()

    agent.emit('r-1', { type: 'agent.task', response_id: 'r-1:gen2', task: {} })

    assert.equal(sent.filter(f => f.type === 'task.state').length, 0)
  })

  it('任务帧不触碰任何播放屏障', () => {
    const { session, sent, agent } = harness()

    agent.emit('r-1', taskEvent('work_1', 'running'))
    agent.emit('r-1', {
      type: 'agent.tool_call_state', response_id: 'r-1:gen2', status: 'tool_call_pending',
    })

    assert.equal(session.doneEmitted, false)
    assert.equal(session.segmentsEmitted, 0)
    assert.equal(sent.filter(f => f.type === 'audio.done').length, 0)
    assert.equal(sent.filter(f => f.type === 'audio.segment_done').length, 0)
  })
})

// ---------------------------------------------------------------------------
// 全栈：真实上游时序（tool_call_pending → idle → task → 工具结果）
// ---------------------------------------------------------------------------

const servers = []
function upstream(handler) {
  return new Promise(resolve => {
    const wss = new WebSocketServer({ port: 0 })
    servers.push(wss)
    wss.on('connection', ws => {
      ws.on('message', raw => {
        let message
        try { message = JSON.parse(raw.toString()) } catch { return }
        handler(ws, message)
      })
    })
    wss.on('listening', () => resolve(`ws://127.0.0.1:${wss.address().port}`))
  })
}
const send = (ws, payload) => ws.send(JSON.stringify(payload))
const audioDelta = (ws, sequence, text) => send(ws, {
  type: 'audio.delta', sequence,
  audio: Buffer.from(text).toString('base64'),
  sampleRate: 24_000, codec: 'pcm_s16le',
})
async function waitFor(predicate, timeoutMs) {
  const deadline = Date.now() + timeoutMs
  return new Promise((resolve, reject) => {
    const poll = () => {
      if (predicate()) return resolve()
      if (Date.now() > deadline) return reject(new Error('waitFor timeout'))
      setTimeout(poll, 20)
    }
    poll()
  })
}

test('ESS-1097 · 全栈：闩锁与任务帧都在第二段音频之前到达客户端', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'up-1', origin: 'model' })
      audioDelta(ws, 0, '我查一下')
      send(ws, { type: 'response.done', responseId: 'up-1', origin: 'agent', hasFunctionCall: true })
      send(ws, { type: 'audio.done' })
      // 实测：done 后 0.2 ms 就是 idle，而工具此刻才刚开始跑。
      send(ws, { type: 'voice.state', state: 'idle', origin: 'model' })
      setTimeout(() => {
        send(ws, { type: 'task.accepted', task: { id: 'work_x', status: 'queued' } })
      }, 80)
      setTimeout(() => {
        send(ws, { type: 'response.started', responseId: 'up-2', origin: 'agent' })
        audioDelta(ws, 1, '结果是')
        send(ws, { type: 'task.completed', task: { id: 'work_x', status: 'completed' } })
        send(ws, { type: 'response.done', responseId: 'up-2', origin: 'agent', hasFunctionCall: false })
        send(ws, { type: 'audio.done' })
      }, 500)
    }
  })
  const sent = []
  const scope = { device_id: 'd9', session_id: 's9', request_id: 'r9', generation: 1 }
  const session = new RealtimeSession({
    scope,
    send: text => sent.push(JSON.parse(text)),
    close: () => {},
    agentTransport: new QwenAgentTransport({
      gatewayUrl: url, segmentGapMs: 200, segmentGapBusyMs: 1_000,
    }),
    log: () => {},
    heartbeatIntervalMs: 0, idleDisconnectMs: 0, commitDeadlineMs: 0,
  })
  session.onFrame(JSON.stringify({
    type: 'session.start', session_id: 's9', request_id: 'r9', generation: 1, protocol_version: 1,
  }))
  session.onFrame(JSON.stringify({
    type: 'audio.append', session_id: 's9', request_id: 'r9', generation: 1,
    sequence: 0, audio: Buffer.from('uplink!!').toString('base64'),
  }))
  session.onFrame(JSON.stringify({
    type: 'audio.commit', session_id: 's9', request_id: 'r9', generation: 1, sequence: 0,
  }))
  await waitFor(() => sent.some(f => f.type === 'audio.done'), 8_000)

  const order = sent.map(f => f.type)
  const firstTaskState = order.indexOf('task.state')
  const secondDeltaIdx = order.lastIndexOf('audio.delta')
  assert.ok(firstTaskState >= 0, '客户端必须收到 task.state')
  assert.ok(
    firstTaskState < secondDeltaIdx,
    `任务事实必须在第二段音频之前到达，否则客户端在段落间隙里仍然是瞎的：${order}`,
  )
  const states = sent.filter(f => f.type === 'task.state')
  assert.equal(states[0].status, 'tool_call_pending', '闩锁先到（此时还没有任务号）')
  assert.ok(!('task_id' in states[0]))
  assert.ok(
    states.some(f => f.task_id === 'work_x' && f.status === 'queued'),
    '任务号出现后必须下发任务帧',
  )
  assert.ok(
    states.some(f => f.task_id === 'work_x' && f.status === 'completed'),
    '任务终态必须下发——它是客户端解除闸门的唯一依据',
  )
  session.onSocketClose(1000, 'test_done')
  servers.forEach(s => s.close())
})
