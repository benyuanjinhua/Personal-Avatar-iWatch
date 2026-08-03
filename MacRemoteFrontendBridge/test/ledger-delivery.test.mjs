import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { TurnLedger } from '../ledger.mjs'

describe('terminal result redelivery ledger', () => {
  it('projects request-correlated stage timestamps, TTFT, and end-to-end latency', () => {
    const stateDir = mkdtempSync(join(tmpdir(), 'turn-timing-'))
    const ledger = new TurnLedger({ stateDir })
    ledger.create({
      requestId: 'req-timing', deviceId: 'watch', bodySha256: 'sha', sessionId: 's',
      watchCreatedAt: '2026-08-04T00:00:00.000Z',
    })
    ledger.update('req-timing', { state: 'processing', detail: 'realtime_processing' })
    ledger.markFirstAudioReady('req-timing', { at: '2026-08-04T00:00:01.250Z', source: 'direct' })
    ledger.markFirstAudioReady('req-timing', { at: '2026-08-04T00:00:09.000Z', source: 'background' })
    ledger.setResult('req-timing', { text: 'done' })

    const projection = ledger.projection('req-timing')
    assert.equal(projection.request_id, 'req-timing')
    assert.equal(projection.timing.watch_created_at, '2026-08-04T00:00:00.000Z')
    assert.ok(projection.timing.bridge_accepted_at)
    assert.ok(projection.timing.processing_started_at)
    assert.equal(projection.timing.first_audio_ready_at, '2026-08-04T00:00:01.250Z')
    assert.equal(projection.timing.first_audio_source, 'direct')
    assert.equal(projection.timing.voice_ttft_ms, 1250)
    assert.ok(Number.isFinite(projection.timing.end_to_end_ms))
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
