// generate-error-cues-v11.mjs — ESS-262 D2 v1.1 拟人化错误语音资产补齐（一次性工具）。
//
// 与 generate-error-cues.mjs 同一条通道（loopback WS /api/realtime →
// audio.delta PCM → AudioPipe encode AAC）。仅文案列表不同：本脚本产的
// 5 条 m4a 服务 D2 v1.1 新增错误格（E-04 / E-10/E-11/E-18 共享 /
// E-12 / E-17 / E-28），与既有 5 条共 10 条打包上手表。
//
// 用法：node generate-error-cues-v11.mjs <audiopipe-bin> <out-dir>

import WebSocket from 'ws'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'

// 文案与 ESS-262 issue body、Shared/ErrorCueCatalog.swift、
// Watch/Resources/ErrorCue_README.md 必须严格一致。
const CUES = [
  { file: 'ErrorCue_MicPermission',    text: '我还没拿到麦克风权限，去手表的「设置 → 隐私」里开一下就能听见你了。' },
  { file: 'ErrorCue_Retryable',        text: '这件事我跑太久也没跑完，点一下重试，不用重新说。' },
  { file: 'ErrorCue_TextOnly',         text: '答案在，只是语音没留住——文字给你看。' },
  { file: 'ErrorCue_PhoneUnreachable', text: '手机没连上。录音我存着了，连上会自动重发。' },
  { file: 'ErrorCue_ManualConfirm',    text: '这件事做完没有我不确定，去 Mac 上看一眼——我不敢替你重跑。' },
]

const GATEWAY = process.env.QWEN_GATEWAY_WS || 'ws://127.0.0.1:3101/api/realtime'
const [, , audiopipeBin, outDir] = process.argv
if (!audiopipeBin || !outDir) {
  console.error('usage: node generate-error-cues-v11.mjs <audiopipe-bin> <out-dir>')
  process.exit(1)
}

const OVERALL_TIMEOUT_MS = 90_000
const READY_TIMEOUT_MS = 8_000

function connectOnce({ takeover, instruction, expectText }) {
  return new Promise((resolve, reject) => {
    const sessionId = `err-cue-gen-v11-${randomUUID().slice(0, 8)}`
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
        clientLabel: 'err-cue-gen-v11',
        clientInstanceId: `err_cue_v11_${randomUUID()}`,
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
          console.error(`[err-cue-gen-v11] voice ready (takeover=${takeover}) → send "${expectText}"`)
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
    console.error(`[err-cue-gen-v11] ${file}: voice busy, retrying with takeover=true`)
    capture = await connectOnce({ takeover: true, instruction, expectText: text })
  }
  if (capture.pcm.length === 0) throw new Error(`${file}: no audio received`)
  console.error(`[err-cue-gen-v11] ${file}: transcript="${capture.transcript}" bytes=${capture.pcm.length} @${capture.sampleRate}Hz`)

  const dir = mkdtempSync(join(tmpdir(), `err-cue-v11-${file}-`))
  try {
    const rawPath = join(dir, `${file}.raw`)
    const outPath = join(outDir, `${file}.m4a`)
    writeFileSync(rawPath, capture.pcm)
    const meta = execFileSync(audiopipeBin, ['encode', rawPath, String(capture.sampleRate), outPath], { encoding: 'utf8' })
    console.error(`[err-cue-gen-v11] ${file}: encoded ${meta.trim()}`)
    return { out: outPath, transcript: capture.transcript, pcmBytes: capture.pcm.length, sampleRate: capture.sampleRate }
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

const results = []
for (const cue of CUES) {
  results.push(await generateOne(cue))
  await new Promise(r => setTimeout(r, 400))
}
console.log(JSON.stringify(results, null, 2))
