# ErrorCue_*.m4a — ESS-180 / ESS-262 拟人化错误语音

**当前来源**：qwen-audio-realtime（DashScope）预生成的真人语气短语音。
生成脚本 `MacRemoteFrontendBridge/generate-error-cues.mjs`（v1.0，5 条）
与 `MacRemoteFrontendBridge/generate-error-cues-v11.mjs`（ESS-262 v1.1，
新增 5 条）与 WelcomeSpeech 同一条通道（loopback WS `/api/realtime` → PCM
audio.delta → AudioPipe AAC）。由 ESS-180-B 补齐首批 5 条；ESS-262 (D2 v1.1)
把资产扩到 10 条。之前 ESS-180 首轮用 `say -v Tingting` 生成的 macOS TTS
仅为占位，180-A 剥离时已被移除，此后**禁止 `say` 占位**。

## 重新生成

```
# 前置：qwen-audio-agent 网关在 127.0.0.1:3101 运行且 DashScope 已配置。
swift build --package-path AudioPipe -c release
cd MacRemoteFrontendBridge
npm install
# v1.0 五条：
node generate-error-cues.mjs \
  ../AudioPipe/.build/arm64-apple-macosx/release/audiopipe \
  ../Watch/Resources
# ESS-262 v1.1 五条（服务 D2 v1.1 E-04 / E-10-E-11-E-18 / E-12 / E-17 / E-28）：
node generate-error-cues-v11.mjs \
  ../AudioPipe/.build/arm64-apple-macosx/release/audiopipe \
  ../Watch/Resources
```

改文案 = 改对应生成脚本里的 `CUES` + 改 `Shared/ErrorCueCatalog.swift`
的对应文案 + 重新生成。文件名必须与 `ErrorCueCatalog.ClipName`（各条目的
`clip` 字段）一致，`AvatarErrorPresenterTests.testAllBundledClipsExistInAppBundle`
会校验 Bundle 内 10 条文件存在且不为空占位。

## 台词与错误码映射

### v1.0（ESS-180-B，5 条）

| 文件 | 错误码 | 台词 |
|---|---|---|
| `ErrorCue_AudioTooShort.m4a` | `ERR_AUDIO_TOO_SHORT` | 刚才没听清，是不是碰到了？多按一会儿再说一遍。 |
| `ErrorCue_TranscriptDiscarded.m4a` | `ERR_TRANSCRIPT_DISCARDED` | 话有点糊，麻烦离麦近一点再说一次。 |
| `ErrorCue_VoiceBusy.m4a` | `ERR_VOICE_BUSY` | 抱歉，我这边有人正在说话，稍后再叫我一下。 |
| `ErrorCue_RealtimeStalled.m4a` | `ERR_REALTIME_STALLED` / `ERR_REALTIME_NO_EVENTS` / `ERR_REALTIME_TIMEOUT` | 刚才那句我卡了一下，麻烦你再说一次。 |
| `ErrorCue_Generic.m4a` | 兜底 (E-99) | 刚才这件事没成，点重试再来一次；还不行就再说一遍。 |

### D2 v1.1（ESS-262，新增 5 条）

| 文件 | 服务的格子 | 错误码 | 台词 |
|---|---|---|---|
| `ErrorCue_MicPermission.m4a` | E-04（族 D） | `ERR_MIC_PERMISSION` | 我还没拿到麦克风权限，去手表的「设置 → 隐私」里开一下就能听见你了。 |
| `ErrorCue_Retryable.m4a` | E-10 / E-11 / E-18 / E-26（族 B） | `ERR_WORK_TIMEOUT` / `ERR_TASK_FAILED` / `ERR_PROCESSING_FAILED` / `ERR_INTERNAL` / `ERR_UPSTREAM_UNAVAILABLE` / `ERR_TRANSPORT` / `ERR_BAD_RESPONSE` / `ERR_TASK_NOT_FOUND` | 这件事我跑太久也没跑完，点一下重试，不用重新说。<br>_(E-11 / E-18 / E-26 各有各的定型文案，共用同一条语音——用户视角只需要知道「点重试就好」)_ |
| `ErrorCue_TextOnly.m4a` | E-12（族 E） | `ERR_NO_SPEECH_FILE` / `ERR_VAULT_LOAD` / `ERR_VAULT_STORE` | 答案在，只是语音没留住——文字给你看。 |
| `ErrorCue_PhoneUnreachable.m4a` | E-17（族 B） | `ERR_WC_NOT_ACTIVATED` | 手机没连上。录音我存着了，连上会自动重发。 |
| `ErrorCue_ManualConfirm.m4a` | E-28（族 H） | `ERR_RESULT_UNKNOWN` | 这件事做完没有我不确定，去 Mac 上看一眼——我不敢替你重跑。 |

**编码**：AAC-LC / m4a container / mono / 24kHz / ~60kbps（AudioPipe `encode`
默认，与 WelcomeSpeech 同链路）；每条 3–6 秒。

## 播放失败的降级

任何一条 clip 加载或起播失败，`AvatarErrorPresenter` 走「文字 + 触觉」降级
路径——卡片仍在、触觉照打、`audioAttempted=false` 触发 UI 露出「静音提醒」
小字。**永远不静音吞错**是白梦林铁律，从 API 形状层杜绝（`clip` 为 nil
或播放器返回 false 都走同一条降级路径）。
