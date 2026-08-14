// ESS-842 / ESS-844 阻断项 1：deadline 只有在「错误帧还能送到一个仍在线的客户端」
// 时才有意义。这里钉两件事：
//   1. 相对时序 —— 出厂配置的 deadline + 送达余量必须落在事故实测的客户端存活窗口内；
//   2. 送达路径 —— 上游沉默时，真实 WSS 客户端确实先收到 error 帧，再收到带 reason
//      的 1008 关闭，而不是一条永远不说话的 socket。
import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import { readFileSync } from 'node:fs'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { after, before, describe, it } from 'node:test'
import WebSocket, { WebSocketServer } from 'ws'

import { createGateway } from '../server.mjs'
import { signRequest } from '../device-auth.mjs'

const BASE = dirname(fileURLToPath(import.meta.url))

// L1 事故实测（ESS-842 单据）：uplink_committed=12:21:03.156，
// session_ended peer_closed=12:21:13.309 —— 客户端在 commit 之后只被观测到存活
// 10.153s。这是我们唯一有实测依据的窗口，deadline 必须钉在它里面。
const OBSERVED_CLIENT_WINDOW_MS = 10_153
// 错误帧从「定时器到期」到「客户端收到」要走 fail() → error 帧 → close(1008)
// 一整条路，外加一次 WAN/WSS 往返。留 1.5s，宽于任何实测的下行送达耗时。
const ERROR_DELIVERY_MARGIN_MS = 1_500

describe('ESS-842 committed-turn deadline', () => {
  it('ships a deadline that fires inside the observed client window', () => {
    const config = JSON.parse(readFileSync(join(BASE, '..', 'config.json'), 'utf8'))
    const deadline = config.agent_response_timeout_ms
    assert.equal(typeof deadline, 'number', 'agent_response_timeout_ms 必须出厂就有值')
    assert.ok(deadline > 0, 'deadline 为 0 等于关掉终止条件')
    // 这一条就是 ESS-844 阻断项 1：12000 会让错误帧发给一个已经走掉的客户端。
    assert.ok(
      deadline + ERROR_DELIVERY_MARGIN_MS <= OBSERVED_CLIENT_WINDOW_MS,
      `deadline(${deadline}ms) + 送达余量(${ERROR_DELIVERY_MARGIN_MS}ms) 必须 ≤ 实测客户端存活窗口 ${OBSERVED_CLIENT_WINDOW_MS}ms`,
    )
    // 另一侧的下限：deadline 不能短到误杀一个正常回答的回合。
    assert.ok(deadline >= 5_000, `deadline(${deadline}ms) 过短会误杀慢但正常的回答`)
  })

  describe('delivery path', () => {
    let gateway, baseUrl, deviceId, tokenRaw, upstreamServer
    const DEADLINE_MS = 200

    before(async () => {
      // 上游：握手后回 voice.ready，然后彻底沉默（复现事故形状）。
      upstreamServer = new WebSocketServer({ host: '127.0.0.1', port: 0 })
      upstreamServer.on('connection', ws => {
        ws.on('message', raw => {
          const message = JSON.parse(raw.toString())
          if (message.type === 'connect') ws.send(JSON.stringify({ type: 'voice.ready' }))
        })
      })
      await new Promise(resolve => upstreamServer.once('listening', resolve))
      const upstreamUrl = `ws://127.0.0.1:${upstreamServer.address().port}/api/realtime`

      gateway = createGateway({
        port: 0, bind: '127.0.0.1', state_dir: mkdtempSync(join(tmpdir(), 'gw-842-')),
        dev_allow_plain_ws: true,
        heartbeat_interval_ms: 0, idle_disconnect_ms: 0,
        agent_transport: 'agent', agent_gateway_url: upstreamUrl,
        agent_response_timeout_ms: DEADLINE_MS,
      })
      deviceId = 'jackson-iphone'
      tokenRaw = crypto.randomBytes(32).toString('hex')
      gateway.devices.register(deviceId, tokenRaw)
      const server = await gateway.start()
      baseUrl = `http://127.0.0.1:${server.address().port}`
    })
    after(async () => {
      await gateway.stop()
      await new Promise(resolve => upstreamServer.close(resolve))
    })

    it('a silent upstream reaches the client as an error frame plus a 1008 close', async () => {
      const scope = {
        protocol_version: 1, device_id: deviceId,
        session_id: 's-842-' + crypto.randomBytes(2).toString('hex'),
        request_id: 'r-842-' + crypto.randomBytes(2).toString('hex'),
        generation: 1, ttl_ms: 30_000,
      }
      const nonce = crypto.randomBytes(8).toString('hex')
      const { rawBody, headers } = signRequest({
        tokenRaw, deviceId, method: 'POST', pathName: '/v1/realtime/session-token',
        requestId: scope.request_id, body: scope, nonce, timestamp: Date.now(),
      })
      const minted = await (await fetch(baseUrl + '/v1/realtime/session-token', {
        method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: rawBody,
      })).json()

      const query = new URLSearchParams({
        device_id: deviceId, session_id: scope.session_id,
        request_id: scope.request_id, generation: '1',
      })
      const ws = new WebSocket(`${baseUrl.replace('http', 'ws')}/api/realtime?${query}`, {
        headers: { authorization: `Bearer ${minted.token}` },
      })
      const frames = []
      const closed = new Promise(resolve => ws.on('close', (code, reason) =>
        resolve({ code, reason: String(reason) })))
      await new Promise(resolve => ws.on('open', resolve))
      ws.on('message', raw => frames.push(JSON.parse(raw.toString())))

      ws.send(JSON.stringify({
        type: 'session.start', session_id: scope.session_id,
        request_id: scope.request_id, generation: 1, protocol_version: 1,
      }))
      await new Promise(resolve => setTimeout(resolve, 50))
      ws.send(JSON.stringify({
        type: 'audio.append', session_id: scope.session_id, request_id: scope.request_id,
        generation: 1, sequence: 0, audio: Buffer.alloc(320).toString('base64'),
      }))
      const committedAt = Date.now()
      ws.send(JSON.stringify({
        type: 'audio.commit', session_id: scope.session_id, request_id: scope.request_id,
        generation: 1, sequence: 0,
      }))

      const close = await closed
      const elapsed = Date.now() - committedAt
      const error = frames.find(frame => frame.type === 'error')
      assert.ok(error, '客户端必须先收到 error 帧，而不是一条沉默的 socket')
      assert.equal(error.code, 'ERR_UPSTREAM_NO_RESPONSE')
      assert.equal(error.retriable, true)
      assert.equal(error.request_id, scope.request_id)
      // 明确的关闭原因（验收标准 3）：不是裸 1006。
      assert.equal(close.code, 1008)
      assert.equal(close.reason, 'ERR_UPSTREAM_NO_RESPONSE')
      // 相对时序：commit 到客户端拿到结论的整条路，必须收在 deadline 的量级内。
      assert.ok(elapsed < DEADLINE_MS + 2_000, `送达耗时 ${elapsed}ms 过长`)
      // 没有回答就不许伪造 done。
      assert.ok(!frames.some(frame => frame.type === 'audio.done'))
    })
  })
})
