// MacAudioCodecPipeline adapter (ESS-25 AudioPipe): controlled process calls,
// arguments passed directly to execFile — never through a shell (§8).
//
// decode: AAC/M4A file → 16kHz mono PCM16LE raw file (anti-aliased SRC)
// encode: 24kHz PCM16LE raw file → AAC-LC .m4a the Watch can play

import { execFile } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const run = (bin, args) => new Promise((resolve, reject) => {
  execFile(bin, args, { encoding: 'utf8', timeout: 30_000 }, (error, stdout) => {
    if (error) return reject(new Error(`audiopipe failed: ${error.message}`))
    try { resolve(JSON.parse(stdout)) } catch { reject(new Error('audiopipe returned non-JSON output')) }
  })
})

export class AudioPipeline {
  constructor({ audiopipePath, allowTestPcm = false }) {
    this.bin = audiopipePath
    this.allowTestPcm = allowTestPcm
  }

  workdir() {
    return mkdtempSync(join(tmpdir(), 'bridge-audio-'))
  }

  // audioBuf (codec per metadata) → { pcm16k: Buffer, meta }
  async decodeTo16k(audioBuf, codec) {
    // Test-only escape hatch: raw 16k PCM bypasses the transcode step so the
    // bridge can be exercised without the Swift toolchain. Off by default.
    if (codec === 'pcm16le_16k') {
      if (!this.allowTestPcm) throw new Error('pcm16le_16k input is disabled (allow_test_pcm=false)')
      return { pcm16k: audioBuf, meta: { passthrough: true } }
    }
    const dir = this.workdir()
    try {
      const input = join(dir, 'in.m4a')
      const output = join(dir, 'out.raw')
      writeFileSync(input, audioBuf)
      const meta = await run(this.bin, ['decode', input, output, '16000'])
      return { pcm16k: readFileSync(output), meta }
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  }

  // 24kHz PCM16LE Buffer → m4a Buffer
  async encode24kToM4a(pcm24k) {
    const dir = this.workdir()
    try {
      const input = join(dir, 'in.raw')
      const output = join(dir, 'out.m4a')
      writeFileSync(input, pcm24k)
      await run(this.bin, ['encode', input, '24000', output])
      return readFileSync(output)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  }
}
