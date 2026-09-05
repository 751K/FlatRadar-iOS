#!/usr/bin/env bash
#
# Xcode Cloud：跑 xcodebuild 之前，把截图要用的模拟器**先启动起来并覆盖状态栏**
# （9:41 + 满信号 + 满电，Apple 营销截图的标准样式）。
#
# 为什么要在这里做
# ----------------
# `xcrun simctl status_bar override` 只能作用在**已启动**的设备上，而 Xcode Cloud
# 的 TEST action 是自己启动模拟器的——等它启动完，我们已经没有插手的时机了
# （ci_post_xcodebuild 跑的时候截图早就拍完了）。所以只能反过来：我们先把设备
# 启动好、设好状态栏，让随后的 xcodebuild 复用这台已经在跑的设备。
#
# 本地那条路（tools/screenshots/run.sh）一直是这么做的，只是它自己管启动；
# 云端这份把同样的事挪到 xcodebuild 之前。
#
# ⚠️ 尚未验证：xcodebuild 做并行测试时会**克隆**模拟器（产物文件名里见过
# `Clone-2-of-…` 前缀，extract_screenshots.py 的注释里记着），而克隆出来的设备
# 会不会继承状态栏覆盖，我没有证据。第一次跑完看截图上的时间就知道了：
# 是 9:41 就成了，还是真实时间就说明这条路不通，得换成导出后再处理图片。
#
# 这个脚本**绝不能让构建失败**：状态栏好不好看是锦上添花，为它挂掉整条流水线
# 是本末倒置。所以每一步都吞掉错误，最后无条件 exit 0。
set -u

# 设备名要和 ASC 里 Screenshot workflow 的 testDestinations 一致。
# 那份配置在 App Store Connect 上，不在仓库里，所以这里只能抄一份——改那边的
# 时候记得回来改这里，不然状态栏覆盖会静默地打在没人用的设备上。
DEVICES=(
  "iPhone 17 Pro Max"
  "iPad Pro 13-inch (M5) (16GB)"
)

echo "› [status-bar] 准备覆盖状态栏 9:41"

for name in "${DEVICES[@]}"; do
  udid=$(xcrun simctl list devices available -j 2>/dev/null | python3 -c "
import json, sys
want = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for runtime, devices in data.get('devices', {}).items():
    for d in devices:
        if d.get('name') == want and d.get('isAvailable'):
            print(d['udid'])
            sys.exit(0)
" "$name")

  if [ -z "${udid:-}" ]; then
    echo "› [status-bar] 找不到「$name」，跳过"
    continue
  fi

  echo "› [status-bar] $name ($udid)"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  xcrun simctl status_bar "$udid" override \
    --time "9:41" \
    --dataNetwork wifi \
    --wifiMode active \
    --wifiBars 3 \
    --cellularMode active \
    --cellularBars 4 \
    --batteryState charged \
    --batteryLevel 100 2>/dev/null \
    && echo "› [status-bar]   已覆盖" \
    || echo "› [status-bar]   覆盖失败（不影响构建）"
done

exit 0
