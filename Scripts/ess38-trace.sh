#!/bin/bash
# ESS-38 四段取证 · Bridge 段（真机验收辅助）。
#
# 用法:
#   Scripts/ess38-trace.sh <bridge-log.jsonl> <request_id> [bridge-dir]
#
# 输出同一 request_id 的：
#   1) Bridge 事件链摘要（turn_accepted → realtime → announcement_bound →
#      result_audio_attached / 各类失败事件），只含时间戳/事件名/字节数，不含音频内容；
#   2) 关键节点计数（缺哪个节点 = 断点在哪一段之前）；
#   3) 语音产物核验：state/result-audio/<request_id>.m4a 存在性、大小、sha256、
#      afinfo 解码结果（时长/编码格式）。
#
# iPhone / Watch 段取证（另两段）在真机 Console.app / log 里过滤：
#   iPhone: subsystem com.benyuan.wristagent  category relay/downlink
#   Watch : subsystem com.benyuan.wristagent.watch  category SpeechIngest / SpeechPlayer
set -euo pipefail

LOG="${1:?用法: ess38-trace.sh <bridge-log.jsonl> <request_id> [bridge-dir]}"
RID="${2:?缺少 request_id}"
DIR="${3:-MacRemoteFrontendBridge}"

echo "== 1) Bridge 事件链 (request_id=$RID) =="
grep -F "\"$RID\"" "$LOG" | python3 -c '
import json, sys
for line in sys.stdin:
    try:
        o = json.loads(line)
    except ValueError:
        continue
    keep = {k: v for k, v in o.items() if k in (
        "ts", "evt", "event", "detail", "state", "bytes", "pcm_bytes", "m4a_bytes",
        "size_bytes", "duration_ms", "task_id", "response_id", "err", "code")}
    print(" ".join(f"{k}={v}" for k, v in keep.items()))
'

echo
echo "== 2) 关键节点 =="
for evt in turn_accepted announcement_bound result_audio_attached \
           announcement_unmatched announcement_encode_failed encode_failed \
           turn_failed work_timeout_realtime; do
  n=$(grep -F "\"$RID\"" "$LOG" | grep -c "\"evt\":\"$evt\"" || true)
  printf '  %-28s %s\n' "$evt" "$n"
done

echo
echo "== 3) 语音产物 =="
FILE="$DIR/state/result-audio/$RID.m4a"
if [[ -f "$FILE" && -s "$FILE" ]]; then
  printf '  文件: %s\n  大小: %s bytes\n  sha256: %s\n' \
    "$FILE" "$(stat -f %z "$FILE")" "$(shasum -a 256 "$FILE" | cut -d' ' -f1)"
  if command -v afinfo >/dev/null; then
    afinfo "$FILE" 2>/dev/null | grep -Ei "duration|format|bit rate|data format" | sed 's/^/  /'
  else
    echo "  (afinfo 不可用，跳过解码核验)"
  fi
else
  echo "  !! 缺少语音产物 $FILE —— 断点在 Bridge 聚合/转码段（见上方节点计数）"
fi
