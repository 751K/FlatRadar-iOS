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

# macOS 那条 workflow 不需要模拟器。build 350/353 上它照样把两台 iOS 模拟器
# 启动了一遍再关掉，纯浪费——现在有实测值了（日志里 CI_PRODUCT_PLATFORM='macOS'），
# 可以安全地跳过。
#
# 只认 'macOS' 这一个值就跳过，其余情况（包括变量为空）一律照跑——iOS 那套
# 现在是好的，不能因为读不到变量就把 9:41 弄丢。
if [ "${CI_PRODUCT_PLATFORM:-}" = "macOS" ]; then
  echo "› [status-bar] 平台是 macOS，不需要模拟器，跳过"
else

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

fi

# ─────────────────────────────────────────────────────────────────────────────
# macOS 测试构建：把**需要描述文件授权**的 entitlement 剥掉。
#
# 为什么必须剥
# ------------
# Xcode Cloud 的 TEST action **一律 ad-hoc 签名**，日志里是
#
#     Signing Identity: "Sign to Run Locally"
#     /usr/bin/codesign --force --sign - --entitlements ... FlatRadarMac.app
#
# `--sign -` 没有描述文件，签出来的包 `TeamIdentifier=not set`。而这三个
# entitlement 只能由描述文件授权：
#
#     com.apple.developer.aps-environment      APNs
#     com.apple.developer.associated-domains   Universal Link
#     keychain-access-groups                   application-identifier（data protection 钥匙串）
#
# 带着它们又没有描述文件，macOS 直接拒绝 spawn。build 380 的六条用例全挂在
# `app.launch()` 上，报的是：
#
#     Could not launch "FlatRadarMac". Runningboard has returned error 5.
#     Domain: RBSRequestErrorDomain Code: 5 / Launchd job spawn failed
#
# 错误信息里一个字都没提签名或 entitlement，所以这里写清楚，省得下次再查一遍。
# （归档那条路不受影响：`Mac Build` 用的是真描述文件，走的也不是这个分支。）
#
# 剥掉之后截图还成不成立
# ----------------------
# 成立。三项在截图里都用不到：
#
#   - APNs：`PushStore` 第 167 行见到 `UI_TEST_SCREENSHOT_MODE` 就直接 return，
#     截图模式本来就不注册推送，也正因此不会弹权限框毁图。
#   - Universal Link：截图不点链接。
#   - 钥匙串：`AuthStore.persist(token:)` 把保存失败 catch 掉了，只置
#     `sessionSavedToKeychain = false`。登录靠的是内存里的 `client.setToken` +
#     `getMe()`，不经钥匙串。而且每条用例都冷启动重新登录，本来就不需要跨启动
#     恢复会话。
#
# 为什么按 action 而不是按 workflow 名
# -----------------------------------
# 名字会被人改，`build-for-testing` 不会——归档永远不是这个 action。变量取不到
# 时**不剥**（归档保持完整 entitlement 是更安全的那一侧），并把实际值打出来，
# 让下一轮日志自己说明为什么没走进来。
#
# 只动 FlatRadarMac 那一份。iOS 截图那条 workflow 的 action 同样是
# build-for-testing，但它不构建 Mac app，改这个文件对它没有任何影响；iOS 的
# entitlement 一个字都不能动——模拟器上那套现在是好的。
# ─────────────────────────────────────────────────────────────────────────────

# 这个脚本**每个 xcodebuild action 都会跑一遍**——一次 TEST action 会跑两趟：
# build-for-testing，然后 test-without-building。而 `CI_PRIMARY_REPOSITORY_PATH`
# 只在第一趟有定义，第二趟是空的：build 353 就是这么挂的，
#
#     ci_pre_xcodebuild.sh: line 141: CI_PRIMARY_REPOSITORY_PATH: unbound variable
#
# （脚本开头 `set -u`）。第一趟其实已经剥干净了，第二趟纯属白跑——那时 app 早就
# 构建并签好名了，改源文件毫无作用。所以只认 build-for-testing 这一趟，
# 而且每个 CI_ 变量都带 `:-` 默认值，不让 set -u 再有机会。
# ─────────────────────────────────────────────────────────────────────────────
# 别让构建机锁屏。
#
# build 371 六条用例全挂在 `Failed to activate application (current state:
# Running Background)`。屏幕录像里是**登录锁屏**——"local / Enter Password"。
# 锁了之后没有可用的 GUI 会话，任何 app 都激活不了，跟被测代码毫无关系。
#
# 这不是偶发：build 369 的日志里 Xcode 自己就报过
#
#     IDETestOperationsObserverDebug: Failed to suppress screen saver
#     (SACSetScreenSaverCanRun returned 22)
#
# 也就是说 Xcode 内置的那套抑制机制在这台机器上是失效的，得我们自己来。
#
# 370 之所以没事，是因为它只跑了三分钟（那一轮 5/6 过，没有 60 秒超时）；
# 371 跑了十四分钟就撞上了。也就是说**跑得越慢越容易锁**，而跑得慢往往正是因为
# 有别的失败在超时——于是一个小问题会被锁屏放大成整轮全红，掩盖真正的原因。
#
# 两条一起上：
#   - `defaults` 把屏保空闲时间设成 0（不需要 sudo，当前用户域就够）；
#   - `caffeinate` 兜底，`-d` 阻止显示器睡眠、`-i` 阻止系统空闲睡眠、`-u` 声明
#     用户活跃。`nohup` + `&` 让它活过这个脚本；一小时后自己退出，不会赖在机器上。
echo "› [awake] 防锁屏"

# 先报告上一次留下的还活着没有——这一条是诊断，不是摆设。
#
# build 375 的日志里 caffeinate 明明起来了（pid=3795），屏幕照样锁了，录像里是
# "local / Enter Password"。所以问题不是"没启动"，而是**启动了没活下来**：
# `nohup` 挡得住 SIGHUP，挡不住 Xcode Cloud 在脚本退出时清理整个进程组。
#
# 下一轮看这一行就知道改法成没成。
if pgrep -x caffeinate > /dev/null 2>&1; then
  echo "› [awake]   已有 caffeinate 在跑：$(pgrep -x caffeinate | tr '\n' ' ')"
else
  echo "› [awake]   没有存活的 caffeinate"
fi

defaults -currentHost write com.apple.screensaver idleTime -int 0 2>/dev/null || true
defaults write com.apple.screensaver askForPassword -int 0 2>/dev/null || true

# 交给 launchd 托管，而不是当这个脚本的子进程。
#
# `launchctl submit` 把它注册成一个 launchd 作业，进程组被清理时不受影响。
# 先 remove 一次，免得第二趟因为同名作业已存在而失败。
launchctl remove flatradar.keepawake 2>/dev/null || true
if launchctl submit -l flatradar.keepawake -- /usr/bin/caffeinate -dimsu -t 5400 2>/dev/null; then
  echo "› [awake]   launchctl submit 成功"
else
  echo "› [awake]   launchctl submit 失败，退回 nohup（可能活不过脚本）"
  nohup caffeinate -dimsu -t 5400 >/dev/null 2>&1 &
fi

# 再补一刀：直接把屏保引擎停掉。锁屏是 loginwindow 干的，killall 让它重置计时。
killall ScreenSaverEngine 2>/dev/null || true

REPO_PATH="${CI_PRIMARY_REPOSITORY_PATH:-}"
XCB_ACTION="${CI_XCODEBUILD_ACTION:-}"

# ─────────────────────────────────────────────────────────────────────────────
# 把构建机的分辨率调大。
#
# 这台 `VirtualMac2,1` 默认 1280×800 点，而 ASC 最小的合法截图尺寸在 2x 下
# **正好**也是 1280×800 点——菜单栏 30 + Dock 78 占掉之后窗口只剩 1280×692，
# 差出来的 108 点在合成时补成白边（build 372 那六张图上下各 108 像素的白边就是它）。
#
# 屏幕够大的话窗口就能拿到首选的 1440×900 点，合成时画布正好等于图，零留白、
# 零重采样——本地那块 2560 点宽的屏正是这样。
#
# 工具默认只列模式、不改任何东西（在开发机上误改分辨率很讨厌），这里显式给
# `--apply`。挑不到够大的模式就保持现状，只把模式表打进日志，下一轮据此再判断。
# 整段失败都不影响构建。
# 分两趟：`build-for-testing` 时编译，两趟都执行。
#
# 必须这样，因为 `CI_PRIMARY_REPOSITORY_PATH` **只在第一趟有定义**（build 353
# 就是栽在这上面），而 app 真正运行、分辨率真正需要生效的是**第二趟**
# （test-without-building）。所以第一趟把工具编译到 /tmp 留着——两趟跑在同一台
# 机器上，第二趟直接用那个二进制。
# 藏 Dock。
#
# 白边是菜单栏 30 点 + Dock 78 点占掉、窗口拿不到的那部分（build 372 的图上下各
# 108 像素）。分辨率那条路走不通（见 mac-display-mode.swift 里的实测结论），
# 能收的就是 Dock 这 78 点：可用高度 692 → 约 766，白边从 108 缩到约 34 像素。
#
# `autohide-delay` 设很大，免得指针恰好扫过屏幕底边时 Dock 探头进画面——截图那
# 一刻指针已经被 hover 到窗口中央了，但多一道保险不费什么。
#
# 菜单栏那 30 点不碰：`_HIHideMenuBar` 要重新登录才生效，在一次性构建机上不可靠。
if [ "${CI_PRODUCT_PLATFORM:-}" = "macOS" ]; then
  echo "› [dock] 隐藏 Dock"
  defaults write com.apple.dock autohide -bool true 2>/dev/null || true
  defaults write com.apple.dock autohide-delay -float 1000 2>/dev/null || true
  killall Dock 2>/dev/null || true
fi

DISPLAY_BIN=/tmp/mac-display-mode
if [ "${CI_PRODUCT_PLATFORM:-}" = "macOS" ]; then
  if [ ! -x "$DISPLAY_BIN" ] && [ -n "$REPO_PATH" ]; then
    DISPLAY_TOOL="$REPO_PATH/tools/screenshots/mac-display-mode.swift"
    if [ -f "$DISPLAY_TOOL" ]; then
      echo "› [display] 编译分辨率工具"
      xcrun --sdk macosx swiftc -O "$DISPLAY_TOOL" -o "$DISPLAY_BIN" 2>&1 \
        || echo "› [display] 编译失败（不影响构建）"
    fi
  fi
  if [ -x "$DISPLAY_BIN" ]; then
    "$DISPLAY_BIN" --apply || true
  else
    echo "› [display] 没有可用的分辨率工具，保持现状"
  fi
fi

echo "› [entitlements] CI_XCODEBUILD_ACTION='${XCB_ACTION}' CI_PRODUCT_PLATFORM='${CI_PRODUCT_PLATFORM:-}'"

case "$XCB_ACTION" in
  build-for-testing)
    if [ -z "$REPO_PATH" ]; then
      echo "› [entitlements] CI_PRIMARY_REPOSITORY_PATH 为空，跳过"
      exit 0
    fi
    MAC_ENTITLEMENTS="$REPO_PATH/FlatRadarMac/FlatRadarMac.entitlements"
    if [ ! -f "$MAC_ENTITLEMENTS" ]; then
      echo "› [entitlements] 找不到 $MAC_ENTITLEMENTS"
      exit 1
    fi
    python3 - "$MAC_ENTITLEMENTS" <<'PYEOF'
import plistlib, sys

# 和 tests/test_mac_screenshot_plan.py 里的 RESTRICTED 是同一份清单。
# 加了新的受限 entitlement 而忘了加到这里，那条测试会红。
RESTRICTED = [
    "com.apple.developer.aps-environment",
    "com.apple.developer.associated-domains",
    "keychain-access-groups",
]

path = sys.argv[1]
with open(path, "rb") as f:
    ent = plistlib.load(f)

removed = [k for k in RESTRICTED if k in ent]
for k in removed:
    del ent[k]

with open(path, "wb") as f:
    plistlib.dump(ent, f)

print("› [entitlements] 已剥离：%s" % (", ".join(removed) or "（无）"))
print("› [entitlements] 保留：%s" % ", ".join(sorted(ent)))
PYEOF
    ;;
  *)
    echo "› [entitlements] 不是 build-for-testing（是 '${XCB_ACTION}'），不动 entitlements"
    ;;
esac

exit 0
