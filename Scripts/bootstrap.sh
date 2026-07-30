#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."

if [[ ! -d /Applications/Xcode.app ]]; then
  echo "错误：未找到 /Applications/Xcode.app。请先从 App Store 安装完整 Xcode。"
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "错误：未安装 XcodeGen。请执行：brew install xcodegen"
  exit 1
fi

xcodegen generate
echo "已生成：${PWD}/WristAgent.xcodeproj"
