// ESS-1100: 把上游 `task.*` 携带的**阶段性进展**投影成一行可展示文字。
//
// 缺口取证（本单实现前的实际线格）：
//   • 上游 qwen-audio-agent 的 `sendTaskEvent(ws, event)`
//     （`server/src/voice/realtime-gateway.mjs`）把**完整的** `publicTask`
//     发下来——含 `activity[]`（工具/计划/文本三类，带 `category`、`label`、
//     `detail`、`status`）、`objective`、`delegation`、`authorization`。
//   • 本网关的 `qwen-agent-transport.mjs` 此前把它压成
//     `onEvent({type:'agent.task', task:{id, status}})`——**进展文字在这一跳
//     被整段丢弃**，再往下（`task.state` → iPhone → Watch）自然什么都没有。
//
// 所以「协议缺口」只有一处、也只需补一处：把已经到达网关的进展文字带上。
// 客户端**不自行编造**工具进展，它显示的每一条都由本模块从真实上游事件里
// 取出（H5 参照实现：`qwen-audio-agent/web/src/task-view.js` 的
// `latestVisibleActivity` / `taskDetail`，本模块是它的手表适配版）。
//
// 与 H5 的两点刻意差异，都是小屏适配（ESS-1100 §5），不是信息造假：
//   1. 不拼「N/M」「· N 秒」这类数字——ESS-180 已经拍板处理中不做纯计时，
//      而手表这一行只有一行的预算，数字挤掉的是真正有信息量的那半句。
//   2. 工具活动优先取**类目短语**而不是上游的自由文本 `label`（可长达 160
//      字符、常为英文工具描述）。类目本身来自上游（`activity.category`），
//      短语只是它的中文渲染——与 H5 主界面显示的「正在查询相关信息」逐字
//      相同，正是本单截图基线里的那句。
//
// 纯函数、无副作用、不依赖 ws/net，`test/ess1100-task-progress.test.mjs`
// 可完整覆盖。

/// 手表一行的可读上限。超出即尾部截断（客户端还会再截一次，两侧都不越界）。
export const MAX_PROGRESS_TEXT = 24

/// 终态不产出进展文字：终态由 `task.state` 的 `status` 独占表达，客户端对
/// 完成/失败/取消有各自的终态呈现。在终态帧上再塞一句「进展」，只会让
/// 「还在做」与「做完了」在同一行里打架。
const TERMINAL_STATUSES = new Set([
  'completed', 'complete', 'done', 'succeeded',
  'failed', 'error',
  'cancelled', 'canceled', 'aborted',
  'timeout', 'timed_out',
])

/// 非生命周期的通知类事件（与 `qwen-agent-transport.mjs` 的同名集合口径一致）：
/// 它们是**关于**任务的通知，不是任务自己的阶段推进，不产出进展文字。
const NON_PROGRESS_EVENTS = new Set([
  'task.notification.pending', 'task.notification.delivered',
  'task.notification.offline', 'task.permission.resolved',
  'task.snapshot',
])

const CATEGORY_TEXT = Object.freeze({
  image: '正在生成图片',
  search: '正在查询相关信息',
  read: '正在读取相关内容',
  write: '正在修改内容',
})

const STATUS_TEXT = Object.freeze({
  queued: '正在排队',
  pending: '正在排队',
  finalizing: '正在整理结果',
  cancelling: '正在取消',
  delegated: '正在处理',
})

function bounded(value) {
  const text = String(value ?? '').trim().replace(/\s+/g, ' ')
  if (!text) return ''
  return Array.from(text).slice(0, MAX_PROGRESS_TEXT).join('')
}

/// H5 `latestVisibleActivity` 的逐条移植：优先「还没结束的工具」，其次
/// 「在跑的计划」，再退到最后一条工具/计划，最后退到最后一条活动。
/// `<qwen_audio_agent_request>` 开头的文本活动是注入给模型的控制文本，
/// 不是给人看的，必须过滤——否则手表会把一段协议内文原样念给用户看。
function latestVisibleActivity(activity) {
  if (!Array.isArray(activity)) return null
  const visible = activity.filter(item => (
    item
    && typeof item === 'object'
    && item.tool !== 'invalid'
    && !(
      item.kind === 'text'
      && String(item.text || '').trim().startsWith('<qwen_audio_agent_request>')
    )
  ))
  const findLast = predicate => {
    for (let i = visible.length - 1; i >= 0; i -= 1) {
      if (predicate(visible[i])) return visible[i]
    }
    return null
  }
  return findLast(item => (
    item.kind === 'tool' && !['completed', 'failed'].includes(item.status)
  ))
    || findLast(item => item.kind === 'plan' && item.status === 'running')
    || findLast(item => item.kind === 'tool')
    || findLast(item => item.kind === 'plan')
    || visible[visible.length - 1]
    || null
}

/// 工具活动 → 类目。`activity.category` 是上游已经判好的那一份，优先用它；
/// 缺席时按 H5 的同一组正则从 `tool`/`detail` 兜一次，两侧口径不分叉。
function toolCategory(activity) {
  const raw = String(activity.category || '').toLowerCase()
  if (CATEGORY_TEXT[raw]) return raw
  const hint = `${activity.tool || ''} ${activity.detail || ''}`.toLowerCase()
  if (/image|图片|图像/.test(hint)) return 'image'
  if (/search|web|fetch|搜索|查询/.test(hint)) return 'search'
  if (/read|glob|grep|list|读取|查找/.test(hint)) return 'read'
  if (/write|edit|patch|写入|修改/.test(hint)) return 'write'
  return raw || 'run'
}

/**
 * 把一个上游任务对象投影成 `{text, category}`，没有可展示进展时返回 `null`。
 *
 * @param {object|null} task  上游 `event.task`（`publicTask` 形状）
 * @param {string} eventType  上游事件类型（`task.progress` / `task.running` / …）
 */
export function projectTaskProgress(task, eventType = '') {
  if (!task || typeof task !== 'object') return null
  if (NON_PROGRESS_EVENTS.has(eventType)) return null

  const status = String(task.status ?? '').toLowerCase()
  if (TERMINAL_STATUSES.has(status)) return null
  if (eventType === 'task.completed' || eventType === 'task.failed'
    || eventType === 'task.cancelled') return null

  // 等待用户确认是**阻塞**用户的事实，优先级高于任何工具进展：不说出来，
  // 用户会一直以为「还在算」，而其实系统在等他。
  if (task.authorization && String(task.authorization.status || '') === 'pending') {
    return {
      text: bounded(task.authorization.summary) || '正在等待你的确认',
      category: 'authorization',
    }
  }

  if (STATUS_TEXT[status]) {
    return { text: STATUS_TEXT[status], category: status }
  }

  const activity = latestVisibleActivity(task.activity)
  if (!activity) return null

  if (activity.kind === 'session') {
    return { text: '正在连接后台', category: 'session' }
  }
  if (activity.kind === 'plan') {
    return {
      text: bounded(activity.detail) || '正在执行任务',
      category: 'plan',
    }
  }
  if (activity.kind === 'text') {
    return { text: '正在整理结果', category: 'text' }
  }
  if (activity.kind !== 'tool') return null

  const category = toolCategory(activity)
  const text = CATEGORY_TEXT[category]
    || (activity.status === 'completed'
      ? '一个步骤已完成，正在继续'
      : '正在执行任务')
  return { text, category }
}
