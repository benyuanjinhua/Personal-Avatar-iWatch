export const AUDIO_KINDS = new Set(['welcome', 'interim', 'result'])

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
