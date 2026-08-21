import { readFileSync } from 'node:fs'

const MAX_SOUL_CHARS = 16_000

export function loadSoulInstruction(path) {
  let content
  try {
    content = readFileSync(path, 'utf8').trim()
  } catch (error) {
    throw new Error(`soul_instruction_read_failed:${error?.code ?? 'unknown'}`)
  }
  if (!content) throw new Error('soul_instruction_empty')
  if ([...content].length > MAX_SOUL_CHARS) {
    throw new Error(`soul_instruction_too_large:max=${MAX_SOUL_CHARS}`)
  }
  return content
}
