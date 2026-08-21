import assert from 'node:assert/strict'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { loadSoulInstruction } from '../soul-instruction.mjs'

test('loads and trims a non-empty soul instruction', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ess-963-soul-'))
  const path = join(dir, 'soul.md')
  writeFileSync(path, '  Jackson soul  \n')
  assert.equal(loadSoulInstruction(path), 'Jackson soul')
})

test('fails explicitly when soul.md is missing or empty', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ess-963-soul-'))
  assert.throws(
    () => loadSoulInstruction(join(dir, 'missing.md')),
    /soul_instruction_read_failed:ENOENT/,
  )
  const empty = join(dir, 'empty.md')
  writeFileSync(empty, ' \n')
  assert.throws(() => loadSoulInstruction(empty), /soul_instruction_empty/)
})
