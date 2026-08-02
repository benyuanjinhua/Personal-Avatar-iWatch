// 手表 build 指纹门禁（ESS-56）。
//
// R3 真机验收的 17 条请求全部跑在旧 build 上：手表 `lifecycle/cold_start` 只有一条
// `watch_ts=14:36:43Z`，待验收 commit `24e1f24` 15:30Z 才合入。整轮人工验收作废，而
// 当时没有任何机器可判定的信号能提前拦住它。
//
// 本模块把「表端 build 是否覆盖待验收 commit」变成开测前的一条命令：从 bridge.log
// 里取最近一条手表冷启动指纹，与待验收 commit 的提交时间比时序。
//
// 判定一律 **fail-closed**：没有 cold_start、指纹缺时间、时间不可解析，全部判不通过。
// 缺证据不等于没问题——R3 正是"看不见"而不是"看见没问题"。

/// cold_start 的 detail：`version=<x> build=<n> built_at=<ISO8601|unknown>`。
/// 未知键忽略，缺失键为 null——解析器不因客户端多报字段而失败。
export function parseBuildDetail(detail) {
  if (typeof detail !== 'string' || detail.length === 0) return null
  const fields = {}
  for (const token of detail.split(/\s+/)) {
    const separator = token.indexOf('=')
    if (separator <= 0) continue
    fields[token.slice(0, separator)] = token.slice(separator + 1)
  }
  const rawBuiltAt = fields.built_at ?? null
  return {
    version: fields.version ?? null,
    build: fields.build ?? null,
    builtAtRaw: rawBuiltAt,
    builtAt: parseTimestamp(rawBuiltAt),
  }
}

/// `unknown` / 空 / 不可解析 → null（调用方按证据不足处理，不放行）。
/// G9 装机自检门禁（watch-smoke.mjs）复用同一时间语义，不复制粘贴。
export function parseTimestamp(value) {
  if (typeof value !== 'string' || value.length === 0 || value === 'unknown') return null
  const parsed = Date.parse(value)
  return Number.isNaN(parsed) ? null : new Date(parsed)
}

/// 从 bridge.log 的若干行里取**最近一条**手表冷启动。
///
/// 排序按 Bridge 落盘的 `ts`（服务端时钟，全局单调）而非客户端 `watch_ts`：手表时钟
/// 可能有偏移，且日志经 chunk 回传，客户端时间序不保证与到达序一致。
export function latestWatchColdStart(lines) {
  let latest = null
  for (const line of lines) {
    if (typeof line !== 'string' || line.trim().length === 0) continue
    let entry
    try { entry = JSON.parse(line) } catch { continue }
    if (!entry || typeof entry !== 'object') continue
    if (entry.evt !== 'watch_client_log') continue
    if (entry.module !== 'lifecycle' || entry.event !== 'cold_start') continue

    const observedAt = parseTimestamp(entry.ts)
    if (latest && observedAt && latest.observedAt && observedAt < latest.observedAt) continue
    latest = {
      observedAt,
      watchTs: entry.watch_ts ?? null,
      deviceId: entry.device_id ?? null,
      detail: entry.detail ?? null,
      fingerprint: parseBuildDetail(entry.detail),
    }
  }
  return latest
}

export const GATE = {
  PASS: 'BUILD_GATE_PASS',
  NO_COLD_START: 'ERR_NO_COLD_START',
  NO_FINGERPRINT: 'ERR_BUILD_FINGERPRINT_MISSING',
  BUILD_TIME_UNKNOWN: 'ERR_BUILD_TIME_UNKNOWN',
  BUILD_STALE: 'ERR_BUILD_STALE',
  BAD_REFERENCE: 'ERR_BAD_REFERENCE_TIME',
}

/// 判定表端 build 是否覆盖待验收 commit。
///
/// requiredBuiltAfter = 待验收 commit 的提交时间。通过条件是 built_at **不早于**它；
/// 相等放行（同一秒完成构建理论上可能，且再严也只会误伤）。
export function evaluateBuildGate({ coldStart, requiredBuiltAfter }) {
  const reference = requiredBuiltAfter instanceof Date
    ? requiredBuiltAfter
    : parseTimestamp(requiredBuiltAfter)
  if (!reference) {
    return { pass: false, code: GATE.BAD_REFERENCE, message: '待验收 commit 的提交时间不可解析，无法判定' }
  }
  if (!coldStart) {
    return {
      pass: false,
      code: GATE.NO_COLD_START,
      message: '未观测到手表冷启动，无法判定表端 build——请先杀掉手表 App 重新打开，确认日志回传后再开测',
    }
  }
  if (!coldStart.fingerprint) {
    return {
      pass: false,
      code: GATE.NO_FINGERPRINT,
      message: `手表冷启动未带 build 指纹（detail=${JSON.stringify(coldStart.detail)}）——表端很可能是 ESS-56 之前的旧 build`,
    }
  }
  const { builtAt, version, build } = coldStart.fingerprint
  if (!builtAt) {
    return {
      pass: false,
      code: GATE.BUILD_TIME_UNKNOWN,
      message: `手表报告 built_at=${coldStart.fingerprint.builtAtRaw ?? 'null'}，构建时间不可读，按证据不足判不通过`,
    }
  }
  if (builtAt < reference) {
    return {
      pass: false,
      code: GATE.BUILD_STALE,
      message:
        `表端 build 早于待验收 commit：built_at=${builtAt.toISOString()} < commit=${reference.toISOString()}` +
        `（version=${version} build=${build}）——这只表上装的不是待验收版本，现在开测等于白测`,
    }
  }
  return {
    pass: true,
    code: GATE.PASS,
    message: `表端 build 覆盖待验收 commit：built_at=${builtAt.toISOString()} ≥ commit=${reference.toISOString()}`,
  }
}
