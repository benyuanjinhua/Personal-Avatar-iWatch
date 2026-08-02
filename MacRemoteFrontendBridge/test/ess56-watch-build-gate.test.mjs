// ESS-56：手表 build 指纹门禁——开测前判定表端装的是不是待验收 build。
// 核心用例是最后一组：用 R3 那次白测的真实时间形态回放，门禁必须拦下。

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import { parseBuildDetail, latestWatchColdStart, evaluateBuildGate, GATE } from '../watch-build.mjs'

const coldStartLine = ({ ts, watchTs, detail }) => JSON.stringify({
  ts,
  evt: 'watch_client_log',
  device_id: 'watch_1',
  chunk_id: 'req_log_1',
  watch_ts: watchTs,
  request_id: null,
  module: 'lifecycle',
  event: 'cold_start',
  detail,
})

describe('ESS-56 parseBuildDetail', () => {
  it('parses the version/build/built_at contract emitted by BuildFingerprint', () => {
    const parsed = parseBuildDetail('version=0.1.0 build=1 built_at=2026-08-01T16:00:00Z')
    assert.equal(parsed.version, '0.1.0')
    assert.equal(parsed.build, '1')
    assert.equal(parsed.builtAt.toISOString(), '2026-08-01T16:00:00.000Z')
  })

  it('treats built_at=unknown as no build time rather than a parse failure', () => {
    const parsed = parseBuildDetail('version=0.1.0 build=1 built_at=unknown')
    assert.equal(parsed.builtAtRaw, 'unknown')
    assert.equal(parsed.builtAt, null)
  })

  it('ignores unknown keys so a newer client can add fields without breaking the gate', () => {
    const parsed = parseBuildDetail('version=0.2.0 build=7 built_at=2026-08-01T16:00:00Z channel=beta')
    assert.equal(parsed.version, '0.2.0')
    assert.equal(parsed.builtAt.toISOString(), '2026-08-01T16:00:00.000Z')
  })

  it('returns null for a legacy cold_start detail that carries no fingerprint', () => {
    assert.equal(parseBuildDetail(''), null)
    assert.equal(parseBuildDetail(null), null)
  })
})

describe('ESS-56 latestWatchColdStart', () => {
  it('picks the newest cold_start by bridge receive time, not file order', () => {
    const lines = [
      coldStartLine({ ts: '2026-08-02T02:00:00Z', watchTs: '2026-08-02T02:00:00Z', detail: 'version=0.1.0 build=1 built_at=2026-08-02T01:00:00Z' }),
      coldStartLine({ ts: '2026-08-01T14:36:43Z', watchTs: '2026-08-01T14:36:43Z', detail: 'version=0.1.0 build=1 built_at=2026-08-01T14:00:00Z' }),
    ]
    const latest = latestWatchColdStart(lines)
    assert.equal(latest.fingerprint.builtAt.toISOString(), '2026-08-02T01:00:00.000Z')
  })

  it('skips non-cold_start entries, other bridge events, and unparseable lines', () => {
    const lines = [
      'not json at all',
      JSON.stringify({ ts: '2026-08-02T02:00:00Z', evt: 'turn_accepted', request_id: 'req_1' }),
      JSON.stringify({ ts: '2026-08-02T02:00:01Z', evt: 'watch_client_log', module: 'recorder', event: 'record_started' }),
      JSON.stringify({ ts: '2026-08-02T02:00:02Z', evt: 'watch_client_log_bad_line', line_index: 0 }),
    ]
    assert.equal(latestWatchColdStart(lines), null)
  })
})

describe('ESS-56 evaluateBuildGate', () => {
  const reference = '2026-08-02T00:00:00Z'
  const gateFor = detail => evaluateBuildGate({
    coldStart: latestWatchColdStart([coldStartLine({ ts: '2026-08-02T01:00:00Z', watchTs: '2026-08-02T01:00:00Z', detail })]),
    requiredBuiltAfter: reference,
  })

  it('passes when the watch build is not older than the commit under acceptance', () => {
    const verdict = gateFor('version=0.1.0 build=1 built_at=2026-08-02T00:30:00Z')
    assert.equal(verdict.pass, true)
    assert.equal(verdict.code, GATE.PASS)
  })

  it('passes on an exact tie — equal timestamps must not be rejected', () => {
    assert.equal(gateFor(`version=0.1.0 build=1 built_at=${reference}`).pass, true)
  })

  it('fails when the watch build predates the commit under acceptance', () => {
    const verdict = gateFor('version=0.1.0 build=1 built_at=2026-08-01T14:00:00Z')
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, GATE.BUILD_STALE)
  })

  // fail-closed：以下四种都是「看不见」而不是「看见没问题」，一律不放行。
  it('fails closed when no cold_start was observed at all', () => {
    const verdict = evaluateBuildGate({ coldStart: null, requiredBuiltAfter: reference })
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, GATE.NO_COLD_START)
  })

  it('fails closed when the build time is unreadable on device', () => {
    const verdict = gateFor('version=0.1.0 build=1 built_at=unknown')
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, GATE.BUILD_TIME_UNKNOWN)
  })

  it('fails closed on a pre-ESS-56 build whose cold_start carries no build time', () => {
    // detail 存在但没有 built_at：解析得到指纹对象、时间为空 → 按时间不可读处理。
    const verdict = gateFor('version=0.1.0')
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, GATE.BUILD_TIME_UNKNOWN)
  })

  it('fails closed when the reference commit time cannot be parsed', () => {
    const verdict = evaluateBuildGate({ coldStart: null, requiredBuiltAfter: 'not-a-date' })
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, GATE.BAD_REFERENCE)
  })
})

describe('ESS-56 regression: the R3 wasted acceptance round', () => {
  // 真实形态（ESS-54 多隆的全样本证据）：手表整轮只有一条 cold_start，
  // watch_ts=2026-08-01T14:36:43Z；待验收 commit 24e1f24 15:30Z 才合入。
  // 验收 15:59 开测，17 次按住说话全部跑在旧 build 上。
  const R3_COMMIT_TIME = '2026-08-01T15:30:00Z'

  it('blocks the R3 session: the only cold_start predates the commit under acceptance', () => {
    const log = [
      coldStartLine({
        ts: '2026-08-01T14:36:45Z',
        watchTs: '2026-08-01T14:36:43Z',
        detail: 'version=0.1.0 build=1 built_at=2026-08-01T14:20:11Z',
      }),
      JSON.stringify({ ts: '2026-08-01T15:59:43Z', evt: 'turn_accepted', request_id: 'req_r3_1' }),
    ]
    const verdict = evaluateBuildGate({
      coldStart: latestWatchColdStart(log),
      requiredBuiltAfter: R3_COMMIT_TIME,
    })
    assert.equal(verdict.pass, false, 'R3 那轮必须被门禁拦下')
    assert.equal(verdict.code, GATE.BUILD_STALE)
    assert.match(verdict.message, /白测/)
  })

  it('lets the same session through once the watch actually runs the accepted build', () => {
    const log = [
      coldStartLine({ ts: '2026-08-01T14:36:45Z', watchTs: '2026-08-01T14:36:43Z', detail: 'version=0.1.0 build=1 built_at=2026-08-01T14:20:11Z' }),
      coldStartLine({ ts: '2026-08-01T15:52:10Z', watchTs: '2026-08-01T15:52:08Z', detail: 'version=0.1.0 build=1 built_at=2026-08-01T15:48:02Z' }),
    ]
    const verdict = evaluateBuildGate({
      coldStart: latestWatchColdStart(log),
      requiredBuiltAfter: R3_COMMIT_TIME,
    })
    assert.equal(verdict.pass, true)
  })
})
