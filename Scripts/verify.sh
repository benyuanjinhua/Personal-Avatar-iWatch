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

# ESS-536：开发与 PR 复审复用独立的 Watch 模拟器门禁。
./Scripts/verify-watch-simulator.sh

echo "WristAgent 验证完成。"
