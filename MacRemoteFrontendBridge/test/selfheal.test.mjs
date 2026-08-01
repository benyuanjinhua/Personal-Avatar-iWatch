// ESS-37 会话自愈协议级回归：
// 1. 零事件 watchdog：注入后无任何网关事件 → 快速判停摆 → 重建 WS → 同幂等键重放
// 2. 注入前健康预检：死会话（unmute 无回播）先重建，绝不盲注
// 3. 持续停摆：快速失败（不等 turn/work 超时），积压队列不被头部阻塞拖死
// 4. 中途掐线：断链即失败当前 turn（可重放），重建后重放成功，终态恰一次

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { WebSocketServer } from 'ws'
import { QwenRealtimeSessionSupervisor } from '../supervisor.mjs'

// 可编程 mock 网关：per-connection 行为由 behavior(conn) 决定
function startGateway(behavior) {
  const wss = new WebSocketServer({ host: '127.0.0.1', port: 0 })
  const state = { connections: 0, appends: [] } // appends[connIdx] = 帧数
  wss.on('connection', ws => {
    state.connections += 1
    const conn = state.connections
    state.appends[conn] = 0
    const b = behavior(conn)
    const send = obj => ws.readyState === ws.OPEN && ws.send(JSON.stringify(obj))
    let answered = false
    ws.on('message', raw => {
      let msg
      try { msg = JSON.parse(raw.toString()) } catch { return }
      if (msg.type === 'connect') { send({ type: 'voice.ready' }) ; return }
      if (msg.type === 'unmute') {
        if (b.answerProbe !== false) {
          send({ type: 'voice.ownership', state: 'active', holder: { label: 'watch-bridge' } })
        }
        return
      }
      if (msg.type === 'audio.append') {
        state.appends[conn] += 1
        if (b.killOnAppend && state.appends[conn] === 2) { ws.terminate() ; return }
        if (b.answerTurn && !answered) {
          answered = true
          setTimeout(() => {
            send({ type: 'turn.started', turnId: `t_${conn}` })
            send({ type: 'transcript.final', role: 'user', content: '测试' })
            send({ type: 'transcript.final', role: 'assistant', content: '好的' })
            send({ type: 'voice.state', state: 'idle' })
          }, 50)
        }
      }
    })
  })
  return new Promise(resolve => wss.on('listening', () => resolve({ wss, state, port: wss.address().port })))
}

function makeSupervisor(port, overrides = {}) {
  return new QwenRealtimeSessionSupervisor({
    gatewayUrl: `ws://127.0.0.1:${port}/api/realtime`,
    deviceId: 'selfheal-test',
    probeTimeoutMs: 400,
    firstEventTimeoutMs: 300,
    turnTimeoutMs: 10_000,
    rebuildDelayMs: 30,
    backoffBaseMs: 50,
    backoffMaxMs: 200,
    log: () => {},
    ...overrides,
  })
}

describe('ESS-37 realtime session self-heal', () => {
  it('zero-event stall → rebuild → replay succeeds within the same inject call', async () => {
    // 连接 1 预检通过但对音频零事件（真机停摆形态）；连接 2 正常
    const { wss, state, port } = await startGateway(conn =>
      conn === 1 ? { answerTurn: false } : { answerTurn: true })
    const supervisor = makeSupervisor(port)
    try {
      const started = Date.now()
      const result = await supervisor.injectTurn(Buffer.alloc(3200), { label: 'req-stall' })
      assert.equal(result.assistantTranscript, '好的')
      assert.ok(Date.now() - started < 5000, 'must not wait for the 10s turn timeout')
      assert.ok(supervisor.journal.some(e => e.event === 'turn.stall.zero-events'), 'stall must be detected')
      assert.ok(supervisor.journal.some(e => e.event === 'session.rebuild' && e.reason === 'turn-stalled'))
      assert.equal(state.connections, 2, 'stall must force a fresh gateway connection')
    } finally {
      supervisor.close('test-done')
      await new Promise(r => wss.close(r))
    }
  })

  it('pre-inject probe rebuilds a dead session instead of blind-injecting', async () => {
    // 连接 1 对 unmute 无回播（事件环路已死）；连接 2 正常
    const { wss, state, port } = await startGateway(conn =>
      conn === 1 ? { answerProbe: false, answerTurn: false } : { answerTurn: true })
    const supervisor = makeSupervisor(port)
    try {
      const result = await supervisor.injectTurn(Buffer.alloc(3200), { label: 'req-probe' })
      assert.equal(result.assistantTranscript, '好的')
      assert.equal(state.appends[1], 0, 'no audio may be injected into the dead session')
      assert.ok(supervisor.journal.some(e => e.event === 'session.probe.timeout'))
      assert.ok(supervisor.journal.some(e => e.event === 'session.rebuild' && e.reason === 'probe-failed'))
    } finally {
      supervisor.close('test-done')
      await new Promise(r => wss.close(r))
    }
  })

  it('persistent stall fails fast and the queued backlog drains without head-of-line blocking', async () => {
    // 所有连接都停摆：预检通过、注入零事件
    const { wss, port } = await startGateway(() => ({ answerTurn: false }))
    const supervisor = makeSupervisor(port)
    try {
      const started = Date.now()
      const outcomes = await Promise.allSettled([
        supervisor.injectTurn(Buffer.alloc(3200), { label: 'q1' }),
        supervisor.injectTurn(Buffer.alloc(3200), { label: 'q2' }),
        supervisor.injectTurn(Buffer.alloc(3200), { label: 'q3' }),
      ])
      const elapsed = Date.now() - started
      for (const o of outcomes) {
        assert.equal(o.status, 'rejected')
        assert.equal(o.reason.stalled, true, `stall must surface as a retryable-stalled error: ${o.reason.message}`)
      }
      // 3 turn × 2 attempt × ~stall窗口 ≪ 单个 10s turn 超时；旧行为下要 3×10s
      assert.ok(elapsed < 9000, `backlog must drain fast, took ${elapsed}ms`)
    } finally {
      supervisor.close('test-done')
      await new Promise(r => wss.close(r))
    }
  })

  it('mid-turn WS kill → connection-loss failure → replay completes exactly once', async () => {
    // 连接 1 在第 2 帧后掐线（模拟真网关下故意 kill WS）；连接 2 正常
    const { wss, state, port } = await startGateway(conn =>
      conn === 1 ? { killOnAppend: true } : { answerTurn: true })
    const supervisor = makeSupervisor(port)
    try {
      const result = await supervisor.injectTurn(Buffer.alloc(6400), { label: 'req-kill' })
      assert.equal(result.assistantTranscript, '好的')
      assert.ok(state.connections >= 2)
      assert.ok(supervisor.journal.some(e => e.event === 'ws.close' && e.code === 1006), 'abnormal close code must be journaled')
      assert.ok(supervisor.journal.some(e => e.event === 'turn.attempt.failed' && e.retryable === true))
      const terminalRecords = supervisor.journal.filter(e => e.event === 'turn.inject.start' && e.label === 'req-kill')
      assert.equal(terminalRecords.length, 2, 'exactly one replay')
    } finally {
      supervisor.close('test-done')
      await new Promise(r => wss.close(r))
    }
  })
})
