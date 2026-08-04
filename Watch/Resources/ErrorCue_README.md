# ErrorCue_*.m4a — ESS-180 拟人化错误语音

**当前来源**：qwen-audio-realtime（DashScope）预生成的真人语气短语音。
生成脚本 `MacRemoteFrontendBridge/generate-error-cues.mjs` 与 WelcomeSpeech
同一条通道（loopback WS `/api/realtime` → PCM audio.delta → AudioPipe AAC）。
由 ESS-180-B 补齐；之前 ESS-180 首轮用 `say -v Tingting` 生成的 macOS TTS
仅为占位，180-A 剥离时已被移除。

## 重新生成

```
# 前置：qwen-audio-agent 网关在 127.0.0.1:3101 运行且 DashScope 已配置。
swift build --package-path AudioPipe -c release
cd MacRemoteFrontendBridge
npm install
node generate-error-cues.mjs \
  ../AudioPipe/.build/arm64-apple-macosx/release/audiopipe \
  ../Watch/Resources
```

改文案 = 改 `generate-error-cues.mjs` 里的 `CUES` + 改 `Shared/ErrorCueCatalog.swift`
的对应文案 + 重新生成。文件名必须与 `ErrorCueCatalog.ClipName`（各条目的 `clip`
字段）一致，`AvatarErrorPresenterTests.testAllBundledClipsExistInAppBundle`
会校验 Bundle 内文件存在且不为空占位。

## 台词与错误码映射

| 文件 | 错误码 | 台词 |
|---|---|---|
| `ErrorCue_AudioTooShort.m4a` | `ERR_AUDIO_TOO_SHORT` | 刚才没听清，是不是碰到了？多按一会儿再说一遍。 |
| `ErrorCue_TranscriptDiscarded.m4a` | `ERR_TRANSCRIPT_DISCARDED` | 话有点糊，麻烦离麦近一点再说一次。 |
| `ErrorCue_VoiceBusy.m4a` | `ERR_VOICE_BUSY` | 抱歉，我这边有人正在说话，稍后再叫我一下。 |
| `ErrorCue_RealtimeStalled.m4a` | `ERR_REALTIME_STALLED` / `ERR_REALTIME_NO_EVENTS` / `ERR_REALTIME_TIMEOUT` | 刚才那句我卡了一下，麻烦你再说一次。 |
| `ErrorCue_Generic.m4a` | 兜底 | 刚才没成功，你可以再说一次。 |

**编码**：AAC-LC / m4a container / mono / 64kbps（AudioPipe `encode` 默认，与
WelcomeSpeech 同链路）；每条 3–5 秒。
