// F2 watchdog (ESS-30): a turn timeout means the realtime session has stalled
// while the socket itself is still alive — ping/pong cannot detect it. The
// supervisor must recycle the WS so the stall does not persist across turns.

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { WebSocketServer } from 'ws'
import { QwenRealtimeSessionSupervisor } from '../supervisor.mjs'

describe('F2 watchdog: turn timeout recycles the realtime WS', () => {
  it('stalled turn → forced reconnect → next turn succeeds on the new connection', async () => {
    let connections = 0
    const wss = new WebSocketServer({ host: '127.0.0.1', port: 0 })
    wss.on('connection', ws => {
      connections += 1
      const conn = connections
      let replied = false
      ws.on('message', raw => {
        let msg
        try { msg = JSON.parse(raw.toString()) } catch { return }
        if (msg.type === 'connect') {
          ws.send(JSON.stringify({ type: 'voice.ready' }))
          return
        }
        if (msg.type === 'unmute') {
          // 活性预检回播：连接 1 事件环路存活（停摆发生在 turn 层），预检必须通过
          ws.send(JSON.stringify({ type: 'voice.ownership', state: 'active', holder: { label: 'watch-bridge' } }))
          return
        }
        // 连接 1 对注入保持沉默（停摆）；连接 2 正常直答
        if (conn >= 2 && msg.type === 'audio.append' && !replied) {
          replied = true
          ws.send(JSON.stringify({ type: 'turn.started', turnId: 't1' }))
          ws.send(JSON.stringify({ type: 'transcript.final', role: 'user', content: '测试' }))
          ws.send(JSON.stringify({ type: 'transcript.final', role: 'assistant', content: '好的' }))
          ws.send(JSON.stringify({ type: 'voice.state', state: 'idle' }))
        }
      })
    })
    await new Promise(resolve => wss.on('listening', resolve))
    const port = wss.address().port

    const supervisor = new QwenRealtimeSessionSupervisor({
      gatewayUrl: `ws://127.0.0.1:${port}/api/realtime`,
      deviceId: 'watchdog-test',
      turnTimeoutMs: 700,
      backoffBaseMs: 50,
      backoffMaxMs: 200,
      log: () => {},
    })
    try {
      const pcm = Buffer.alloc(3200)
      await assert.rejects(
        supervisor.injectTurn(pcm, { label: 'stalled' }),
        /turn timeout/,
      )
      assert.ok(
        supervisor.journal.some(e => e.event === 'ws.recycle.turn-timeout'),
        'turn timeout must record a recycle event',
      )
      const second = await supervisor.injectTurn(pcm, { label: 'after-recycle' })
      assert.equal(second.assistantTranscript, '好的')
      assert.ok(connections >= 2, 'watchdog must have opened a fresh connection')
    } finally {
      supervisor.close('test-done')
      await new Promise(resolve => wss.close(resolve))
    }
  })
})
