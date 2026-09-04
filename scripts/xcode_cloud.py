#!/usr/bin/env python3
"""Xcode Cloud 的命令行入口：触发截图构建、看状态、把图拉下来。

为什么需要它
------------
截图从 GitHub Actions 全部搬到 Xcode Cloud 之后，仓库里就没有任何一处描述
「怎么跑一轮截图」了——Xcode Cloud 的 workflow 定义在 App Store Connect 的
网页上，仓库里只剩 ci_scripts 那个钩子。于是这件事的全部知识只存在于某次
对话里：怎么触发、artifacts 在哪条关系链上、结果桶按什么分。

这个脚本把那条链写下来：

    ciWorkflows/<id>                      ← 网页上配的那个 workflow
      └ POST /ciBuildRuns                 ← 触发（要指定分支的 gitReference）
          └ /actions                      ← 每个设备一个 action
              ├ /issues                   ← 失败详情（消息会被截到 ~3000 字）
              ├ /testResults              ← 每条用例 × 每个设备的结果
              └ /artifacts                ← RESULT_BUNDLE 就在这里

用法
----
    python3 scripts/xcode_cloud.py list
    python3 scripts/xcode_cloud.py run [--workflow Screenshot] [--branch master] [--wait]
    python3 scripts/xcode_cloud.py status <build-number|run-id>
    python3 scripts/xcode_cloud.py fetch  <build-number|run-id> [--outdir screenshots]

凭据走 tools/asc/asc_api.py 那一套（~/.config/asc/config.json）。
"""
from __future__ import annotations

import argparse
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools" / "asc"))

import asc_api as asc  # noqa: E402


def _product(cfg):
    prods = asc.call(cfg, "GET", "/ciProducts?limit=20")["data"]
    if not prods:
        sys.exit("这个账号下没有 Xcode Cloud product")
    return prods[0]


def _workflow(cfg, name: str):
    prod = _product(cfg)
    wfs = asc.call(cfg, "GET", f"/ciProducts/{prod['id']}/workflows?limit=50")["data"]
    for w in wfs:
        if w["attributes"].get("name") == name:
            return w
    sys.exit(f"没有叫「{name}」的 workflow，现有："
             + ", ".join(w["attributes"].get("name", "?") for w in wfs))


def _branch_ref(cfg, workflow_id: str, branch: str):
    repo = asc.call(cfg, "GET", f"/ciWorkflows/{workflow_id}/repository")["data"]
    refs = asc.call(
        cfg, "GET",
        f"/scmRepositories/{repo['id']}/gitReferences?limit=200")["data"]
    for g in refs:
        a = g["attributes"]
        if a.get("kind") == "BRANCH" and a.get("name") == branch:
            return g
    names = [g["attributes"].get("name") for g in refs
             if g["attributes"].get("kind") == "BRANCH"]
    sys.exit(f"仓库里没有分支「{branch}」，现有：{names}")


def _resolve_run(cfg, ident: str) -> dict:
    """接受 build 号或 run id。build 号更好记，但 API 只认 id。"""
    if "-" in ident:                                  # 看着像 UUID
        return asc.call(cfg, "GET", f"/ciBuildRuns/{ident}")["data"]
    prod = _product(cfg)
    # sort=-number 是必须的：默认顺序是**升序**，不加这一句就会在最旧的
    # 50 次构建里找一个刚跑完的编号，永远找不到。
    runs = asc.call(
        cfg, "GET",
        f"/ciProducts/{prod['id']}/buildRuns?limit=50&sort=-number")["data"]
    for r in runs:
        if str(r["attributes"].get("number")) == str(ident):
            return r
    sys.exit(f"最近 50 次构建里没有编号 {ident}")


# ── 子命令 ────────────────────────────────────────────────────────────

def cmd_list(cfg, args) -> int:
    prod = _product(cfg)
    print(f"product: {prod['attributes'].get('name')}")
    for w in asc.call(cfg, "GET",
                      f"/ciProducts/{prod['id']}/workflows?limit=50")["data"]:
        a = w["attributes"]
        print(f"  workflow {a.get('name'):24s} enabled={a.get('isEnabled')}")
    print("最近的构建：")
    for r in asc.call(
            cfg, "GET",
            f"/ciProducts/{prod['id']}/buildRuns?limit=10&sort=-number")["data"]:
        a = r["attributes"]
        print(f"  {str(a.get('number')):>5s}  {a.get('executionProgress'):9s} "
              f"{str(a.get('completionStatus')):10s} {a.get('createdDate','')[:19]}")
    return 0


def cmd_run(cfg, args) -> int:
    wf = _workflow(cfg, args.workflow)
    ref = _branch_ref(cfg, wf["id"], args.branch)
    body = {"data": {"type": "ciBuildRuns", "attributes": {}, "relationships": {
        "workflow": {"data": {"type": "ciWorkflows", "id": wf["id"]}},
        "sourceBranchOrTag": {"data": {"type": "scmGitReferences",
                                       "id": ref["id"]}}}}}
    run = asc.call(cfg, "POST", "/ciBuildRuns", body)["data"]
    num = run["attributes"].get("number")
    print(f"已触发 build {num}  ({args.workflow} @ {args.branch})  id={run['id']}")
    if args.wait:
        return _wait(cfg, run["id"])
    print(f"跟进： python3 {Path(__file__).name} status {num}")
    return 0


def _wait(cfg, run_id: str, timeout: int = 3600) -> int:
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        a = asc.call(cfg, "GET", f"/ciBuildRuns/{run_id}")["data"]["attributes"]
        prog = a.get("executionProgress")
        if prog != last:
            print(f"  {prog}")
            last = prog
        if prog == "COMPLETE":
            ok = a.get("completionStatus") == "SUCCEEDED"
            print(f"完成：{a.get('completionStatus')}")
            return 0 if ok else 1
        time.sleep(30)
    print("等待超时", file=sys.stderr)
    return 2


def cmd_status(cfg, args) -> int:
    run = _resolve_run(cfg, args.build)
    a = run["attributes"]
    print(f"build {a.get('number')}  {a.get('executionProgress')} / "
          f"{a.get('completionStatus')}")
    for act in asc.call(cfg, "GET",
                        f"/ciBuildRuns/{run['id']}/actions")["data"]:
        aa = act["attributes"]
        print(f"\naction {aa.get('name')} "
              f"[{aa.get('executionProgress')}/{aa.get('completionStatus')}]")
        results = asc.call(
            cfg, "GET",
            f"/ciBuildActions/{act['id']}/testResults?limit=200")["data"]
        for t in sorted(results, key=lambda x: x["attributes"].get("name", "")):
            ta = t["attributes"]
            print(f"  {ta.get('status'):8s} {ta.get('name')}")
            for d in ta.get("destinationTestResults") or []:
                print(f"          └ {d.get('deviceName')}: {d.get('status')}")
        issues = asc.call(
            cfg, "GET",
            f"/ciBuildActions/{act['id']}/issues?limit=200")["data"]
        fails = [i["attributes"].get("message", "") for i in issues
                 if i["attributes"].get("issueType") == "TEST_FAILURE"]
        for msg in fails:
            # ASC 把这段截在三千字左右——测试里的诊断必须短、要点在最前面。
            print("\n  " + msg.strip().replace("\n", "\n  ")[:1500])
    return 0


def cmd_fetch(cfg, args) -> int:
    run = _resolve_run(cfg, args.build)
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    found = 0
    for act in asc.call(cfg, "GET",
                        f"/ciBuildRuns/{run['id']}/actions")["data"]:
        arts = asc.call(cfg, "GET",
                        f"/ciBuildActions/{act['id']}/artifacts?limit=50")["data"]
        for art in arts:
            aa = art["attributes"]
            if aa.get("fileType") != "RESULT_BUNDLE":
                continue
            name = aa.get("fileName", "bundle.zip")
            if "build-for-testing" in name:      # 这个包里没有截图
                continue
            size_mb = (aa.get("fileSize") or 0) / 1e6
            print(f"下载 {name}  ({size_mb:.0f} MB)")
            zpath = outdir / "_download.zip"
            urllib.request.urlretrieve(aa["downloadUrl"], zpath)
            with zipfile.ZipFile(zpath) as z:
                z.extractall(outdir / "_bundles")
            zpath.unlink()
            found += 1
    if not found:
        print("没有找到 RESULT_BUNDLE —— 构建可能还没跑完", file=sys.stderr)
        return 1
    bundles = list((outdir / "_bundles").glob("**/*.xcresult"))
    if not bundles:
        print("下载下来的包里没有 .xcresult", file=sys.stderr)
        return 1
    # 顺手把图提出来。分成两条命令的话，多数时候第二条会被忘掉，
    # 然后「我拉过图了」和「我看过图了」就混成一件事。
    import subprocess
    rc = 0
    for b in bundles:
        print(f"\n提取 {b.name}")
        rc |= subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "extract_screenshots.py"),
             str(b), str(outdir)]).returncode
    pngs = list(outdir.glob("**/*.png"))
    print(f"\n共 {len(pngs)} 张 PNG 在 {outdir}/")
    print("校验张数与尺寸： python3 scripts/verify_screenshots.py "
          f"{outdir}/<桶> --expect N --width W --height H")
    return rc


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", help="列出 workflow 与最近的构建")

    p = sub.add_parser("run", help="触发一次构建")
    p.add_argument("--workflow", default="Screenshot")
    p.add_argument("--branch", default="master")
    p.add_argument("--wait", action="store_true", help="等到跑完再返回")

    p = sub.add_parser("status", help="构建结果 + 失败详情")
    p.add_argument("build", help="build 号或 run id")

    p = sub.add_parser("fetch", help="下载 RESULT_BUNDLE")
    p.add_argument("build", help="build 号或 run id")
    p.add_argument("--outdir", default="screenshots")

    args = ap.parse_args()
    cfg = asc.load_config()
    return {"list": cmd_list, "run": cmd_run,
            "status": cmd_status, "fetch": cmd_fetch}[args.cmd](cfg, args)


if __name__ == "__main__":
    raise SystemExit(main())
