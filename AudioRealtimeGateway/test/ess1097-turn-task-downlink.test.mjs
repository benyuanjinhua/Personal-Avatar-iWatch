// ESS-1097 — 上游任务生命周期必须下发到客户端。
//
// 事故（ESS-1095 真机证据）：工具回合里，客户端判「这一轮完了没有」只有音频
// 侧的两个输入（`audio.done` 屏障 + 本地播放终局）。「工具还在跑」这件事只有
// 网关知道，所以客户端只能信网关的有界空闲窗（ESS-1043 `toolCallWindowMs`
// = 30 s，按实测 8–16 s 工具耗时标定）。一次更慢的工具跑穿窗口 → 客户端提前
// 回「正在听」→ 用户开口 → 新 request 把工具回合 supersede 掉 → 结果丢失。
//
// 这里钉住的是修复的**前半段**：网关必须把它已经知道的任务事实转发下去。
// 客户端怎么消费在 `Tests/ToolTurnGateTests.swift` 与
// `WatchTests/Ess1097ToolTurnStateMachineTests.swift`。

import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import { RealtimeSession } from '../realtime-session.mjs'
import { ScriptedAgentTransport } from '../agent-transport.mjs'

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
  return { session, sent, logs, agent, scope }
}

const task = (id, status, terminal) => ({
  type: 'agent.task', response_id: 'r-1:gen2', task: { id, status, terminal },
})

describe('ESS-1097 · turn.task 下行', () => {
  it('把任务生命周期原样转发，并带上回合身份', () => {
    const { sent, agent } = harness()

    agent.emit('r-1', task('work_1', 'running', false))

    const frames = sent.filter(f => f.type === 'turn.task')
    assert.equal(frames.length, 1)
    assert.deepEqual(frames[0], {
      type: 'turn.task',
      session_id: 's-1', request_id: 'r-1',
      response_id: 'r-1:gen2', generation: 2,
      task_id: 'work_1', status: 'running', terminal: false,
    })
  })

  it('终态标记由网关判定后下发——客户端不该自己维护一份 status 白名单', () => {
    const { sent, agent } = harness()

    agent.emit('r-1', task('work_1', 'running', false))
    agent.emit('r-1', task('work_1', 'completed', true))

    assert.deepEqual(
      sent.filter(f => f.type === 'turn.task').map(f => [f.status, f.terminal]),
      [['running', false], ['completed', true]],
    )
  })

  /// 回合终态之后到达的任务终态**必须**照样下发：它正是客户端解除闸门的那条
  /// 事件。在这里按 `doneEmitted` 丢掉它，等于把本单要防的死锁亲手造出来。
  it('回合已 done 之后的任务终态仍然下发', () => {
    const { sent, logs, agent } = harness()
    agent.emit('r-1', task('work_1', 'running', false))
    agent.emit('r-1', {
      type: 'agent.audio.done', response_id: 'r-1:gen2', final_sequence: -1,
    })
    // 空回合的 done 有一个有界观察窗，这里不依赖它是否已经释放——
    // 只断言任务终态无论如何都能出去。
    agent.emit('r-1', task('work_1', 'completed', true))

    const terminalFrame = sent.filter(f => f.type === 'turn.task').at(-1)
    assert.equal(terminalFrame.task_id, 'work_1')
    assert.equal(terminalFrame.terminal, true)
    assert.ok(
      logs.some(l => l.evt === 'downlink_turn_task' && l.terminal === true),
      'downlink_turn_task 必须留证，真机复盘要靠它把 UI 状态与任务对上',
    )
  })

  it('没有 task id 的事件不产生下行帧', () => {
    const { sent, agent } = harness()

    agent.emit('r-1', { type: 'agent.task', response_id: 'r-1:gen2', task: {} })

    assert.equal(sent.filter(f => f.type === 'turn.task').length, 0)
  })

  it('任务事件不触碰任何播放屏障', () => {
    const { session, sent, agent } = harness()

    agent.emit('r-1', task('work_1', 'running', false))

    assert.equal(session.doneEmitted, false)
    assert.equal(session.segmentsEmitted, 0)
    assert.equal(sent.filter(f => f.type === 'audio.done').length, 0)
    assert.equal(sent.filter(f => f.type === 'audio.segment_done').length, 0)
  })
})
