// generate-error-cues.mjs — ESS-180-B 拟人化错误语音批量生成（一次性资产工具）。
//
// 以伪前端身份连接 qwen-audio-agent 的 loopback WS /api/realtime，用 text.message
// 让 Qwen Audio Realtime 朗读固定错误文案，聚合 24kHz PCM audio.delta，经 AudioPipe
// 转成 Watch 可直接播放的 AAC/M4A。
//
// 用法：node generate-error-cues.mjs <audiopipe-bin> <out-dir>
// 前置：qwen-audio-agent 网关在 127.0.0.1:3101 运行且 DashScope 已配置。
//
// 产物提交进仓库（Watch/Resources/ErrorCue_*.m4a），随 App 打包；重新生成只需
// 重跑本脚本。文案即代码：改文案 = 改这里 + 重新生成。

import WebSocket from 'ws'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'

// 文案与 Watch/Resources/ErrorCue_README.md、ErrorCueCatalog.swift 一致。
const CUES = [
  { file: 'ErrorCue_AudioTooShort',       text: '刚才没听清，是不是碰到了？多按一会儿再说一遍。' },
  { file: 'ErrorCue_TranscriptDiscarded', text: '话有点糊，麻烦离麦近一点再说一次。' },
  { file: 'ErrorCue_VoiceBusy',           text: '抱歉，我这边有人正在说话，稍后再叫我一下。' },
  { file: 'ErrorCue_RealtimeStalled',     text: '刚才那句我卡了一下，麻烦你再说一次。' },
  { file: 'ErrorCue_Generic',             text: '刚才没成功，你可以再说一次。' },
]

const GATEWAY = process.env.QWEN_GATEWAY_WS || 'ws://127.0.0.1:3101/api/realtime'
const [, , audiopipeBin, outDir] = process.argv
if (!audiopipeBin || !outDir) {
  console.error('usage: node generate-error-cues.mjs <audiopipe-bin> <out-dir>')
  process.exit(1)
}

const OVERALL_TIMEOUT_MS = 90_000
const READY_TIMEOUT_MS = 6_000

function connectOnce({ takeover, instruction, expectText }) {
  return new Promise((resolve, reject) => {
    const sessionId = `err-cue-gen-${randomUUID().slice(0, 8)}`
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
        clientLabel: 'err-cue-gen',
        clientInstanceId: `err_cue_${randomUUID()}`,
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
          console.error(`[err-cue-gen] voice ready (takeover=${takeover}) → send "${expectText}"`)
          ws.send(JSON.stringify({ type: 'text.message', text: instruction }))
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

async function generateOne({ file, text }) {
  const instruction = `请用自然、亲切、略带歉意的语气一字不差地说出下面这句话，不要添加、省略或改动任何字，也不要说其他内容：${text}`
  let capture
  try {
    capture = await connectOnce({ takeover: false, instruction, expectText: text })
  } catch (error) {
    if (error.code !== 'NOT_READY') throw error
    console.error(`[err-cue-gen] ${file}: voice busy, retrying with takeover=true`)
    capture = await connectOnce({ takeover: true, instruction, expectText: text })
  }
  if (capture.pcm.length === 0) throw new Error(`${file}: no audio received`)
  console.error(`[err-cue-gen] ${file}: transcript="${capture.transcript}" bytes=${capture.pcm.length} @${capture.sampleRate}Hz`)

  const dir = mkdtempSync(join(tmpdir(), `err-cue-${file}-`))
  try {
    const rawPath = join(dir, `${file}.raw`)
    const outPath = join(outDir, `${file}.m4a`)
    writeFileSync(rawPath, capture.pcm)
    const meta = execFileSync(audiopipeBin, ['encode', rawPath, String(capture.sampleRate), outPath], { encoding: 'utf8' })
    console.error(`[err-cue-gen] ${file}: encoded ${meta.trim()}`)
    return { out: outPath, transcript: capture.transcript, pcmBytes: capture.pcm.length, sampleRate: capture.sampleRate }
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

const results = []
for (const cue of CUES) {
  // 串行：qwen 网关同时只能有一个 realtime session。中间加短 sleep 让 voice.ownership 归位。
  results.push(await generateOne(cue))
  await new Promise(r => setTimeout(r, 400))
}
console.log(JSON.stringify(results, null, 2))
