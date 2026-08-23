// ESS-886: the ESS-843 dev universal token (`rtk_dev_universal`) must survive
// the *outermost* gate, not just the branch that was written for it.
//
// `d3e8114` added the allow branch at server.mjs:94 but left `extractBearer`
// rejecting underscores, so every universal-token upgrade was answered with
// `ws_upgrade_rejected reason=missing_bearer` at server.mjs:80 and the branch
// never executed once. Unit coverage of the branch alone could not see that —
// hence the end-to-end gate-order test below.

import assert from 'node:assert/strict'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, before, describe, it } from 'node:test'
import WebSocket from 'ws'

import { createGateway, extractBearer } from '../server.mjs'

const UNIVERSAL_TOKEN = 'rtk_dev_universal'

function collectLogs() {
  const lines = []
  const original = process.stdout.write.bind(process.stdout)
  process.stdout.write = chunk => {
    if (typeof chunk === 'string' && chunk.startsWith('{"ts"')) lines.push(JSON.parse(chunk.trim()))
    return original(chunk)
  }
  return { lines, restore() { process.stdout.write = original } }
}

describe('extractBearer accepts underscores in the token body (ESS-886)', () => {
  it('parses the dev universal token verbatim', () => {
    assert.equal(extractBearer(`Bearer ${UNIVERSAL_TOKEN}`), UNIVERSAL_TOKEN)
  })

  it('parses any rtk_ token that carries underscores after the prefix', () => {
    for (const token of ['rtk_dev_universal', 'rtk_a_b_c', 'rtk__double', 'rtk_dev_universal_2']) {
      assert.equal(extractBearer(`Bearer ${token}`), token, `should parse ${token}`)
    }
  })

  it('still parses the minted hex token shape and tolerates padding', () => {
    assert.equal(extractBearer('Bearer rtk_abc123XYZ'), 'rtk_abc123XYZ')
    assert.equal(extractBearer('  Bearer   rtk_dev_universal  '), UNIVERSAL_TOKEN)
  })

  it('still rejects what it always rejected', () => {
    for (const header of [
      null, undefined, '', 'rtk_dev_universal', 'Bearer', 'Bearer ',
      'Basic rtk_dev_universal', 'Bearer dev_universal', 'Bearer rtk_bad token',
      'Bearer rtk_semi;colon',
    ]) {
      assert.equal(extractBearer(header), null, `should reject ${JSON.stringify(header)}`)
    }
  })
})

// Gate-order regression: a request carrying nothing but the universal token,
// entering at the real `upgrade` handler, must reach the allow branch.
describe('universal token reaches the allow branch through the real entry point (ESS-886)', () => {
  let gateway, port

  before(async () => {
    gateway = createGateway({
      port: 0, bind: '127.0.0.1', state_dir: mkdtempSync(join(tmpdir(), 'gw-ess886-')),
      dev_allow_plain_ws: true, dev_universal_token: UNIVERSAL_TOKEN,
      heartbeat_interval_ms: 0, idle_disconnect_ms: 0,
      // Hermetic on CI: no qwen-audio-agent on 127.0.0.1:3101.
      agent_transport: 'mock',
    })
    const server = await gateway.start()
    port = server.address().port
  })
  after(async () => { await gateway.stop() })

  function upgradeUrl(requestId) {
    return `ws://127.0.0.1:${port}/api/realtime`
      + `?device_id=&session_id=s-ess886&request_id=${requestId}&generation=1`
  }

  it('upgrades (101) and logs ws_upgrade token_mode=universal — no missing_bearer', async () => {
    const requestId = 'r-ess886-ok'
    const captured = collectLogs()
    let opened = false
    try {
      const ws = new WebSocket(upgradeUrl(requestId), {
        headers: { authorization: `Bearer ${UNIVERSAL_TOKEN}` },
      })
      opened = await new Promise(resolve => {
        ws.once('open', () => resolve(true))
        ws.once('unexpected-response', () => resolve(false))
        ws.once('error', () => resolve(false))
      })
      if (opened) {
        ws.close()
        await new Promise(resolve => ws.once('close', resolve))
      }
    } finally {
      captured.restore()
    }

    assert.ok(opened, 'universal token must complete the WSS upgrade (101), not 401')

    const mine = captured.lines.filter(l => l.request_id === requestId)
    const rejected = mine.find(l => l.evt === 'ws_upgrade_rejected')
    assert.equal(rejected, undefined, `no rejection expected, saw ${JSON.stringify(rejected)}`)

    const upgraded = mine.find(l => l.evt === 'ws_upgrade')
    assert.ok(upgraded, `expected ws_upgrade, saw: ${mine.map(l => l.evt).join(', ')}`)
    assert.equal(upgraded.token_mode, 'universal')
    assert.equal(upgraded.device_id, 'dev_universal', 'blank device_id falls back to dev_universal')

    // The whole point of ESS-886: the outermost gate must not have fired.
    const missingBearer = captured.lines.filter(l => l.reason === 'missing_bearer')
    assert.equal(missingBearer.length, 0, 'universal token must not be seen as a missing bearer')
  })

  it('a non-universal unminted token is still rejected (the branch is not a bypass)', async () => {
    const ws = new WebSocket(upgradeUrl('r-ess886-bad'), {
      headers: { authorization: 'Bearer rtk_not_the_universal_one' },
    })
    const status = await new Promise(resolve => {
      ws.on('unexpected-response', (_, response) => resolve(response.statusCode))
      ws.on('error', () => resolve(null))
    })
    assert.equal(status, 401)
  })
})
