// ESS-1160 — `task.state` 进展帧风暴必须在**产生端**收住。
//
// 事故取证（真机 turn `01a07230-b0a1-795a-ad2a-d2e67c6478be`）：上游在 209 ms
// 内推了 33 次逐字相同的「正在整理结果」，网关 `_emitTaskState` 只要文本非空
// 就自增序号并整帧下发（每帧 295 bytes），客户端在 iPhone → Watch 的 WCSession
// 那一跳积压 3 s，随后 1006 断连，`segments_emitted=0 done_emitted=false`，
// 答案一个字都没到过手表。
//
// ESS-1100 的「同文去抖 + 0.8 s 节流」在客户端 `ToolProgressNarration.swift`，
// 那是**渲染**节流：它减少 UI 刷新次数，减不掉已经上了网络的 33 帧。本文件钉
// 的是产生端的三条义务：
//   1. 同文不重发（且**不占** `progress_seq`）；
//   2. 文本变化或生命周期跃迁立即下发，抑制永远不吃裁决面；
//   3. 同文超过心跳间隔补一帧，客户端的 60 s 任务活动看门狗仍有据可依。
// 外加一条护栏：纯展示帧的每秒上限，以及它的可判定取证。

import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import { RealtimeSession } from '../realtime-session.mjs'
import { ScriptedAgentTransport } from '../agent-transport.mjs'

const RESPONSE_ID = 'r-1:gen2'

/// 可控时钟的会话夹具。抑制与限速都是**时间**判据，用真实时钟测就是在赌
/// 机器快慢，这里把 `now` 注入进去，每个用例自己推时间。
function harness({ taskStateHeartbeatMs, maxTaskStateFramesPerSecond,
  taskStateSnapshotWindowMs } = {}) {
  const sent = []
  const logs = []
  const agent = new ScriptedAgentTransport()
  const scope = { device_id: 'd-1', session_id: 's-1', request_id: 'r-1', generation: 2 }
  let clock = 1_000
  const session = new RealtimeSession({
    scope,
    send: text => sent.push(JSON.parse(text)),
    close: () => {},
    agentTransport: agent,
    log: (evt, extra) => logs.push({ evt, ...extra }),
    heartbeatIntervalMs: 0, idleDisconnectMs: 0, commitDeadlineMs: 0,
    now: () => clock,
    setTimer: () => null, clearTimer: () => {},
    ...(taskStateHeartbeatMs === undefined ? {} : { taskStateHeartbeatMs }),
    ...(maxTaskStateFramesPerSecond === undefined ? {} : { maxTaskStateFramesPerSecond }),
    ...(taskStateSnapshotWindowMs === undefined ? {} : { taskStateSnapshotWindowMs }),
  })
  session.onFrame(JSON.stringify({
    type: 'session.start',
    session_id: scope.session_id, request_id: scope.request_id,
    generation: scope.generation, protocol_version: 1,
  }))
  return {
    session, sent, logs, agent,
    advance: ms => { clock += ms },
    at: () => clock,
    /// 一帧上游 `agent.task`，形状与 `qwen-agent-transport.mjs` 下发的一致。
    task: ({ id = 'task-1', status = 'running', text = null, category = null,
      delta = null } = {}) => agent.emit('r-1', {
      type: 'agent.task', response_id: RESPONSE_ID,
      task: { id, status },
      ...(text === null ? {} : { progress: { text, ...(category ? { category } : {}) } }),
      ...(delta === null ? {} : { answer: { delta } }),
    }),
    latch: status => agent.emit('r-1', {
      type: 'agent.tool_call_state', response_id: RESPONSE_ID, status,
    }),
  }
}

const taskState = sent => sent.filter(f => f.type === 'task.state')
const logsOf = (logs, evt) => logs.filter(l => l.evt === evt)

describe('ESS-1160 · 同文抑制', () => {
  it('209ms 内 33 帧同文只下发 1 帧，progress_seq 只 +1', () => {
    const h = harness()
    // 事故的时序：33 帧挤在 209 ms 里，平均 6.3 ms 一帧。
    for (let i = 0; i < 33; i += 1) {
      h.task({ status: 'running', text: '正在整理结果', category: 'text' })
      h.advance(6)
    }
    const frames = taskState(h.sent)
    assert.equal(frames.length, 1, '同文 33 帧只应下发第一帧')
    assert.equal(frames[0].progress_text, '正在整理结果')
    assert.equal(frames[0].progress_seq, 1)
    assert.equal(h.session.taskStateSuppressedSameText, 32)
    // 抑制的帧不占序号：客户端「不比已应用的更新就丢弃」的规则不能有洞。
    assert.equal(h.session.progressSequence, 1)
  })

  it('被抑制的帧不落日志——不能把线格上的风暴原样搬进日志', () => {
    const h = harness()
    for (let i = 0; i < 10; i += 1) {
      h.task({ text: '正在整理结果', category: 'text' })
      h.advance(5)
    }
    assert.equal(logsOf(h.logs, 'downlink_task_state').length, 1)
  })

  it('文本一变立刻下发，不受心跳间隔约束', () => {
    const h = harness()
    h.task({ text: '正在查询相关信息', category: 'search' })
    h.advance(5)
    h.task({ text: '正在查询相关信息', category: 'search' })   // 同文 → 抑制
    h.advance(5)
    h.task({ text: '正在读取相关内容', category: 'read' })     // 变了 → 立刻
    const frames = taskState(h.sent)
    assert.deepEqual(frames.map(f => f.progress_text),
      ['正在查询相关信息', '正在读取相关内容'])
    assert.deepEqual(frames.map(f => f.progress_seq), [1, 2])
  })

  it('类目变化也算展示面变化（同文不同 category 仍下发）', () => {
    const h = harness()
    h.task({ text: '正在执行任务', category: 'plan' })
    h.advance(5)
    h.task({ text: '正在执行任务', category: 'run' })
    const frames = taskState(h.sent)
    assert.equal(frames.length, 2)
    assert.deepEqual(frames.map(f => f.progress_category), ['plan', 'run'])
  })

  it('同文满 2s 补一帧心跳，序号继续递增且带取证标记', () => {
    const h = harness()
    h.task({ text: '正在整理结果', category: 'text' })
    h.advance(1_999)
    h.task({ text: '正在整理结果', category: 'text' })
    assert.equal(taskState(h.sent).length, 1, '不足心跳间隔仍抑制')
    h.advance(1)                                    // 累计 2000ms
    h.task({ text: '正在整理结果', category: 'text' })
    const frames = taskState(h.sent)
    assert.equal(frames.length, 2, '满 2s 必须补心跳帧')
    assert.equal(frames[1].progress_seq, 2)
    const emitted = logsOf(h.logs, 'downlink_task_state')
    assert.equal(emitted[1].same_text_heartbeat, true)
    assert.equal(emitted[0].same_text_heartbeat, false)
    assert.equal(emitted[1].suppressed_same_text, 1)
  })

  it('taskStateHeartbeatMs=0 关闭抑制（逐帧下发的老行为可回退）', () => {
    const h = harness({ taskStateHeartbeatMs: 0 })
    for (let i = 0; i < 5; i += 1) h.task({ text: '正在整理结果', category: 'text' })
    assert.equal(taskState(h.sent).length, 5)
    assert.equal(h.session.taskStateSuppressedSameText, 0)
  })
})

describe('ESS-1160 · 抑制不吃裁决面', () => {
  it('status 跃迁永远下发，哪怕进展文字一字未变', () => {
    const h = harness()
    h.task({ status: 'running', text: '正在整理结果', category: 'text' })
    h.advance(3)
    h.task({ status: 'finalizing', text: '正在整理结果', category: 'text' })
    h.advance(3)
    h.task({ status: 'completed' })                 // 终态帧不带进展
    const frames = taskState(h.sent)
    assert.deepEqual(frames.map(f => f.status), ['running', 'finalizing', 'completed'])
    assert.equal(h.session.taskStateSuppressedSameText, 0)
  })

  it('不同 task_id 各走各的，互不抑制', () => {
    const h = harness()
    h.task({ id: 'task-1', status: 'running', text: '正在整理结果', category: 'text' })
    h.advance(3)
    h.task({ id: 'task-2', status: 'running', text: '正在整理结果', category: 'text' })
    const frames = taskState(h.sent)
    assert.deepEqual(frames.map(f => f.task_id), ['task-1', 'task-2'])
  })

  // 复审取证（ESS-1160）：只记「全局上一帧」时，两个并行 task 交替上报同一句
  // `running + 同文`，每帧相对全局上一帧都「换了 task_id」，于是每帧都被伪装成
  // 生命周期跃迁——抑制与限速双双落空，实测 1 秒 100 帧 `emitted=100
  // rateLimited=0`。判据改成按 task 分槽后，A 只跟 A 的上一帧比。
  it('两个 task 交替刷同文 100 次不再互相伪装成跃迁', () => {
    const h = harness()
    for (let i = 0; i < 100; i += 1) {
      h.task({ id: i % 2 === 0 ? 'task-0' : 'task-1', status: 'running',
        text: '正在整理结果', category: 'text' })
      h.advance(5)          // 500ms 内 100 帧，同一个限速窗口
    }
    const frames = taskState(h.sent)
    // 两个 task 各自的第一帧（首见即新信息），其余 98 帧全被同文抑制。
    assert.equal(frames.length, 2)
    assert.deepEqual(frames.map(f => f.task_id), ['task-0', 'task-1'])
    assert.equal(h.session.taskStateSuppressedSameText, 98)
  })

  it('交错风暴之后，两个 task 的 completed 都立即下发', () => {
    const h = harness()
    for (let i = 0; i < 100; i += 1) {
      h.task({ id: i % 2 === 0 ? 'task-0' : 'task-1', status: 'running',
        text: '正在整理结果', category: 'text' })
      h.advance(5)
    }
    h.task({ id: 'task-0', status: 'completed' })
    h.task({ id: 'task-1', status: 'completed' })
    const terminal = taskState(h.sent).filter(f => f.status === 'completed')
    // 客户端 `ToolTurnAggregate` 靠这两帧清空未结集合，一帧都不能少。
    assert.deepEqual(terminal.map(f => f.task_id), ['task-0', 'task-1'])
  })

  it('文字每帧都在变的交错风暴由限速兜住', () => {
    const h = harness({ maxTaskStateFramesPerSecond: 5 })
    for (let i = 0; i < 40; i += 1) {
      h.task({ id: i % 2 === 0 ? 'task-0' : 'task-1', status: 'running',
        text: `正在执行第${i}步`, category: 'plan' })
      h.advance(5)
    }
    // 两个 task 的首帧是「首见」跃迁，直通；其余展示帧受 5 fps 预算约束。
    assert.equal(taskState(h.sent).length, 5)
    assert.equal(h.session.taskStateRateLimited, 35)
  })

  it('槽表按插入序淘汰，长时间不动的 task 不会把内存撑大', () => {
    const h = harness()
    for (let i = 0; i < 200; i += 1) {
      h.task({ id: `task-${i}`, status: 'running' })
      h.advance(1)
    }
    assert.equal(h.session._taskStateSlots.size, h.session.maxTaskStateSlots)
  })

  it('答案增量帧永不被抑制（内容是增量，逐帧都不同）', () => {
    const h = harness()
    h.task({ status: 'running', delta: '杭州' })
    h.advance(2)
    h.task({ status: 'running', delta: '今天' })
    h.advance(2)
    h.task({ status: 'running', delta: '多云' })
    const frames = taskState(h.sent)
    assert.deepEqual(frames.map(f => f.answer_delta), ['杭州', '今天', '多云'])
    assert.deepEqual(frames.map(f => f.answer_seq), [1, 2, 3])
    assert.equal(h.session.taskStateSuppressedSameText, 0)
  })

  it('风暴期间到达的答案增量照常下发——事故里丢的正是它', () => {
    const h = harness()
    for (let i = 0; i < 20; i += 1) {
      h.task({ text: '正在整理结果', category: 'text' })
      h.advance(6)
    }
    h.task({ status: 'running', delta: '知识库的核心观点是' })
    const frames = taskState(h.sent)
    assert.equal(frames.length, 2)
    assert.equal(frames[1].answer_delta, '知识库的核心观点是')
  })

  it('工具调用闩锁：重复 pending 被抑制，resolved 立即下发', () => {
    const h = harness()
    h.latch('tool_call_pending')
    h.advance(4)
    h.latch('tool_call_pending')
    h.advance(4)
    h.latch('tool_call_resolved')
    const frames = taskState(h.sent)
    assert.deepEqual(frames.map(f => f.status),
      ['tool_call_pending', 'tool_call_resolved'])
    for (const frame of frames) assert.equal('task_id' in frame, false)
  })
})

describe('ESS-1160 · 背压护栏', () => {
  it('纯展示帧超过每秒上限即丢弃，计数与日志可判定', () => {
    const h = harness({ maxTaskStateFramesPerSecond: 5 })
    // 每帧文本都不同 → 同文抑制不生效，只能靠限速兜住。
    for (let i = 0; i < 20; i += 1) {
      h.task({ text: `正在执行第${i}步`, category: 'plan' })
      h.advance(10)          // 200ms 内 20 帧，全部落在同一个 1s 窗口
    }
    assert.equal(taskState(h.sent).length, 5)
    assert.equal(h.session.taskStateRateLimited, 15)
    const limited = logsOf(h.logs, 'task_state_rate_limited')
    assert.equal(limited.length, 1, '同一窗口只落一行日志，不再造第二场风暴')
    assert.equal(limited[0].limit_per_second, 5)
    assert.equal(limited[0].dropped_total, 1)
  })

  it('窗口滚动后配额恢复', () => {
    const h = harness({ maxTaskStateFramesPerSecond: 2 })
    h.task({ text: 'a' }); h.advance(10)
    h.task({ text: 'b' }); h.advance(10)
    h.task({ text: 'c' })                       // 超限
    assert.equal(taskState(h.sent).length, 2)
    h.advance(1_000)
    h.task({ text: 'd' })
    assert.equal(taskState(h.sent).length, 3)
    assert.equal(h.session.taskStateRateLimited, 1)
  })

  it('限速不碰生命周期帧与答案增量——丢裁决面比风暴更危险', () => {
    const h = harness({ maxTaskStateFramesPerSecond: 2 })
    h.task({ text: 'a' }); h.advance(5)
    h.task({ text: 'b' }); h.advance(5)
    h.task({ text: 'c' }); h.advance(5)         // 展示帧，超限丢弃
    h.task({ status: 'finalizing' }); h.advance(5)
    h.task({ status: 'running', delta: '答案' }); h.advance(5)
    h.task({ status: 'completed' })
    const frames = taskState(h.sent)
    assert.deepEqual(frames.map(f => f.status),
      ['running', 'running', 'finalizing', 'running', 'completed'])
    assert.equal(frames[3].answer_delta, '答案')
    assert.equal(h.session.taskStateRateLimited, 1)
  })

  it('繁忙窗口里的终态帧必须到达客户端——丢它就是把 ESS-1095 装回去', () => {
    // 上游一秒内推 12 帧并不病态：ESS-1109 的 24 s Codex 任务每秒都在报进展。
    // 若限速对生命周期帧一视同仁，第 11 帧起被丢，紧随其后的 `completed`
    // 正好落在窗口里 —— 客户端的工具回合闩锁就要等到 180 s 绝对上限才解除。
    const h = harness()
    for (let i = 0; i < 11; i += 1) {
      h.task({ status: 'running', text: `正在执行第${i}步`, category: 'plan' })
      h.advance(80)
    }
    h.task({ status: 'completed' })
    const frames = taskState(h.sent)
    assert.equal(frames.filter(f => f.status === 'running').length, 10, '第 11 帧展示帧超限被丢')
    assert.equal(h.session.taskStateRateLimited, 1)
    assert.ok(frames.some(f => f.status === 'completed'), '终态帧必须穿过限速窗口')
    assert.equal(frames.at(-1).status, 'completed', '终态必须是最后一帧')
  })

  it('maxTaskStateFramesPerSecond=0 关闭限速', () => {
    const h = harness({ maxTaskStateFramesPerSecond: 0 })
    for (let i = 0; i < 30; i += 1) { h.task({ text: `第${i}步` }); h.advance(1) }
    assert.equal(taskState(h.sent).length, 30)
    assert.equal(h.session.taskStateRateLimited, 0)
  })
})

describe('ESS-1160 · session_ended 帧率快照', () => {
  it('断线时报出总帧数、窗口内帧数、抑制数与限速数', () => {
    const h = harness({ taskStateSnapshotWindowMs: 5_000 })
    h.task({ text: '正在排队', category: 'queued' })
    h.advance(10_000)                            // 落在快照窗口之外
    for (let i = 0; i < 8; i += 1) {
      h.task({ text: '正在整理结果', category: 'text' })
      h.advance(6)
    }
    h.session.onSocketClose(1006, undefined)
    const ended = logsOf(h.logs, 'session_ended')
    assert.equal(ended.length, 1)
    assert.equal(ended[0].close_code, 1006)
    assert.equal(ended[0].task_state_frames, 2)
    assert.equal(ended[0].task_state_frames_last_window, 1, '窗口只数最近 5s')
    assert.equal(ended[0].task_state_snapshot_window_ms, 5_000)
    assert.equal(ended[0].task_state_suppressed_same_text, 7)
    assert.equal(ended[0].task_state_rate_limited, 0)
  })

  it('事故形态在修复后：单会话 task.state 总帧数远低于 15 帧门槛', () => {
    const h = harness()
    // 事故里的 53 帧 = 排队 / 处理 / 整理结果 三段文字 + 33 帧同文风暴 +
    // 此后每秒一帧的重复上报。同一串上游事件在修复后应收敛到个位数。
    h.task({ status: 'queued', text: '正在排队', category: 'queued' }); h.advance(7)
    h.task({ status: 'running', text: '正在处理', category: 'delegated' }); h.advance(8_868)
    h.task({ status: 'running', text: '正在整理结果', category: 'text' }); h.advance(59)
    for (let i = 0; i < 33; i += 1) {
      h.task({ status: 'running', text: '正在整理结果', category: 'text' })
      h.advance(6)
    }
    for (let i = 0; i < 3; i += 1) {
      h.advance(1_000)
      h.task({ status: 'running', text: '正在整理结果', category: 'text' })
    }
    h.session.onSocketClose(1006, undefined)
    const ended = logsOf(h.logs, 'session_ended')[0]
    assert.ok(ended.task_state_frames < 15,
      `单会话 task.state 帧数应 <15，实际 ${ended.task_state_frames}`)
    // 53 帧 → 4 帧：三段真实文字各一帧，加上第 12.1 s 那一帧同文心跳。
    assert.equal(ended.task_state_frames, 4)
    assert.equal(ended.task_state_suppressed_same_text, 35)
  })
})
