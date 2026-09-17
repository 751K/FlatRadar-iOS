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
REPO_PATH="${CI_PRIMARY_REPOSITORY_PATH:-}"
XCB_ACTION="${CI_XCODEBUILD_ACTION:-}"

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
