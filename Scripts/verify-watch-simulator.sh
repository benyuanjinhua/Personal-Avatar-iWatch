#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

watch_sim_id="$(
  xcrun simctl list devices -j watchOS 2>/dev/null \
    | /usr/bin/plutil -convert json -o - - \
    | node -e '
        const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
        const all = [];
        for (const [runtime, devices] of Object.entries(data.devices || {})) {
          if (!runtime.includes("watchOS")) continue;
          for (const device of devices) if (device.isAvailable !== false) all.push(device);
        }
        const selected = all.find(device => device.state === "Booted") || all[0];
        if (!selected) process.exit(2);
        process.stdout.write(selected.udid);
      '
)" || {
  echo "ERROR: 没有可用的 watchOS Simulator，无法执行 Watch 模拟器回归。" >&2
  exit 1
}

xcodebuild test \
  -project WristAgent.xcodeproj \
  -scheme "WristAgent Watch App" \
  -destination "id=${watch_sim_id}" \
  -derivedDataPath .build/DerivedData-WatchTest

echo "PASS: Watch 模拟器回归完成（Test Suite 'All tests' passed）。"
