// ESS-990：回合终态判据取证的落地——**存在未终结 task ⇒ 一律不得收口回合**。
//
// 为什么需要它（2026-08-22 对真实上游实测，200 秒观察窗，问「杭州今天天气怎么样」）：
//
//    0.013  voice.state {"state":"idle"}     ← 连接初始态，回答尚未开始
//    6.204  audio.done  第 1 段
//    6.257  voice.state {"state":"thinking"} ← 是 thinking，不是 idle
//   10.222  audio.done  末段
//          …此后 190 秒零事件，没有任何 voice.state…
//
// 结论（已确认，非嫌疑）：ESS-969 选的终态 `voice.state {state:'idle'}`
// **在真实上游的健康回合上根本不会到**。于是回合只能落到 45 s 兜底，
// 而客户端 45 s 硬超时先一步误报「回答超时」——ESS-1004 的用户可见故障。
//
// 所以本单把终态判据换成**上游确实会发的事实**：未终结 task 集合。
// 它只用于**否决**收口，不用于在 done 时刻直接判 final——因为实测
// `task.accepted` 可能比第 1 段 `audio.done` 晚约 800 ms，远超 `doneSettleMs=120`，
// done 那一刻的 task 集合是不完整的。
import assert from 'node:assert/strict'
import { after, describe, it } from 'node:test'
import { WebSocketServer } from 'ws'
import { QwenAgentTransport } from '../qwen-agent-transport.mjs'

const servers = []
after(async () => {
  await Promise.all(servers.splice(0).map(s => new Promise(r => s.close(r))))
})

async function upstream(onMessage) {
  const server = new WebSocketServer({ port: 0 })
  servers.push(server)
  server.on('connection', ws => {
    ws.on('message', raw => onMessage(ws, JSON.parse(raw.toString())))
  })
  await new Promise(r => server.once('listening', r))
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

const b64 = s => Buffer.from(s, 'utf8').toString('base64')

// 建一个「已经 park 了一个段落」的回合：多段模式需要先见过 voice.state。
async function parkedSegment({ backstopMs }) {
  let socket
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') { socket = ws; ws.send(JSON.stringify({ type: 'voice.ready' })) }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, responseTimeoutMs: 0, doneSettleMs: 5,
    multiSegmentMode: 'always', turnIdleBackstopMs: backstopMs,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r990', sessionId: 's990', generation: 1, responseId: 'r990:gen1',
    onEvent: e => events.push(e),
  })
  await waitFor(() => logs.some(l => l.evt === 'upstream_ready'))
  const send = o => socket.send(JSON.stringify(o))
  send({ type: 'audio.delta', sequence: 0, audio: b64('seg1'), sampleRate: 24000 })
  send({ type: 'audio.done' })
  await waitFor(() => logs.some(l => l.evt === 'upstream_segment_closed'))
  return { turn, events, logs, send }
}

describe('ESS-990 未终结 task 否决回合收口', () => {
  it('有未终结 task 时，兜底到期也不收口', async () => {
    const { turn, events, logs, send } = await parkedSegment({ backstopMs: 40 })
    send({ type: 'task.running', task: { id: 'w1', status: 'running' } })
    await waitFor(() => logs.some(l => l.evt === 'upstream_task_state'))

    await waitFor(() => logs.some(l => l.evt === 'upstream_turn_terminal_vetoed'))
    const vetoed = logs.find(l => l.evt === 'upstream_turn_terminal_vetoed')
    assert.equal(vetoed.reason, 'idle_backstop')
    assert.equal(vetoed.outstanding_tasks, 1)
    assert.deepEqual(vetoed.task_ids, ['w1'])
    // 否决意味着回合还活着：不得下发任何 agent.audio.done
    assert.equal(events.some(e => e.type === 'agent.audio.done'), false,
      '未终结 task 存在时不得收口回合')
    turn.close()
  })

  it('最后一件 task 终结即收口，理由是 tasks_settled', async () => {
    const { turn, events, logs, send } = await parkedSegment({ backstopMs: 0 })
    send({ type: 'task.running', task: { id: 'w1', status: 'running' } })
    send({ type: 'task.running', task: { id: 'w2', status: 'running' } })
    await waitFor(() => logs.filter(l => l.evt === 'upstream_task_state').length === 2)

    // 只结掉一件：集合非空，仍不收口
    send({ type: 'task.completed', task: { id: 'w1', status: 'completed' } })
    await waitFor(() => logs.filter(l => l.evt === 'upstream_task_state').length === 3)
    assert.equal(events.some(e => e.type === 'agent.audio.done'), false,
      '还剩一件在跑，不能收口')

    // 结掉最后一件 → 这才是回合真正的终点
    send({ type: 'task.failed', task: { id: 'w2', status: 'failed' } })
    await waitFor(() => events.some(e => e.type === 'agent.audio.done'))
    const terminal = logs.find(l => l.evt === 'upstream_turn_terminal')
    assert.equal(terminal.reason, 'tasks_settled')
    // failed 也是终态：任务失败不等于回合还欠一段
    turn.close()
  })

  it('没有 task 时兜底照旧收口，本改动不得让健康回合永远挂着', async () => {
    const { turn, events, logs } = await parkedSegment({ backstopMs: 40 })
    await waitFor(() => events.some(e => e.type === 'agent.audio.done'))
    const terminal = logs.find(l => l.evt === 'upstream_turn_terminal')
    assert.equal(terminal.reason, 'idle_backstop')
    assert.equal(logs.some(l => l.evt === 'upstream_turn_terminal_vetoed'), false)
    turn.close()
  })
})
