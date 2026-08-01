// generate-welcome-speech.mjs — ESS-40 欢迎语音生成（一次性资产工具）。
//
// 以伪前端身份连接 qwen-audio-agent 的 loopback WS /api/realtime（与
// supervisor.mjs 同一通道），用 text.message 让 Qwen Audio Realtime 朗读
// 固定欢迎文案，聚合 24kHz PCM audio.delta，经 AudioPipe（与 ESS-38 下行
// 结果语音同一编码链）转成 Watch 可直接播放的 AAC/M4A。
//
// 用法：node generate-welcome-speech.mjs <audiopipe-bin> <out.m4a>
// 前置：qwen-audio-agent 网关在 127.0.0.1:3101 运行且 DashScope 已配置。
//
// 产物提交进仓库作为 Watch App 预置缓存（需求允许「分发或预置缓存」二选一）；
// 重新生成只需重跑本脚本。文案即代码：改文案 = 改这里 + 重新生成。

import WebSocket from 'ws'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'

const WELCOME_TEXT = '你好Jackson，我是你的AI分身'
const INSTRUCTION = `请用自然、亲切的语气一字不差地说出下面这句话，不要添加、省略或改动任何字，也不要说其他内容：${WELCOME_TEXT}`

const GATEWAY = process.env.QWEN_GATEWAY_WS || 'ws://127.0.0.1:3101/api/realtime'
const [, , audiopipeBin, outPath] = process.argv
if (!audiopipeBin || !outPath) {
  console.error('usage: node generate-welcome-speech.mjs <audiopipe-bin> <out.m4a>')
  process.exit(1)
}

const OVERALL_TIMEOUT_MS = 90_000
const READY_TIMEOUT_MS = 6_000

function connectOnce({ takeover }) {
  return new Promise((resolve, reject) => {
    const sessionId = `welcome-gen-${randomUUID().slice(0, 8)}`
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
        clientLabel: 'welcome-gen',
        clientInstanceId: `welcome_${randomUUID()}`,
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
          console.error(`[welcome-gen] voice ready (takeover=${takeover}), sending text.message`)
          ws.send(JSON.stringify({ type: 'text.message', text: INSTRUCTION }))
        }
        return
      }
      // 后台任务播报与本次朗读无关，全部忽略（ESS-36 隔离原则）。
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
        ws.send(JSON.stringify({ type: 'mute' }))   // 释放语音所有权
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
  console.error('[welcome-gen] voice busy, retrying with takeover=true')
  capture = await connectOnce({ takeover: true })
}

if (capture.pcm.length === 0) {
  console.error('[welcome-gen] no audio received')
  process.exit(1)
}
console.error(`[welcome-gen] transcript: ${capture.transcript}`)
console.error(`[welcome-gen] pcm bytes: ${capture.pcm.length} @ ${capture.sampleRate}Hz`)
if (!capture.transcript.includes('Jackson')) {
  console.error('[welcome-gen] WARNING: transcript does not match the fixed copy, consider re-running')
}

const dir = mkdtempSync(join(tmpdir(), 'welcome-gen-'))
try {
  const rawPath = join(dir, 'welcome.raw')
  writeFileSync(rawPath, capture.pcm)
  const meta = execFileSync(audiopipeBin, ['encode', rawPath, String(capture.sampleRate), outPath], { encoding: 'utf8' })
  console.error(`[welcome-gen] encoded: ${meta.trim()}`)
  console.log(JSON.stringify({ out: outPath, transcript: capture.transcript, pcmBytes: capture.pcm.length, sampleRate: capture.sampleRate }))
} finally {
  rmSync(dir, { recursive: true, force: true })
}
