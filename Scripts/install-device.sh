#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."

if [[ ! -d /Applications/Xcode.app ]]; then
  echo "错误：未找到 /Applications/Xcode.app。请先安装完整 Xcode。"
  exit 1
fi

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

if [[ -z "${APPLE_TEAM_ID:-}" ]]; then
  echo "错误：请设置 APPLE_TEAM_ID。"
  echo "可在 Xcode → Settings → Accounts → Team Details 中查看。"
  exit 1
fi

if [[ -z "${IPHONE_UDID:-}" ]]; then
  echo "错误：请设置已与 Apple Watch 配对的 IPHONE_UDID。"
  echo ""
  echo "当前可见设备："
  xcrun devicectl list devices
  exit 1
fi

bundle_id="${WRISTAGENT_BUNDLE_ID:-com.benyuan.wristagent.WristAgent}"
derived_data="${PWD}/DerivedData"
app_path="${derived_data}/Build/Products/Debug-iphoneos/WristAgent.app"

./Scripts/bootstrap.sh

xcodebuild \
  -project WristAgent.xcodeproj \
  -scheme WristAgent \
  -configuration Debug \
  -destination "platform=iOS,id=${IPHONE_UDID}" \
  -derivedDataPath "$derived_data" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  WRISTAGENT_BUNDLE_ID="$bundle_id" \
  build

if [[ ! -d "$app_path" ]]; then
  echo "错误：构建完成，但没有找到 ${app_path}"
  exit 1
fi

xcrun devicectl device install app \
  --device "$IPHONE_UDID" \
  "$app_path"

echo ""
echo "iPhone App 已安装。"
echo "如果 Watch 未自动安装：iPhone → Watch App → 可用 App → 腕语 → 安装。"

