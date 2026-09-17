#!/usr/bin/env bash
#
# FlatRadar for Mac 截图自动化（本地跑）。
#
# 用法
# ----
#   ./tools/screenshots/run-mac.sh
#
# 输出到 ~/Desktop/flatradar-screenshots/mac/en-US/
#
# 和 iOS 那条（run.sh）差在哪
# ---------------------------
# 1. **没有模拟器。** 也就没有 `simctl status_bar`——iOS 那边把时钟锁成 9:41 的
#    整套在这里不存在，也不需要：截图只拍**窗口**，菜单栏和那个真实时钟不进画面。
# 2. **不用挑设备。** destination 就是这台 Mac。
# 3. **要辅助功能权限。** 见下面那段。
#
# ⚠️ 第一次跑之前要授权
# --------------------
# macOS 的 UI Test 要靠辅助功能（Accessibility）驱动被测 App。没授权时报的是
#
#     Failed to initialize for UI testing:
#     Timed out while enabling automation mode.
#
# ——它**不说**是权限问题，只说超时，所以很容易往别处查。授权路径：
#
#     系统设置 → 隐私与安全性 → 辅助功能
#     → 把「跑 xcodebuild 的那个程序」加进去并打开
#
# 「那个程序」指的是终端本身（Terminal / iTerm），不是 Xcode——权限跟的是**发起
# 测试的进程**。在 Xcode 里按 ⌘U 跑时要授权的才是 Xcode。
#
# Xcode Cloud 上不需要做这一步，构建机是预授权的。
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
XCODEPROJ="$PROJECT_ROOT/FlatRadar.xcodeproj"
OUT_DIR="$HOME/Desktop/flatradar-screenshots/mac/en-US"
RESULT_BUNDLE="/tmp/flatradar-mac-shots.xcresult"

# Xcode 装在外置盘上，而 xcode-select 指向 CommandLineTools。
# 不 export 这个的话 xcodebuild 会用到一个没有 iOS/macOS 平台的工具链。
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Volumes/MacoutDsik/Applications/Xcode.app/Contents/Developer}"

echo "═══ FlatRadar Mac 截图 ═══"
echo "  plan   = MacScreenshots"
echo "  output = $OUT_DIR"
echo

rm -rf "$RESULT_BUNDLE"
xcodebuild test \
  -project "$XCODEPROJ" \
  -scheme FlatRadarMac \
  -testPlan MacScreenshots \
  -destination 'platform=macOS,arch=arm64' \
  -resultBundlePath "$RESULT_BUNDLE" \
  2>&1 | grep -E "Test (Case|Suite)|passed|failed|error:|拍出来|automation mode" || true

command -v xcparse > /dev/null || {
  echo "❌ 需要 xcparse: brew tap chargepoint/xcparse && brew install xcparse"
  exit 1
}

mkdir -p "$OUT_DIR"
echo "› 提取截图到 $OUT_DIR…"
xcparse screenshots "$RESULT_BUNDLE" "$OUT_DIR" 2>&1 | tail -3

# 文件名清理：附件名已经是 `01-Listings`，xcparse 会在后面缀上 runner/UUID。
cd "$OUT_DIR"
for f in *.png; do
  [ -e "$f" ] || continue
  new=$(echo "$f" | sed -E 's/^([0-9]+-[A-Za-z]+)_.*$/\1.png/')
  [ "$new" != "$f" ] && mv -f "$f" "$new"
done
cd - > /dev/null

echo
echo "✓ 完成。尺寸核对（ASC 只收 1280×800 / 1440×900 / 2560×1600 / 2880×1800）："
for f in "$OUT_DIR"/*.png; do
  [ -e "$f" ] || continue
  printf "  %-20s %s\n" "$(basename "$f")" \
    "$(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixel/ {printf "%s ", $2}')"
done
