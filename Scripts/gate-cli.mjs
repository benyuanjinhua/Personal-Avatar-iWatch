// 门禁脚本共用的 CLI 工具（ESS-65 抽取自 watch-build-gate.mjs）：
// 参数解析、commit 提交时间解析、日志读取。三个入口
// （watch-build-gate / watch-smoke-gate / preflight）共用，不复制粘贴。

import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'

export function parseArgs(argv) {
  const args = {}
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i]
    if (!token.startsWith('--')) continue
    const key = token.slice(2)
    const next = argv[i + 1]
    if (next === undefined || next.startsWith('--')) { args[key] = true; continue }
    args[key] = next
    i += 1
  }
  return args
}

export function fail(message) {
  process.stderr.write(`${message}\n`)
  process.exit(2)
}

export function commitTime(rev, repo) {
  try {
    return execFileSync('git', ['-C', repo, 'log', '-1', '--format=%cI', rev], { encoding: 'utf8' }).trim()
  } catch {
    fail(`无法在 ${repo} 解析 commit ${rev} 的提交时间`)
  }
}

/// --rev/--built-after 二选一，解析出「表端证据必须不早于」的参照时间。
export function resolveRequiredBuiltAfter(args, defaultRepo) {
  if (!args.rev && !args['built-after']) fail('必须给 --rev 或 --built-after 之一')
  return args['built-after'] || commitTime(args.rev, args.repo || defaultRepo)
}

export function readLogLines(path) {
  try {
    return readFileSync(path, 'utf8').split('\n')
  } catch (error) {
    fail(`读不到日志文件 ${path}：${error.message}`)
  }
}
