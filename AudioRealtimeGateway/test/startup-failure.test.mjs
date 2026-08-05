// ESS-429: standalone startup failures (thrown synchronously inside
// createGateway(), not just start() rejections) must surface as ONE
// structured startup_failed JSON line — never a bare Node stack — and the
// process must exit 1. The line is emitted on stdout (JSONL collector
// stream) and mirrored on stderr (fatal diagnostics).

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { mkdtempSync, writeFileSync, rmSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'

const HERE = dirname(fileURLToPath(import.meta.url))
const SERVER = join(HERE, '..', 'server.mjs')
const PROVIDER_SENTINEL = 'sk-startup-test-sentinel-9f8e7d6c5b'

function runServer(env = {}) {
  return spawnSync(process.execPath, [SERVER], {
    encoding: 'utf8',
    timeout: 10_000,
    env: { ...process.env, AUDIO_REALTIME_PROVIDER_KEY: PROVIDER_SENTINEL, ...env },
  })
}

function assertStructuredStartupFailure(result, { expectDetail }) {
  assert.equal(result.status, 1, `expected exit 1, got ${result.status}: ${result.stderr}`)

  const stdoutLines = result.stdout.trim().split('\n').filter(Boolean)
  assert.equal(stdoutLines.length, 1, `stdout must carry exactly one line: ${result.stdout}`)
  const record = JSON.parse(stdoutLines[0])
  assert.equal(record.evt, 'startup_failed')
  assert.ok(record.ts, 'record has ts')
  assert.match(record.detail, expectDetail)

  // Same structured line mirrored to stderr, and NO bare stack anywhere.
  assert.ok(result.stderr.includes('"evt":"startup_failed"'), `stderr missing structured line: ${result.stderr}`)
  assert.ok(!result.stderr.includes('node:fs'), `bare stack leaked to stderr: ${result.stderr}`)
  assert.ok(!/\n\s+at\s/.test(result.stderr), `stack frames leaked to stderr: ${result.stderr}`)

  // Redaction stance: provider key never appears in any stream.
  assert.ok(!result.stdout.includes(PROVIDER_SENTINEL), 'provider key leaked to stdout')
  assert.ok(!result.stderr.includes(PROVIDER_SENTINEL), 'provider key leaked to stderr')
  return record
}

test('missing TLS cert → structured startup_failed, exit 1, no bare stack', () => {
  // Default config.json points at ./certs/gateway.crt which does not exist in
  // a fresh checkout → readFileSync throws synchronously inside createGateway().
  const result = runServer()
  assertStructuredStartupFailure(result, { expectDetail: /ENOENT|no such file/ })
})

test('unknown agent_transport → structured startup_failed, exit 1, no bare stack', () => {
  const dir = mkdtempSync(join(tmpdir(), 'gw-startup-'))
  try {
    const base = JSON.parse(readFileSync(join(HERE, '..', 'config.json'), 'utf8'))
    // dev_allow_plain_ws skips cert loading entirely so the transport
    // validation is the failure under test.
    const config = { ...base, dev_allow_plain_ws: true, agent_transport: 'bogus-transport' }
    const configPath = join(dir, 'config.json')
    writeFileSync(configPath, JSON.stringify(config))

    const result = runServer({ GATEWAY_CONFIG_PATH: configPath })
    const record = assertStructuredStartupFailure(result, { expectDetail: /unknown agent_transport/ })
    assert.ok(record.detail.includes('bogus-transport'))
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('dev_allow_plain_ws with non-loopback bind → structured startup_failed', () => {
  const dir = mkdtempSync(join(tmpdir(), 'gw-startup-'))
  try {
    const base = JSON.parse(readFileSync(join(HERE, '..', 'config.json'), 'utf8'))
    const config = { ...base, dev_allow_plain_ws: true, bind: '0.0.0.0' }
    const configPath = join(dir, 'config.json')
    writeFileSync(configPath, JSON.stringify(config))

    const result = runServer({ GATEWAY_CONFIG_PATH: configPath })
    assertStructuredStartupFailure(result, { expectDetail: /loopback/ })
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})
