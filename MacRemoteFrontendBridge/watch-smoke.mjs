// 装机音频自检门禁（ESS-65 / G9）。
//
// G8（watch-build.mjs）回答「装的是不是新包」，本模块回答「新包能不能用」：
// 表端 SelfCheckRunner 在新 build 首启自动跑「录音 → 播放 → 播放后立刻录音 →
// 会话状态复位」四步，结论以 module=selfcheck / event=selfcheck_finished 经
// watch_client_log 落进 bridge.log；这里取最近一条并判定。
//
// 判定一律 **fail-closed**，与 G8 同口径：查无记录、结论缺 built_at、
// 时间不可解析、结论字段不可识别，全部判不通过。缺证据不等于没问题。
//
// selfcheck_finished 的 detail 契约（Shared/SelfCheckPolicy.swift 生成）：
//   result=pass|fail|inconclusive failed_step=<Sn|none> [reason=<...>]
//   version=<x> build=<n> built_at=<ISO8601|unknown>
// 失败时原始错误码（如 NSOSStatusErrorDomain#-50）在条目的 error_code 字段。

import { parseBuildDetail, parseTimestamp } from './watch-build.mjs'

/// detail 的通用 k=v 解析（未知键忽略，缺失键为 undefined）。
function parseDetailFields(detail) {
  const fields = {}
  if (typeof detail !== 'string') return fields
  for (const token of detail.split(/\s+/)) {
    const separator = token.indexOf('=')
    if (separator <= 0) continue
    fields[token.slice(0, separator)] = token.slice(separator + 1)
  }
  return fields
}

/// 从 bridge.log 的若干行里取**最近一条**装机自检结论。
/// 与 latestWatchColdStart 同理，按 Bridge 落盘 ts（服务端时钟）排序，
/// 不信客户端时间序。
export function latestSelfCheckFinished(lines) {
  let latest = null
  for (const line of lines) {
    if (typeof line !== 'string' || line.trim().length === 0) continue
    let entry
    try { entry = JSON.parse(line) } catch { continue }
    if (!entry || typeof entry !== 'object') continue
    if (entry.evt !== 'watch_client_log') continue
    if (entry.module !== 'selfcheck' || entry.event !== 'selfcheck_finished') continue

    const observedAt = parseTimestamp(entry.ts)
    if (latest && observedAt && latest.observedAt && observedAt < latest.observedAt) continue
    const fields = parseDetailFields(entry.detail)
    latest = {
      observedAt,
      watchTs: entry.watch_ts ?? null,
      deviceId: entry.device_id ?? null,
      detail: entry.detail ?? null,
      errorCode: entry.error_code ?? null,
      result: fields.result ?? null,
      failedStep: fields.failed_step ?? null,
      reason: fields.reason ?? null,
      fingerprint: parseBuildDetail(entry.detail),
    }
  }
  return latest
}

export const SMOKE = {
  PASS: 'SMOKE_GATE_PASS',
  NO_SELFCHECK: 'ERR_NO_SELFCHECK',
  BUILD_TIME_UNKNOWN: 'ERR_SELFCHECK_BUILD_TIME_UNKNOWN',
  STALE: 'ERR_SELFCHECK_STALE',
  FAILED: 'ERR_SELFCHECK_FAILED',
  INCONCLUSIVE: 'ERR_SELFCHECK_INCONCLUSIVE',
  BAD_RESULT: 'ERR_SELFCHECK_RESULT_UNPARSEABLE',
  BAD_REFERENCE: 'ERR_BAD_REFERENCE_TIME',
}

/// 判定装机自检是否放行。requiredBuiltAfter = 待验收 commit 的提交时间；
/// 先校验结论属于哪个 build（built_at 不早于该时间），再看结论本身——
/// 旧 build 上哪怕是 pass 也不算数。
export function evaluateSmokeGate({ selfCheck, requiredBuiltAfter }) {
  const reference = requiredBuiltAfter instanceof Date
    ? requiredBuiltAfter
    : parseTimestamp(requiredBuiltAfter)
  if (!reference) {
    return { pass: false, code: SMOKE.BAD_REFERENCE, message: '待验收 commit 的提交时间不可解析，无法判定' }
  }
  if (!selfCheck) {
    return {
      pass: false,
      code: SMOKE.NO_SELFCHECK,
      message: '未观测到装机自检，无法判定——请确认新包已装机并重新打开 App，等自检跑完（约 10 秒）后再试',
    }
  }
  const builtAt = selfCheck.fingerprint?.builtAt ?? null
  if (!builtAt) {
    return {
      pass: false,
      code: SMOKE.BUILD_TIME_UNKNOWN,
      message: `自检结论未带可读的 built_at（detail=${JSON.stringify(selfCheck.detail)}），按证据不足判不通过`,
    }
  }
  if (builtAt < reference) {
    return {
      pass: false,
      code: SMOKE.STALE,
      message:
        `最近一次自检属于旧 build：built_at=${builtAt.toISOString()} < commit=${reference.toISOString()}` +
        '——请装上待验收的新包重新打开 App 跑自检',
    }
  }
  switch (selfCheck.result) {
    case 'pass':
      return {
        pass: true,
        code: SMOKE.PASS,
        message: `装机自检通过：built_at=${builtAt.toISOString()} ≥ commit=${reference.toISOString()}`,
      }
    case 'fail':
      return {
        pass: false,
        code: SMOKE.FAILED,
        message:
          `装机自检失败于 ${selfCheck.failedStep ?? '未知步骤'}` +
          `（${stepDescription(selfCheck.failedStep)}），原始错误码=${selfCheck.errorCode ?? '未上报'}` +
          '——新包的音频链路有缺陷，不要进入人工验收',
      }
    case 'inconclusive':
      return {
        pass: false,
        code: SMOKE.INCONCLUSIVE,
        // 铁律 2：区分「代码坏了」和「你还没授权」，别误导排查方向。
        message: selfCheck.reason === 'mic_permission_missing'
          ? '装机自检无法判定：手表还没授予麦克风权限（不是代码缺陷）——先在手表上允许麦克风，重开 App 或点「重新自检」'
          : `装机自检无法判定（reason=${selfCheck.reason ?? '未上报'}，多半是自检被按住说话打断）——重开 App 或点「重新自检」`,
      }
    default:
      return {
        pass: false,
        code: SMOKE.BAD_RESULT,
        message: `自检结论不可识别（result=${selfCheck.result ?? 'null'}），按证据不足判不通过`,
      }
  }
}

function stepDescription(step) {
  switch (step) {
    case 'S1': return '录音可用'
    case 'S2': return '播放可用'
    case 'S3': return '播放→录音交替'
    // S3R：ESS-72 的 S3'——录音刚结束立刻播放，拦截会话未交还导致的
    // 两级激活 !res(561145203)。
    case 'S3R': return '录音→播放交替'
    case 'S4': return '会话状态复位'
    // S5/S6：PM 2026-08-02 拍板并入；S5 自 ESS-73 起改为「中断残留不得
    // 阻塞新播放」。表端实现见 Watch/SelfCheck.swift，与此处步骤名一一对应。
    case 'S5': return '中断残留不阻塞播放'
    case 'S6': return '双激活失败'
    default: return '未知'
  }
}
