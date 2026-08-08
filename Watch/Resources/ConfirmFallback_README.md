# ConfirmFallback.m4a

ESS-522 本地兜底确认语音。

## 内容

中文女声 TTS："正在处理，请稍候"（约 1.5 秒）。

## 生成方法

```bash
# 用 macOS 内置 say 命令生成 aiff，再转 m4a
say -v Ting-Ting "正在处理，请稍候" -o /tmp/confirm.aiff
afconvert /tmp/confirm.aiff -o ConfirmFallback.m4a -f m4af -d aac
```

## 规格

- 编码：AAC-LC
- 采样率：44.1 kHz
- 声道：单声道
- 时长：约 1.5 秒

## 回退行为

资源缺失时（开发 build 忘记加入 Resources），代码回退为：
- 落 `fallback_audio_missing` 日志（ERR_CONFIRM_FALLBACK_MISSING）
- 播放 `taskAccepted` 触觉（手表贴腕用户至少能感知处理已开始）
- 不卡主流程
