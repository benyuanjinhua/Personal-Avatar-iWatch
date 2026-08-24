// ESS-1100 — 长任务的阶段性进展文字必须一路下发到客户端。
//
// 缺口（本单实现前的实际线格，`qwen-agent-transport.mjs` 老代码）：
//   上游 `task.progress` 带着完整 `publicTask`（含 `activity[]`），网关只取
//   `{id, status}` 就丢掉其余全部 → `task.state` 帧里没有任何可展示文本 →
//   客户端只能显示笼统的「正在思考」。
//
// 本文件钉两件事：
//   1. 投影规则（`task-progress.mjs`）与 H5 `web/src/task-view.js` 同口径；
//   2. 线格：`task.state` 带 `progress_text` / `progress_category` /
//      `progress_seq`，无进展时**一个键都不多**（老客户端逐字节不受影响）。

import assert from 'node:assert/strict'
import { describe, it, test } from 'node:test'
import { WebSocketServer } from 'ws'

import { RealtimeSession } from '../realtime-session.mjs'
import { ScriptedAgentTransport } from '../agent-transport.mjs'
import { QwenAgentTransport } from '../qwen-agent-transport.mjs'
import { projectTaskProgress, MAX_PROGRESS_TEXT } from '../task-progress.mjs'

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

const taskState = sent => sent.filter(f => f.type === 'task.state')

const toolActivity = (over = {}) => ({
  id: 'call-1', kind: 'tool', tool: 'web_search', label: '', status: 'running',
  category: 'search', detail: '', ...over,
})

describe('ESS-1100 · 任务进展投影', () => {
  it('工具活动按类目投影出 H5 同一句短语', () => {
    const cases = [
      ['search', '正在查询相关信息'],
      ['read', '正在读取相关内容'],
      ['write', '正在修改内容'],
      ['image', '正在生成图片'],
    ]
    for (const [category, text] of cases) {
      assert.deepEqual(
        projectTaskProgress({ status: 'running', activity: [toolActivity({ category })] }, 'task.progress'),
        { text, category },
      )
    }
  })

  it('类目缺席时按 tool/detail 兜底判定，与 H5 同一组正则', () => {
    assert.deepEqual(
      projectTaskProgress({
        status: 'running',
        activity: [toolActivity({ category: '', tool: 'WebFetch', detail: '' })],
      }, 'task.progress'),
      { text: '正在查询相关信息', category: 'search' },
    )
    assert.deepEqual(
      projectTaskProgress({
        status: 'running',
        activity: [toolActivity({ category: '', tool: 'Bash', detail: 'ls -al' })],
      }, 'task.progress'),
      { text: '正在执行任务', category: 'run' },
    )
  })

  it('取最后一条「未结束的工具」，已完成的工具不盖住在跑的那条', () => {
    const progress = projectTaskProgress({
      status: 'running',
      activity: [
        toolActivity({ id: 'a', category: 'read', status: 'completed' }),
        toolActivity({ id: 'b', category: 'search', status: 'running' }),
      ],
    }, 'task.progress')
    assert.deepEqual(progress, { text: '正在查询相关信息', category: 'search' })
  })

  it('协议内文（<qwen_audio_agent_request>）不得被当成进展说给用户', () => {
    const progress = projectTaskProgress({
      status: 'running',
      activity: [{
        kind: 'text', status: 'running',
        text: '<qwen_audio_agent_request>请查询…</qwen_audio_agent_request>',
      }],
    }, 'task.progress')
    assert.equal(progress, null)
  })

  it('等待用户确认压过一切工具进展', () => {
    const progress = projectTaskProgress({
      status: 'running',
      authorization: { status: 'pending', summary: '要不要执行删除？' },
      activity: [toolActivity()],
    }, 'task.progress')
    assert.deepEqual(progress, { text: '要不要执行删除？', category: 'authorization' })
  })

  it('生命周期子状态有各自的短语', () => {
    for (const [status, text] of [
      ['queued', '正在排队'],
      ['finalizing', '正在整理结果'],
      ['cancelling', '正在取消'],
      ['delegated', '正在处理'],
    ]) {
      assert.deepEqual(
        projectTaskProgress({ status }, `task.${status}`),
        { text, category: status },
      )
    }
  })

  it('终态不产出进展文字——终态由 status 独占表达', () => {
    for (const status of ['completed', 'failed', 'cancelled', 'timeout']) {
      assert.equal(
        projectTaskProgress({ status, activity: [toolActivity()] }, `task.${status}`),
        null,
      )
    }
  })

  it('没有任何活动时返回 null，由客户端回退到稳定的「正在处理」', () => {
    assert.equal(projectTaskProgress({ status: 'running', activity: [] }, 'task.progress'), null)
    assert.equal(projectTaskProgress({ status: 'running' }, 'task.running'), null)
    assert.equal(projectTaskProgress(null, 'task.progress'), null)
  })

  it('计划活动的自由文本按小屏上限截断', () => {
    const long = '把'.repeat(MAX_PROGRESS_TEXT * 2)
    const progress = projectTaskProgress({
      status: 'running',
      activity: [{ kind: 'plan', status: 'running', detail: long, completed: 1, total: 3 }],
    }, 'task.progress')
    assert.equal(Array.from(progress.text).length, MAX_PROGRESS_TEXT)
    assert.equal(progress.category, 'plan')
  })
})

describe('ESS-1100 · task.state 线格', () => {
  it('带进展的帧下发 progress_text / progress_category / 单调 progress_seq', () => {
    const { sent, agent } = harness()

    agent.emit('r-1', {
      type: 'agent.task', response_id: 'r-1:gen2',
      task: { id: 'work_1', status: 'running' },
      progress: { text: '正在查询相关信息', category: 'search' },
    })
    agent.emit('r-1', {
      type: 'agent.task', response_id: 'r-1:gen2',
      task: { id: 'work_1', status: 'running' },
      progress: { text: '正在整理结果', category: 'text' },
    })

    assert.deepEqual(taskState(sent), [
      {
        type: 'task.state', session_id: 's-1', request_id: 'r-1', generation: 2,
        task_id: 'work_1', status: 'running',
        progress_text: '正在查询相关信息', progress_seq: 1, progress_category: 'search',
      },
      {
        type: 'task.state', session_id: 's-1', request_id: 'r-1', generation: 2,
        task_id: 'work_1', status: 'running',
        progress_text: '正在整理结果', progress_seq: 2, progress_category: 'text',
      },
    ])
  })

  it('无进展的帧与 ESS-1097 的老帧逐字节相同——老客户端不受影响', () => {
    const { sent, agent } = harness()

    agent.emit('r-1', {
      type: 'agent.task', response_id: 'r-1:gen2', task: { id: 'work_1', status: 'running' },
    })

    assert.deepEqual(taskState(sent), [{
      type: 'task.state', session_id: 's-1', request_id: 'r-1', generation: 2,
      task_id: 'work_1', status: 'running',
    }])
  })

  it('progress_seq 只在真的带了进展时递增，中间的无进展帧不吃掉号', () => {
    const { sent, agent } = harness()

    agent.emit('r-1', {
      type: 'agent.task', response_id: 'r-1:gen2',
      task: { id: 'w', status: 'running' }, progress: { text: '正在查询相关信息', category: 'search' },
    })
    agent.emit('r-1', {
      type: 'agent.task', response_id: 'r-1:gen2', task: { id: 'w', status: 'running' },
    })
    agent.emit('r-1', {
      type: 'agent.task', response_id: 'r-1:gen2',
      task: { id: 'w', status: 'running' }, progress: { text: '正在读取相关内容', category: 'read' },
    })

    assert.deepEqual(
      taskState(sent).map(f => f.progress_seq ?? null),
      [1, null, 2],
    )
  })

  it('空白进展文本视同没有进展，不占序号也不下发键', () => {
    const { sent, agent } = harness()

    agent.emit('r-1', {
      type: 'agent.task', response_id: 'r-1:gen2',
      task: { id: 'w', status: 'running' }, progress: { text: '   ', category: 'search' },
    })

    assert.deepEqual(taskState(sent), [{
      type: 'task.state', session_id: 's-1', request_id: 'r-1', generation: 2,
      task_id: 'w', status: 'running',
    }])
  })

  it('进展下发落进结构化日志，真机可按 request/task 关联', () => {
    const { logs, agent } = harness()

    agent.emit('r-1', {
      type: 'agent.task', response_id: 'r-1:gen2',
      task: { id: 'work_1', status: 'running' },
      progress: { text: '正在查询相关信息', category: 'search' },
    })

    const line = logs.find(entry => entry.evt === 'downlink_task_state')
    assert.equal(line.progress_text, '正在查询相关信息')
    assert.equal(line.progress_category, 'search')
    assert.equal(line.progress_seq, 1)
    assert.equal(line.task_id, 'work_1')
  })
})

// ---------------------------------------------------------------------------
// 全栈：真实上游时序（tool_call_pending → idle → task.progress ×2 → 回答音频）
//
// 验收 2 的机器可判定形态：一次长任务里至少**依次**下发两条真实中间进展，
// 并且它们都赶在回答音频之前到达——晚于回答的进展是没有意义的。
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

// 上游任务对象的真实形状（`publicTask`，见 qwen-audio-agent
// `server/src/task/task-manager.mjs`）——`activity[]` 就是进展的来源。
const upstreamTask = (status, activity) => ({
  id: 'work_x', workId: 'work_x', status,
  workState: 'active', kind: 'work', objective: '查一下这个项目的进度',
  sessionId: 'up-s', turnId: 'up-t', elapsedMs: 4_200, activity,
})

test('ESS-1100 · 全栈：两条真实中间进展在回答音频之前依次到达', async () => {
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
      send(ws, { type: 'voice.state', state: 'idle', origin: 'model' })
      setTimeout(() => {
        send(ws, {
          type: 'task.accepted',
          task: upstreamTask('queued', []),
        })
      }, 60)
      setTimeout(() => {
        send(ws, {
          type: 'task.progress',
          task: upstreamTask('running', [
            { id: 'c1', kind: 'tool', tool: 'web_search', status: 'running',
              category: 'search', label: '', detail: 'ESS-1100' },
          ]),
        })
      }, 140)
      setTimeout(() => {
        send(ws, {
          type: 'task.progress',
          task: upstreamTask('running', [
            { id: 'c1', kind: 'tool', tool: 'web_search', status: 'completed',
              category: 'search', label: '', detail: 'ESS-1100' },
            { id: 'c2', kind: 'tool', tool: 'Read', status: 'running',
              category: 'read', label: '', detail: 'notes.md' },
          ]),
        })
      }, 220)
      setTimeout(() => {
        send(ws, { type: 'response.started', responseId: 'up-2', origin: 'agent' })
        audioDelta(ws, 1, '结果是')
        send(ws, { type: 'task.completed', task: upstreamTask('completed', []) })
        send(ws, { type: 'response.done', responseId: 'up-2', origin: 'agent', hasFunctionCall: false })
        send(ws, { type: 'audio.done' })
      }, 600)
    }
  })
  const sent = []
  const scope = { device_id: 'd11', session_id: 's11', request_id: 'r11', generation: 1 }
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
    type: 'session.start', session_id: 's11', request_id: 'r11', generation: 1, protocol_version: 1,
  }))
  session.onFrame(JSON.stringify({
    type: 'audio.append', session_id: 's11', request_id: 'r11', generation: 1,
    sequence: 0, audio: Buffer.from('uplink!!').toString('base64'),
  }))
  session.onFrame(JSON.stringify({
    type: 'audio.commit', session_id: 's11', request_id: 'r11', generation: 1, sequence: 0,
  }))
  await waitFor(() => sent.some(f => f.type === 'audio.done'), 8_000)

  const withProgress = sent.filter(f => f.type === 'task.state' && f.progress_text)
  assert.deepEqual(
    withProgress.map(f => f.progress_text),
    ['正在排队', '正在查询相关信息', '正在读取相关内容'],
    '长任务必须依次给出多条真实中间进展（验收 2 要求至少两条）',
  )
  assert.deepEqual(withProgress.map(f => f.progress_seq), [1, 2, 3], 'progress_seq 严格单调')
  assert.deepEqual(
    withProgress.map(f => f.task_id),
    ['work_x', 'work_x', 'work_x'],
    '进展必须绑定任务号',
  )

  const order = sent.map(f => f.type)
  const lastProgressIdx = sent.findLastIndex(f => f.type === 'task.state' && f.progress_text)
  const answerDeltaIdx = order.lastIndexOf('audio.delta')
  assert.ok(
    lastProgressIdx < answerDeltaIdx,
    `进展必须在回答音频之前到达，晚到的进展没有意义：${order}`,
  )
  assert.ok(
    sent.some(f => f.type === 'task.state' && f.status === 'completed' && !f.progress_text),
    '终态帧不带进展文字——终态由 status 独占表达',
  )
  session.onSocketClose(1000, 'test_done')
  servers.forEach(s => s.close())
})
