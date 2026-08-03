// ESS-65 / G9：装机音频自检门禁——「新包能不能用」的机器判定。
// 核心用例：fail S3 必须把 ESS-61 那次 -50 的形态拦下并报出原始错误码；
// 缺证据（无记录 / 无 built_at / 结论不可识别）一律 fail-closed。

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import {
  latestSelfCheckFinished,
  evaluateSmokeGate,
  SMOKE,
  SMOKE_STEP_DESCRIPTIONS,
} from '../watch-smoke.mjs'

const finishedLine = ({ ts, watchTs, detail, errorCode }) => JSON.stringify({
  ts,
  evt: 'watch_client_log',
  device_id: 'watch_1',
  chunk_id: 'req_log_1',
  watch_ts: watchTs ?? ts,
  request_id: null,
  module: 'selfcheck',
  event: 'selfcheck_finished',
  detail,
  error_code: errorCode ?? null,
})

const REFERENCE = '2026-08-02T05:00:00Z'
const FRESH = 'version=0.1.0 build=1 built_at=2026-08-02T06:00:00Z'

const gateFor = lines => evaluateSmokeGate({
  selfCheck: latestSelfCheckFinished(lines),
  requiredBuiltAfter: REFERENCE,
})

describe('ESS-65 latestSelfCheckFinished', () => {
  it('picks the newest selfcheck_finished by bridge receive time and parses the contract', () => {
    const lines = [
      finishedLine({ ts: '2026-08-02T07:00:00Z', detail: `result=pass failed_step=none ${FRESH}` }),
      finishedLine({
        ts: '2026-08-02T06:00:00Z',
        detail: 'result=fail failed_step=S3 version=0.1.0 build=1 built_at=2026-08-02T05:30:00Z',
        errorCode: 'NSOSStatusErrorDomain#-50',
      }),
    ]
    const latest = latestSelfCheckFinished(lines)
    assert.equal(latest.result, 'pass')
    assert.equal(latest.failedStep, 'none')
    assert.equal(latest.fingerprint.builtAt.toISOString(), '2026-08-02T06:00:00.000Z')
  })

  it('ignores other watch events, other bridge events, and unparseable lines', () => {
    const lines = [
      'not json',
      JSON.stringify({ ts: '2026-08-02T06:00:00Z', evt: 'turn_accepted' }),
      JSON.stringify({
        ts: '2026-08-02T06:00:01Z', evt: 'watch_client_log',
        module: 'selfcheck', event: 'selfcheck_step', detail: 'step=S1 result=pass elapsed_ms=612',
      }),
      JSON.stringify({
        ts: '2026-08-02T06:00:02Z', evt: 'watch_client_log',
        module: 'lifecycle', event: 'cold_start', detail: FRESH,
      }),
    ]
    assert.equal(latestSelfCheckFinished(lines), null)
  })
})

describe('ESS-65 evaluateSmokeGate', () => {
  it('passes on a fresh pass verdict', () => {
    const verdict = gateFor([finishedLine({ ts: '2026-08-02T07:00:00Z', detail: `result=pass failed_step=none ${FRESH}` })])
    assert.equal(verdict.pass, true)
    assert.equal(verdict.code, SMOKE.PASS)
  })

  it('fails closed when no selfcheck_finished was ever observed', () => {
    const verdict = gateFor([])
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, SMOKE.NO_SELFCHECK)
    assert.match(verdict.message, /未观测到装机自检/)
    assert.match(verdict.message, /无法判定/)
  })

  it('reports the failed step and the original error code on result=fail', () => {
    // ESS-61 事故形态：播放→录音交替时共享会话残留 .longFormAudio，-50 全灭。
    const verdict = gateFor([finishedLine({
      ts: '2026-08-02T07:00:00Z',
      detail: `result=fail failed_step=S3 ${FRESH}`,
      errorCode: 'NSOSStatusErrorDomain#-50',
    })])
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, SMOKE.FAILED)
    assert.match(verdict.message, /S3/)
    assert.match(verdict.message, /播放→录音交替/)
    assert.match(verdict.message, /NSOSStatusErrorDomain#-50/)
  })

  it('labels every self-check step from the shared description map', () => {
    for (const [step, description] of Object.entries(SMOKE_STEP_DESCRIPTIONS)) {
      const verdict = gateFor([finishedLine({
        ts: '2026-08-02T07:00:00Z',
        detail: `result=fail failed_step=${step} ${FRESH}`,
        errorCode: 'ERR_CONTROLLED_FAILURE',
      })])
      assert.equal(verdict.pass, false)
      assert.ok(verdict.message.includes(`失败于 ${step}（${description}）`))
      assert.match(verdict.message, /ERR_CONTROLLED_FAILURE/)
    }
  })

  it('blocks on inconclusive but points at permission, not at a code defect', () => {
    const verdict = gateFor([finishedLine({
      ts: '2026-08-02T07:00:00Z',
      detail: `result=inconclusive failed_step=none reason=mic_permission_missing ${FRESH}`,
      errorCode: 'ERR_MIC_PERMISSION',
    })])
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, SMOKE.INCONCLUSIVE)
    assert.match(verdict.message, /麦克风权限/)
    assert.match(verdict.message, /不是代码缺陷/)
  })

  it('rejects a pass verdict that belongs to a build older than the commit under acceptance', () => {
    const verdict = gateFor([finishedLine({
      ts: '2026-08-02T07:00:00Z',
      detail: 'result=pass failed_step=none version=0.1.0 build=1 built_at=2026-08-02T04:00:00Z',
    })])
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, SMOKE.STALE)
  })

  it('fails closed when built_at is unknown or missing', () => {
    for (const detail of ['result=pass failed_step=none version=0.1.0 build=1 built_at=unknown', 'result=pass failed_step=none']) {
      const verdict = gateFor([finishedLine({ ts: '2026-08-02T07:00:00Z', detail })])
      assert.equal(verdict.pass, false)
      assert.equal(verdict.code, SMOKE.BUILD_TIME_UNKNOWN)
    }
  })

  it('fails closed on an unrecognized result value', () => {
    const verdict = gateFor([finishedLine({ ts: '2026-08-02T07:00:00Z', detail: `result=maybe failed_step=none ${FRESH}` })])
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, SMOKE.BAD_RESULT)
  })

  it('fails closed on an unparseable reference time', () => {
    const verdict = evaluateSmokeGate({
      selfCheck: latestSelfCheckFinished([finishedLine({ ts: '2026-08-02T07:00:00Z', detail: `result=pass failed_step=none ${FRESH}` })]),
      requiredBuiltAfter: 'not-a-date',
    })
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, SMOKE.BAD_REFERENCE)
  })
})
