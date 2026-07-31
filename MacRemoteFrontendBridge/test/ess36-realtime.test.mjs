// ESS-36 regression: Bridge ↔ qwen-audio-agent Realtime 双向链路的协议级回归。
// 真实网关对非 owner 的 audio.append 是静默丢弃——这些用例锁定所有权仲裁、
// 会话重建、注入回执 watchdog 与 announcement 隔离的行为。

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import WebSocket from 'ws'
import { QwenRealtimeSessionSupervisor } from '../supervisor.mjs'
import { MockGateway } from './mock-gateway.mjs'

const STALE_BRIDGE = { type: 'cli', label: 'watch-bridge', instanceId: 'bridge_stale_prev_process' }
const WEB_FRONTEND = { type: 'web', instanceId: 'web_tab_1' }

function makeSupervisor(mock, overrides = {}) {
  return new QwenRealtimeSessionSupervisor({
    gatewayUrl: `ws://127.0.0.1:${mock.port}/api/realtime`,
    deviceId: 'ess36-test',
    backoffBaseMs: 50,
    backoffMaxMs: 200,
    trailingSilenceMs: 200,
    turnTimeoutMs: 5_000,
    injectAckTimeoutMs: 400,
    log: () => {},
    ...overrides,
  })
}
const pcm = Buffer.alloc(3200) // 100ms @16k

describe('ESS-36 voice ownership arbitration', () => {
  it('stale watch-bridge holder → automatic takeover on first connect, turn completes', async () => {
    const mock = new MockGateway({ preHolder: STALE_BRIDGE })
    await mock.start()
    const supervisor = makeSupervisor(mock)
    try {
      const result = await supervisor.injectTurn(pcm, { label: 't1' })
      assert.equal(result.assistantTranscript, '现在是上午九点。')
      // 第一次 connect 不抢占、拿到 busy 后自动带 takeover 重连
      assert.deepEqual(mock.connects.map(c => c.takeover), [false, true])
      assert.ok(supervisor.journal.some(e => e.event === 'takeover.retry'))
    } finally {
      supervisor.close('test-done')
      await mock.stop()
    }
  })

  it('foreign frontend holder + takeoverFromFrontends=false → fast ERR_VOICE_BUSY, no takeover attempted', async () => {
    const mock = new MockGateway({ preHolder: WEB_FRONTEND })
    await mock.start()
    const supervisor = makeSupervisor(mock, { takeoverFromFrontends: false })
    try {
      const t0 = Date.now()
      await assert.rejects(
        supervisor.injectTurn(pcm, { label: 't1' }),
        error => error.code === 'ERR_VOICE_BUSY',
      )
      assert.ok(Date.now() - t0 < 2_000, 'busy must fail fast, not burn the turn timeout')
      assert.ok(mock.connects.every(c => c.takeover === false), 'must never try to take over a foreign frontend')
      assert.equal(mock.droppedFrames, 0, 'must not inject frames into a session that will drop them')
    } finally {
      supervisor.close('test-done')
      await mock.stop()
    }
  })

  it('foreign frontend holder + takeoverFromFrontends=true → takeover, turn completes', async () => {
    const mock = new MockGateway({ preHolder: WEB_FRONTEND })
    await mock.start()
    const supervisor = makeSupervisor(mock, { takeoverFromFrontends: true })
    try {
      const result = await supervisor.injectTurn(pcm, { label: 't1' })
      assert.equal(result.assistantTranscript, '现在是上午九点。')
    } finally {
      supervisor.close('test-done')
      await mock.stop()
    }
  })

  it('mid-session voice.deactivated → current turn fails fast; next turn re-acquires after holder leaves', async () => {
    const mock = new MockGateway({ scenario: 'silent' }) // turn 不回答，保持 in-flight
    await mock.start()
    const supervisor = makeSupervisor(mock)
    try {
      const pending = supervisor.injectTurn(pcm, { label: 't1' })
      pending.catch(() => {}) // 断言前先挂上 handler，避免 unhandled rejection
      // 等 Bridge 拿到所有权并开始注入
      await waitUntil(() => supervisor.voiceReady)
      // 另一个前台 takeover → Bridge 收到 voice.deactivated
      const intruder = new WebSocket(`ws://127.0.0.1:${mock.port}/api/realtime`)
      await new Promise(resolve => intruder.on('open', resolve))
      intruder.send(JSON.stringify({ type: 'connect', clientType: 'web', voiceEnabled: true, takeover: true }))
      await assert.rejects(pending, error => error.code === 'ERR_VOICE_BUSY')
      assert.equal(supervisor.voiceReady, false, 'ready flag must not survive ownership loss')
      // 前台退出 → 下一 turn 重新仲裁成功（无需 takeover）
      intruder.close()
      mock.scenario = 'direct'
      const result = await supervisor.injectTurn(pcm, { label: 't2' })
      assert.equal(result.assistantTranscript, '现在是上午九点。')
    } finally {
      supervisor.close('test-done')
      await mock.stop()
    }
  })
})

describe('ESS-36 inject-ack watchdog', () => {
  it('zero events after injection → recycle + one retry → completes on the fresh session', async () => {
    const mock = new MockGateway({ scenario: 'no-events-once' })
    await mock.start()
    const supervisor = makeSupervisor(mock)
    try {
      const result = await supervisor.injectTurn(pcm, { label: 't1' })
      assert.equal(result.assistantTranscript, '现在是上午九点。')
      assert.ok(supervisor.journal.some(e => e.event === 'turn.no-events'))
      assert.ok(supervisor.journal.some(e => e.event === 'turn.retry'))
      assert.equal(mock.realtimeTurns, 2, 'exactly one retry')
    } finally {
      supervisor.close('test-done')
      await mock.stop()
    }
  })
})

describe('ESS-36 real-protocol turn outcomes', () => {
  it('origin=agent answer (backend agent presentation) completes the turn', async () => {
    const mock = new MockGateway({ scenario: 'agent-origin' })
    await mock.start()
    const supervisor = makeSupervisor(mock)
    try {
      const result = await supervisor.injectTurn(pcm, { label: 't1' })
      assert.equal(result.assistantTranscript, '今天是星期五。')
      assert.equal(result.state, 'completed_direct')
    } finally {
      supervisor.close('test-done')
      await mock.stop()
    }
  })

  it('transcript.discard → fast ERR_TRANSCRIPT_DISCARDED instead of burning the turn timeout', async () => {
    const mock = new MockGateway({ scenario: 'discard' })
    await mock.start()
    const supervisor = makeSupervisor(mock)
    try {
      const t0 = Date.now()
      await assert.rejects(
        supervisor.injectTurn(pcm, { label: 't1' }),
        error => error.code === 'ERR_TRANSCRIPT_DISCARDED',
      )
      assert.ok(Date.now() - t0 < 3_000, 'discard must fail fast, not wait for the turn timeout')
    } finally {
      supervisor.close('test-done')
      await mock.stop()
    }
  })
})

describe('ESS-36 announcement isolation and playback receipts', () => {
  it('announcement audio/transcript stays out of the turn result but still gets receipts', async () => {
    const mock = new MockGateway({ scenario: 'announcement' })
    await mock.start()
    const supervisor = makeSupervisor(mock)
    try {
      const result = await supervisor.injectTurn(pcm, { label: 't1' })
      assert.equal(result.assistantTranscript, '现在是上午九点。', 'announcement transcript must not leak into the turn')
      assert.equal(result.audioBytes24k, 4800, 'announcement audio must not be aggregated into the turn reply')
      assert.deepEqual(result.responseIds, ['resp_1'])
      // 回执是异步上行消息：等 mock 侧全部收齐再断言
      await waitUntil(() => mock.playbackReceipts.length >= 4)
      const receipts = mock.playbackReceipts.map(r => `${r.type}:${r.responseId}`)
      assert.ok(receipts.includes('playback.started:resp_ann') && receipts.includes('playback.ended:resp_ann'),
        'announcements must be acknowledged or the gateway announcement window stalls')
      assert.ok(receipts.includes('playback.started:resp_1') && receipts.includes('playback.ended:resp_1'))
    } finally {
      supervisor.close('test-done')
      await mock.stop()
    }
  })
})

function waitUntil(predicate, { timeoutMs = 5_000, stepMs = 20 } = {}) {
  return new Promise((resolve, reject) => {
    const t0 = Date.now()
    const timer = setInterval(() => {
      if (predicate()) { clearInterval(timer); resolve() }
      else if (Date.now() - t0 > timeoutMs) { clearInterval(timer); reject(new Error('waitUntil timeout')) }
    }, stepMs)
  })
}
