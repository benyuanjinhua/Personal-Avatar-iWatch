#!/usr/bin/env bash
#
# ESS-1172: 采集 xcodebuild test 的取证材料，供「测试宿主进程概率性死亡」这类
# 形态定性用。
#
# 背景（ESS-1170 / CI run #570）：watchOS 测试宿主在某个用例执行中途死亡、xctest
# 重启宿主后从下一个用例继续，死掉的用例既无 passed 也无 failed 行。要把机理从
# 「嫌疑」抬到「根因」需要崩溃栈帧，而 CI 当时只上传了 xcodebuild 的纯文本日志，
# xcresult 与 DiagnosticReports 都没采，取证到此为止。
#
# 本脚本采三类材料：
#   1. xcresult bundle（打成 tar.gz，bundle 是目录，逐文件上传既慢又易被
#      artifact 的路径归一化改形）+ 就地解析出的 summary / tests JSON，
#      让 artifact 不下整包也能一眼看出「哪个用例没有结果」。
#   2. DiagnosticReports（用户级 + 系统级 + Retired/）：宿主进程若是崩溃，
#      报告落在这里；若是挂起被看门狗回收，这里就没有报告——**「采了、是空的」
#      本身就是一条判据**，所以即使为空也必须留下 MANIFEST 证明采过。
#   3. CoreSimulator 每设备 system.log：jetsam / watchdog 回收的记录在这里，
#      是区分「崩溃」与「挂起被回收」的另一半证据。
#
# 采集永远不能把一次绿的运行判红、也不能掩盖真实的测试失败：脚本内部不使用
# `set -e`，任何采集失败都降级成 ::warning:: 并记进 MANIFEST，退出码恒为 0。
#
# 用法: Scripts/collect-test-diagnostics.sh <label> <derived-data-path> <out-dir>
#   label             材料归属标签（watch / ios），只用于日志与 MANIFEST
#   derived-data-path xcodebuild 的 -derivedDataPath（xcresult 在其 Logs/Test/ 下）
#   out-dir           采集产物输出目录，由调用方交给 upload-artifact

set -uo pipefail

label="${1:?usage: collect-test-diagnostics.sh <label> <derived-data-path> <out-dir>}"
derived_data="${2:?usage: collect-test-diagnostics.sh <label> <derived-data-path> <out-dir>}"
out_dir="${3:?usage: collect-test-diagnostics.sh <label> <derived-data-path> <out-dir>}"

mkdir -p "$out_dir" || exit 0
manifest="$out_dir/MANIFEST.txt"
: > "$manifest"

note() { echo "$*" | tee -a "$manifest"; }
warn() { echo "::warning::collect-test-diagnostics($label): $*"; echo "WARN: $*" >> "$manifest"; }

note "# test diagnostics — label=$label"
note "collected_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
note "host: $(hostname)"
note "derived_data: $derived_data"
note "xcresulttool: $(xcrun xcresulttool --version 2>&1 | head -1)"
note ""

# ---------------------------------------------------------------- 1. xcresult
note "## xcresult"
xcresult_dir="$out_dir/xcresult"
mkdir -p "$xcresult_dir"

# 一次 xcodebuild test 只写一个 xcresult，但 -derivedDataPath 被复用时 Logs/Test/
# 下会累积多个；取 mtime 最新的那个，即本次运行的结果。
latest_xcresult=""
if [ -d "$derived_data/Logs/Test" ]; then
  latest_xcresult=$(
    /usr/bin/find "$derived_data/Logs/Test" -maxdepth 1 -name '*.xcresult' -print0 2>/dev/null \
      | xargs -0 -r stat -f '%m %N' 2>/dev/null \
      | sort -rn | head -1 | cut -d' ' -f2-
  )
fi

if [ -z "$latest_xcresult" ]; then
  warn "no .xcresult found under $derived_data/Logs/Test — xcodebuild 可能在写结果前就死了"
  note "xcresult: (none)"
else
  note "xcresult: $latest_xcresult"
  note "xcresult_size: $(du -sh "$latest_xcresult" 2>/dev/null | cut -f1)"

  # 就地解析：即使 reviewer 不下载整包，也能从 artifact 里直接看到结构化结果。
  # 新版子命令（Xcode 16+）优先，失败再退回 --legacy，避免 runner 上的 Xcode
  # 版本漂移让取证整条断掉。
  if ! xcrun xcresulttool get test-results summary --path "$latest_xcresult" \
        > "$xcresult_dir/test-results-summary.json" 2> "$xcresult_dir/test-results-summary.err"; then
    warn "xcresulttool get test-results summary failed; falling back to --legacy"
    xcrun xcresulttool get --legacy --format json --path "$latest_xcresult" \
      > "$xcresult_dir/test-results-legacy.json" 2>> "$xcresult_dir/test-results-summary.err" \
      || warn "legacy xcresulttool get also failed (see test-results-summary.err)"
  fi
  xcrun xcresulttool get test-results tests --path "$latest_xcresult" \
    > "$xcresult_dir/test-results-tests.json" 2> "$xcresult_dir/test-results-tests.err" \
    || warn "xcresulttool get test-results tests failed (see test-results-tests.err)"

  # bundle 本身：打包上传，保持目录结构与文件名完整，下载后可直接 xcresulttool。
  bundle_parent=$(dirname "$latest_xcresult")
  bundle_name=$(basename "$latest_xcresult")
  tarball="$xcresult_dir/${label}.xcresult.tar.gz"
  if tar -czf "$tarball" -C "$bundle_parent" "$bundle_name" 2>> "$manifest"; then
    note "xcresult_tarball: $(basename "$tarball") ($(du -h "$tarball" 2>/dev/null | cut -f1))"
    tarball_bytes=$(stat -f '%z' "$tarball" 2>/dev/null || echo 0)
    # artifact 体积软上限：超了照样上传（证据比配额重要），但留个显式警告，
    # 免得某天保留期 × 体积悄悄吃掉仓库配额。
    if [ "$tarball_bytes" -gt 524288000 ]; then
      warn "xcresult tarball > 500MB ($tarball_bytes bytes) — 留意 artifact 配额与保留期"
    fi
  else
    warn "tar of $bundle_name failed"
  fi
fi
note ""

# ------------------------------------------------------- 2. DiagnosticReports
# 宿主进程崩溃 → 这里有 .ips/.crash（含 signal 与栈帧）；挂起被回收 → 这里为空。
# 两种结果都是判据，所以本节永远写计数，0 也要写出来。
note "## DiagnosticReports"
reports_dir="$out_dir/DiagnosticReports"
mkdir -p "$reports_dir"

collect_reports() {
  local src="$1" name="$2" dest count
  dest="$reports_dir/$name"
  mkdir -p "$dest"
  if [ ! -d "$src" ]; then
    note "  $name: source '$src' does not exist"
    return
  fi
  # Retired/ 也收：轮转过的报告同样有栈帧。
  /usr/bin/find "$src" -type f \
    \( -name '*.ips' -o -name '*.crash' -o -name '*.diag' -o -name '*.hang' -o -name '*.spin' -o -name '*.wakeups_resource.ips' \) \
    -exec cp -p {} "$dest/" \; 2>/dev/null
  count=$(/usr/bin/find "$dest" -type f | wc -l | tr -d ' ')
  note "  $name: $count file(s) collected from $src"
  if [ "$count" -gt 0 ]; then
    /usr/bin/find "$dest" -type f -exec basename {} \; | sort | sed 's/^/    - /' >> "$manifest"
  fi
}

collect_reports "$HOME/Library/Logs/DiagnosticReports" "user"
collect_reports "/Library/Logs/DiagnosticReports" "system"
total_reports=$(/usr/bin/find "$reports_dir" -type f | wc -l | tr -d ' ')
note "diagnostic_reports_total: $total_reports"
note "note: 0 份报告不等于没采——本节存在即证明采集执行过；宿主若是挂起被看门狗"
note "      回收（而非崩溃），本来就不会有报告，这条本身就是判据。"
# artifact 里保留一个空目录会被 upload-artifact 丢掉，放个占位文件保住「采了是空的」这条证据。
if [ "$total_reports" -eq 0 ]; then
  echo "no crash/diagnostic reports were present at $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$reports_dir/EMPTY.txt"
fi
note ""

# ---------------------------------------------------------- 3. CoreSimulator
# 每设备 system.log 里有 SpringBoard/launchd 对被测宿主的 jetsam / watchdog 记录。
note "## CoreSimulator device logs"
sim_dir="$out_dir/CoreSimulator"
mkdir -p "$sim_dir"
sim_log_count=0
if [ -d "$HOME/Library/Logs/CoreSimulator" ]; then
  while IFS= read -r log; do
    [ -n "$log" ] || continue
    udid=$(basename "$(dirname "$log")")
    # 只留尾部 20000 行：整份 system.log 可到数百 MB，而回收事件必然在末尾。
    tail -n 20000 "$log" | gzip -c > "$sim_dir/${udid}.system.log.gz" 2>/dev/null \
      && sim_log_count=$((sim_log_count + 1))
  done < <(/usr/bin/find "$HOME/Library/Logs/CoreSimulator" -maxdepth 2 -name 'system.log' -type f 2>/dev/null)
  if [ -f "$HOME/Library/Logs/CoreSimulator/CoreSimulator.log" ]; then
    tail -n 20000 "$HOME/Library/Logs/CoreSimulator/CoreSimulator.log" | gzip -c \
      > "$sim_dir/CoreSimulator.log.gz" 2>/dev/null
  fi
else
  note "  $HOME/Library/Logs/CoreSimulator does not exist"
fi
note "simulator_device_logs: $sim_log_count"
if [ "$sim_log_count" -eq 0 ] && [ ! -f "$sim_dir/CoreSimulator.log.gz" ]; then
  echo "no CoreSimulator logs were present at $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$sim_dir/EMPTY.txt"
fi
note ""

note "## collected tree"
(cd "$out_dir" && /usr/bin/find . -type f | sort | sed 's/^/  /') >> "$manifest"
note "total_size: $(du -sh "$out_dir" 2>/dev/null | cut -f1)"

exit 0
