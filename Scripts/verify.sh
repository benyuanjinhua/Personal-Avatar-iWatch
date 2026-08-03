#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."

./Scripts/bootstrap.sh
node --test Tools/mock-gateway.test.mjs

for source in Shared/*.swift iOS/*.swift Watch/*.swift Tests/*.swift WatchTests/*.swift; do
  swiftc -frontend -parse "$source"
done

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="${PWD}/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${PWD}/.build/module-cache"

swift test

xcodebuild \
  -project WristAgent.xcodeproj \
  -scheme WristAgent \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedData \
  WRISTAGENT_BUNDLE_ID=com.benyuan.wristagent.verify.WristAgent \
  CODE_SIGNING_ALLOWED=NO \
  build

# ESS-156：watch 模拟器宿主单测——swift test 编不到 Watch target，
# 必须走 xcodebuild test 才是 R-02.1 运行时证据。选一台已 Booted 的
# watchOS Simulator；没有就选任意可用的，让 xcodebuild 自己启动。
watch_sim_id="$(
  xcrun simctl list devices -j watchOS 2>/dev/null \
    | /usr/bin/plutil -convert json -o - - \
    | node -e '
        const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
        const runtimes = data.devices || {};
        const all = [];
        for (const [rt, list] of Object.entries(runtimes)) {
          if (!rt.includes("watchOS")) continue;
          for (const d of list) if (d.isAvailable !== false) all.push(d);
        }
        const booted = all.find(d => d.state === "Booted");
        const pick = booted || all[0];
        if (!pick) { process.exit(2); }
        process.stdout.write(pick.udid);
      '
)"

if [[ -z "${watch_sim_id}" ]]; then
  echo "ERROR: 没有可用的 watchOS Simulator，无法跑 WatchTests。" >&2
  exit 1
fi

xcodebuild test \
  -project WristAgent.xcodeproj \
  -scheme "WristAgent Watch App" \
  -destination "id=${watch_sim_id}" \
  -derivedDataPath .build/DerivedData-WatchTest

echo "WristAgent 验证完成。"
