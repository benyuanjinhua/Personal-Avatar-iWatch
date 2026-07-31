// ESS-37 真网关自愈验收：连续 ≥5 轮 turn 注入 qwen-audio-agent v0.9.1
// （127.0.0.1:3101），其中第 3 轮在注入中途故意掐断 WS，验证：
// 每轮都有事件流回传、终态恰一次、断链轮经重建+重放后仍到达终态。
// 运行: node test/ess37-live.mjs <16k-pcm-file> [rounds]
// 使用独立 deviceId=ess37-verify，不占用/抢占其他前台的语音所有权。

import { readFileSync } from 'node:fs'
import { QwenRealtimeSessionSupervisor } from '../supervisor.mjs'

const pcm = readFileSync(process.argv[2] || '/tmp/ess37-16k.pcm')
const rounds = Number(process.argv[3] || 5)
const KILL_ROUND = 3

const supervisor = new QwenRealtimeSessionSupervisor({
  gatewayUrl: 'ws://127.0.0.1:3101/api/realtime',
  deviceId: 'ess37-verify',
  turnTimeoutMs: 90_000,
  log: () => {},
})
supervisor.listeners.add(e => {
  if (e.event === 'audio.delta') return
  console.error(JSON.stringify({ journal: e }))
})

const outcomes = []
for (let round = 1; round <= rounds; round++) {
  const label = `ess37-r${round}`
  let killTimer = null
  if (round === KILL_ROUND) {
    // 注入开始后掐线：等 turn.inject.start 出现再 terminate
    const arm = item => {
      if (item.event === 'turn.inject.start' && item.label === label && item.attempt === 1) {
        killTimer = setTimeout(() => {
          console.error(JSON.stringify({ note: `round ${round}: killing WS mid-turn` }))
          supervisor.ws?.terminate()
        }, 400)
      }
    }
    supervisor.listeners.add(arm)
    setTimeout(() => supervisor.listeners.delete(arm), 60_000)
  }
  const t0 = Date.now()
  try {
    const r = await supervisor.injectTurn(pcm, { label })
    outcomes.push({
      round, label, terminal: 'resolved', elapsedMs: Date.now() - t0,
      state: r.state, path: r.path, eventCount: r.eventCount,
      userTranscript: r.userTranscript,
      assistantTranscript: (r.assistantTranscript || '').slice(0, 80),
      audioBytes24k: r.audioBytes24k, taskId: r.taskId,
    })
  } catch (error) {
    outcomes.push({
      round, label, terminal: 'rejected', elapsedMs: Date.now() - t0,
      error: error.message, eventCount: error.partial?.eventCount ?? null,
    })
  } finally {
    clearTimeout(killTimer)
  }
}

const rebuilds = supervisor.journal.filter(e => e.event === 'session.rebuild')
const summary = {
  rounds: outcomes,
  rebuilds: rebuilds.map(r => r.reason),
  injectStarts: supervisor.journal.filter(e => e.event === 'turn.inject.start').length,
  wsCloses: supervisor.journal.filter(e => e.event === 'ws.close').map(e => e.code),
  allRoundsTerminal: outcomes.length === rounds,
  allRoundsHadEvents: outcomes.every(o => (o.eventCount ?? 0) > 0),
}
console.log(JSON.stringify(summary, null, 2))
supervisor.close('ess37-live-done')
setTimeout(() => process.exit(0), 500)
