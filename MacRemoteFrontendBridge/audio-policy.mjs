// welcome/interim/result 是产品下行音频 kind；probe 是 ESS-184 加入的门禁探针 kind
// ——固定文案下行到手表/手机走完真实链路。任何新增 kind 都必须同时更新契约
// 用例（test/ess57-audio-policy.test.mjs），以及 Watch 端 AudioDownlinkPolicy 的
// 允许集合，否则 ESS-181 那种"自己拦自己"会重演。
export const AUDIO_KINDS = new Set(['welcome', 'interim', 'result', 'probe'])

export function rejectAudio({ kind, requestId, source, causal = false, log }) {
  let reason = null
  if (!kind) reason = 'missing_kind'
  else if (!AUDIO_KINDS.has(kind)) reason = 'unknown_kind'
  else if (!causal) reason = 'missing_causal_request'
  if (!reason) return false
  log({ evt: 'l1_audio_rejected', reason, request_id: requestId ?? null, source: source ?? 'unknown', kind: kind ?? null })
  return true
}

// Bridge northbound出口的最后一道门：任何携带音频的事件都必须声明产品 kind，
// 且必须能回溯到冷启动或用户 request_id。返回 false 时调用方不得 ws.send。
export function allowDownlinkMessage(message, log) {
  const interim = message?.interim
  if (interim?.audio) {
    return !rejectAudio({
      kind: interim.audio.kind,
      requestId: interim.request_id,
      source: 'interim',
      causal: Boolean(interim.request_id),
      log,
    })
  }
  const turns = message?.turn ? [message.turn] : (message?.turns ?? [])
  for (const turn of turns) {
    if (!turn?.result?.audio && !turn?.result?.audio_base64) continue
    if (rejectAudio({
      kind: turn.result?.audio?.kind,
      requestId: turn.request_id,
      source: turn.path === 'background' ? 'background' : 'direct',
      causal: Boolean(turn.request_id),
      log,
    })) return false
  }
  return true
}

// 音频不满足契约时只剥离音频，保留同一事件里的文字作为用户可见降级。
// 返回原对象表示无需降级；返回副本避免污染账本和重放缓存。
export function prepareDownlinkMessage(message, log) {
  if (allowDownlinkMessage(message, log)) return message
  const safe = structuredClone(message)
  if (safe.interim?.audio) delete safe.interim.audio
  const turns = safe.turn ? [safe.turn] : (safe.turns ?? [])
  for (const turn of turns) {
    if (!turn?.result) continue
    delete turn.result.audio
    delete turn.result.audio_base64
  }
  return safe
}
