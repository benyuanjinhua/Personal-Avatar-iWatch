// generate-probe-audio.mjs — ESS-184 下行探针语音生成（一次性资产工具）。
//
// 与 generate-welcome-speech.mjs 同一手法（qwen-audio-agent loopback WS →
// aggregate 24 kHz PCM → AudioPipe 编 AAC/M4A），仅文案不同：这里生成的是
// 装机门禁 S3 用的固定短句「你好Jackson，我是你的数字分身」（白梦林
// 2026-08-03 拍板），保持 qwen-audio-realtime 的人物音色。
//
// 用法：node generate-probe-audio.mjs <audiopipe-bin> <out.m4a>
// 前置：qwen-audio-agent 网关在 127.0.0.1:3101 运行且 DashScope 已配置。
//
// 产物建议提交进仓库为 Watch App 预置资产（例如 Watch/Resources/ProbeSpeech.m4a），
// 与 WelcomeSpeech.m4a 并列——探针一律用固定资产，绝不临时合成，以拦「Mac 生
// 成语音这一步坏了」和「下行链路坏了」这两类故障。文案即代码：改文案 = 改这里
// + 重新生成。
//
// 与 generate-welcome-speech.mjs 有相同结构。为什么不抽公共 helper：本单只加
// 一个平行短脚本，不改 ESS-40 已交付的欢迎语生成路径（R-01.2 单内夹带原则）；
// 后续若两条真需要合并，另开重构单。

import WebSocket from 'ws'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'

const PROBE_TEXT = '你好Jackson，我是你的数字分身'
const INSTRUCTION = `请用自然、亲切的语气一字不差地说出下面这句话，不要添加、省略或改动任何字，也不要说其他内容：${PROBE_TEXT}`

const GATEWAY = process.env.QWEN_GATEWAY_WS || 'ws://127.0.0.1:3101/api/realtime'
const [, , audiopipeBin, outPath] = process.argv
if (!audiopipeBin || !outPath) {
  console.error('usage: node generate-probe-audio.mjs <audiopipe-bin> <out.m4a>')
  process.exit(1)
}

const OVERALL_TIMEOUT_MS = 90_000
const READY_TIMEOUT_MS = 6_000

function connectOnce({ takeover }) {
  return new Promise((resolve, reject) => {
    const sessionId = `probe-gen-${randomUUID().slice(0, 8)}`
    const ws = new WebSocket(`${GATEWAY}?sessionId=${encodeURIComponent(sessionId)}`)
    const chunks = []
    let sampleRate = 24_000
    let responseId = null
    let transcript = ''
    let ready = false
    let settled = false

    const finish = (error, value) => {
      if (settled) return
      settled = true
      clearTimeout(overallTimer)
      clearTimeout(readyTimer)
      try { ws.close() } catch {}
      error ? reject(error) : resolve(value)
    }

    const overallTimer = setTimeout(() => finish(new Error('overall timeout')), OVERALL_TIMEOUT_MS)
    const readyTimer = setTimeout(() => {
      if (!ready) finish(Object.assign(new Error('voice not ready'), { code: 'NOT_READY' }))
    }, READY_TIMEOUT_MS)

    ws.on('open', () => {
      ws.send(JSON.stringify({
        type: 'connect',
        clientType: 'cli',
        clientLabel: 'probe-gen',
        clientInstanceId: `probe_${randomUUID()}`,
        voiceEnabled: true,
        takeover,
        timeZone: 'Asia/Shanghai',
        locale: 'zh-CN',
      }))
    })
    ws.on('error', error => finish(error))
    ws.on('close', () => finish(new Error('connection closed before audio.done')))
    ws.on('message', raw => {
      let event
      try { event = JSON.parse(raw.toString()) } catch { return }

      if (event.type === 'voice.ready'
        || (event.type === 'voice.ownership' && event.state === 'active')) {
        if (!ready) {
          ready = true
          clearTimeout(readyTimer)
          console.error(`[probe-gen] voice ready (takeover=${takeover}), sending text.message`)
          ws.send(JSON.stringify({ type: 'text.message', text: INSTRUCTION }))
        }
        return
      }
      if (event.origin === 'announcement') return

      if (event.type === 'response.started') {
        if (!responseId) responseId = event.responseId
        return
      }
      if (event.type === 'audio.delta' && event.responseId && event.responseId === (responseId ?? event.responseId)) {
        responseId ??= event.responseId
        if (chunks.length === 0) {
          ws.send(JSON.stringify({ type: 'playback.started', responseId: event.responseId }))
        }
        if (event.sampleRate) sampleRate = event.sampleRate
        if (event.audio) chunks.push(Buffer.from(event.audio, 'base64'))
        return
      }
      if (event.type === 'transcript.delta' && event.role === 'assistant') {
        transcript += event.content ?? event.delta ?? ''
        return
      }
      if (event.type === 'transcript.final' && event.role === 'assistant') {
        transcript = event.content ?? transcript
        return
      }
      if (event.type === 'audio.done' && responseId && event.responseId === responseId) {
        ws.send(JSON.stringify({ type: 'playback.ended', responseId }))
        ws.send(JSON.stringify({ type: 'mute' }))
        finish(null, { pcm: Buffer.concat(chunks), sampleRate, transcript })
        return
      }
      if (event.type === 'error') {
        finish(new Error(`gateway error: ${event.message}`))
      }
    })
  })
}

let capture
try {
  capture = await connectOnce({ takeover: false })
} catch (error) {
  if (error.code !== 'NOT_READY') throw error
  console.error('[probe-gen] voice busy, retrying with takeover=true')
  capture = await connectOnce({ takeover: true })
}

if (capture.pcm.length === 0) {
  console.error('[probe-gen] no audio received')
  process.exit(1)
}
console.error(`[probe-gen] transcript: ${capture.transcript}`)
console.error(`[probe-gen] pcm bytes: ${capture.pcm.length} @ ${capture.sampleRate}Hz`)
// 文本对齐必须严格，探针文案是门禁的 ground truth；轻微漂移就重跑。
if (!capture.transcript.includes('Jackson') || !capture.transcript.includes('数字分身')) {
  console.error('[probe-gen] WARNING: transcript does not match the fixed copy exactly, consider re-running')
}

const dir = mkdtempSync(join(tmpdir(), 'probe-gen-'))
try {
  const rawPath = join(dir, 'probe.raw')
  writeFileSync(rawPath, capture.pcm)
  const meta = execFileSync(audiopipeBin, ['encode', rawPath, String(capture.sampleRate), outPath], { encoding: 'utf8' })
  console.error(`[probe-gen] encoded: ${meta.trim()}`)
  console.log(JSON.stringify({ out: outPath, transcript: capture.transcript, pcmBytes: capture.pcm.length, sampleRate: capture.sampleRate, text: PROBE_TEXT }))
} finally {
  rmSync(dir, { recursive: true, force: true })
}
