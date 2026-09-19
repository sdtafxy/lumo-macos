#!/usr/bin/env python3
"""从 CHANGELOG.md 里取出指定版本的段落，用作 GitHub Release 的正文。

**为什么不能再用 GitHub 的自动生成**（`generate_release_notes: true`）：
它只罗列**合并的 PR**，于是"这个版本改了什么"完全取决于提交/PR 怎么写的。
实测踩过：v0.0.2 的发布说明整篇只有一条机器人依赖升级
（`Bump the actions group with 3 updates by @dependabot[bot]`），
真正的界面改动、语言支持、几个致命修复一个字都没有——
因为那些改动是**直接提交到 main** 的，没有 PR，自动生成器根本看不见。

Release 正文是给下载的人看的。它的唯一可信来源应该是 CHANGELOG：
那里是按「用户能感知的变化」手写的，也是全项目**唯一**需要维护版本说明的地方。

用法：
    python3 Scripts/extract_release_notes.py v0.0.2      # 也接受 0.0.2
    python3 Scripts/extract_release_notes.py --check 0.0.2   # 只检查有没有，不打印
退出码：找到 0 / 找不到 1（找不到时**必须**让调用方知道，而不是输出空正文）。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")


def section(version: str) -> str | None:
    """返回该版本的正文（不含 `## [x.y.z]` 标题行）。"""
    with open(CHANGELOG, encoding="utf-8") as fh:
        text = fh.read()
    want = version.lstrip("vV").strip()
    # 标题形如 `## [0.0.2] — 2026-09-19` 或 `## [Unreleased]`
    heads = list(re.finditer(r"^## \[([^\]]+)\](.*)$", text, re.M))
    for i, m in enumerate(heads):
        if m.group(1).strip() != want:
            continue
        start = m.end()
        end = heads[i + 1].start() if i + 1 < len(heads) else len(text)
        body = text[start:end]
        # 去掉尾部那条分隔线和「更早版本」的链接块
        body = re.split(r"\n---\n", body)[0]
        # 去掉尾部的链接引用定义（`[0.0.2]: https://…`）——那是给 CHANGELOG 内部
        # 交叉引用用的，放进 Release 正文只会变成两行裸露的网址。
        body = re.sub(r"(?m)^\[[^\]]+\]:\s*https?://\S+\s*$", "", body)
        return body.strip("\n")
    return None


def main() -> int:
    args = [a for a in sys.argv[1:]]
    check_only = "--check" in args
    args = [a for a in args if not a.startswith("--")]
    if len(args) != 1:
        print("用法：extract_release_notes.py [--check] <版本号|v版本号>", file=sys.stderr)
        return 2
    version = args[0]
    body = section(version)
    if body is None:
        print(f"CHANGELOG.md 里没有 {version.lstrip('vV')} 的条目。"
              f"\n发版前请先把它写进去——Release 正文就是从这里来的。", file=sys.stderr)
        return 1
    if check_only:
        print(f"✓ CHANGELOG 里有 {version.lstrip('vV')} 的条目（{len(body)} 字符）")
        return 0
    # 末尾补一行指向完整变更，方便从 Release 页跳到仓库
    print(body)
    print()
    print(f"完整变更记录见 [CHANGELOG.md](https://github.com/sdtafxy/lumo-macos/blob/main/CHANGELOG.md)。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
