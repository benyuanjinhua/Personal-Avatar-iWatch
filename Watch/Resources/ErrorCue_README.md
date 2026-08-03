# ErrorCue_*.m4a — ESS-180 拟人化错误语音

**当前来源**：Apple 系统 TTS（`say -v Tingting`）临时占位——把主干链路
（错误码 → 卡片 + 语音 + 触觉）跑通所需的最小可用资产。

**待白梦林/内容侧交付**：由 qwen-audio-realtime 按下列文案预生成、随包分发。
生成后就地替换同名 .m4a，文件名与 `ErrorCueCatalog.ClipName` 保持一致，
`ErrorCueCatalogTests` 会校验 Bundle 内文件存在。

| 文件 | 错误码 | 台词 |
|---|---|---|
| `ErrorCue_AudioTooShort.m4a` | `ERR_AUDIO_TOO_SHORT` | 刚才没听清，是不是碰到了？多按一会儿再说一遍。 |
| `ErrorCue_TranscriptDiscarded.m4a` | `ERR_TRANSCRIPT_DISCARDED` | 话有点糊，麻烦离麦近一点再说一次。 |
| `ErrorCue_VoiceBusy.m4a` | `ERR_VOICE_BUSY` | 抱歉，我这边有人正在说话，稍后再叫我一下。 |
| `ErrorCue_RealtimeStalled.m4a` | `ERR_REALTIME_STALLED` / `ERR_REALTIME_NO_EVENTS` / `ERR_REALTIME_TIMEOUT` | 刚才那句我卡了一下，麻烦你再说一次。 |
| `ErrorCue_Generic.m4a` | 兜底 | 刚才没成功，你可以再说一次。 |

**编码**：AAC LC / m4a container / mono / 32kbps（与 WelcomeSpeech 对齐，`afconvert -f m4af -d aac`）。
