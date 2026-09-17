#!/bin/sh
# Xcode Cloud：把凭据注入截图用的 test plan（iOS 一份、Mac 一份）。
#
# 为什么要绕这一道
# ----------------
# xcodebuild 只把带 TEST_RUNNER_ 前缀的环境变量转发给测试进程。而 Xcode Cloud
# **明确禁止**用这个前缀命名环境变量：
#
#   Variable name cannot start with "CI_" or "TEST_RUNNER_".
#
# 于是成了死结：带前缀的建不出来，不带前缀的到不了测试进程。
#
# 出路是绕开环境变量：test plan 自己支持 environmentVariableEntries，而 test
# plan 是仓库里的文件——构建前改它就行。本脚本在克隆之后、构建之前跑，把 Xcode
# Cloud 的（不带前缀的）环境变量写进去。
#
# 凭据不进仓库
# ------------
# 这个仓库是公开的。值只存在于 Xcode Cloud 的 Secret 环境变量里，构建时才注入
# 到工作副本，不会被提交。没设环境变量时脚本原样跳过——App 退回访客模式，只有
# Notifications 那一屏拍不到（访客的 tab bar 里没有 Alerts）。
set -eu

# ci_scripts 必须紧挨 .xcodeproj。
#
# Xcode Cloud 只在「workflow 里配置的那个项目文件旁边」找 ci_scripts，别处一律
# 不看。在单仓库时代项目在 ios/FlatRadar/，第一版把脚本放到了仓库根——那样它
# **静默不执行**：构建照常绿，只是凭据没注入、Notifications 那屏拍不到，而没有
# 任何一行日志会说「脚本没找到」。
#
# 在这个仓库里 .xcodeproj 就在根目录，所以 ci_scripts 也在根目录——看起来像是
# 「放仓库根」，其实是「放项目文件旁边」，两者在这里恰好重合。以后若把项目挪进
# 子目录，这个目录得跟着一起挪。
#
# 脚本的工作目录是 ci_scripts 自己，所以路径走 CI_PRIMARY_REPOSITORY_PATH，
# 它指向克隆下来的仓库根。
# 两端各一份 plan。
#
# iOS 那份在 app 的源码目录里（历史位置），Mac 这份在仓库根的 TestPlans/。
# **别把 Mac 这份挪进 FlatRadarMac/**：那个目录是 PBXFileSystemSynchronizedRootGroup，
# 扔进去的文件会自动成为 app target 的资源——也就是说，一份刚被注入了明文凭据的
# plan 会被原样拷进 .app 里跟着上架。
#
# 这不是假想：iOS 那两份现在正是这个状态，Release 产物里实测有
#     Release-iphonesimulator/FlatRadar.app/Screenshots.xctestplan
#     Release-iphonesimulator/FlatRadar.app/FlatRadar.xctestplan
# 所以 iOS 那两份该挪出来，挪完把上面这行路径改掉。
PLANS="$CI_PRIMARY_REPOSITORY_PATH/FlatRadar/Screenshots.xctestplan
$CI_PRIMARY_REPOSITORY_PATH/TestPlans/MacScreenshots.xctestplan"

for PLAN in $PLANS; do
    if [ ! -f "$PLAN" ]; then
        echo "找不到 test plan：$PLAN"
        exit 1
    fi
done

if [ -z "${UI_TEST_USERNAME:-}" ] || [ -z "${UI_TEST_PASSWORD:-}" ]; then
    echo "未设置 UI_TEST_USERNAME / UI_TEST_PASSWORD，跳过注入（将以访客模式截图）"
    exit 0
fi

for PLAN in $PLANS; do
python3 - "$PLAN" <<'PY'
import json, os, sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    plan = json.load(f)

# 写进 defaultOptions，对所有 configuration（即所有语言）都生效。
opts = plan.setdefault("defaultOptions", {})
entries = [e for e in opts.get("environmentVariableEntries", [])
           if e.get("key") not in ("UI_TEST_USERNAME", "UI_TEST_PASSWORD")]
entries += [
    {"key": "UI_TEST_USERNAME", "value": os.environ["UI_TEST_USERNAME"]},
    {"key": "UI_TEST_PASSWORD", "value": os.environ["UI_TEST_PASSWORD"]},
]
opts["environmentVariableEntries"] = entries

with open(path, "w", encoding="utf-8") as f:
    json.dump(plan, f, ensure_ascii=False, indent=2)
    f.write("\n")

# 不打印值。只确认写进去了。
print("已注入 %d 个环境变量到 %s" % (len(entries), os.path.basename(path)))
PY
done
