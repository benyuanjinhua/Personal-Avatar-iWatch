// ESS-184：下行链路探针 —— bridge.log 逐跳解析与判定。
//
// G8/G9 只证明「装的是新包」「表的音频链路本地能用」，都不经过下行通道；这一层
// 补的是从 Mac Bridge 出口一路到手表播放并回执的端到端探针。运行时怎么让这条
// 探针跑起来见 `Scripts/downlink-probe.mjs`（本模块只负责解析已产出的日志）。
//
// 五跳（同 `probe_id` 贯穿）：
//   H1  Bridge 侧 `l1_audio_ready`（kind=probe，未被 ESS-57 白名单拒）；
//   H2  iPhone Relay 收到 + transferFile 已到手表（用 Watch 侧 `wcsession/
//       file_received` 作为最近的 Bridge 可见证据 —— 手机自身日志不入 bridge.log）；
//   H3  Watch 落盘 + sha 一致（Watch 侧 `turn/speech_stored` 或探针专用 kind
//       落盘事件，两者都带 request_id）；
//   H4  Watch `player/play_started` → `player/play_finished`（成对出现）；
//   H5  Bridge 收到播放成功 ACK（`probe_acked` 或既有 `result_acked` 兜底）。
//
// 判定原则与 G8/G9 一致，全部 **fail-closed**：任何一跳没有可核对的证据，都判
// 不通过；stopped_at 指到第一个缺失的跳，方便按跳修理由。

import { parseTimestamp } from './watch-build.mjs'

/// bridge.log 行 → 内部条目。跳过非对象/坏 JSON/空行，不因客户端多字段而失败。
function parseLogEntries(lines) {
  const entries = []
  for (const line of lines) {
    if (typeof line !== 'string') { if (line && typeof line === 'object') entries.push(line); continue }
    if (line.trim().length === 0) continue
    try {
      const entry = JSON.parse(line)
      if (entry && typeof entry === 'object') entries.push(entry)
    } catch { /* bad_line 已由 Bridge 自己记 evt=watch_client_log_bad_line */ }
  }
  return entries
}

/// bridge.log 里对我们探针的观测：一等公民 request_id（Bridge 侧 evt 与
/// watch_client_log 都携带同名字段），可靠对齐；detail 里的 kind= 只作辅助判据。
function belongsToProbe(entry, requestId) {
  return typeof entry === 'object' && entry !== null && entry.request_id === requestId
}

/// 从日志条目中抓 detail 字段里的 `kind=<value>`。detail 是 Watch/Bridge 自由文本，
/// 未来若结构化了这里换字段名即可；调用方永远从 hopDetails() 拿。
function detailKind(entry) {
  const detail = entry?.detail
  if (typeof detail !== 'string') return null
  const match = detail.match(/(?:^|\s)kind=(\S+)/)
  return match ? match[1] : null
}

/// 抓 detail 里 `sha256=<hex>` 的 64 位十六进制；Watch H3 探针路径会带这个字段
/// （ESS-207 补齐），parser 用它做 H1↔H3↔H5 三处 sha 相等断言（ESS-207 P0 修复）。
function detailSha(entry) {
  const detail = entry?.detail
  if (typeof detail !== 'string') return null
  const match = detail.match(/(?:^|\s)sha256=([0-9a-fA-F]{64})/)
  return match ? match[1].toLowerCase() : null
}

/// 顶层 sha256 字段兜底：Bridge 侧 `evt=l1_audio_ready` / `probe_acked` 都在
/// entry.sha256 上直接落，不进 detail。
function entrySha(entry) {
  if (typeof entry?.sha256 === 'string' && /^[0-9a-fA-F]{64}$/.test(entry.sha256)) {
    return entry.sha256.toLowerCase()
  }
  return detailSha(entry)
}

/// 把一条 bridge.log 条目映射到探针跳编号（H1..H5），返回 null 表示与探针无关。
///
/// 匹配规则严格从紧，不放行貌似相关但语义不合的事件（例如别的 request_id 的
/// `l1_audio_ready` 不会算 H1）。同 request_id 但事件路径未知（Watch 新加 kind=probe
/// 后可能起新事件名），要么在这里补一条 case，要么把 Watch 端事件名对齐既有的
/// `wcsession/file_received` / `turn/speech_stored` / `player/play_*`。
function classifyEntry(entry, requestId) {
  if (!belongsToProbe(entry, requestId)) return null
  const evt = entry.evt
  const module = entry.module ?? null
  const event = entry.event ?? null

  // H5：播放成功回执。毕玄 2026-08-03 15:33Z 复审 §2：`probe_acked` 只在
  // `played_ok===true` 时才算 H5——播放失败的 ACK 也可能被伪造为「五跳齐」，
  // 与门禁「播放成功回执」目标矛盾。`result_acked` 是探针未拆分前的兼容通道，
  // 复用生产 result-ack 语义（Watch 只在落盘成功后发），保留不做 played_ok
  // 断言。
  if (evt === 'probe_acked') return entry.played_ok === true ? 'H5' : null
  if (evt === 'result_acked') return 'H5'

  // H1：Bridge 出口写出 l1_audio_ready。要求同 request_id + kind=probe，
  // 不接受同 request_id 但 kind=result（保持语义）。source 允许 direct/background/interim。
  if (evt === 'l1_audio_ready' && (entry.kind === 'probe' || detailKind(entry) === 'probe')) return 'H1'

  // Bridge 白名单拒（负信号，单独抓，不算跳但用于停机诊断）。
  if (evt === 'l1_audio_rejected') return 'REJECTED'

  // Watch 侧的 watch_client_log 是唯一从 Bridge 视角可看到 Watch 内部事件的手段。
  if (evt !== 'watch_client_log') return null

  // H2：Watch 侧 file_received。目前无 request_id 字段（file_received 早于 envelope
  // 解出前就落，参见 WatchSettingsStore.swift）——但为了 H2 精确到 probe，我们要求
  // Watch 端在探针路径上补 request_id（子单里明列）。若还没补上，先按 detail 中
  // kind=probe|speech + 时序邻接推断（在 evaluateProbe 里处理）。
  if (module === 'wcsession' && event === 'file_received') return 'H2'

  // H3：Watch 落盘 + sha 一致（speech_stored 保留原名；为 kind=probe 新增专用事件时
  // 可以叫 `turn/probe_stored`，兼容也保留）。
  if (module === 'turn' && (event === 'speech_stored' || event === 'probe_stored')) return 'H3'

  // H4：Watch 起播/收尾。同 request_id 的 play_started 与 play_finished 必须成对。
  if (module === 'player' && event === 'play_started') return 'H4_start'
  if (module === 'player' && event === 'play_finished') return 'H4_finish'

  return null
}

const HOP_ORDER = ['H1', 'H2', 'H3', 'H4', 'H5']
export const HOP_DESCRIPTIONS = Object.freeze({
  H1: 'Bridge 出口 l1_audio_ready(kind=probe)',
  H2: 'iPhone Relay + transferFile 到达 Watch',
  H3: 'Watch 落盘 + sha 一致',
  H4: 'Watch play_started → play_finished',
  H5: 'Bridge 收到播放成功 ACK',
})

/// 解析 bridge.log，返回该 requestId 的逐跳观测。
///
/// - 只按 Bridge 落盘 ts 排序（服务端时钟，与 watch-build.mjs 同口径）；
/// - H2 允许「无 request_id 但 detail=kind=speech|probe 且时间落在 H1 之后 / H3 之前」
///   的邻近推断（Watch 端补齐 request_id 前的过渡兼容，Watch 端补齐后此路径失效）；
/// - 缺 H1 或 H2 不推断出 H3/H4/H5；缺失就是缺失，不做善意补齐。
export function parseProbeHops(lines, requestId, { window = null } = {}) {
  if (typeof requestId !== 'string' || requestId.length === 0) {
    throw new Error('parseProbeHops: requestId 必填')
  }
  const entries = parseLogEntries(lines)

  const observations = { H1: [], H2: [], H3: [], H4_start: [], H4_finish: [], H5: [] }
  const rejected = []
  const orphanFileReceived = []

  for (const entry of entries) {
    const at = parseTimestamp(entry.ts)
    if (window?.since && at && at < window.since) continue

    const hop = classifyEntry(entry, requestId)
    if (hop === 'REJECTED') { rejected.push({ at, reason: entry.reason ?? null, source: entry.source ?? null }); continue }
    if (hop) { observations[hop].push({ at, entry }); continue }

    // 孤儿 file_received（无 request_id）：仅当 detail=kind=speech|probe 时保留，
    // 后续 buildHops 用 H1/H3 的时间窗判是否属于本探针。
    if (entry.evt === 'watch_client_log' && entry.module === 'wcsession' && entry.event === 'file_received') {
      const kind = detailKind(entry)
      if (kind === 'speech' || kind === 'probe' || kind === 'result_audio') {
        orphanFileReceived.push({ at, entry })
      }
    }
  }

  const firstOf = list => list.length === 0 ? null : list.reduce((a, b) => (
    (a.at && b.at && a.at <= b.at) ? a : (a.at ? a : b)
  ))

  const hops = {}
  hops.H1 = firstOf(observations.H1)
  hops.H2 = firstOf(observations.H2)
  hops.H3 = firstOf(observations.H3)
  const startObs = firstOf(observations.H4_start)
  const finishObs = firstOf(observations.H4_finish)
  hops.H4 = startObs && finishObs ? { at: finishObs.at, entry: finishObs.entry, startAt: startObs.at } : null
  hops.H5 = firstOf(observations.H5)

  // H2 兜底：Watch 端未在探针路径上补 request_id 时，用「H1 之后 / H3 之前 + detail
  // 里 kind 与探针语义一致」的孤儿 file_received 邻近推断（仅一条）。这条兜底显式
  // 标记 `inferred: true`，PM/门禁看得见是推断而非直证。
  if (!hops.H2 && orphanFileReceived.length > 0 && hops.H1) {
    const h1At = hops.H1.at
    const h3At = hops.H3?.at ?? null
    const candidate = orphanFileReceived.find(o => o.at && h1At && o.at >= h1At && (!h3At || o.at <= h3At))
    if (candidate) hops.H2 = { at: candidate.at, entry: candidate.entry, inferred: true }
  }

  return {
    requestId,
    hops,
    rejected: rejected.length > 0 ? rejected[0] : null,
    counts: {
      H1: observations.H1.length,
      H2: observations.H2.length,
      H3: observations.H3.length,
      H4_start: observations.H4_start.length,
      H4_finish: observations.H4_finish.length,
      H5: observations.H5.length,
      REJECTED: rejected.length,
      orphanFileReceived: orphanFileReceived.length,
    },
  }
}

export const PROBE = {
  PASS: 'PROBE_PASS',
  REJECTED: 'ERR_PROBE_REJECTED_BY_ALLOWLIST',
  MISSING_H1: 'ERR_PROBE_STOPPED_AT_H1',
  MISSING_H2: 'ERR_PROBE_STOPPED_AT_H2',
  MISSING_H3: 'ERR_PROBE_STOPPED_AT_H3',
  MISSING_H4: 'ERR_PROBE_STOPPED_AT_H4',
  MISSING_H5: 'ERR_PROBE_STOPPED_AT_H5',
  TIMEOUT: 'ERR_PROBE_TIMEOUT',
  BAD_ORDER: 'ERR_PROBE_HOP_OUT_OF_ORDER',
  // ESS-207 复审 §2：H1/H3/H5 三处 sha 不一致 → 播放的可能不是本次注入的字节。
  SHA_MISMATCH: 'ERR_PROBE_SHA_MISMATCH',
}

/// 依据逐跳观测出裁决。停在第一个缺跳，附每跳耗时（自 H1 起算）。
///
/// - 时序严格：H_i 的 at 必须 >= H_{i-1} 的 at，否则记 BAD_ORDER；
/// - 有 rejected 记录（同 request_id）→ 直接 FAIL，不再看后续跳；
/// - timeoutMs 从 H1 起算；跳齐但耗时超阈值判 TIMEOUT。
export function evaluateProbe(hopResult, { timeoutMs = 60_000 } = {}) {
  const { hops, rejected, requestId } = hopResult
  if (rejected) {
    return {
      pass: false, code: PROBE.REJECTED, stoppedAt: 'H1',
      message: `探针被 ESS-57 白名单拒（reason=${rejected.reason ?? '?'} source=${rejected.source ?? '?'}）——检查 kind 是否已进 AUDIO_KINDS`,
      requestId, timings: {}, summary: summarize(hops, null),
    }
  }

  let previousAt = null
  for (const hop of HOP_ORDER) {
    const obs = hops[hop]
    if (!obs) {
      return {
        pass: false, code: PROBE[`MISSING_${hop}`], stoppedAt: hop,
        message: `探针停在 ${hop}（${HOP_DESCRIPTIONS[hop]}）——上一跳 ${previousHop(hop) ?? '起点'} ` +
          `${previousAt ? `观测于 ${previousAt.toISOString()}` : '未观测'}`,
        requestId, timings: buildTimings(hops), summary: summarize(hops, hop),
      }
    }
    if (previousAt && obs.at && obs.at < previousAt) {
      return {
        pass: false, code: PROBE.BAD_ORDER, stoppedAt: hop,
        message: `${hop} 时间早于上一跳（${obs.at.toISOString()} < ${previousAt.toISOString()}），日志乱序或探针复用了旧 request_id`,
        requestId, timings: buildTimings(hops), summary: summarize(hops, hop),
      }
    }
    previousAt = obs.at ?? previousAt
  }

  // ESS-207 复审 §2：H1（Bridge 出口）、H3（Watch 落盘）、H5（Watch 播完 ACK）
  // 三处的 sha 必须一致，否则「播的可能不是本次注入的字节」——H5 事件伪造 /
  // Watch 侧沾了残留 vault 数据都能被这条挡住。任一 sha 缺失（旧日志格式）
  // 时不强制断言，保留向前兼容窗；两个都有值时必须相等。
  const h1Sha = entrySha(hops.H1.entry)
  const h3Sha = entrySha(hops.H3.entry)
  const h5Sha = entrySha(hops.H5.entry)
  const observedShas = [h1Sha, h3Sha, h5Sha].filter(Boolean)
  const uniqueShas = new Set(observedShas)
  if (observedShas.length >= 2 && uniqueShas.size > 1) {
    return {
      pass: false, code: PROBE.SHA_MISMATCH, stoppedAt: 'H5',
      message: `探针 5 跳齐但 H1/H3/H5 sha 不一致：H1=${h1Sha ?? '?'} H3=${h3Sha ?? '?'} H5=${h5Sha ?? '?'}`,
      requestId, timings: buildTimings(hops),
      summary: summarize(hops, null),
      shas: { h1: h1Sha, h3: h3Sha, h5: h5Sha },
    }
  }

  const timings = buildTimings(hops)
  if (timings.totalMs !== null && timings.totalMs > timeoutMs) {
    return {
      pass: false, code: PROBE.TIMEOUT, stoppedAt: 'H5',
      message: `探针 5 跳齐但耗时 ${timings.totalMs} ms 超过 ${timeoutMs} ms`,
      requestId, timings, summary: summarize(hops, null),
    }
  }
  return {
    pass: true, code: PROBE.PASS, stoppedAt: null,
    message: `探针 5 跳齐、耗时 ${timings.totalMs ?? '?'} ms（H1 → H5）`,
    requestId, timings, summary: summarize(hops, null),
    shas: { h1: h1Sha, h3: h3Sha, h5: h5Sha },
  }
}

function previousHop(hop) {
  const index = HOP_ORDER.indexOf(hop)
  return index <= 0 ? null : HOP_ORDER[index - 1]
}

function buildTimings(hops) {
  const at = key => hops[key]?.at ?? null
  const h1 = at('H1')
  const timings = { totalMs: null, perHopMs: { H1: 0 } }
  let last = h1
  for (let i = 1; i < HOP_ORDER.length; i += 1) {
    const key = HOP_ORDER[i]
    const value = at(key)
    timings.perHopMs[key] = (value && last) ? value.getTime() - last.getTime() : null
    if (value) last = value
  }
  if (h1 && last && last !== h1) timings.totalMs = last.getTime() - h1.getTime()
  else if (h1 && at('H5')) timings.totalMs = at('H5').getTime() - h1.getTime()
  return timings
}

function summarize(hops, stoppedAt) {
  return HOP_ORDER.map(key => ({
    hop: key,
    description: HOP_DESCRIPTIONS[key],
    present: Boolean(hops[key]),
    at: hops[key]?.at?.toISOString() ?? null,
    inferred: hops[key]?.inferred ?? false,
    is_stopped_at: key === stoppedAt,
  }))
}
