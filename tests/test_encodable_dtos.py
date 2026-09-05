"""上行 DTO：自定义 CodingKeys 必须盖住每一个存储属性。

为什么值得一条测试
------------------
Swift 在这件事上对 `Encodable` 和 `Decodable` 是两种态度：

    struct Req: Encodable {
        let a: String
        let b: String          ← 新加的字段
        enum CodingKeys: String, CodingKey {
            case a             ← 忘了加 b
        }
    }

`Decodable` 会**编译不过**——合成的 init 没法给 b 赋值，编译器直接拦下。
但 `Encodable` 只按 CodingKeys 里列出的键合成 `encode(to:)`，**b 被安静地丢掉**。
编译通过、没有警告、请求照发、状态码 200，只是那个字段从来没出现在 body 里。

这个失败模式的代价不在崩溃，在**时间**：后端加好了字段、iOS 也「加好了」字段，
然后等一个版本周期，发现数据表里那一列全是 NULL，再回头两边对着查。而两边的
代码看上去都是对的。

2026-09-05 给 `DeviceRegisterRequest` 加 `osVersion` 时，这条测试就是当时唯一
能验证「字段真的会被发出去」的手段——那台机器上没装 Xcode（只有 Command Line
Tools），编译器和模拟器都不在，改完的 Swift 一行都跑不了。

顺带说明为什么不放宽到「Decodable 也查」
----------------------------------------
查了也没坏处，所以这里一并查了。只是 Decodable 那半边编译器已经挡住了，
真正靠这条测试兜住的只有 Encodable。
"""
from __future__ import annotations

import re
from pathlib import Path

SOURCE_ROOT = Path(__file__).resolve().parent.parent / "FlatRadar"

_STRUCT_HEAD = re.compile(r"\bstruct\s+(\w+)\s*:\s*([^{\n]+?)\s*\{")
# 存储属性：`let x: T` / `var x: T`，行内不能出现 `{`（那是计算属性）。
_STORED_PROPERTY = re.compile(r"^(?:let|var)\s+(\w+)\s*:")
_CASE_LINE = re.compile(r"^case\s+(.+)$")


def _balanced_body(src: str, open_brace_index: int) -> str:
    """从 `{` 开始做括号配对，返回其中的内容。"""
    depth = 0
    for i in range(open_brace_index, len(src)):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[open_brace_index + 1:i]
    raise AssertionError("括号没配上——文件被截断了？")


def _top_level_declarations(body: str) -> list[tuple[str, bool]]:
    """body 里嵌套深度为 0 的声明，附带「后面紧跟一个 `{`」的标记。

    那个标记就是存储属性和计算属性的分界：`var isEmpty: Bool {` 后面跟着花括号，
    它不占存储、不参与编码，自然也不该出现在 CodingKeys 里。少了这个判断，
    ListingFilter 的 isEmpty / summary / summaryParts / summaryChips 会被全部
    误报成「漏掉的字段」。
    """
    out: list[tuple[str, bool]] = []
    depth, current = 0, ""
    for ch in body:
        if ch == "\n":
            if depth == 0:
                out.append((current.strip(), False))
            current = ""
            continue
        if ch == "{":
            if depth == 0:
                out.append((current.strip(), True))
                current = ""
            depth += 1
            continue
        if ch == "}":
            depth -= 1
            continue
        if depth == 0:
            current += ch
    out.append((current.strip(), False))
    return out


def _coding_keys(body: str) -> set[str] | None:
    m = re.search(r"\benum\s+CodingKeys\b[^{]*\{", body)
    if not m:
        return None
    keys: set[str] = set()
    for line in _balanced_body(body, m.end() - 1).splitlines():
        case = _CASE_LINE.match(line.strip())
        if not case:
            continue
        for part in case.group(1).split(","):
            keys.add(part.split("=")[0].strip())
    return keys


def _encodable_structs_with_custom_keys():
    for path in sorted(SOURCE_ROOT.rglob("*.swift")):
        src = path.read_text(encoding="utf-8")
        for head in _STRUCT_HEAD.finditer(src):
            name, conformances = head.group(1), head.group(2)
            if not re.search(r"\b(Encodable|Codable)\b", conformances):
                continue
            body = _balanced_body(src, head.end() - 1)
            keys = _coding_keys(body)
            if keys is None:      # 没有自定义 CodingKeys → 编译器全合成，不会漏
                continue
            props = [
                m.group(1)
                for line, computed in _top_level_declarations(body)
                if not computed and not line.startswith("static")
                for m in [_STORED_PROPERTY.match(line)]
                if m
            ]
            yield path, name, props, keys


def test_the_scan_actually_finds_something():
    """空扫描等于没测试——正则或文件布局变了要立刻知道。"""
    found = list(_encodable_structs_with_custom_keys())
    assert found, (
        "没有扫到任何『带自定义 CodingKeys 的 Encodable 结构』。"
        "要么这类 DTO 全被删了，要么解析逻辑跟不上代码结构的变化了。")


def test_every_stored_property_has_a_coding_key():
    problems = []
    for path, name, props, keys in _encodable_structs_with_custom_keys():
        missing = [p for p in props if p not in keys]
        if missing:
            rel = path.relative_to(SOURCE_ROOT.parent)
            problems.append(f"{rel} 的 {name} 漏了：{missing}")
    assert not problems, (
        "以下属性不在 CodingKeys 里，Encodable 合成时会被**安静地丢掉**"
        "——编译通过、无警告、请求照发，只是 body 里没有这个字段：\n  "
        + "\n  ".join(problems))
