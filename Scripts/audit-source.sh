#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."

echo "检查 Gateway 协议测试…"
node --test Tools/mock-gateway.test.mjs

echo "检查 Swift 语法…"
for source in Shared/*.swift iOS/*.swift Watch/*.swift Tests/*.swift WatchTests/*.swift; do
  swiftc -frontend -parse "$source"
done

echo "检查 Plist 与 Asset Catalog…"
plutil -lint \
  iOS/Info.plist \
  iOS/WristAgent.entitlements \
  Watch/Info.plist \
  Watch/WristAgentWatch.entitlements \
  iOS/Assets.xcassets/AppIcon.appiconset/Contents.json \
  Watch/Assets.xcassets/AppIcon.appiconset/Contents.json >/dev/null

required_icons=(48 55 58 80 87 88 92 100 102 108 172 196 216 234 258 1024)
for size in "${required_icons[@]}"; do
  icon="Watch/Assets.xcassets/AppIcon.appiconset/AppIcon-${size}.png"
  [[ -f "$icon" ]] || { echo "缺少图标：$icon"; exit 1; }
  actual="$(sips -g pixelWidth "$icon" 2>/dev/null | awk '/pixelWidth/ { print $2 }')"
  [[ "$actual" == "$size" ]] || { echo "图标尺寸错误：$icon"; exit 1; }
done

ios_icon="iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
[[ "$(sips -g hasAlpha "$ios_icon" 2>/dev/null | awk '/hasAlpha/ { print $2 }')" == "no" ]]

echo "重新生成并检查 Xcode 工程…"
xcodegen generate >/dev/null
rg -q 'SDKROOT = watchos;' WristAgent.xcodeproj/project.pbxproj
rg -q 'Embed Watch Content' WristAgent.xcodeproj/project.pbxproj
rg -q 'NSMicrophoneUsageDescription' Watch/Info.plist
rg -q 'WKCompanionAppBundleIdentifier' Watch/Info.plist

echo "源码审计通过。"

