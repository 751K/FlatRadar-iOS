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
# 覆盖是**持久化在设备上的**，跨重启还在（本地那条路末尾专门有一句
# `status_bar clear` 去清它，正说明这一点）。所以设完就**关机**，把设备按它原本
# 的状态交回给 xcodebuild，让它走自己的启动路径——我们只留下一份状态栏配置，
# 不改变别的任何东西。
#
# 这不是在修某个已知故障，是少留一个变量：把一台**正在运行**的模拟器交给
# xcodebuild（它做并行测试时还会克隆，产物文件名里见过 `Clone-2-of-…`）本来就是
# 一种不常见的状态，而 9:41 完全不需要它。
#
# 记一下已经查清的两次失败，免得以后又怀疑到这个脚本头上：
#
#     293  无此脚本      11 分钟，70 张全过
#     295  iPad 全挂     `.sidebarAdaptable` 横屏默认展开侧边栏，tab 不再是
#                        button，截图套件找不到 —— 已由 defaultAdaptableTabBarPlacement 修掉
#     299  iPhone 部分挂 后端在那个时间段不可用。失败录屏里登录页三个统计胶囊是
#                        `0 live` / `-- ago` / `0 new today`，那几个数来自
#                        /api/v1/stats/public/summary —— 全零就是没拿到数据，
#                        App 自然停在登录页
#
# 两次都不是这个脚本引起的。9:41 本身在 295 的产物里已经验证生效。
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
  if xcrun simctl status_bar "$udid" override \
      --time "9:41" \
      --dataNetwork wifi \
      --wifiMode active \
      --wifiBars 3 \
      --cellularMode active \
      --cellularBars 4 \
      --batteryState charged \
      --batteryLevel 100 2>/dev/null; then
    echo "› [status-bar]   已覆盖"
  else
    echo "› [status-bar]   覆盖失败（不影响构建）"
  fi

  # 关机。覆盖留在设备上，xcodebuild 待会按自己的流程重新启动。
  xcrun simctl shutdown "$udid" 2>/dev/null || true
done

exit 0
