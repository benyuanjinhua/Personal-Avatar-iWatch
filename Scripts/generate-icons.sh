#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."

source_svg="Brand/AppIcon.svg"
ios_dir="iOS/Assets.xcassets/AppIcon.appiconset"
watch_dir="Watch/Assets.xcassets/AppIcon.appiconset"
master_png="${TMPDIR:-/tmp}/wristagent-appicon-1024.png"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

if [[ ! -x "$chrome" ]]; then
  echo "错误：生成图标需要 Google Chrome 渲染 SVG 母版。"
  exit 1
fi

"$chrome" \
  --headless \
  --disable-gpu \
  --hide-scrollbars \
  --force-device-scale-factor=1 \
  --window-size=1024,1024 \
  --screenshot="$master_png" \
  "file://${PWD}/${source_svg}" >/dev/null 2>&1

sips -z 1024 1024 "$master_png" --out "$ios_dir/AppIcon-1024.png" >/dev/null
sips -z 1024 1024 "$master_png" --out "$watch_dir/AppIcon-1024.png" >/dev/null

for size in 48 55 58 80 87 88 92 100 102 108 172 196 216 234 258; do
  sips -z "$size" "$size" "$master_png" --out "$watch_dir/AppIcon-${size}.png" >/dev/null
done

echo "已生成 iOS 与 watchOS AppIcon。"
