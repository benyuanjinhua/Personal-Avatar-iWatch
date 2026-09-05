// ESS-1160：`task.state` 进展帧的**产生端**护栏。
//
// 事故（真机 2026-09-05，turn `01a07230-b0a1-795a-ad2a-d2e67c6478be`）：
// 上游在 209 毫秒内连发 33 条同文「正在整理结果」，网关逐帧下发；
// bridge.log 对时显示客户端消费落后 3 秒，断线前 15 毫秒猛追 8 帧，
// 随即 `close_code=1006` 异常断开，长任务答案全丢（`answer_seq` 始终为 nil）。
//
// ESS-1100 的同文去抖放在客户端 `ToolProgressNarration.swift`，那是**渲染**
// 节流——已经上了 WSS 与 WCSession 的帧一个都少不了。所以抑制必须在网关侧做。
//
// 本文件钉住四条不变量：
//   1. 同文连续 N 次只发 1 帧，`progress_seq` 只 +1（不留序号空洞）；
//   2. 文本一变立即下发；
//   3. 同文超过 `progressHeartbeatMs` 补发心跳帧，客户端不会误判链路卡死；
//   4. 帧率超过 `maxTaskStateFramesPerSecond` 的帧被丢弃并计数，且
//      **携带 `answer_delta` 的帧永不被抑制或限速丢弃**（答案是正确性面，
//      不是展示面）。

import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import { RealtimeSession } from '../realtime-session.mjs'
import { ScriptedAgentTransport } from '../agent-transport.mjs'

function harness(over = {}) {
  const sent = []
  const logs = []
  const agent = new ScriptedAgentTransport()
  const scope = { device_id: 'd-1', session_id: 's-1', request_id: 'r-1', generation: 1 }
  let clock = 1_000
  const session = new RealtimeSession({
    scope,
    send: text => sent.push(JSON.parse(text)),
    close: () => {},
    agentTransport: agent,
    log: (evt, extra) => logs.push({ evt, ...extra }),
    heartbeatIntervalMs: 0, idleDisconnectMs: 0, commitDeadlineMs: 0,
    now: () => clock,
    ...over,
  })
  session.onFrame(JSON.stringify({
    type: 'session.start',
    session_id: scope.session_id, request_id: scope.request_id,
    generation: scope.generation, protocol_version: 1,
  }))
  return {
    session, sent, logs, agent, scope,
    advance: ms => { clock += ms },
    // 复现事故形态：上游同一个任务反复报同一句进展。
    progress: (text, extra = {}) => agent.emit(scope.request_id, {
      type: 'agent.task',
      task: { id: 'work-1', status: 'running' },
      progress: { text, category: 'text' },
      ...extra,
    }),
  }
}

const taskStates = sent => sent.filter(f => f.type === 'task.state')
const withProgress = sent => taskStates(sent).filter(f => f.progress_text !== undefined)

describe('ESS-1160 · 进展帧产生端护栏', () => {
  it('同文连续 33 次只下发 1 帧，progress_seq 只 +1（事故形态回归）', () => {
    const h = harness()
    for (let i = 0; i < 33; i += 1) h.progress('正在整理结果')

    const frames = withProgress(h.sent)
    assert.equal(frames.length, 1, '33 帧同文只应下发 1 帧')
    assert.equal(frames[0].progress_text, '正在整理结果')
    assert.equal(frames[0].progress_seq, 1, 'progress_seq 不得被抑制帧推高')

    // 整帧被压掉时不会再产生 `downlink_task_state`，所以累计计数看会话状态；
    // 对外的可观测出口是 `session_ended`（见本文件最后一个用例）。
    assert.equal(h.session.progressSuppressedSameText, 32, '被抑制的帧数须可观测')
  })

  it('文本一变立即下发，序号连续无空洞', () => {
    const h = harness()
    h.progress('正在排队')
    h.progress('正在排队')
    h.progress('正在处理')
    h.progress('正在处理')
    h.progress('正在整理结果')

    const frames = withProgress(h.sent)
    assert.deepEqual(
      frames.map(f => [f.progress_seq, f.progress_text]),
      [[1, '正在排队'], [2, '正在处理'], [3, '正在整理结果']],
      '每次文本变化各发一帧，序号连续',
    )
  })

  it('同文超过心跳间隔补发一帧，客户端不会误判链路卡死', () => {
    const h = harness({ progressHeartbeatMs: 2_000 })
    h.progress('正在整理结果')          // seq=1，首帧
    h.advance(1_000)
    h.progress('正在整理结果')          // 未到心跳 → 抑制
    assert.equal(withProgress(h.sent).length, 1)

    h.advance(1_500)                    // 距上次实际下发 2.5s，超过心跳
    h.progress('正在整理结果')
    const frames = withProgress(h.sent)
    assert.equal(frames.length, 2, '心跳到期须补发')
    assert.equal(frames[1].progress_seq, 2, '心跳帧照常推进序号')
  })

  it('帧率超顶的帧被丢弃并计数，不失败会话', () => {
    const h = harness({ maxTaskStateFramesPerSecond: 5 })
    // 文本每次都变 → 同文抑制不介入，只能靠帧率顶挡住。
    for (let i = 0; i < 20; i += 1) h.progress(`步骤 ${i}`)

    const frames = withProgress(h.sent)
    assert.equal(frames.length, 5, '同一秒内最多放行 5 帧')
    const dropped = h.logs.filter(l => l.evt === 'downlink_task_state_rate_dropped')
    assert.equal(dropped.length, 15, '其余 15 帧应记录为限速丢弃')
    assert.equal(dropped.at(-1).total_dropped, 15)
    assert.equal(h.session.state, 'open', '限速只降级展示面，绝不失败会话')

    h.advance(1_100)                    // 滑窗翻页
    h.progress('新窗口')
    assert.equal(withProgress(h.sent).length, 6, '下一秒窗口重新放行')
  })

  it('携带 answer_delta 的帧永不被同文抑制或限速丢弃', () => {
    const h = harness({ maxTaskStateFramesPerSecond: 1 })
    h.progress('正在整理结果')          // seq=1，占满当秒配额
    for (let i = 0; i < 10; i += 1) {
      h.agent.emit(h.scope.request_id, {
        type: 'agent.task',
        task: { id: 'work-1', status: 'running' },
        progress: { text: '正在整理结果', category: 'text' },
        answer: { delta: `片段${i}` },
      })
    }
    const answers = taskStates(h.sent).filter(f => f.answer_delta !== undefined)
    assert.equal(answers.length, 10, '答案增量一条都不能丢')
    assert.deepEqual(answers.map(f => f.answer_seq), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
  })

  it('session_ended 汇总抑制与丢弃计数，供 1006 复盘区分「上游安静」与「被打爆」', () => {
    const h = harness()
    for (let i = 0; i < 10; i += 1) h.progress('正在整理结果')
    h.session.onSocketClose(1006, "peer_closed")

    const ended = h.logs.find(l => l.evt === 'session_ended')
    assert.equal(ended.close_code, 1006)
    assert.equal(ended.progress_suppressed_same_text, 9)
    assert.equal(ended.task_state_rate_dropped, 0)
  })
})
