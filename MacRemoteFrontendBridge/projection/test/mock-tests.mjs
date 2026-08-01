// ESS-27 mock 网关测试：确定性覆盖投影模块的边界与错误路径。
// 运行: node test/mock-tests.mjs
//
// 覆盖场景：
//  1. sse-happy            — SSE 全程投影，终态恰好交付一次
//  2. sse-drop-rest        — SSE 中断（且不再可用）→ REST 退避轮询恢复终态，不丢结果
//  3. sse-resume           — SSE 中断 → 退避后 SSE 重连继续投影
//  4. html-catch-all       — 网关 catch-all 返回 200+HTML → 不当 JSON/SSE 解析，稳定重试
//  5. hard-timeout         — 300s(缩短) 硬超时 → DELETE + 稳定错误 work_timeout
//  6. cancel-northbound    — 北向 cancel → DELETE → cancelled 终态
//  7. cancel-409-race      — cancel 撞上已完成 → 交付真实 completed 终态（不丢结果）
//  8. permission-chain     — POST /api/permissions/:id 决定校验 / 404 / 成功
//  9. result-trimming      — 长文本 speech/inline 裁剪只留摘要
// 10. progress-cap         — 进度事件限流与总量上限，终态仍放行
// 11. task-lost            — 任务见过后 404 → task_lost 稳定错误，人工确认语义
// 12. ledger               — 幂等登记 / settle / 重启恢复列表

import { createServer } from 'node:http'
import assert from 'node:assert/strict'
import { QwenTaskProjection, respondPermission, sleep } from '../task-projection.mjs'
import { ProjectionLedger } from '../projection-ledger.mjs'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

// ---- 可编程 mock 网关 -------------------------------------------------------

function makeMockGateway() {
  const state = {
    task: null,                 // 当前 task 对象（handler 可变更）
    sseMode: 'stream',          // stream | refuse | html
    restMode: 'json',           // json | html | missing
    sseClients: new Set(),
    deletes: [],
    permissions: [],
    sseConnects: 0,
  }
  const server = createServer((req, res) => {
    const url = new URL(req.url, 'http://localhost')
    const parts = url.pathname.split('/').filter(Boolean)
    // GET /api/tasks/:id/events
    if (req.method === 'GET' && parts[0] === 'api' && parts[1] === 'tasks' && parts[3] === 'events') {
      state.sseConnects += 1
      if (state.sseMode === 'refuse') { res.writeHead(503, { 'content-type': 'application/json' }); return res.end('{"error":"unavailable"}') }
      if (state.sseMode === 'html') { res.writeHead(200, { 'content-type': 'text/html' }); return res.end('<!doctype html><html>SPA</html>') }
      if (!state.task || state.restMode === 'missing') { res.writeHead(404, { 'content-type': 'application/json' }); return res.end('{"error":"task not found"}') }
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' })
      res.write(`data: ${JSON.stringify({ type: 'task.snapshot', task: state.task })}\n\n`)
      state.sseClients.add(res)
      req.on('close', () => state.sseClients.delete(res))
      return
    }
    // GET /api/tasks/:id
    if (req.method === 'GET' && parts[0] === 'api' && parts[1] === 'tasks' && parts.length === 3) {
      if (state.restMode === 'html') { res.writeHead(200, { 'content-type': 'text/html' }); return res.end('<!doctype html>') }
      if (!state.task || state.restMode === 'missing') { res.writeHead(404, { 'content-type': 'application/json' }); return res.end('{"error":"task not found"}') }
      res.writeHead(200, { 'content-type': 'application/json' })
      return res.end(JSON.stringify(state.task))
    }
    // DELETE /api/tasks/:id
    if (req.method === 'DELETE' && parts[1] === 'tasks') {
      state.deletes.push(parts[2])
      if (!state.task) { res.writeHead(404, { 'content-type': 'application/json' }); return res.end('{"error":"task not found"}') }
      if (['completed', 'failed', 'cancelled'].includes(state.task.status)) {
        res.writeHead(409, { 'content-type': 'application/json' })
        return res.end(JSON.stringify({ error: 'task is no longer active', task: state.task }))
      }
      state.task = { ...state.task, status: 'cancelled' }
      broadcast('task.cancelled')
      res.writeHead(200, { 'content-type': 'application/json' })
      return res.end(JSON.stringify(state.task))
    }
    // POST /api/permissions/:id
    if (req.method === 'POST' && parts[1] === 'permissions') {
      let body = ''
      req.on('data', chunk => { body += chunk })
      req.on('end', () => {
        let decision = null
        try { decision = JSON.parse(body).decision } catch {}
        state.permissions.push({ id: parts[2], decision })
        if (!['always', 'reject'].includes(decision)) { res.writeHead(400, { 'content-type': 'application/json' }); return res.end('{"error":"decision must be always or reject"}') }
        if (parts[2] === 'missing-perm') { res.writeHead(404, { 'content-type': 'application/json' }); return res.end('{"error":"permission not found"}') }
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ id: parts[2], decision, resolved: true }))
      })
      return
    }
    // catch-all：与真实网关一致，未知 GET 返回 200 + HTML（SPA index.html）
    res.writeHead(200, { 'content-type': 'text/html' })
    res.end('<!doctype html><html>SPA catch-all</html>')
  })
  function broadcast(type) {
    for (const res of state.sseClients) res.write(`data: ${JSON.stringify({ type, task: state.task })}\n\n`)
  }
  function dropSseClients() {
    for (const res of state.sseClients) res.destroy()
    state.sseClients.clear()
  }
  return new Promise(resolve => {
    server.listen(0, '127.0.0.1', () => {
      resolve({
        url: `http://127.0.0.1:${server.address().port}`,
        state,
        broadcast,
        dropSseClients,
        close: () => new Promise(done => { dropSseClients(); server.close(done) }),
      })
    })
  })
}

function baseTask(over = {}) {
  return {
    id: 'task_test1', workId: 'task_test1', status: 'running', kind: 'work',
    objective: 'test objective', ownerId: 'personal', sessionId: 'watch-bridge-v1-test',
    createdAt: Date.now(), startedAt: Date.now(), result: null, error: null,
    resultMetadata: null, activity: [], delegation: null, authorization: null,
    ...over,
  }
}

function collector() {
  const events = []
  return { events, deliver: e => events.push(e) }
}

function projection(gw, over = {}) {
  const { events, deliver } = collector()
  const proj = new QwenTaskProjection({
    gatewayHttp: gw.url, taskId: 'task_test1', requestId: 'req_test1', deliver,
    backoffBaseMs: 60, backoffMaxMs: 300, progressMinIntervalMs: 0,
    ...over,
  })
  return { proj, events }
}

const results = []
async function scenario(name, fn) {
  const gw = await makeMockGateway()
  try {
    await fn(gw)
    results.push({ name, ok: true })
    console.log(`PASS ${name}`)
  } catch (error) {
    results.push({ name, ok: false, error: error.message })
    console.log(`FAIL ${name}: ${error.stack}`)
  } finally {
    await gw.close()
  }
}

const terminalOf = events => events.filter(e => ['completed', 'failed', 'cancelled'].includes(e.state))

// 1. SSE 全程
await scenario('sse-happy', async gw => {
  gw.state.task = baseTask()
  const { proj, events } = projection(gw)
  const run = proj.start()
  await sleep(150)
  gw.state.task = { ...gw.state.task, status: 'delegated' }; gw.broadcast('task.delegated')
  await sleep(80)
  gw.state.task = {
    ...gw.state.task, status: 'completed',
    resultMetadata: { presentation: { speech: '统计完成，共 42 个文件', inline: { title: '统计', content: '共 42 个 Swift 文件' } } },
  }
  gw.broadcast('task.completed')
  await run
  assert.equal(events[0].state, 'background_accepted')
  const terms = terminalOf(events)
  assert.equal(terms.length, 1)
  assert.equal(terms[0].state, 'completed')
  assert.equal(terms[0].transport, 'sse')
  assert.equal(terms[0].result.speech, '统计完成，共 42 个文件')
})

// 2. SSE 中断且不再可用 → REST 恢复
await scenario('sse-drop-rest', async gw => {
  gw.state.task = baseTask()
  const { proj, events } = projection(gw)
  const run = proj.start()
  await sleep(150)
  proj.killSse({ disable: true })          // 模拟 SSE 长期不可用
  gw.state.task = {
    ...gw.state.task, status: 'completed',
    resultMetadata: { presentation: { speech: '离线完成', inline: null } },
  }
  await run
  const terms = terminalOf(events)
  assert.equal(terms.length, 1)
  assert.equal(terms[0].state, 'completed')
  assert.equal(terms[0].transport, 'rest')  // 终态经 REST 交付
  assert.equal(terms[0].result.speech, '离线完成')
})

// 3. SSE 中断 → 退避后 SSE 重连
await scenario('sse-resume', async gw => {
  gw.state.task = baseTask()
  const { proj, events } = projection(gw)
  const run = proj.start()
  await sleep(150)
  const connectsBefore = gw.state.sseConnects
  gw.dropSseClients()                       // 服务端掐断 SSE
  await sleep(500)                          // 等退避重连
  assert.ok(gw.state.sseConnects > connectsBefore, 'SSE 应重连')
  gw.state.task = { ...gw.state.task, status: 'completed', resultMetadata: { presentation: { speech: '重连后完成', inline: null } } }
  gw.broadcast('task.completed')
  await run
  const terms = terminalOf(events)
  assert.equal(terms.length, 1)
  assert.equal(terms[0].result.speech, '重连后完成')
})

// 4. catch-all HTML 防御
await scenario('html-catch-all', async gw => {
  gw.state.task = baseTask()
  gw.state.sseMode = 'html'
  gw.state.restMode = 'html'
  const { proj, events } = projection(gw)
  const run = proj.start()
  await sleep(400)                          // 多轮：SSE 拿到 HTML、REST 拿到 HTML，都不得误判
  assert.equal(terminalOf(events).length, 0, 'HTML 响应不得被解析成任务状态')
  assert.ok(proj.journal.some(e => e.event === 'rest.error' && /non-JSON|bad_content_type/.test(e.message || e.code)), 'REST 应记录 content-type 防御')
  gw.state.sseMode = 'stream'
  gw.state.restMode = 'json'
  gw.state.task = { ...gw.state.task, status: 'completed', resultMetadata: { presentation: { speech: '恢复后完成', inline: null } } }
  await run
  const terms = terminalOf(events)
  assert.equal(terms.length, 1)
  assert.equal(terms[0].result.speech, '恢复后完成')
})

// 5. 硬超时 → DELETE + work_timeout
await scenario('hard-timeout', async gw => {
  gw.state.task = baseTask()
  const { proj, events } = projection(gw, { hardTimeoutMs: 300 })
  await proj.start()
  const terms = terminalOf(events)
  assert.equal(terms.length, 1)
  assert.equal(terms[0].state, 'failed')
  assert.equal(terms[0].error.code, 'work_timeout')
  assert.ok(gw.state.deletes.length >= 1, '超时必须发 DELETE 取消')
})

// 6. 北向 cancel
await scenario('cancel-northbound', async gw => {
  gw.state.task = baseTask()
  const { proj, events } = projection(gw)
  const run = proj.start()
  await sleep(150)
  await proj.cancel()
  await run
  const terms = terminalOf(events)
  assert.equal(terms.length, 1)
  assert.equal(terms[0].state, 'cancelled')
  assert.deepEqual(gw.state.deletes, ['task_test1'])
})

// 7. cancel 撞上已完成（409）→ 真实终态
await scenario('cancel-409-race', async gw => {
  gw.state.task = baseTask()
  const { proj, events } = projection(gw)
  const run = proj.start()
  await sleep(150)
  proj.killSse({ disable: true })
  gw.state.task = { ...gw.state.task, status: 'completed', resultMetadata: { presentation: { speech: '早已完成', inline: null } } }
  await proj.cancel()                       // DELETE → 409 + task
  await run
  const terms = terminalOf(events)
  assert.equal(terms.length, 1)
  assert.equal(terms[0].state, 'completed', 'cancel 竞态不得丢真实结果')
  assert.equal(terms[0].result.speech, '早已完成')
})

// 8. 权限链路
await scenario('permission-chain', async gw => {
  const bad = await respondPermission({ gatewayHttp: gw.url, authorizationId: 'auth1', decision: 'yes' })
  assert.equal(bad.ok, false); assert.equal(bad.code, 'invalid_decision')
  const missing = await respondPermission({ gatewayHttp: gw.url, authorizationId: 'missing-perm', decision: 'reject' })
  assert.equal(missing.ok, false); assert.equal(missing.code, 'permission_not_found')
  const ok = await respondPermission({ gatewayHttp: gw.url, authorizationId: 'auth1', decision: 'always' })
  assert.equal(ok.ok, true)
  assert.deepEqual(gw.state.permissions.at(-1), { id: 'auth1', decision: 'always' })
  // permission_required 投影：task 携带 authorization
  gw.state.task = baseTask({ authorization: { id: 'auth1', command: '在 ~ 创建文件 ESS_TEST.txt' } })
  const { proj, events } = projection(gw)
  const run = proj.start()
  await sleep(150)
  assert.ok(events.some(e => e.state === 'permission_required' && e.authorization.id === 'auth1'))
  gw.state.task = { ...gw.state.task, status: 'completed', authorization: null, resultMetadata: { presentation: { speech: '完成', inline: null } } }
  gw.broadcast('task.completed')
  await run
})

// 9. 结果裁剪
await scenario('result-trimming', async gw => {
  const longText = 'A'.repeat(9000)
  gw.state.task = baseTask({
    status: 'completed',
    resultMetadata: { presentation: { speech: longText, inline: { title: 'T'.repeat(300), content: longText } } },
  })
  const { proj, events } = projection(gw, { speechMaxChars: 600, inlineMaxChars: 2000 })
  await proj.start()
  const [term] = terminalOf(events)
  assert.equal(term.result.speech.length, 600)
  assert.equal(term.result.inline.content.length, 2000)
  assert.equal(term.result.inline.truncated, true)
  assert.ok(term.result.inline.title.length <= 120)
})

// 10. 进度限流与上限
await scenario('progress-cap', async gw => {
  gw.state.task = baseTask()
  const { proj, events } = projection(gw, { maxProjectedEvents: 5, progressMinIntervalMs: 0 })
  const run = proj.start()
  await sleep(150)
  for (let i = 0; i < 30; i++) { gw.broadcast('task.progress'); await sleep(10) }
  gw.state.task = { ...gw.state.task, status: 'completed', resultMetadata: { presentation: { speech: '完成', inline: null } } }
  gw.broadcast('task.completed')
  await run
  assert.ok(events.length <= 6, `事件总量必须受限（实际 ${events.length}）`)
  const terms = terminalOf(events)
  assert.equal(terms.length, 1, '终态永远放行')
  assert.ok(proj.progressSuppressed > 0)
})

// 11. 任务状态丢失 → task_lost
await scenario('task-lost', async gw => {
  gw.state.task = baseTask()
  const { proj, events } = projection(gw)
  const run = proj.start()
  await sleep(150)
  proj.killSse({ disable: true })
  gw.state.restMode = 'missing'             // 网关重启丢状态：见过的任务 404
  await run
  const terms = terminalOf(events)
  assert.equal(terms.length, 1)
  assert.equal(terms[0].state, 'failed')
  assert.equal(terms[0].error.code, 'task_lost')
  assert.ok(/人工确认/.test(terms[0].error.message), '结果未知必须转人工确认语义')
})

// 12. 账本：幂等 + 恢复
await scenario('ledger', async () => {
  const path = join(mkdtempSync(join(tmpdir(), 'ess27-')), 'ledger.json')
  const ledger = new ProjectionLedger({ path })
  const first = ledger.upsert('req_a', { taskId: 'task_1' })
  assert.equal(first.duplicate, false)
  const dup = ledger.upsert('req_a', { taskId: 'task_1' })
  assert.equal(dup.duplicate, true)
  assert.equal(dup.taskId, 'task_1')
  ledger.upsert('req_b', { taskId: 'task_2' })
  ledger.markSettled('req_a', 'completed')
  assert.equal(ledger.markSettled('req_a', 'failed'), false, '终态只落一次')
  // 重启恢复
  const reopened = new ProjectionLedger({ path })
  assert.deepEqual(reopened.unsettled().map(e => e.requestId), ['req_b'])
  assert.equal(reopened.get('req_a').terminalState, 'completed')
})

console.log('---')
const failed = results.filter(r => !r.ok)
console.log(JSON.stringify({ total: results.length, passed: results.length - failed.length, failed }, null, 2))
process.exit(failed.length ? 1 : 0)
