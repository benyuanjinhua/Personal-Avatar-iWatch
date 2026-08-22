// ESS-1004：回合终态不得依赖 `voice.state {state:'idle'}`。
//
// ESS-969 选它作终态，依据是注释里的一句推断：
//   「the SAME upstream endpoint emits `voice.state {state:'idle'}`」
// 同一段注释也承认：「No real-device sample of「末段 audio.done → voice.state idle」
// exists yet」。现在样本有了，而且是反例：
//
//   三轮真机（08-22 03:29 / 05:37 / 10:34）`downlink_done` 全部为 0 次。
//
// 上游源码（`QwenAudio/qwen-audio-agent`，本机 clone）里 `state: 'idle'` 共 5 处，
// 全部是异常/边缘路径：
//   :549  模型没开始回复（error）
//   :1029 turn 无效
//   :1267 `if (!responseContext?.hasAudio)` —— **只在 response 没有音频时**
//   :1501 realtime socket 关闭
//   :1866 休眠/挂起
// 正常回答必然 `hasAudio`，因此 **永远不会**收到 idle。
//
// 后果：末段收口后回合没有正向终态，只能等 backstop 兜底。
//
// **本文件原先还断言「backstop 45 s 与客户端硬超时 45 s 相等 ⇒ 客户端总是抢先」，
// 该断言已被证伪并删除**（毕玄 REQUEST CHANGES，我核对后接受）。两个计时器不同时起表：
//   10:34:35.112  upstream_segment_closed segment_index=1   ← backstop 武装
//   10:34:35.646  session_ended reason=peer_closed          ← 0.534 s 后连接断
//   10:35:02.657  [Watch] session_answer_interim            ← 客户端 45 s 才起表
// 连接若存活，backstop 应在 10:35:20.112 触发，比客户端的 10:35:47.740 早 27.5 秒。
// 现场没触发的原因是断连（ESS-1008），不是数值相等。所以本文件不再对该常数下断言——
// 标定留给 ESS-990 用 n≥20 的实测分布做。

import assert from 'node:assert/strict'
import { after, describe, it } from 'node:test'
import { WebSocketServer } from 'ws'
import { QwenAgentTransport } from '../qwen-agent-transport.mjs'

const servers = []
after(async () => {
  await Promise.all(servers.splice(0).map(s => new Promise(r => s.close(r))))
})

// 真实的最小上游：本进程内起一个 WSS，按脚本回事件。
async function upstream(onMessage) {
  const server = new WebSocketServer({ port: 0 })
  servers.push(server)
  server.on('connection', ws => {
    ws.on('message', raw => onMessage(ws, JSON.parse(raw.toString())))
  })
  await new Promise(r => server.once('listening', r))
  return `ws://127.0.0.1:${server.address().port}/api/realtime`
}

function waitFor(predicate, timeoutMs = 2_000) {
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

// 本 PR 交付的**只有取证**，常数一个字没动（见文件头的整改说明）。
// 这两条用例钉的就是取证本身：没有它们，PR 等于零测试。
describe('ESS-1004 上游事件取证', () => {
  it('所有非 audio.delta 的上游事件都留证，含 origin / state / task_status', async () => {
    let socket
    const url = await upstream((ws, message) => {
      if (message.type === 'connect') { socket = ws; ws.send(JSON.stringify({ type: 'voice.ready' })) }
    })
    const logs = []
    const transport = new QwenAgentTransport({
      gatewayUrl: url, responseTimeoutMs: 0,
      log: (evt, extra) => logs.push({ evt, ...extra }),
    })
    const turn = transport.openTurn({
      requestId: 'r1004', sessionId: 's1004', generation: 1, responseId: 'r1004:gen1',
      onEvent: () => {},
    })
    await waitFor(() => logs.some(l => l.evt === 'upstream_ready'))

    socket.send(JSON.stringify({ type: 'voice.state', state: 'thinking' }))
    socket.send(JSON.stringify({ type: 'response.started', origin: 'agent', responseId: 'resp_x' }))
    socket.send(JSON.stringify({
      type: 'task.running', task: { id: 'work_1', status: 'running' },
    }))
    // audio.delta 量太大，刻意不进这条取证线（它有 upstream_audio_delta 专线）
    socket.send(JSON.stringify({
      type: 'audio.delta', sequence: 0, audio: Buffer.from('x').toString('base64'), sampleRate: 24000,
    }))
    await waitFor(() => logs.filter(l => l.evt === 'upstream_event_seen').length >= 3)

    const seen = logs.filter(l => l.evt === 'upstream_event_seen')
    const byType = Object.fromEntries(seen.map(l => [l.upstream_event_type, l]))
    assert.equal(byType['voice.state'].state, 'thinking')
    assert.equal(byType['response.started'].origin, 'agent')
    assert.equal(byType['task.running'].task_status, 'running')
    assert.ok(!seen.some(l => l.upstream_event_type === 'audio.delta'),
      'audio.delta 不进这条线，否则日志会被它淹掉')
    turn.close()
  })

  // 这组数据是 ESS-990 标定 backstop 的原料：兜底触发时手上还有几件后台工作。
  // 本 PR **只记录不据此改判定** —— 判定要等 n≥20 的真机样本。
  it('后台工作的起止被记账，终态事件把它移出集合', async () => {
    let socket
    const url = await upstream((ws, message) => {
      if (message.type === 'connect') { socket = ws; ws.send(JSON.stringify({ type: 'voice.ready' })) }
    })
    const logs = []
    const transport = new QwenAgentTransport({
      gatewayUrl: url, responseTimeoutMs: 0,
      log: (evt, extra) => logs.push({ evt, ...extra }),
    })
    const turn = transport.openTurn({
      requestId: 'r1004b', sessionId: 's1004b', generation: 1, responseId: 'r1004b:gen1',
      onEvent: () => {},
    })
    await waitFor(() => logs.some(l => l.evt === 'upstream_ready'))

    socket.send(JSON.stringify({ type: 'task.running', task: { id: 'w1', status: 'running' } }))
    socket.send(JSON.stringify({ type: 'task.running', task: { id: 'w2', status: 'running' } }))
    await waitFor(() => logs.filter(l => l.evt === 'upstream_event_seen').length >= 2)

    socket.send(JSON.stringify({ type: 'task.completed', task: { id: 'w1', status: 'completed' } }))
    socket.send(JSON.stringify({ type: 'task.failed', task: { id: 'w2', status: 'failed' } }))
    await waitFor(() => logs.filter(l => l.evt === 'upstream_event_seen').length >= 4)

    // completed / failed 都是终态，两件都该被移出；集合空了才谈得上「可以收口」。
    const statuses = logs.filter(l => l.evt === 'upstream_event_seen' && l.task_status)
      .map(l => l.task_status)
    assert.deepEqual(statuses, ['running', 'running', 'completed', 'failed'])
    turn.close()
  })
})
