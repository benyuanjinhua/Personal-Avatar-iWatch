import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import { TaskWatcher, userProgressText } from '../taskwatch.mjs'

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

describe('ESS-59 real task progress', () => {
  it('maps recognised real activity and never exposes unknown identifiers', () => {
    assert.equal(userProgressText({ status: 'running', activity: [{ tool: 'weather_query' }] }), '正在查询天气')
    assert.equal(userProgressText({ status: 'running', activity: [{ tool: 'vault.search' }] }), '正在翻你的笔记')
    assert.equal(
      userProgressText({ status: 'running', activity: [{ tool: 'internal_tool_X9', title: 'task_123 secret' }] }),
      '正在执行任务'
    )
    assert.equal(userProgressText({ status: 'finalizing' }), '正在整理结果')
  })

  it('throttles to one event per interval and enforces the total cap', async () => {
    const watcher = new TaskWatcher({
      gateway: {}, ledger: {},
      config: { progress_min_interval_ms: 30, max_progress_events: 2 },
    })
    const events = []
    watcher.onProgress = event => events.push(event)

    watcher.emitProgress('req-1', { status: 'running', activity: [{ tool: 'weather_query' }] })
    watcher.emitProgress('req-1', { status: 'delegated' })
    assert.equal(events.length, 1, 'same interval must suppress later progress')

    await sleep(35)
    watcher.emitProgress('req-1', { status: 'delegated' })
    await sleep(35)
    watcher.emitProgress('req-1', { status: 'finalizing' })

    assert.deepEqual(events.map(event => event.text), ['正在查询天气', '已交给执行助手处理'])
    assert.deepEqual(events.map(event => event.sequence), [1, 2])
  })
})
