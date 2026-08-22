import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  BRIDGE_TASK_TERMINAL_ERRORS,
  TurnLedger,
  isAutomaticallyRetryableTerminalError,
} from '../ledger.mjs'

describe('ESS-255 D2 terminal error projection', () => {
  const cases = [
    ['ERR_UPSTREAM_UNAVAILABLE', 'Mac 那边没应答。确认助手在运行，点重试不用重新说。'],
    ['ERR_TASK_NOT_FOUND', 'Mac 那边找不到这件事了，点重试我重新交一次。'],
    ['ERR_TASK_FAILED', '这件事我没办成，点重试再跑一次，不用重新说。'],
    ['ERR_RESULT_UNKNOWN', '这件事做完没有我不确定，去 Mac 上看一眼——我不敢替你重跑。'],
  ]

  for (const [errorCode, expectedDetail] of cases) {
    it(`projects ${errorCode} with client-safe detail`, () => {
      const stateDir = mkdtempSync(join(tmpdir(), 'terminal-error-'))
      const ledger = new TurnLedger({ stateDir })
      ledger.create({ requestId: errorCode, deviceId: 'phone', bodySha256: 'sha', sessionId: 's' })
      ledger.fail(errorCode, errorCode, `unsafe upstream detail ${errorCode}`)

      const projection = ledger.projection(errorCode)
      assert.equal(projection.error, errorCode)
      assert.equal(projection.detail, expectedDetail)
      assert.equal(projection.detail.includes('ERR_'), false)
    })
  }

  it('enumerates the real terminal set and keeps unknown-result non-retryable', () => {
    assert.deepEqual([...BRIDGE_TASK_TERMINAL_ERRORS], cases.map(([code]) => code))
    assert.equal(isAutomaticallyRetryableTerminalError('ERR_RESULT_UNKNOWN'), false)
    assert.equal(isAutomaticallyRetryableTerminalError('ERR_TASK_FAILED'), true)
    assert.equal(isAutomaticallyRetryableTerminalError('ERR_NOT_ENUMERATED'), false)
  })

  it('settles deterministic failures after one delivery and never auto-retries them', () => {
    const stateDir = mkdtempSync(join(tmpdir(), 'deterministic-failure-'))
    const ledger = new TurnLedger({ stateDir })
    ledger.create({ requestId: 'req-deterministic', deviceId: 'watch', bodySha256: 'sha', sessionId: 's' })
    ledger.fail('req-deterministic', 'ERR_FALLBACK_NOT_CONFIGURED')

    assert.equal(isAutomaticallyRetryableTerminalError('ERR_FALLBACK_NOT_CONFIGURED'), false)

    const projection = ledger.projection('req-deterministic')
    assert.equal(projection.detail, '助手这边还没准备好，这次没接上，稍后再试。')
    assert.equal(projection.detail.includes('ERR_'), false)

    // ESS-983：确定性失败第一次投递即收口——delay_ms=0，不再进入退避重投链。
    assert.deepEqual(ledger.markResultRedelivered('req-deterministic', { now: 1_000, baseDelayMs: 100 }), {
      attempt: 1, delay_ms: 0,
    })
    assert.equal(ledger.get('req-deterministic').delivered_ack.source, 'bridge_deterministic')
    assert.equal(ledger.replayable({ now: 99_999, maxDeliveryAttempts: 5 }).length, 0)
  })

  it('never exposes unknown error codes or raw failed detail', () => {
    const stateDir = mkdtempSync(join(tmpdir(), 'terminal-error-fallback-'))
    const ledger = new TurnLedger({ stateDir })
    ledger.create({ requestId: 'unknown', deviceId: 'phone', bodySha256: 'sha', sessionId: 's' })
    ledger.fail('unknown', 'ERR_PRIVATE_INTERNAL', 'secret upstream status')
    const projection = ledger.projection('unknown')
    assert.equal(projection.detail, '刚才这件事没成，点重试再来一次；还不行就再说一遍。')
    assert.equal(projection.detail.includes('ERR_'), false)
  })
})

describe('terminal result redelivery ledger', () => {
  it('marks delivered only after the matching final response really rendered', () => {
    const logs = []
    const stateDir = mkdtempSync(join(tmpdir(), 'render-delivery-'))
    const ledger = new TurnLedger({ stateDir, log: event => logs.push(event) })
    ledger.create({ requestId: 'req-render', deviceId: 'watch', bodySha256: 'sha', sessionId: 's' })
    ledger.setResult('req-render', { text: 'done', extra: { response_id: 'resp-final' } })

    assert.equal(ledger.get('req-render').delivered_ack, null, 'audio.done/result storage is not delivery')
    assert.equal(ledger.recordPlaybackEnded('req-render', {
      responseId: 'resp-final', bytesPlayed: 0,
    }), null, 'zero-byte/failed playback is not delivery')
    ledger.recordPlaybackEnded('req-render', { responseId: 'resp-old', bytesPlayed: 2400 })
    assert.equal(ledger.get('req-render').delivered_ack, null, 'another response cannot deliver the final result')

    ledger.recordPlaybackEnded('req-render', { responseId: 'resp-final', bytesPlayed: 4800 })
    assert.equal(ledger.get('req-render').delivered_ack.source, 'watch_render')
    assert.equal(ledger.replayable().some(turn => turn.request_id === 'req-render'), false)
    assert.ok(logs.some(event => event.evt === 'result_delivered_after_render'
      && event.request_id === 'req-render' && event.bytes_played === 4800))
  })

  it('reconciles an out-of-order render receipt that arrives before the terminal result', () => {
    const stateDir = mkdtempSync(join(tmpdir(), 'render-race-'))
    const ledger = new TurnLedger({ stateDir })
    ledger.create({ requestId: 'req-race', deviceId: 'watch', bodySha256: 'sha', sessionId: 's' })
    ledger.recordPlaybackEnded('req-race', { responseId: 'resp-race', bytesPlayed: 3200 })
    assert.equal(ledger.get('req-race').delivered_ack, null)

    ledger.setResult('req-race', { text: 'done', extra: { response_id: 'resp-race' } })
    assert.equal(ledger.get('req-race').delivered_ack.source, 'watch_render')

    const restarted = new TurnLedger({ stateDir })
    assert.equal(restarted.replayable().some(turn => turn.request_id === 'req-race'), false)
  })

  it('keeps interrupted playback replayable and logs attempts after delivery', () => {
    const logs = []
    const stateDir = mkdtempSync(join(tmpdir(), 'render-interrupted-'))
    const ledger = new TurnLedger({ stateDir, log: event => logs.push(event) })
    ledger.create({ requestId: 'req-interrupted', deviceId: 'watch', bodySha256: 'sha', sessionId: 's' })
    ledger.setResult('req-interrupted', { text: 'done', extra: { response_id: 'resp-i' } })
    assert.equal(ledger.replayable().some(turn => turn.request_id === 'req-interrupted'), true)

    ledger.recordPlaybackEnded('req-interrupted', { responseId: 'resp-i', bytesPlayed: 1600 })
    assert.equal(ledger.markResultRedelivered('req-interrupted'), null)
    assert.ok(logs.some(event => event.evt === 'result_replayed_after_delivered'
      && event.request_id === 'req-interrupted'))
  })

  it('projects request-correlated stage timestamps, TTFT, and end-to-end latency', () => {
    const stateDir = mkdtempSync(join(tmpdir(), 'turn-timing-'))
    const ledger = new TurnLedger({ stateDir })
    ledger.create({
      requestId: 'req-timing', deviceId: 'watch', bodySha256: 'sha', sessionId: 's',
      watchCreatedAt: '2026-08-04T00:00:00.000Z',
    })
    const bridgeAcceptedAt = ledger.get('req-timing').timing.bridge_accepted_at
    const firstAudioAt = new Date(Date.parse(bridgeAcceptedAt) + 1250).toISOString()
    ledger.update('req-timing', { state: 'processing', detail: 'realtime_processing' })
    ledger.markFirstAudioReady('req-timing', { at: firstAudioAt, source: 'direct' })
    ledger.markFirstAudioReady('req-timing', { at: '2026-08-04T00:00:09.000Z', source: 'background' })
    ledger.setResult('req-timing', { text: 'done' })

    const projection = ledger.projection('req-timing')
    assert.equal(projection.request_id, 'req-timing')
    assert.equal(projection.timing.watch_created_at, '2026-08-04T00:00:00.000Z')
    assert.ok(projection.timing.bridge_accepted_at)
    assert.ok(projection.timing.processing_started_at)
    assert.equal(projection.timing.first_audio_ready_at, firstAudioAt)
    assert.equal(projection.timing.first_audio_source, 'direct')
    assert.equal(projection.timing.voice_ttft_ms, 1250)
    assert.ok(Number.isFinite(projection.timing.end_to_end_ms))
  })

  it('backfills old ledgers with a Bridge-domain timing baseline', () => {
    const stateDir = mkdtempSync(join(tmpdir(), 'legacy-turn-timing-'))
    const first = new TurnLedger({ stateDir })
    first.create({ requestId: 'req-legacy', deviceId: 'watch', bodySha256: 'sha', sessionId: 's' })
    const legacy = first.get('req-legacy')
    delete legacy.timing
    first.save()

    const restarted = new TurnLedger({ stateDir })
    const acceptedAt = restarted.get('req-legacy').timing.bridge_accepted_at
    restarted.markFirstAudioReady('req-legacy', {
      at: new Date(Date.parse(acceptedAt) + 800).toISOString(),
      source: 'direct',
    })
    const projection = restarted.projection('req-legacy')
    assert.equal(projection.timing.watch_created_at, null)
    assert.equal(projection.timing.first_audio_source, 'direct')
    assert.equal(projection.timing.voice_ttft_ms, 800)
  })

  it('persists ACK across restart and never replays it', () => {
    const stateDir = mkdtempSync(join(tmpdir(), 'result-ack-'))
    const first = new TurnLedger({ stateDir })
    first.create({ requestId: 'req-ack', deviceId: 'watch', bodySha256: 'sha', sessionId: 's' })
    first.setResult('req-ack', { text: 'done' })
    first.acknowledgeResult('req-ack')

    const restarted = new TurnLedger({ stateDir })
    assert.equal(restarted.replayable().some(t => t.request_id === 'req-ack'), false)
  })

  it('applies exponential backoff, logs attempts in state, and stops at the cap', () => {
    const stateDir = mkdtempSync(join(tmpdir(), 'result-retry-'))
    const ledger = new TurnLedger({ stateDir })
    ledger.create({ requestId: 'req-retry', deviceId: 'watch', bodySha256: 'sha', sessionId: 's' })
    ledger.setResult('req-retry', { text: 'done' })

    assert.deepEqual(ledger.markResultRedelivered('req-retry', { now: 1_000, baseDelayMs: 100 }), {
      attempt: 1, delay_ms: 100,
    })
    assert.equal(ledger.replayable({ now: 1_050, maxDeliveryAttempts: 2 }).length, 0)
    assert.equal(ledger.replayable({ now: 1_100, maxDeliveryAttempts: 2 }).length, 1)
    assert.equal(ledger.markResultRedelivered('req-retry', { now: 1_100, baseDelayMs: 100 }).attempt, 2)
    assert.equal(ledger.replayable({ now: 99_999, maxDeliveryAttempts: 2 }).length, 0)
  })

  it('exposes due terminal deliveries for an already-connected events client and removes them after ACK', () => {
    const stateDir = mkdtempSync(join(tmpdir(), 'result-sweep-'))
    const ledger = new TurnLedger({ stateDir })
    ledger.create({ requestId: 'req-live', deviceId: 'phone', bodySha256: 'sha', sessionId: 's' })
    ledger.setResult('req-live', { text: 'done' })

    assert.deepEqual(ledger.dueTerminalDeliveries({ now: Date.now() }).map(t => t.request_id), ['req-live'])
    ledger.markResultRedelivered('req-live', { now: 1_000, baseDelayMs: 100 })
    assert.equal(ledger.dueTerminalDeliveries({ now: 1_050 }).length, 0)
    assert.equal(ledger.dueTerminalDeliveries({ now: 1_100 }).length, 1)
    ledger.acknowledgeResult('req-live')
    assert.equal(ledger.dueTerminalDeliveries({ now: 99_999 }).length, 0)
  })
})

describe('ESS-742 bounded sharded persistence', () => {
  it('migrates a legacy monolithic ledger and recovers it after restart', () => {
    const stateDir = mkdtempSync(join(tmpdir(), 'ledger-migration-'))
    const createdAt = '2026-08-01T00:00:00.000Z'
    writeFileSync(join(stateDir, 'turn-ledger.json'), JSON.stringify({ turns: {
      legacy: {
        request_id: 'legacy', body_sha256: 'sha', state: 'processing',
        created_at: createdAt, updated_at: createdAt,
      },
    } }))

    const migrated = new TurnLedger({ stateDir, terminalRetentionMs: Infinity })
    assert.equal(migrated.get('legacy').state, 'processing')
    assert.equal(migrated.get('legacy').timing.bridge_accepted_at, createdAt)
    assert.equal(existsSync(join(stateDir, 'turn-ledger.json.migrated')), true)

    const restarted = new TurnLedger({ stateDir, terminalRetentionMs: Infinity })
    assert.equal(restarted.get('legacy').state, 'processing')
  })

  it('bounds terminal history by count while preserving active turns', () => {
    const stateDir = mkdtempSync(join(tmpdir(), 'ledger-retention-'))
    const ledger = new TurnLedger({ stateDir, maxTurns: 100, terminalRetentionMs: Infinity })
    ledger.create({ requestId: 'active', deviceId: 'watch', bodySha256: 'sha', sessionId: 's' })
    for (let i = 0; i < 250; i += 1) {
      const requestId = `terminal-${i}`
      ledger.create({ requestId, deviceId: 'watch', bodySha256: 'sha', sessionId: 's' })
      ledger.setResult(requestId, { text: 'done' })
    }

    assert.equal(ledger.turns.size, 100)
    assert.ok(ledger.get('active'))
    assert.equal(readdirSync(join(stateDir, 'turn-ledger.d')).filter(name => name.endsWith('.json')).length, 100)
    const restarted = new TurnLedger({ stateDir, maxTurns: 100, terminalRetentionMs: Infinity })
    assert.equal(restarted.turns.size, 100)
    assert.ok(restarted.get('active'))
    assert.ok(restarted.get('terminal-249'))
  })

  it('updates only one bounded record with a large retained ledger', () => {
    const stateDir = mkdtempSync(join(tmpdir(), 'ledger-latency-'))
    const ledger = new TurnLedger({ stateDir, maxTurns: 2000, terminalRetentionMs: Infinity })
    for (let i = 0; i < 1000; i += 1) {
      ledger.create({ requestId: `large-${i}`, deviceId: 'watch', bodySha256: 'sha', sessionId: 's' })
    }
    const started = process.hrtime.bigint()
    ledger.update('large-999', { detail: 'latency_probe' })
    const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6

    assert.ok(elapsedMs < 50, `single-record update took ${elapsedMs.toFixed(2)}ms`)
    const record = JSON.parse(readFileSync(ledger.recordPath('large-999'), 'utf8'))
    assert.equal(record.detail, 'latency_probe')
    assert.equal(existsSync(join(stateDir, 'turn-ledger.json')), false)
  })
})
