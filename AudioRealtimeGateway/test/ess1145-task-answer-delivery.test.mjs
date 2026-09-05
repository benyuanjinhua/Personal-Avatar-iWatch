// ESS-1145 —— 委派任务的整轮收口必须排在**最终答案交付**之后。
//
// ESS-1140 三段真实语音 E2E 只过 1/3。两条失败时间线（杭州天气
// `work_df15b9b6-…`、Obsidian 最新文章观点 `work_9c7c9665-…`）形状完全一样，
// 逐帧证据在父 Issue 的测试评论里：
//
//   41578.9 ms  upstream_event_seen        task.completed
//   41579.2 ms  upstream_turn_busy_cleared cause=task_terminal
//   41579.2 ms  upstream_turn_terminal     reason=task_terminal_audio_done   ← 收口
//   41579.3 ms  upstream_task_state        status=completed
//   —— 消费端收到 `agent.audio.done` 后关闭 WSS ——
//   之后 qwen-audio-agent 侧：
//     task.streaming_fallback  reason=cancelled          （答案文本完整，没人收）
//     task.stream.frame_dropped reason=socket_not_open category=terminal
//
// 根因不是竞态，是**顺序写反了**：`task.completed` 只证明后台任务算完了，
// 上游随后才把最终答案推进有序下行——`server/src/voice/realtime-gateway.mjs`
// 在同一个订阅回调里先 `sendTaskEvent()`（生命周期终态），再
// `taskStreamProtocol.text(finalSpeech)` + `codexStreamProjector.push()`，
// 等语音段全部排空后由 `task-stream-protocol.mjs` 的 `finish()`
// （要求 taskDone **且** responseDone）发唯一一帧 `category:'terminal'`。
// 那一帧才是「答案已交付」。本网关此前把它整个过滤掉，于是必然领先答案收口。
//
// 本文件钉四件事：
//   1. 顺序：task.completed → 答案增量 → 交付终态 → `agent.audio.done`，
//      且完整答案恰好到达一次；
//   2. 不提前收口：交付终态到达前不得有任何 `agent.audio.done`，
//      `toolGateActive()` 保持为真（WSS 不得被收口关掉）；
//   3. 终态分类：取消 / 失败 / 交付超时各有各的终态，不用正常 done 掩盖；
//   4. 向后兼容：上游不走 `task.stream` 契约时，逐字节保持改动前的行为。

import assert from 'node:assert/strict'
import { after, test } from 'node:test'
import { WebSocketServer } from 'ws'

import { QwenAgentTransport } from '../qwen-agent-transport.mjs'

const servers = []
after(async () => {
  await Promise.all(servers.splice(0).map(server => new Promise(resolve => {
    for (const client of server.clients) client.terminate()
    server.close(resolve)
  })))
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

function waitFor(predicate, timeoutMs = 4_000) {
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

// ESS-1140 逐帧证据里两条失败用例共有的委派回合骨架（杭州天气那条的时间戳）：
//   0.51 s  段1 response.started origin=model  … response.done hasFunctionCall=true
//   1.60 s  audio.done                          → upstream_tool_call_pending
//   1.60 s  task.accepted / task.stream progress / task.running
//   1.86 s  段2 response.started origin=agent 「我去查一下」
//   2.86 s  response.done hasFunctionCall=false → upstream_tool_call_resolved
//   2.98 s  audio.done → endTurn('tool_result_done') → 因任务在飞而挂起
// 分歧只发生在 `task.completed` 之后，所以这里把「之后」交给调用方写。
const delegationPrologue = (ws, taskId, { taskStream = true } = {}) => {
  send(ws, { type: 'response.started', responseId: 'up-1', origin: 'model' })
  audioDelta(ws, 0, '我正在查询')
  send(ws, { type: 'response.done', responseId: 'up-1', origin: 'model', hasFunctionCall: true })
  send(ws, { type: 'audio.done', responseId: 'up-1' })
  send(ws, { type: 'voice.state', state: 'idle', origin: 'model' })
  send(ws, { type: 'task.accepted', task: { id: taskId, status: 'queued' } })
  if (taskStream) {
    send(ws, {
      type: 'task.stream', protocolVersion: 1,
      taskId, requestId: taskId, sessionId: 's1145', generation: 1,
      category: 'progress', seq: 0, message: 'running', status: 'running',
    })
  }
  send(ws, { type: 'task.running', task: { id: taskId, status: 'running' } })
  // 委派确认段：它一收口，整轮终态就变成「候选」并被任务在飞挂起——
  // ESS-1140 里那个提前 0.3 ms 兑现的候选终态就是它。
  setTimeout(() => {
    send(ws, { type: 'response.started', responseId: 'up-2', origin: 'agent' })
    audioDelta(ws, 1, '我去查一下')
    send(ws, { type: 'response.done', responseId: 'up-2', origin: 'agent', hasFunctionCall: false })
    send(ws, { type: 'audio.done', responseId: 'up-2' })
  }, 10)
}

const streamFrame = (taskId, over = {}) => ({
  type: 'task.stream', protocolVersion: 1,
  taskId, requestId: taskId, sessionId: 's1145', generation: 1,
  ...over,
})

const ANSWER = '杭州现在大约二十七摄氏度，多云，湿度约百分之八十。'

function harness(url, over = {}) {
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, responseTimeoutMs: 0, doneSettleMs: 20,
    // 空闲窗口刻意短：本文件钉的不是「窗口够不够宽」，而是「交付没到就不许
    // 收口」。窗口再短也不该越过交付门禁——越过就是 ESS-1140 的丢答案路径。
    segmentGapMs: 40, segmentGapBusyMs: 80, toolCallWindowMs: 200,
    taskAnswerWindowMs: 1_500,
    log: (evt, extra) => logs.push({ evt, ...extra }),
    ...over,
  })
  const turn = transport.openTurn({
    requestId: 'r1145', sessionId: 's1145', deviceId: 'd1145', generation: 1,
    responseId: 'r1145:gen1',
    onEvent: event => events.push(event),
  })
  return { events, logs, turn }
}

test('ESS-1145 · 杭州天气时间线：答案在收口之前完整到达，且恰好一次', async () => {
  const taskId = 'work_df15b9b6-f8c6-4932-b556-a8fb1d371674'
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type !== 'audio.commit') return
    delegationPrologue(ws, taskId)
    // 上游真实顺序：生命周期终态在前，答案与交付终态在后。旧代码在第一行
    // 就收口了，后面三帧全部撞在已关闭的 socket 上。
    setTimeout(() => {
      send(ws, { type: 'task.completed', task: { id: taskId, status: 'completed' } })
      send(ws, streamFrame(taskId, { category: 'text', seq: 0, delta: ANSWER }))
      // 答案语音：上游 `codexStreamProjector` 逐段 speak，段间还会发投影旁白。
      send(ws, { type: 'task.stream.first_audio', taskId, sequence: 0, latency_ms: 12 })
      send(ws, { type: 'response.started', responseId: 'up-3', origin: 'agent' })
      audioDelta(ws, 2, 'answer-audio')
      send(ws, { type: 'response.done', responseId: 'up-3', origin: 'agent', hasFunctionCall: false })
      send(ws, { type: 'audio.done', responseId: 'up-3' })
      send(ws, { type: 'task.stream.segment', taskId, sequence: 0, text: ANSWER })
      send(ws, streamFrame(taskId, {
        category: 'terminal', seq: 0, status: 'completed', finalAudioSequence: 0,
      }))
      send(ws, { type: 'task.stream.done', taskId, final_sequence: 0 })
    }, 60)
  })
  const { events, logs, turn } = harness(url)
  turn.commit()
  try {
    await waitFor(() => events.some(e => e.type === 'agent.audio.done'))
    await new Promise(resolve => setTimeout(resolve, 120))

    const answers = events.filter(e => e.type === 'agent.task' && e.answer?.delta)
    assert.equal(answers.length, 1, '完整答案恰好到达一次')
    assert.equal(answers[0].answer.delta, ANSWER)

    const answerAt = events.indexOf(answers[0])
    const doneAt = events.findIndex(e => e.type === 'agent.audio.done')
    assert.ok(answerAt < doneAt,
      'ESS-1140 的失败面：答案必须排在整轮 agent.audio.done 之前')
    assert.equal(events.filter(e => e.type === 'agent.audio.done').length, 1,
      '唯一最终 terminal')
    assert.equal(events.at(-1).type, 'agent.audio.done',
      '收口必须是最后一帧——它之后没有任何东西还需要这条 WSS')

    // ESS-1145 复审整改：生命周期先到的这条路径也要钉住权威终态的位置。
    // 整改前 `maybeEndDeferredTurn()` 跑在 `onEvent(agent.task)` **之前**，
    // 正是 ESS-1140 逐帧证据里 41579.2 done / 41579.3 completed 的倒序。
    const lifecycle = events.filter(e => e.type === 'agent.task'
      && e.task?.id === taskId && e.task?.status === 'completed')
    assert.equal(lifecycle.length, 1, '权威 completed 生命周期终态恰好一次')
    assert.ok(events.indexOf(lifecycle[0]) < doneAt,
      "agent.task{status:'completed'} 必须排在 agent.audio.done 之前")

    // 收口理由可判定，且证据链完整：欠交付 → 交付到达 → 收口。
    const terminal = logs.find(l => l.evt === 'upstream_turn_terminal')
    assert.equal(terminal.reason, 'task_terminal_audio_done')
    assert.equal(terminal.awaiting_delivery, 0)
    const pending = logs.find(l => l.evt === 'upstream_task_answer_pending')
    const delivered = logs.find(l => l.evt === 'upstream_task_answer_delivered')
    assert.equal(pending.task_id, taskId)
    assert.equal(delivered.task_id, taskId)
    assert.equal(delivered.status, 'completed')
    assert.ok(logs.indexOf(pending) < logs.indexOf(delivered))
    assert.ok(logs.indexOf(delivered) < logs.indexOf(terminal))
    // 交付超时窗口必须真的武装过，否则「有界等待」只是嘴上说说。
    assert.ok(logs.some(l => l.evt === 'upstream_task_answer_window_armed'))
    // 上游的投影旁白不得被当成生命周期帧下发成 `status:'stream.done'`。
    assert.ok(!events.some(e => e.type === 'agent.task'
      && String(e.task?.status ?? '').startsWith('stream.')),
    '`task.stream.*` 是投影旁白，不是任务状态')
  } finally { turn.close() }
})

test('ESS-1145 · Obsidian 时间线：交付终态到达前，一帧 audio.done 都不许发', async () => {
  const taskId = 'work_9c7c9665-86fa-4d9d-bb7b-8cd52742cb97'
  let gate
  const opened = new Promise(resolve => { gate = resolve })
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type !== 'audio.commit') return
    delegationPrologue(ws, taskId)
    setTimeout(() => {
      send(ws, { type: 'task.completed', task: { id: taskId, status: 'completed' } })
      gate(ws)
    }, 60)
  })
  const { events, logs, turn } = harness(url)
  turn.commit()
  try {
    const ws = await opened
    await waitFor(() => logs.some(l => l.evt === 'upstream_task_answer_pending'))
    // 任务已经 completed。旧代码此刻就发 `agent.audio.done`，消费端随即关闭
    // WSS——真机上答案 100% 丢失。停在这里等两个窗口的时长，证明收口没发生。
    await new Promise(resolve => setTimeout(resolve, 250))
    assert.equal(events.filter(e => e.type === 'agent.audio.done').length, 0,
      '答案没交付就收口，正是 ESS-1140 丢答案的入口')
    assert.ok(!logs.some(l => l.evt === 'upstream_turn_terminal'))
    // 候选终态确实已经产生并被扣住（`tool_result_done` 就是 ESS-1140 里那个
    // 提前 0.3 ms 兑现的候选），而欠交付账本是扣住它的那条证据。
    assert.ok(logs.some(l => l.evt === 'upstream_turn_terminal_deferred'
      && l.candidate_reason === 'tool_result_done'))
    const pending = logs.find(l => l.evt === 'upstream_task_answer_pending')
    assert.equal(pending.task_id, taskId)
    assert.equal(pending.turn_state, 'busy')
    // 收口没发生 ⇒ 上游 socket 仍然可用，最终答案还追得上。
    send(ws, streamFrame(taskId, { category: 'text', seq: 0, delta: '最新文章的观点是……' }))
    send(ws, streamFrame(taskId, { category: 'terminal', seq: 0, status: 'completed' }))

    await waitFor(() => events.some(e => e.type === 'agent.audio.done'))
    const answerAt = events.findIndex(e => e.type === 'agent.task' && e.answer?.delta)
    const doneAt = events.findIndex(e => e.type === 'agent.audio.done')
    assert.ok(answerAt >= 0 && answerAt < doneAt)
  } finally { turn.close() }
})

test('ESS-1145 · 上游哑在交付上：显式失败，不用正常 done 掩盖', async () => {
  const taskId = 'work_silent_delivery'
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type !== 'audio.commit') return
    delegationPrologue(ws, taskId)
    // 生命周期终态到了，交付终态永远不来（上游 socket 半死 / 投影卡住）。
    setTimeout(() => {
      send(ws, { type: 'task.completed', task: { id: taskId, status: 'completed' } })
    }, 60)
  })
  const { events, logs, turn } = harness(url, { taskAnswerWindowMs: 150 })
  turn.commit()
  try {
    await waitFor(() => events.some(e => e.type === 'agent.error'))
    const error = events.find(e => e.type === 'agent.error')
    assert.equal(error.code, 'ERR_UPSTREAM_TASK_ANSWER_TIMEOUT')
    assert.equal(events.filter(e => e.type === 'agent.audio.done').length, 0,
      '答案没到就报 done，等于把失败报成通过——ESS-1140 的判定错误正是这样来的')
    const timeout = logs.find(l => l.evt === 'upstream_task_answer_timeout')
    assert.equal(timeout.task_id, taskId)
    assert.equal(timeout.ui_state, 'error')
    // 等待必须是有界的：窗口只准量静默时长，不准变成永久锁死。
    assert.equal(timeout.timeout_ms, 150)
  } finally { turn.close() }
})

// ESS-1145 复审整改（毕玄 2026-09-05 阻断）：**乱序**路径的回归。
//
// 上游只有取消/失败这一条路径会先发交付终态：`realtime-gateway.mjs` 的
// `['task.cancelling','task.cancelled']` 分支先 `taskStreamProtocol.cancel()`
//（立刻满足 taskDone && responseDone ⇒ 发 `category:'terminal'`），之后才走到
// 同一回调末尾的 `sendTaskEvent()` 下发权威的 `task.cancelled`。
//
// 整改前这里只断言 reason 与 done 次数，看不见真正的失败面：交付终态被当成
// 生命周期终态签了字，`agent.audio.done` 抢在 `agent.task{status}` 前面。
// 下面这个工厂把两条乱序用例（cancelled / failed）钉在同一组不变量上。
const outOfOrderTerminalCase = ({ title, taskId, status, expectedReason }) => {
  test(title, async () => {
    const url = await upstream((ws, message) => {
      if (message.type === 'connect') send(ws, { type: 'voice.ready' })
      if (message.type !== 'audio.commit') return
      delegationPrologue(ws, taskId)
      setTimeout(() => {
        // 交付终态**先**到（合法乱序），权威生命周期终态后到。
        send(ws, streamFrame(taskId, { category: 'terminal', seq: 0, status }))
        setTimeout(() => {
          send(ws, { type: `task.${status}`, task: { id: taskId, status } })
        }, 30)
      }, 60)
    })
    const { events, logs, turn } = harness(url)
    turn.commit()
    try {
      // 交付终态到达后先停一拍：整改前这一拍里就已经收口了。
      await waitFor(() => logs.some(l => l.evt === 'upstream_task_answer_delivered'))
      assert.equal(events.filter(e => e.type === 'agent.audio.done').length, 0,
        '交付终态不得替权威生命周期终态签字——收口不能早于 task.' + status)
      const delivered = logs.find(l => l.evt === 'upstream_task_answer_delivered')
      assert.equal(delivered.lifecycle_pending, true)
      assert.ok(delivered.outstanding_tasks >= 1,
        '在飞的生命周期账不得被交付终态删掉')

      await waitFor(() => events.some(e => e.type === 'agent.audio.done'))
      await new Promise(resolve => setTimeout(resolve, 120))

      const lifecycle = events.filter(e => e.type === 'agent.task'
        && e.task?.id === taskId && e.task?.status === status)
      const doneEvents = events.filter(e => e.type === 'agent.audio.done')
      assert.equal(lifecycle.length, 1, `权威 ${status} 生命周期终态恰好一次`)
      assert.equal(doneEvents.length, 1, '整轮终态恰好一次')
      assert.ok(events.indexOf(lifecycle[0]) < events.indexOf(doneEvents[0]),
        `agent.task{status:'${status}'} 必须排在 agent.audio.done 之前`)
      assert.equal(events.at(-1).type, 'agent.audio.done',
        '收口必须是最后一帧——消费端收到它就可以关 WSS')
      assert.equal(doneEvents[0].reason, expectedReason,
        '取消 / 失败不得与正常交付共用一个终态')
      assert.ok(!logs.some(l => l.evt === 'upstream_task_answer_timeout'),
        '交付终态先到时不得再去等一帧永远不会来的第二个交付终态')
      assert.ok(!logs.some(l => l.evt === 'upstream_task_terminal_timeout'),
        '等待权威生命周期终态是短暂的，不得烧掉在飞兜底窗口')
    } finally { turn.close() }
  })
}

outOfOrderTerminalCase({
  title: 'ESS-1145 · 取消乱序：交付终态先到也必须等权威 task.cancelled 下行后再收口',
  taskId: 'work_cancelled', status: 'cancelled',
  expectedReason: 'task_cancelled_answer_done',
})

outOfOrderTerminalCase({
  title: 'ESS-1145 · 失败乱序：交付终态先到也必须等权威 task.failed 下行后再收口',
  taskId: 'work_failed', status: 'failed',
  expectedReason: 'task_failed_answer_done',
})

test('ESS-1145 · 不走 task.stream 契约的上游逐字节保持原行为', async () => {
  const taskId = 'work_legacy'
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type !== 'audio.commit') return
    // 老上游：只有生命周期帧，一帧 `task.stream` 都没有。
    delegationPrologue(ws, taskId, { taskStream: false })
    setTimeout(() => {
      send(ws, { type: 'task.completed', task: { id: taskId, status: 'completed' } })
    }, 60)
  })
  const { events, logs, turn } = harness(url)
  turn.commit()
  try {
    await waitFor(() => events.some(e => e.type === 'agent.audio.done'))
    const terminal = logs.find(l => l.evt === 'upstream_turn_terminal')
    assert.equal(terminal.reason, 'task_terminal_audio_done',
      '老上游仍然由 task.completed 直接裁决收口')
    assert.ok(!logs.some(l => l.evt === 'upstream_task_answer_pending'),
      '没承诺过交付终态的 task 不得被等')
    assert.ok(!logs.some(l => l.evt === 'upstream_task_answer_window_armed'))
  } finally { turn.close() }
})

test('ESS-1145 · 交付未完成时上游断连：显式断连终态，不沉默也不假装成功', async () => {
  const taskId = 'work_disconnect'
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type !== 'audio.commit') return
    delegationPrologue(ws, taskId)
    setTimeout(() => {
      send(ws, { type: 'task.completed', task: { id: taskId, status: 'completed' } })
      // 答案已经开口（段落会被停放），但交付终态还没发上游就断了。
      // 这条 close 分支原本会把停放的段落当成「回合正常收口」，而挂起的
      // 候选终态被交付门禁扣着，客户端于是一帧终态都收不到。
      send(ws, streamFrame(taskId, { category: 'text', seq: 0, delta: '半截答案' }))
      send(ws, { type: 'response.started', responseId: 'up-3', origin: 'agent' })
      audioDelta(ws, 2, 'half')
      send(ws, { type: 'response.done', responseId: 'up-3', origin: 'agent', hasFunctionCall: false })
      send(ws, { type: 'audio.done', responseId: 'up-3' })
      setTimeout(() => ws.close(1001, 'gone'), 40)
    }, 60)
  })
  const { events, logs, turn } = harness(url)
  turn.commit()
  try {
    await waitFor(() => events.some(e => e.type === 'agent.error'))
    assert.equal(events.find(e => e.type === 'agent.error').code, 'ERR_UPSTREAM_DISCONNECTED')
    assert.equal(events.filter(e => e.type === 'agent.audio.done').length, 0,
      '断连不得借正常 done 收口')
    assert.ok(logs.some(l => l.evt === 'upstream_closed_task_answer_undelivered'
      && l.task_id === taskId))
  } finally { turn.close() }
})

test('ESS-1145 · 交付门禁可关：taskAnswerWindowMs<=0 退回旧收口时序，不是永久挂起', async () => {
  // 毕玄复审第 2 点：我上一版把 `taskAnswerWindowMs = 0` 说成软回滚，但当时
  // 它只是不武装计时器，门禁照拦——交付终态缺失就是永久挂起。这条用例钉住
  // 现在的语义：关掉门禁 ⇒ 逐字节回到旧时序（`task.completed` 直接收口），
  // 而且**在没有交付终态的情况下**也能收口，不挂起。
  const taskId = 'work_gate_off'
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type !== 'audio.commit') return
    delegationPrologue(ws, taskId)
    setTimeout(() => {
      // 故意不发 `category:'terminal'`：门禁开着时这会走交付超时，
      // 关掉后必须按旧时序正常收口。
      send(ws, { type: 'task.completed', task: { id: taskId, status: 'completed' } })
    }, 60)
  })
  const { events, logs, turn } = harness(url, { taskAnswerWindowMs: 0 })
  turn.commit()
  try {
    await waitFor(() => events.some(e => e.type === 'agent.audio.done'))
    await new Promise(resolve => setTimeout(resolve, 120))
    assert.equal(events.filter(e => e.type === 'agent.error').length, 0,
      '关掉门禁后不得再走交付超时失败')
    assert.equal(events.filter(e => e.type === 'agent.audio.done').length, 1)
    assert.ok(!logs.some(l => l.evt === 'upstream_task_answer_pending'),
      '门禁关掉时账本根本不建')
    assert.ok(!logs.some(l => l.evt === 'upstream_task_answer_window_armed'))
    // 旧时序也必须守住「权威终态先于收口」——那一处整改与门禁无关。
    const lifecycle = events.filter(e => e.type === 'agent.task'
      && e.task?.id === taskId && e.task?.status === 'completed')
    const doneAt = events.findIndex(e => e.type === 'agent.audio.done')
    assert.equal(lifecycle.length, 1)
    assert.ok(events.indexOf(lifecycle[0]) < doneAt)
  } finally { turn.close() }
})
