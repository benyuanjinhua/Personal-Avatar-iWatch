// ESS-184 门禁：下行链路探针解析与判定的契约测试。
//
// 输入是 bridge.log 的若干行 JSONL；输出是「PASS/FAIL + 停在哪一跳」。测试
// 覆盖 5 跳齐、逐跳缺失、白名单拒、乱序、超时，以及 Watch 端未补 request_id
// 时的 H2 邻近推断。

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  HOP_DESCRIPTIONS,
  PROBE,
  evaluateProbe,
  parseProbeHops,
} from '../downlink-probe.mjs'

const RID = 'probe-0189aa00-0000-7000-8000-000000000184'
const OTHER_RID = 'req_' + '0'.repeat(32)

// 以 T0 为基点造若干 ISO 时间；1 秒粒度足够，parser 不看毫秒。
const T0 = new Date('2026-08-03T13:30:00Z')
function ts(offsetSec) { return new Date(T0.getTime() + offsetSec * 1000).toISOString() }

function j(obj) { return JSON.stringify(obj) }

// ESS-207 复审 §2 修复：H1/H3/H5 三处 sha 必须一致；probe_acked 必须带
// played_ok=true 才算 H5。以下固定 sha 用于 happy-path，负例单独覆盖。
const HAPPY_SHA = 'a'.repeat(64)

/// 完整 5 跳齐的一场探针（H1=+0.0s，H2=+0.8s，H3=+1.0s，H4=+1.5s→+3.8s，H5=+4.0s）。
function happyPathLines(requestId = RID) {
  return [
    j({ ts: ts(0.0), evt: 'l1_audio_ready', request_id: requestId, source: 'direct', kind: 'probe', sha256: HAPPY_SHA, size_bytes: 40000, duration_ms: 3500, codec: 'm4a' }),
    j({ ts: ts(0.8), evt: 'watch_client_log', module: 'wcsession', event: 'file_received', request_id: requestId, detail: 'kind=probe bytes=40000' }),
    j({ ts: ts(1.0), evt: 'watch_client_log', module: 'turn', event: 'speech_stored', request_id: requestId, detail: `bytes=40000 sha256=${HAPPY_SHA}` }),
    j({ ts: ts(1.5), evt: 'watch_client_log', module: 'player', event: 'play_started', request_id: requestId }),
    j({ ts: ts(3.8), evt: 'watch_client_log', module: 'player', event: 'play_finished', request_id: requestId, detail: 'successfully=true' }),
    j({ ts: ts(4.0), evt: 'probe_acked', request_id: requestId, source: 'watch', played_ok: true, sha256: HAPPY_SHA }),
  ]
}

describe('ESS-184 probe log parser', () => {
  it('passes when the 5 hops are all present, correctly ordered, within timeout', () => {
    const hopResult = parseProbeHops(happyPathLines(), RID)
    const verdict = evaluateProbe(hopResult, { timeoutMs: 60_000 })
    assert.equal(verdict.pass, true)
    assert.equal(verdict.code, PROBE.PASS)
    assert.equal(verdict.stoppedAt, null)
    assert.equal(verdict.timings.totalMs, 4000)
    assert.equal(verdict.summary.filter(r => r.present).length, 5)
    assert.equal(verdict.summary.every(r => !r.is_stopped_at), true)
  })

  it('accepts the existing result_acked when a probe-specific ack is not yet wired', () => {
    const lines = happyPathLines().slice(0, 5)
    // 兼容路径：无 probe_acked、只有 result_acked——仍算 H5，不做 played_ok 断言。
    lines.push(j({ ts: ts(4.0), evt: 'result_acked', request_id: RID, device_id: 'jackson-iphone' }))
    const verdict = evaluateProbe(parseProbeHops(lines, RID), { timeoutMs: 60_000 })
    assert.equal(verdict.pass, true, verdict.message)
  })

  // === ESS-207 复审 §2 修复：新增契约 ===

  it('rejects probe_acked with played_ok!==true as H5 (avoids failure ACKs faking PASS)', () => {
    const lines = happyPathLines().slice(0, 5)
    lines.push(j({ ts: ts(4.0), evt: 'probe_acked', request_id: RID, played_ok: false, sha256: HAPPY_SHA, error_code: 'ERR_PROBE_PLAYBACK_TRUNCATED' }))
    const verdict = evaluateProbe(parseProbeHops(lines, RID))
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, PROBE.MISSING_H5,
      'played_ok=false 的 ACK 不能算 H5——那就等于「播失败也 PASS」')
  })

  it('rejects probe_acked without played_ok field (defensive: no default-true)', () => {
    const lines = happyPathLines().slice(0, 5)
    lines.push(j({ ts: ts(4.0), evt: 'probe_acked', request_id: RID, sha256: HAPPY_SHA }))
    const verdict = evaluateProbe(parseProbeHops(lines, RID))
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, PROBE.MISSING_H5)
  })

  it('flags SHA_MISMATCH when H1 and H5 shas diverge (H5 forging: right rid, wrong bytes)', () => {
    const lines = happyPathLines().slice(0, 5)
    lines.push(j({ ts: ts(4.0), evt: 'probe_acked', request_id: RID, played_ok: true, sha256: 'b'.repeat(64) }))
    const verdict = evaluateProbe(parseProbeHops(lines, RID))
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, PROBE.SHA_MISMATCH,
      'H5 ack 的 sha 与 H1 注入 sha 不一致 → 播的可能不是本次注入的字节，必须挡')
    assert.equal(verdict.shas.h1, HAPPY_SHA)
    assert.equal(verdict.shas.h5, 'b'.repeat(64))
  })

  it('flags SHA_MISMATCH when H1 and H3 shas diverge (Watch played stale vault data)', () => {
    const lines = [
      j({ ts: ts(0.0), evt: 'l1_audio_ready', request_id: RID, source: 'direct', kind: 'probe', sha256: HAPPY_SHA, size_bytes: 40000 }),
      j({ ts: ts(0.8), evt: 'watch_client_log', module: 'wcsession', event: 'file_received', request_id: RID, detail: 'kind=probe bytes=40000' }),
      j({ ts: ts(1.0), evt: 'watch_client_log', module: 'turn', event: 'speech_stored', request_id: RID, detail: `bytes=40000 sha256=${'c'.repeat(64)}` }),
      j({ ts: ts(1.5), evt: 'watch_client_log', module: 'player', event: 'play_started', request_id: RID }),
      j({ ts: ts(3.8), evt: 'watch_client_log', module: 'player', event: 'play_finished', request_id: RID }),
      j({ ts: ts(4.0), evt: 'probe_acked', request_id: RID, played_ok: true, sha256: HAPPY_SHA }),
    ]
    const verdict = evaluateProbe(parseProbeHops(lines, RID))
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, PROBE.SHA_MISMATCH)
  })

  it('stays backward-compatible when Watch H3 log has no sha256 field (skip sha check silently)', () => {
    // 旧日志格式没有 sha256=… 时，parser 退化为不做 H3 断言，避免升级窗内误报。
    const lines = [
      j({ ts: ts(0.0), evt: 'l1_audio_ready', request_id: RID, source: 'direct', kind: 'probe', sha256: HAPPY_SHA, size_bytes: 40000 }),
      j({ ts: ts(0.8), evt: 'watch_client_log', module: 'wcsession', event: 'file_received', request_id: RID, detail: 'kind=probe' }),
      j({ ts: ts(1.0), evt: 'watch_client_log', module: 'turn', event: 'speech_stored', request_id: RID, detail: 'bytes=40000' }), // 无 sha
      j({ ts: ts(1.5), evt: 'watch_client_log', module: 'player', event: 'play_started', request_id: RID }),
      j({ ts: ts(3.8), evt: 'watch_client_log', module: 'player', event: 'play_finished', request_id: RID }),
      j({ ts: ts(4.0), evt: 'probe_acked', request_id: RID, played_ok: true, sha256: HAPPY_SHA }),
    ]
    const verdict = evaluateProbe(parseProbeHops(lines, RID))
    assert.equal(verdict.pass, true, verdict.message)
  })

  it('flags H1 stop when the whitelist rejected the probe (kind not in AUDIO_KINDS)', () => {
    const lines = [
      j({ ts: ts(0.0), evt: 'l1_audio_rejected', request_id: RID, reason: 'unknown_kind', source: 'direct', kind: 'probe' }),
    ]
    const verdict = evaluateProbe(parseProbeHops(lines, RID))
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, PROBE.REJECTED)
    assert.equal(verdict.stoppedAt, 'H1')
    assert.match(verdict.message, /白名单/)
  })

  it('stops at H1 when there is no l1_audio_ready for this request_id', () => {
    const lines = [
      j({ ts: ts(0.0), evt: 'l1_audio_ready', request_id: OTHER_RID, source: 'direct', kind: 'probe' }),
      j({ ts: ts(0.8), evt: 'watch_client_log', module: 'wcsession', event: 'file_received', request_id: RID, detail: 'kind=probe' }),
    ]
    const verdict = evaluateProbe(parseProbeHops(lines, RID))
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, PROBE.MISSING_H1)
    assert.equal(verdict.stoppedAt, 'H1')
  })

  it('stops at H2 when the file never reached the Watch', () => {
    const lines = happyPathLines().filter(line => !JSON.parse(line).event || JSON.parse(line).event !== 'file_received')
    // 且没有孤儿 file_received 兜底可推断（H2 兜底路径由下一条用例覆盖）
    const filtered = lines.filter(line => {
      const p = JSON.parse(line)
      return !(p.module === 'wcsession' && p.event === 'file_received')
    })
    const verdict = evaluateProbe(parseProbeHops(filtered, RID))
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, PROBE.MISSING_H2)
    assert.equal(verdict.stoppedAt, 'H2')
  })

  it('infers H2 from an orphan file_received (no request_id but kind=speech, within H1..H3 window)', () => {
    // Watch 端在探针路径上暂未补 request_id 时的过渡兼容：孤儿 file_received（无
    // request_id 但 detail 里 kind=speech）在 H1 之后 / H3 之前 → 记 inferred。
    const lines = [
      j({ ts: ts(0.0), evt: 'l1_audio_ready', request_id: RID, source: 'direct', kind: 'probe' }),
      j({ ts: ts(0.8), evt: 'watch_client_log', module: 'wcsession', event: 'file_received', detail: 'kind=speech bytes=40000' }),
      j({ ts: ts(1.0), evt: 'watch_client_log', module: 'turn', event: 'speech_stored', request_id: RID, detail: 'bytes=40000' }),
      j({ ts: ts(1.5), evt: 'watch_client_log', module: 'player', event: 'play_started', request_id: RID }),
      j({ ts: ts(3.8), evt: 'watch_client_log', module: 'player', event: 'play_finished', request_id: RID, detail: 'successfully=true' }),
      j({ ts: ts(4.0), evt: 'result_acked', request_id: RID }),
    ]
    const verdict = evaluateProbe(parseProbeHops(lines, RID))
    assert.equal(verdict.pass, true, verdict.message)
    const h2 = verdict.summary.find(r => r.hop === 'H2')
    assert.equal(h2.present, true)
    assert.equal(h2.inferred, true)
  })

  it('stops at H3 when Watch never confirmed the sha match', () => {
    const lines = happyPathLines().filter(line => {
      const p = JSON.parse(line)
      return !(p.module === 'turn' && p.event === 'speech_stored')
    })
    const verdict = evaluateProbe(parseProbeHops(lines, RID))
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, PROBE.MISSING_H3)
    assert.equal(verdict.stoppedAt, 'H3')
  })

  it('stops at H4 when play_started fires but play_finished does not', () => {
    const lines = happyPathLines().filter(line => {
      const p = JSON.parse(line)
      return !(p.module === 'player' && p.event === 'play_finished')
    })
    const verdict = evaluateProbe(parseProbeHops(lines, RID))
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, PROBE.MISSING_H4)
    assert.equal(verdict.stoppedAt, 'H4')
  })

  it('stops at H5 when no ack ever comes back', () => {
    const lines = happyPathLines().filter(line => {
      const p = JSON.parse(line)
      return p.evt !== 'probe_acked' && p.evt !== 'result_acked'
    })
    const verdict = evaluateProbe(parseProbeHops(lines, RID))
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, PROBE.MISSING_H5)
    assert.equal(verdict.stoppedAt, 'H5')
  })

  it('rejects out-of-order timings (older H3 than H1 — logs replayed / request_id reused)', () => {
    const lines = [
      j({ ts: ts(5.0), evt: 'l1_audio_ready', request_id: RID, source: 'direct', kind: 'probe' }),
      j({ ts: ts(5.8), evt: 'watch_client_log', module: 'wcsession', event: 'file_received', request_id: RID, detail: 'kind=probe' }),
      j({ ts: ts(1.0), evt: 'watch_client_log', module: 'turn', event: 'speech_stored', request_id: RID }),
      j({ ts: ts(6.5), evt: 'watch_client_log', module: 'player', event: 'play_started', request_id: RID }),
      j({ ts: ts(8.8), evt: 'watch_client_log', module: 'player', event: 'play_finished', request_id: RID }),
      j({ ts: ts(9.0), evt: 'probe_acked', request_id: RID }),
    ]
    const verdict = evaluateProbe(parseProbeHops(lines, RID))
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, PROBE.BAD_ORDER)
    assert.equal(verdict.stoppedAt, 'H3')
  })

  it('reports timeout when hops complete but past the deadline', () => {
    const lines = happyPathLines()
    const verdict = evaluateProbe(parseProbeHops(lines, RID), { timeoutMs: 500 })
    assert.equal(verdict.pass, false)
    assert.equal(verdict.code, PROBE.TIMEOUT)
    assert.match(verdict.message, /超过 500 ms/)
  })

  it('ignores hops from a different request_id (no cross-probe leakage)', () => {
    const good = happyPathLines(RID)
    const noise = happyPathLines(OTHER_RID)
    const verdict = evaluateProbe(parseProbeHops([...good, ...noise], RID), { timeoutMs: 60_000 })
    assert.equal(verdict.pass, true, verdict.message)
    // 换成筛另一个 rid，噪音里也是完整链路 → 同样 pass，但用的是别的 request_id。
    const verdictOther = evaluateProbe(parseProbeHops([...good, ...noise], OTHER_RID), { timeoutMs: 60_000 })
    assert.equal(verdictOther.pass, true, verdictOther.message)
    assert.equal(verdictOther.requestId, OTHER_RID)
  })

  it('drops bad-JSON lines and non-string log rows without throwing', () => {
    const lines = ['not json at all', '', j({ evt: 'l1_audio_ready', request_id: RID, kind: 'probe', ts: ts(0.0), source: 'direct' })]
    const hopResult = parseProbeHops(lines, RID)
    assert.equal(hopResult.hops.H1 !== null, true)
  })

  it('skips lines before --since, so a stale replay does not falsely satisfy the probe', () => {
    // 一场 5 跳齐的历史探针（T0）+ 后来的注入没走完（T0+3600）。since=T0+3000 应该
    // 判 MISSING_H1（历史那场时间戳早于 since，被过滤）。
    const stale = happyPathLines(RID)
    const laterOnlyH1 = [
      j({ ts: ts(3600), evt: 'l1_audio_ready', request_id: RID, source: 'direct', kind: 'probe' }),
    ]
    const window = { since: new Date(T0.getTime() + 3000 * 1000) }
    const hopResult = parseProbeHops([...stale, ...laterOnlyH1], RID, { window })
    assert.equal(hopResult.hops.H1 !== null, true)
    assert.equal(hopResult.hops.H2, null)
    const verdict = evaluateProbe(hopResult)
    assert.equal(verdict.code, PROBE.MISSING_H2)
  })
})

describe('ESS-184 probe HOP_DESCRIPTIONS 契约', () => {
  it('exposes 5 hops keyed H1..H5 with human labels', () => {
    assert.deepEqual(Object.keys(HOP_DESCRIPTIONS).sort(), ['H1', 'H2', 'H3', 'H4', 'H5'])
    for (const key of Object.keys(HOP_DESCRIPTIONS)) {
      assert.equal(typeof HOP_DESCRIPTIONS[key], 'string')
      assert.ok(HOP_DESCRIPTIONS[key].length > 0)
    }
  })
})
