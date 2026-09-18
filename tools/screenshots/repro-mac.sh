#!/usr/bin/env bash
#
# 在本机按**构建机的窗口尺寸**跑一次 Mac 截图模式，看某一屏会不会崩。
#
# 用法
# ----
#   ./tools/screenshots/repro-mac.sh <section> [lang] [locale] [WxH] [秒数]
#   ./tools/screenshots/repro-mac.sh listings zh-Hans zh_CN 1280x800
#
# 先编一次 Debug（`xcodebuild build -scheme FlatRadarMac -destination 'platform=macOS'`），
# 本脚本不编译。崩了退出码 1 并打印异常原因，活过 [秒数]（默认 15）退出码 0。
#
# 为什么要有它
# ------------
# Xcode Cloud 的 Mac 截图构建机是 1280×800 点。开发机的屏大，截图模式按规则会挑
# 1440×900，于是「只在 1280 宽下才出现」的布局问题在本地永远看不见，只能推上去
# 等一轮十五分钟。2026-09-18 列表页顶部统计带的最小宽度（约 904 点）超过了 1280
# 窗口里内容区能给的宽度，分栏视图反复改最小尺寸直到 AppKit 抛异常杀进程——
# 本脚本十几秒就能复现，然后逐块关掉界面二分出是哪一块。
#
# 为什么要复制一份、改 bundle id、重签名
# ------------------------------------
# 截图模式会**写持久偏好**（关掉菜单栏常驻、外观改回跟随系统），没给账号时还会
# 切到游客身份。和开发者自己装的正式版同一个 bundle id 的话，偏好和钥匙串是
# 同一份：跑一次就改掉你的设置，甚至把你登出。所以：
#
#   - bundle id 改成 `….l10nrepro`，偏好容器和钥匙串都是独立的一份；
#   - 删掉内嵌的小组件扩展（它的 bundle id 前缀对不上新 id，签名会拒）；
#   - ad-hoc 重签，entitlements 只留沙盒和网络——不带钥匙串组、推送、关联域。
set -euo pipefail

SECTION="${1:?用法: repro-mac.sh <section> [lang] [locale] [WxH] [秒数]}"
LANG_CODE="${2:-en}"
LOCALE="${3:-en_US}"
SIZE="${4:-1280x800}"
SECONDS_ALIVE="${5:-15}"

SRC="/Volumes/MacoutDsik/Xcode/Product/Debug/FlatRadarMac.app"
WORK="/Volumes/MacoutDsik/tmp/repro"
APP="$WORK/FlatRadarRepro.app"

[ -d "$SRC" ] || { echo "找不到 $SRC，先编一次 Debug"; exit 2; }

mkdir -p "$WORK"
if [ ! -d "$APP" ] || [ "$SRC/Contents/MacOS/FlatRadarMac" -nt "$APP/Contents/MacOS/FlatRadarMac" ]; then
    rm -rf "$APP"
    cp -R "$SRC" "$APP"
    plutil -replace CFBundleIdentifier -string com.j.kong.FlatRadar.l10nrepro "$APP/Contents/Info.plist"
    rm -rf "$APP/Contents/PlugIns" "$APP/Contents/Extensions"
    cat > "$WORK/min.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.network.client</key><true/>
</dict></plist>
EOF
    codesign --force --deep --sign - --entitlements "$WORK/min.entitlements" "$APP" >/dev/null 2>&1
fi

LOG="$WORK/$SECTION-$LANG_CODE-$SIZE.log"
set +e
# macOS 没有 timeout；perl 的 alarm 到点发 SIGALRM，退出码 142 = 活到了最后。
perl -e "alarm $SECONDS_ALIVE; exec @ARGV" "$APP/Contents/MacOS/FlatRadarMac" \
    -ApplePersistenceIgnoreState YES \
    -UI_TEST_SCREENSHOT_MODE 1 \
    -UI_TEST_SECTION "$SECTION" \
    -AppleLanguages "($LANG_CODE)" \
    -AppleLocale "$LOCALE" \
    -UI_TEST_WINDOW_SIZE "$SIZE" >"$LOG" 2>&1
CODE=$?
set -e

if [ "$CODE" -eq 142 ]; then
    echo "✓ $SECTION $LANG_CODE $SIZE：活过 ${SECONDS_ALIVE}s"
    exit 0
fi
echo "✗ $SECTION $LANG_CODE $SIZE：退出码 $CODE"
grep -m1 "reason:" "$LOG" | cut -c1-400 || true
echo "  完整输出：$LOG"
exit 1
