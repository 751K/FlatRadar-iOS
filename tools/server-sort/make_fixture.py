"""用**后端的原始代码**算出排序的标准答案，给 Core 的 `ServerListingOrderTests` 当夹具。

为什么不自己写一份 Python 版
--------------------------
Mac 端点列头时要在本地重排（全量已经在手，没必要再请求四页），而本地的顺序必须和
`GET /api/v1/listings?sort=` 一模一样——否则刷新一下行就跳。拿"我理解的规则"写
一份 Python 再和 Swift 对，等于同一个人出题又答题。这里直接从后端仓库取
`sort_listing_rows` 那几个函数的**源码原文**来跑，只替换掉它们的 import。

用法（需要 `gh` 已登录）::

    python3 tools/server-sort/make_fixture.py > /tmp/fixture.json

后端换了排序规则时：改下面的 BACKEND_SHA，重跑，把输出贴回测试文件。
"""
from __future__ import annotations

import ast
import json
import re
import subprocess
import sys
import types
from typing import Iterable, Optional

REPO = "751K/holland2stay-monitor"
BACKEND_SHA = "a0ac8c631d6094c73137953904f7d879a84d6a0d"   # 2026-09-17


def fetch(path: str) -> str:
    return subprocess.run(
        ["gh", "api", f"repos/{REPO}/contents/{path}?ref={BACKEND_SHA}",
         "-H", "Accept: application/vnd.github.raw"],
        check=True, capture_output=True, text=True).stdout


def extract(source: str, names: set[str]) -> str:
    """只取出指定的顶层函数 / 常量的源码原文，不执行模块的其它部分。"""
    tree = ast.parse(source)
    lines = source.splitlines(keepends=True)
    out = []
    for node in tree.body:
        name = None
        if isinstance(node, (ast.FunctionDef, ast.ClassDef)):
            name = node.name
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            target = node.targets[0] if isinstance(node, ast.Assign) else node.target
            name = getattr(target, "id", None)
        if name in names:
            start = (node.decorator_list[0].lineno if getattr(node, "decorator_list", None)
                     else node.lineno) - 1
            out.append("".join(lines[start:node.end_lineno]))
    missing = names - {n for n in names if any(f" {n}" in s or s.startswith(n) for s in out)}
    if missing:
        sys.exit(f"后端源码里找不到：{missing}")
    return "\n".join(out)


def module(name: str, code: str, **extra) -> types.ModuleType:
    m = types.ModuleType(name)
    m.__dict__.update(re=re, json=json, Optional=Optional, Iterable=Iterable, **extra)
    exec(compile(code, f"<backend {name}>", "exec"), m.__dict__)
    sys.modules[name] = m
    return m


models = module("models", extract(fetch("models.py"), {
    "SENTINEL_AVAILABLE_FROM_YEAR", "is_sentinel_available_from", "parse_float",
    "parse_features_list", "LISTING_KEY_MAP"}))
config = module("config", extract(fetch("config.py"), {"ENERGY_LABELS", "energy_rank"}))
derived = module("derived", extract(fetch("mstorage/_derived.py"), {"derived_from_features"}))
service = module("service", extract(fetch("app/services/listing_service.py"), {
    "_STATUS_RANK_OTHER", "status_rank", "_sort_value", "sort_listing_rows", "SORT_KEYS"}))

# ── 样本：专挑规则的边角 ──────────────────────────────────────────────
# 每一列都有：并列值（考 id 兜底）、未知值（考"一律沉底"）、写法变体。
# id 故意不按字母顺序给，而且有 "h2s_10" / "h2s_9" 这种按码位比才对的。
ROWS = [
    # id,        price,        status,                 available,     city,          source,         first_seen,                   last_seen,                    features
    ("h2s_10", "€707",        "Available to book",    "2026-10-01", "Amsterdam",   "holland2stay", "2026-09-01T10:00:00+00:00", "2026-09-10T10:00:00+00:00", ["Area: 26.0 m²", "Energy: A+"]),
    ("h2s_9",  "€707",        "available_to_book",    "2026-10-01", "amsterdam",   "holland2stay", "2026-09-01T10:00:00+00:00", "2026-09-11T10:00:00+00:00", ["Area: 26 m²", "Energy: a+"]),
    ("xr_2",   "€1.587",      "Available in lottery", "2050-01-01", "Utrecht",     "xior",         "2026-08-01T09:00:00+00:00", "",                          ["Area: 87.28 m²", "Energy: A+++"]),
    ("xr_10",  "€ 1.587",     "To be in lottery",     "",           " Utrecht",    "xior",         "",                          "2026-09-12T08:00:00+00:00", ["Area: 9 m²", "Energy: B"]),
    ("A1",     "on request",  "Reserved",             "2099-12-31", "Den Haag",    "ourdomain",    "2026-07-15T00:00:00+00:00", "2026-09-01T00:00:00+00:00", ["Area: 0 m²", "Energy: G"]),
    ("a1",     "",            "Occupied",             "2026-09-15", "den haag",    "ourdomain",    "2026-07-15T00:00:00+00:00", "2026-09-01T00:00:00+00:00", ["Energy: A++"]),
    ("b7",     "€1,200.50",   "Rented",               "2027-01-01", "Zürich",      "holland2stay", "2026-09-02T00:00:00+00:00", "2026-09-02T00:00:00+00:00", ["Area: 45,5 m²"]),
    ("b8",     "€1.200,50",   "Not available",        "2026-12-24", "zwolle",      "vestide",      "2026-09-03T00:00:00+00:00", "2026-09-03T00:00:00+00:00", ["Area: 45.5 m²", "Energy: C"]),
    ("c3",     "1,5",         "Something else",       "2026-10-01", "",            "vestide",      "2026-09-03T00:00:00+00:00", "2026-09-04T00:00:00+00:00", ["Energy: A"]),
    ("c30",    "€1.234.567",  "",                     "  2026-10-02  ", "Eindhoven", "xior",       "2026-09-04T00:00:00+00:00", "2026-09-05T00:00:00+00:00", ["Area: 1.234 m²", "Energy: F"]),
    ("d4",     "€0",          "Available to book",    "2051-06-01", "Eindhoven",   "holland2stay", "2026-09-04T00:00:00+00:00", "2026-09-05T00:00:00+00:00", ["Area: 30 m²", "Energy: E"]),
    ("d40",    "€950",        "RESERVED",             "2026-11-01", "Rotterdam",   "holland2stay", "2026-09-05T00:00:00+00:00", "", ["Area: 30.0 m²", "Energy: D"]),
    ("e5",     "€950",        "Available in lottery", "2026-11-01", "rotterdam",   "vestide",      "2026-09-05T00:00:00+00:00", "2026-09-06T00:00:00+00:00", ["Area: 30 m²", "Energy: A+++"]),
    ("Z9",     "€12",         "Occupied",             "20",         "Rotterdam",   "xior",         "2026-09-06T00:00:00+00:00", "2026-09-06T00:00:00+00:00", ["Area: 120 m²", "Energy: A++"]),
]

listings, rows = [], []
for rid, price, status, avail, city, source, first, last, feats in ROWS:
    area, energy = derived.derived_from_features(json.dumps(feats))
    rows.append({"id": rid, "price_raw": price, "status": status, "available_from": avail,
                 "city": city, "source": source, "first_seen": first, "last_seen": last,
                 "area_value": area, "energy_rank": energy})
    # 客户端收到的形状，照 `serialize_listing`。
    listings.append({"id": rid, "name": rid, "status": status, "price_raw": price,
                     "price_value": models.parse_float(price), "available_from": avail,
                     "city": city, "source": source, "url": "", "features": feats,
                     "feature_map": models.parse_features_list(feats),
                     "first_seen": first, "last_seen": last})

orders = {}
for key in service.SORT_KEYS:
    for desc in (False, True):
        wire = ("-" if desc else "") + key
        orders[wire] = [r["id"] for r in service.sort_listing_rows(rows, key, desc)]

json.dump({"backend_sha": BACKEND_SHA, "listings": listings, "orders": orders},
          sys.stdout, ensure_ascii=False, indent=1)
