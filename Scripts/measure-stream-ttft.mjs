#!/usr/bin/env node

// ESS-279 protocol simulator. This is deliberately not a device/audible TTFT
// claim: it compares the Bridge downlink eligibility point for the legacy
// whole-response path with the first L1 chunk emission point.
import { VoiceStreamDownlink } from '../MacRemoteFrontendBridge/voice-stream-downlink.mjs'

const sampleCount = 20
const scenarios = ['direct', 'announcement']
const rows = []

for (const scenario of scenarios) {
  for (let index = 0; index < sampleCount; index += 1) {
    const chunks = 8 + (index % 5)
    const deltaIntervalMs = 18 + (index % 4)
    let clock = 1_800_000_000_000
    let firstEmissionAt = null
    const stream = new VoiceStreamDownlink({
      enabled: true,
      now: () => clock,
      send: () => { if (firstEmissionAt === null) firstEmissionAt = clock; return true },
    })
    const requestId = `${scenario}-${index}`
    const responseStartedAt = clock
    for (let sequence = 0; sequence < chunks; sequence += 1) {
      clock += deltaIntervalMs
      stream.append({ requestId, responseId: `resp-${index}`, audio: Buffer.alloc(960), sequence })
    }
    const legacyEligibleAt = clock // whole PCM is available only after the final delta
    rows.push({
      scenario,
      legacy_ms: legacyEligibleAt - responseStartedAt,
      streaming_ms: firstEmissionAt - responseStartedAt,
    })
  }
}

const nearestRank = (values, quantile) => [...values].sort((a, b) => a - b)[Math.ceil(values.length * quantile) - 1]
const summarize = scenario => {
  const selected = rows.filter(row => row.scenario === scenario)
  const legacy = selected.map(row => row.legacy_ms)
  const streaming = selected.map(row => row.streaming_ms)
  const legacyP50 = nearestRank(legacy, 0.5)
  const streamingP50 = nearestRank(streaming, 0.5)
  return {
    scenario,
    n: selected.length,
    legacy_p50_ms: legacyP50,
    streaming_p50_ms: streamingP50,
    p50_relative_improvement_pct: Number((((legacyP50 - streamingP50) / legacyP50) * 100).toFixed(1)),
    legacy_p95_ms: nearestRank(legacy, 0.95),
    streaming_p95_ms: nearestRank(streaming, 0.95),
  }
}

console.log(JSON.stringify({
  source: 'deterministic Node protocol simulator (not Watch/iPhone, not audible TTFT)',
  window: 'single local invocation; virtual clock; 2026-08-04 model',
  endpoint: 'Realtime response.started -> Bridge first downlink-eligible payload',
  assumptions: '8-12 PCM deltas, 18-21ms inter-delta; excludes network, WatchConnectivity, buffering, decode, AVAudioPlayer',
  samples: scenarios.map(summarize),
}, null, 2))
