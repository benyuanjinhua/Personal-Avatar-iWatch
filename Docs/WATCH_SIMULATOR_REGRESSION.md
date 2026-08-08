# Watch 模拟器回归门禁

架构重构后，凡是改动 `Shared/`、`Watch/`、`WatchTests/`、`project.yml` 或 Watch target 构建设置，开发自测与 PR 复审都必须执行：

```sh
./Scripts/verify-watch-simulator.sh
```

脚本选择已启动或首个可用的 watchOS Simulator，并以 `WristAgent Watch App` scheme 运行 `WristAgent Watch Tests`。退出码为 0，且末尾同时出现 Xcode 的 `** TEST SUCCEEDED **` 与脚本的 `PASS: Watch 模拟器回归完成`，才算通过。没有可用模拟器、测试未实际执行、存在失败或非零退出都算门禁失败。全量入口 `./Scripts/verify.sh` 调用同一门禁。

## 模拟器必测范围

新增或修改对应链路时，必须在 `WatchTests/` 保留或补齐下列回归：

| 能力 | 覆盖重点 | 当前测试锚点 |
|---|---|---|
| 实时流接收 | start/delta/done、完整事件序、重复分片幂等 | `WatchStreamReceiverTests`、`WatchRealtimeMediaAdapterTests` |
| 乱序与降级 | sequence 重排、缺片/done barrier 超时、跨 generation 丢弃、单次完整文件降级 | `WatchStreamReceiverTests`、`WatchRealtimeMediaAdapterTests` |
| 播放调度 | 首帧启动、末帧完成、停止/用户打断、队列释放 | `PlaybackEndgameChainTests`、`SpeechPlayerUserInterruptTests`、`SpeechPlayerReleaseTests` |
| AVAudioEngine / AVAudioPlayerNode 恢复 | interruption 后重新激活、engine/player 恢复、失败证据 | `SpeechPlayerInterruptionTests`、`SpeechPlayerInterruptionEvidenceTests` |

这些是合入前门禁。只跑 `swift test` 不合格，因为 Swift Package 测试不编译 Watch target。

## 不替代真机的范围

模拟器通过不代表以下能力通过，合入 main 后仍按 R-02.5 用物理 Apple Watch / iPhone 和 `WatchLog` 收口：

- 麦克风录音输入与真实采样；
- 真实音频路由、音频会话竞争及扬声器出声；
- WCSession 可达、暂时不可达、恢复及真实抖动；
- 后台、锁屏、降腕和真实 app lifecycle。

PR 证据应贴脚本命令、退出码和 Xcode 测试汇总；涉及以上真机独有能力时，同时注明“模拟器已验、仍需真机验”，不得用模拟器结果宣称真机功能完成。
