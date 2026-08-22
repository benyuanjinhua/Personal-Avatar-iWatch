// ESS-1004：回合终态不得依赖 `voice.state {state:'idle'}`。
//
// ESS-969 选它作终态，依据是注释里的一句推断：
//   「the SAME upstream endpoint emits `voice.state {state:'idle'}`」
// 同一段注释也承认：「No real-device sample of「末段 audio.done → voice.state idle」
// exists yet」。现在样本有了，而且是反例：
//
//   三轮真机（08-22 03:29 / 05:37 / 10:34）`downlink_done` 全部为 0 次。
//
// 上游源码（`QwenAudio/qwen-audio-agent`，本机 clone）里 `state: 'idle'` 共 5 处，
// 全部是异常/边缘路径：
//   :549  模型没开始回复（error）
//   :1029 turn 无效
//   :1267 `if (!responseContext?.hasAudio)` —— **只在 response 没有音频时**
//   :1501 realtime socket 关闭
//   :1866 休眠/挂起
// 正常回答必然 `hasAudio`，因此 **永远不会**收到 idle。
//
// 后果：末段收口后只能等 45 s backstop，而客户端
// `SessionController.thinkingHardTimeoutSeconds` 也是 45 s —— 真机上客户端先到，
// 误报「回答超时」并自动挂断，下一问落进正在挂断/重启的 App。

import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { QwenAgentTransport } from '../qwen-agent-transport.mjs'

// 最小假上游：不建真实 WSS，直接把事件喂进 transport 的处理函数。
function harness({ multiSegmentMode = 'auto', ...opts } = {}) {
  const events = []
  const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: 'ws://127.0.0.1:1/api/realtime',
    multiSegmentMode,
    log: (evt, extra) => logs.push({ evt, ...extra }),
    ...opts,
  })
  return { transport, events, logs }
}

describe('ESS-1004 回合终态', () => {
  it('backstop 必须显著小于客户端硬超时（45 s），否则永远轮不到它', () => {
    const { transport } = harness()
    const CLIENT_HARD_TIMEOUT_MS = 45_000 // SessionController.thinkingHardTimeoutSeconds
    assert.ok(
      transport.turnIdleBackstopMs < CLIENT_HARD_TIMEOUT_MS,
      `backstop(${transport.turnIdleBackstopMs}) 必须 < 客户端硬超时(${CLIENT_HARD_TIMEOUT_MS})。`
        + '两者相等时谁先触发全看调度顺序 —— 真机三轮全是客户端先到，'
        + 'backstop 一次都没生效过。'
    )
    assert.ok(
      CLIENT_HARD_TIMEOUT_MS - transport.turnIdleBackstopMs >= 10_000,
      '余量至少 10 s，否则播放排空的抖动就能让客户端反超'
    )
  })

  it('backstop 仍要容得下工具时延，不许为了抢先而调得过小', () => {
    const { transport } = harness()
    // 真机工具调用整轮（segment0 收口 → segment1 收口）实测 5.8 s。
    // 【n=1，待标定 R-04.4】
    const OBSERVED_TOOL_ROUND_MS = 5_800
    assert.ok(
      transport.turnIdleBackstopMs > OBSERVED_TOOL_ROUND_MS * 3,
      `backstop(${transport.turnIdleBackstopMs}) 必须显著大于实测工具时延 `
        + `${OBSERVED_TOOL_ROUND_MS}ms —— 调小会把本单要救的多段回合截断`
    )
  })

  it('默认值必须同时满足上下两侧约束（回归护栏）', () => {
    const { transport } = harness()
    assert.equal(transport.turnIdleBackstopMs, 30_000,
      '改这个默认值前请同时复核上面两条约束与 ESS-1004 的真机标定说明')
  })
})
