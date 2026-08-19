// ESS-886：万能 token 必须真的能走到放行分支。
//
// 事故形态（2026-08-19 19:13，白梦林升级新包后）：网关 2.3 秒内连续 9 次
// `ws_upgrade_rejected reason=missing_bearer`，零 token_issued、零 ws_upgrade。
// 根因是 `extractBearer` 的正则 `rtk_[A-Za-z0-9]+` 不含下划线，而万能 token
// 是 `rtk_dev_universal`——请求在 `missing_bearer` 关卡就被判死，
// ESS-843 加的放行分支（server.mjs:94）一次都没执行过，是死代码。
//
// 这里刻意从**最外层入口**（真实 WSS upgrade）出发，而不是直接测放行分支：
// `d3e8114` 的单测只覆盖了「分支被调用时会放行」，覆盖不到「这个 token 能不能
// 走到分支」，所以前置关卡把它挡死了 CI 也全绿。
import assert from 'node:assert/strict'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, before, describe, it } from 'node:test'
import WebSocket from 'ws'

import { createGateway } from '../server.mjs'

const UNIVERSAL = 'rtk_dev_universal'

function openUpgrade(baseUrl, token) {
  const url = `${baseUrl}/api/realtime`
    + `?device_id=probe&session_id=s-886&request_id=r-886&generation=1`
  const ws = new WebSocket(url, {
    headers: token === null ? {} : { Authorization: `Bearer ${token}` },
  })
  return new Promise(resolve => {
    ws.once('open', () => resolve({ ok: true, ws }))
    ws.once('unexpected-response', (_req, res) => resolve({ ok: false, status: res.statusCode }))
    ws.once('error', error => resolve({ ok: false, status: null, error: error.message }))
  })
}

describe('ESS-886 universal token admission', () => {
  let gateway, baseUrl

  before(async () => {
    gateway = createGateway({
      port: 0, bind: '127.0.0.1', state_dir: mkdtempSync(join(tmpdir(), 'gw-886-')),
      dev_allow_plain_ws: true, agent_transport: 'mock',
      heartbeat_interval_ms: 0, idle_disconnect_ms: 0,
      dev_universal_token: UNIVERSAL,
    })
    const server = await gateway.start()
    baseUrl = `ws://127.0.0.1:${server.address().port}`
  })
  after(async () => { await gateway.stop() })

  // 这一条就是事故本身：修复前它拿到 401。
  it('accepts the shipped universal token verbatim', async () => {
    const result = await openUpgrade(baseUrl, UNIVERSAL)
    assert.equal(result.ok, true,
      `万能 token 必须能完成 upgrade，实际 status=${result.status} ${result.error ?? ''}`)
    result.ws.close()
  })

  // 下划线是万能 token 字面量的一部分，token 解析器必须认它。
  // 这条直接钉住 `extractBearer` 的字符类，而不是钉住某一个具体字面量。
  it('parses any rtk_ token containing underscores', async () => {
    for (const token of ['rtk_dev_universal', 'rtk_a_b_c', 'rtk_plain123']) {
      const result = await openUpgrade(baseUrl, token)
      // 非万能 token 会走 issuer.consume 而被拒（正常），但**拒的理由不能是
      // missing_bearer**——那说明它根本没被解析出来。
      if (token === UNIVERSAL) assert.equal(result.ok, true, `${token} 应放行`)
      else assert.equal(result.status, 401, `${token} 应走 issuer 校验后被拒`)
      if (result.ws) result.ws.close()
    }
  })

  // 反向保证：真的没带头时仍然必须拒，别为了修这条把门开了。
  it('still refuses a request with no Authorization header', async () => {
    const result = await openUpgrade(baseUrl, null)
    assert.equal(result.ok, false)
    assert.equal(result.status, 401)
  })
})
