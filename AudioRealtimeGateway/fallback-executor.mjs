// Runs one full-file PCM16/16k fallback through the Gateway's existing
// QwenAgentTransport. This is the only process that opens an upstream voice
// connection; Bridge calls the HTTP job API and never instantiates a voice owner.
export function createFallbackExecutor({ agentTransport, timeoutMs = 30_000, chunkBytes = 32_000 }) {
  return ({ requestId, audio, parentRequestId = null, contextSummary = null, signal = null }) => new Promise((resolve, reject) => {
    const chunks = []; let settled = false; let handle; let assistantTranscript = null; let userTranscript = null
    const result = extra => ({ audio24k_base64: chunks.length ? Buffer.concat(chunks.filter(Boolean)).toString('base64') : null,
      assistant_transcript: assistantTranscript, user_transcript: userTranscript, ...extra })
    const finish = (error, result) => {
      if (settled) return
      settled = true; clearTimeout(timer)
      try { handle?.close() } catch { /* already closed */ }
      error ? reject(error) : resolve(result)
    }
    signal?.addEventListener('abort', () => {
      try { handle?.cancel?.() } catch { /* best effort */ }
      finish(Object.assign(new Error('cancelled'), { code: 'cancelled' }))
    }, { once: true })
    const timer = setTimeout(() => finish(Object.assign(new Error('fallback upstream timeout'), {
      code: 'upstream_timeout',
    })), timeoutMs)
    timer.unref?.()
    handle = agentTransport.openTurn({
      requestId, sessionId: 'watch-fallback-jobs', deviceId: 'bridge-fallback', generation: 1,
      responseId: `${requestId}:fallback`,
      onEvent: event => {
        if (event.type === 'agent.audio.delta') {
          try { chunks[event.sequence] = Buffer.from(event.audio, 'base64') }
          catch { finish(Object.assign(new Error('invalid upstream audio'), { code: 'invalid_upstream_audio' })) }
        } else if (event.type === 'agent.audio.done') {
          const missing = Array.from({ length: event.final_sequence + 1 }, (_, i) => chunks[i]).some(x => !x)
          if (missing) return finish(Object.assign(new Error('upstream sequence gap'), { code: 'upstream_sequence_gap' }))
          finish(null, result({}))
        } else if (event.type === 'agent.transcript.final') {
          if (event.role === 'assistant') assistantTranscript = event.content
          if (event.role === 'user') userTranscript = event.content
        } else if (event.type === 'agent.task') {
          finish(null, result({ task_id: event.task.id }))
        } else if (event.type === 'agent.error') {
          finish(Object.assign(new Error(event.detail ?? event.code), { code: event.code ?? 'upstream_failed' }))
        }
      },
    })
    let sequence = 0
    for (let offset = 0; offset < audio.length; offset += chunkBytes) {
      const bytes = audio.subarray(offset, Math.min(offset + chunkBytes, audio.length))
      const first = sequence === 0
      handle.appendAudio({ sequence: sequence++, bytes,
        ...(first ? { parentRequestId, contextSummary } : {}) })
    }
    handle.commit()
  })
}
