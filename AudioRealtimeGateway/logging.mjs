// Structured JSON logger with hard-coded secret redaction. Every log line is
// one JSON object with a stable `ts` and `evt`; scope fields (request_id,
// session_id, response_id, generation, sequence) surface at the top level so
// grep by request_id reconstructs a whole turn (ESS-403 acceptance #4).
//
// Secret fields (`token`, `token_sha`, `signature`, `provider_key`,
// `authorization`, `pairing_code`, `raw_audio`) are dropped BEFORE
// stringification: the logger cannot be tricked into printing them by the
// caller. This is defence-in-depth for acceptance #5 ("no long-lived keys
// exposed").

const REDACTED_KEYS = new Set([
  'token', 'token_sha', 'token_sha256', 'signature', 'x-signature',
  'authorization', 'provider_key', 'provider_key_env', 'api_key',
  'pairing_code', 'device_secret', 'raw_audio', 'audio',
])

function redact(value) {
  if (value === null || value === undefined) return value
  if (Array.isArray(value)) return value.map(redact)
  if (typeof value !== 'object') return value
  const out = {}
  for (const [key, v] of Object.entries(value)) {
    if (REDACTED_KEYS.has(key.toLowerCase())) continue
    out[key] = redact(v)
  }
  return out
}

export function createLogger({ write = line => process.stdout.write(line + '\n'), now = () => new Date().toISOString() } = {}) {
  const emit = record => {
    const safe = redact(record)
    write(JSON.stringify({ ts: now(), ...safe }))
  }
  const log = (evt, extra = {}) => emit({ evt, ...extra })
  log.child = (base = {}) => (evt, extra = {}) => emit({ evt, ...base, ...extra })
  log.raw = emit
  return log
}

export const _redactForTest = redact
