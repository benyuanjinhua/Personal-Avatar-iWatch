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

/// 抓 detail 里 `bytes=<n>` / `size_bytes=<n>` 的十进制正整数；顶层 `size_bytes`
/// 数值字段兜底（Bridge 侧 l1_audio_ready 直接落）。返回 number 或 null。
function detailNumber(entry, name) {
  const detail = entry?.detail
  if (typeof detail !== 'string') return null
  const re = new RegExp(`(?:^|\\s)${name}=(\\d+)(?:\\s|$)`)
  const match = detail.match(re)
  return match ? Number(match[1]) : null
}
function entrySize(entry) {
  if (Number.isFinite(entry?.size_bytes)) return Number(entry.size_bytes)
  const fromSize = detailNumber(entry, 'size_bytes')
  if (fromSize !== null) return fromSize
  return detailNumber(entry, 'bytes')
}

/// 抓 detail 里 `<name>=true|false` 的布尔值。三态返回：true/false/null（缺）。
function detailBool(entry, name) {
  const detail = entry?.detail
  if (typeof detail !== 'string') return null
  const re = new RegExp(`(?:^|\\s)${name}=(true|false)(?:\\s|$)`)
  const match = detail.match(re)
  return match ? (match[1] === 'true') : null
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

  // 负信号：AVAudioSession activate 返回 activated=false → 显式激活失败。
  // 不是跳，但要在 evaluateProbe 里挡下（H4_NOT_ACTIVATED），比事后从 play_*
  // 判定更可靠——真机上 play_started 有时能在未激活的会话下上，产出静音回执。
  if (module === 'player' && event === 'session_activation_failed') return 'SESSION_ACTIVATION_FAILED'

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
/// - 缺 H1 或 H2 不推断出 H3/H4/H5；缺失就是缺失，不做善意补齐；
/// - ESS-240：**H2 不再做孤儿 file_received 邻近推断**。任何跳都必须显式携带
///   request_id（即 probe_id）与 H1 相同才被采纳；缺 probe_id 一律 fail-closed。
///   历史「Watch 未补 request_id」兜底路径是 PR #59 fail-open 的入口之一（ESS-240），
///   同一时间窗内任意别人的 file_received 都能被无差别捡走当作本探针的 H2。
export function parseProbeHops(lines, requestId, { window = null } = {}) {
  if (typeof requestId !== 'string' || requestId.length === 0) {
    throw new Error('parseProbeHops: requestId 必填')
  }
  const entries = parseLogEntries(lines)

  const observations = { H1: [], H2: [], H3: [], H4_start: [], H4_finish: [], H5: [] }
  const rejected = []
  const activationFailed = []

  for (const entry of entries) {
    const at = parseTimestamp(entry.ts)
    if (window?.since && at && at < window.since) continue

    const hop = classifyEntry(entry, requestId)
    if (hop === 'REJECTED') { rejected.push({ at, reason: entry.reason ?? null, source: entry.source ?? null }); continue }
    if (hop === 'SESSION_ACTIVATION_FAILED') { activationFailed.push({ at, entry }); continue }
    if (hop) { observations[hop].push({ at, entry }); continue }
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

  return {
    requestId,
    hops,
    rejected: rejected.length > 0 ? rejected[0] : null,
    activationFailed: activationFailed.length > 0 ? activationFailed[0] : null,
    counts: {
      H1: observations.H1.length,
      H2: observations.H2.length,
      H3: observations.H3.length,
      H4_start: observations.H4_start.length,
      H4_finish: observations.H4_finish.length,
      H5: observations.H5.length,
      REJECTED: rejected.length,
      SESSION_ACTIVATION_FAILED: activationFailed.length,
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
  // ESS-240：跨跳 size_bytes 不一致（H1 声明的字节数与 H2/H3 观测到的不同）→
  // 途中被截/被换字节。size 与 sha 分开报，方便按维度定位。
  SIZE_MISMATCH: 'ERR_PROBE_SIZE_MISMATCH',
  // ESS-240：H4 段观察到 session_activation_failed 或 play_finished successfully=false
  // ——播放器路径没走通，回执用户听到的可能是静音/半段。
  H4_NOT_ACTIVATED: 'ERR_PROBE_H4_NOT_ACTIVATED',
  H4_NOT_FINISHED: 'ERR_PROBE_H4_NOT_FINISHED',
}

/// 依据逐跳观测出裁决。停在第一个缺跳，附每跳耗时（自 H1 起算）。
///
/// - 时序严格：H_i 的 at 必须 >= H_{i-1} 的 at，否则记 BAD_ORDER；
/// - 有 rejected 记录（同 request_id）→ 直接 FAIL，不再看后续跳；
/// - timeoutMs 从 H1 起算；跳齐但耗时超阈值判 TIMEOUT。
export function evaluateProbe(hopResult, { timeoutMs = 60_000 } = {}) {
  const { hops, rejected, activationFailed, requestId } = hopResult
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

  // ESS-207 复审 §2 / ESS-240 强化：H1（Bridge 出口）、H3（Watch 落盘）、H5
  // （Watch 播完 ACK）三处的 sha 必须一致。ESS-240 之前是「filter(Boolean) +
  // set.size>1」判定——H3 缺 sha 时静默跳过，就是 PR #59 fail-open 入口之一。
  // 现在改为：H1 有 sha 时 H3/H5 也必须有 sha 且值相同，任一缺失/不匹配即
  // SHA_MISMATCH。H1 自身无 sha 的旧日志格式仍保留兼容窗。
  const h1Sha = entrySha(hops.H1.entry)
  const h3Sha = entrySha(hops.H3.entry)
  const h5Sha = entrySha(hops.H5.entry)
  if (h1Sha) {
    // H3（Watch 落盘）必须携带 sha 且与 H1 相等——这是「Watch 真的拿到本次注入
    // 的字节」的直接证据；缺 sha 视同不匹配（fail-closed，ESS-240）。
    if (h3Sha !== h1Sha) {
      return {
        pass: false, code: PROBE.SHA_MISMATCH, stoppedAt: 'H3',
        message: `H1/H3 sha 不一致：H1=${h1Sha} H3=${h3Sha ?? '缺失'}`
          + `（H3 ${h3Sha === null ? '缺 sha256 字段' : '不同'}）`,
        requestId, timings: buildTimings(hops),
        summary: summarize(hops, null),
        shas: { h1: h1Sha, h3: h3Sha, h5: h5Sha },
      }
    }
    // H5 sha 弱要求：`probe_acked` 走 sha 双保险；`result_acked`（探针未拆前的
    // 兼容通道）不带 sha 字段——允许缺失但不允许不匹配。
    if (h5Sha !== null && h5Sha !== h1Sha) {
      return {
        pass: false, code: PROBE.SHA_MISMATCH, stoppedAt: 'H5',
        message: `H1/H5 sha 不一致：H1=${h1Sha} H5=${h5Sha}——ACK 里的字节不是本次注入的字节`,
        requestId, timings: buildTimings(hops),
        summary: summarize(hops, null),
        shas: { h1: h1Sha, h3: h3Sha, h5: h5Sha },
      }
    }
  }

  // ESS-240 AC2：H1 声明 size_bytes 时，H2 / H3 的 bytes= 必须与 H1 相等。任一
  // 缺失 / 不匹配即 SIZE_MISMATCH——被截字节、误传别的文件都能被这条挡住。
  // H1 自身无 size 的老包保留兼容（此时上游没定 baseline，不做断言）。
  const h1Size = entrySize(hops.H1.entry)
  const h2Size = entrySize(hops.H2.entry)
  const h3Size = entrySize(hops.H3.entry)
  if (Number.isFinite(h1Size)) {
    for (const [name, obsSize] of [['H2', h2Size], ['H3', h3Size]]) {
      if (obsSize !== h1Size) {
        return {
          pass: false, code: PROBE.SIZE_MISMATCH, stoppedAt: name,
          message: `探针 5 跳齐但 size_bytes 不一致：H1=${h1Size} H2=${h2Size ?? '缺失'} H3=${h3Size ?? '缺失'}`
            + `（${name} ${obsSize === null ? '缺 bytes 字段' : '不同'}）`,
          requestId, timings: buildTimings(hops),
          summary: summarize(hops, null),
          sizes: { h1: h1Size, h2: h2Size, h3: h3Size },
        }
      }
    }
  }

  // ESS-240 AC4a：H4 段任何时刻观察到 session_activation_failed（同 request_id）
  // → 不给 PASS。真机取证过：activate 回调 activated=false 也可能后续走 fallback
  // 让 play_started 上，产出静音回执；这里挡住不再看是否 play_finished。
  if (activationFailed) {
    const detail = activationFailed.entry?.detail ?? ''
    return {
      pass: false, code: PROBE.H4_NOT_ACTIVATED, stoppedAt: 'H4',
      message: `H4 观察到 session_activation_failed（${detail || '无 detail'}）——播放会话未激活`,
      requestId, timings: buildTimings(hops), summary: summarize(hops, 'H4'),
    }
  }

  // ESS-240 AC4b：play_finished successfully=false → 不给 PASS。play_started +
  // play_finished 都在但 successfully=false 意味着播放被打断，回执用户听到的
  // 是半段/静音。detail 缺 successfully 字段的旧日志按 true 处理（保留兼容）。
  const finishOk = detailBool(hops.H4.entry, 'successfully')
  if (finishOk === false) {
    return {
      pass: false, code: PROBE.H4_NOT_FINISHED, stoppedAt: 'H4',
      message: `H4 play_finished successfully=false——播放未成功收尾`,
      requestId, timings: buildTimings(hops), summary: summarize(hops, 'H4'),
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
