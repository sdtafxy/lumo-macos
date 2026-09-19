#!/usr/bin/env python3
"""断言"界面上用到的每一条文案，英文表里都有"。

为什么需要它
------------
中文界面的文案就是源码里的中文原文（`T("添加 PDF")`），英文界面查表，
**查不到就退回中文**。这个回退是刻意设计的：漏翻的表现是"这一句还是中文"，
而不是空白或一串 key——但它同时意味着**漏翻不会报错**。
切到英文之后满屏找哪一句还是中文，是件很费眼睛的事；机器查一遍是一瞬间的事。

所以这里做两件事：
  1. 把 Sources 下所有 `T("…")` 用到的 key 收集起来；
  2. 和两张表（Core 的 core / App 的 en）的 key 取差集——差集非空就红，
     并把缺的是哪些、在哪个文件用的打出来。

反过来（表里有、代码里没用）只提示不报错：那是删文案之后留下的死条目，
清掉更好，但不该因此拦住一次提交。

注意
----
* 只扫**非注释行**。注释里出现 `T("…")` 是说明文字，不是真的在用。
* 这个脚本本身也要能失败：改掉任意一条英文表的 key，它必须报出来。
  自检方式：`python3 Scripts/check_localization.py --selftest`
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 用到的 key：源码里的 T("…")（也接受带参数的形式 T("…", 值)）
USE = re.compile(r'\bT\("((?:[^"\\]|\\.)*)"')
# 表里的 key：缩进 8 空格 + "…" + 冒号。两张表都是这个写法，
# 续行（以 + 或别的开头）不会被误判成 key。
KEY = re.compile(r'^ {8}"((?:[^"\\]|\\.)*)"\s*:', re.M)

# 间接使用的 key：这些字符串**不作为 `T("…")` 的字面量出现**，而是被当成数据传进 T()
# 的（OCR 的语言名就是这样：存在 `OCR.languages` 里，取用 `name` 时才翻译）。
# 静态扫描看不见它们，但它们**必须在表里**——所以不能当成"死条目"删掉。
INDIRECT = {
    "中文 + 英文", "中文简体", "中文繁体 + 英文",
    "英文", "日文", "韩文", "法文", "德文", "西班牙文", "意大利文", "葡萄牙文", "俄文",
}

# 带参数的 T("…", 值) 调用：字符串后面紧跟逗号
FORMAT_CALL = re.compile(r'\bT\("((?:[^"\\]|\\.)*)"\s*,')
# 只允许 %@（对象占位符）与 %%（字面百分号）。
# 理由见 LumoCore/Localization.swift 的 T(_:_:)：参数统一转成字符串再格式化，
# 所以 %d / %.1f 这类数字占位符**对不上类型**——%@ 收到 String 才对。
# 而反过来，把 Int 交给 %@ 会 SIGSEGV（实测崩过），所以这里两头都要卡住。
BAD_SPEC = re.compile(r'%(?!%|@)')

CORE_DIR = os.path.join(ROOT, "Sources", "LumoCore")
APP_DIR = os.path.join(ROOT, "Sources", "LumoApp")

# 这两张表各自覆盖哪些目录（Core 表只管 Core，App 表只管 App）
TABLES = [
    (os.path.join(CORE_DIR, "Localization.swift"), CORE_DIR, "core"),
    (os.path.join(APP_DIR, "Localization.swift"), APP_DIR, "en"),
]


def swift_files(d):
    for dirpath, _dirnames, filenames in os.walk(d):
        for fn in sorted(filenames):
            if fn.endswith(".swift"):
                yield os.path.join(dirpath, fn)


def used_keys(d):
    """{key: [文件:行, …]}，跳过注释行。"""
    found = {}
    for path in swift_files(d):
        if os.path.basename(path) == "Localization.swift":
            continue          # 表本身不算"使用"
        with open(path, encoding="utf-8") as fh:
            for i, line in enumerate(fh, 1):
                st = line.strip()
                if st.startswith("//") or st.startswith("///"):
                    continue
                for m in USE.finditer(line):
                    found.setdefault(m.group(1), []).append(
                        f"{os.path.relpath(path, ROOT)}:{i}")
    return found


def table_keys(path):
    with open(path, encoding="utf-8") as fh:
        return KEY.findall(fh.read())


def duplicate_keys(path):
    """表里重复的 key。

    ⚠️ 这个必须单独查，理由很硬：**Swift 的字典字面量遇到重复 key 是运行时崩溃**
    （`Dictionary literal contains duplicate keys` → SIGTRAP），不是编译错误。
    编译器只给一条 warning，很容易没看见——实测就这么崩过一次：
    在表里补条目时把同一个 key 写了两遍，App 一启动就退，而 `swift build` 的退出码是 0。
    """
    from collections import Counter
    return [k for k, n in Counter(table_keys(path)).items() if n > 1]


def main() -> int:
    # Core 与 App 都要扫：`T()` 是同一个函数，查表时两张表一起查，
    # 所以"用到了但没翻"也必须在**两边**都找一遍
    # （只扫 App 会漏掉 Core 里新加的文案——那正是最容易忘的地方）。
    used = used_keys(APP_DIR)
    for k, v in used_keys(CORE_DIR).items():
        used.setdefault(k, []).extend(v)
    # 格式串体检：带参数的 T("…", 值) 里只能有 %@ 与 %%
    bad_fmt = []
    for d in (APP_DIR, CORE_DIR):
        for path in swift_files(d):
            if os.path.basename(path) == "Localization.swift":
                continue
            with open(path, encoding="utf-8") as fh:
                for i, line in enumerate(fh, 1):
                    st = line.strip()
                    if st.startswith("//") or st.startswith("///"):
                        continue
                    for m in FORMAT_CALL.finditer(line):
                        key = m.group(1)
                        stripped = key.replace("%%", "").replace("%@", "")
                        if BAD_SPEC.search(stripped):
                            bad_fmt.append((f"{os.path.relpath(path, ROOT)}:{i}", key))
    if bad_fmt:
        print("✗ 带参数的 T(\"…\", 值) 里用了 %@ / %% 之外的格式符：")
        for where, key in bad_fmt:
            print(f"  {where}  {key!r}")
        print()
        print("原因：T 的参数统一转成字符串再交给 String(format:)，")
        print("      所以 %d / %.1f 这类数字占位符永远对不上类型（会打出乱码或崩）。")
        print("      要数字就在调用处自己 String(...)，或者在 T 之外用 String(format:)。")
        return 1

    dupes = {}
    for path, _d, name in TABLES:
        dupes[name] = duplicate_keys(path)
    bad_dupes = {k: v for k, v in dupes.items() if v}
    if bad_dupes:
        print("✗ 翻译表里有重复的 key —— **这会让 App 一启动就崩**：")
        for name, keys in bad_dupes.items():
            print(f"  {name} 表：{keys}")
        print()
        print("修法：同一条文案只留一处。Swift 的字典字面量遇到重复 key 是运行时 SIGTRAP，")
        print("      编译器只会给一条 warning（很容易漏），所以必须在这里拦住。")
        return 1

    tables = {}
    for path, _d, name in TABLES:
        tables[name] = set(table_keys(path))
    all_keys = set().union(*tables.values())

    # 用法：--selftest 时故意把一条 key 从表里摘掉，断言它会被报出来
    selftest = "--selftest" in sys.argv
    if selftest:
        victim = next(iter(sorted(used)))
        all_keys.discard(victim)
        print(f"（自检模式：故意摘掉 key {victim!r}）\n")

    missing = {k: v for k, v in used.items() if k not in all_keys}
    # 死条目：表里有、代码里没用。只提示。
    extra = sorted(k for k in all_keys if k not in used and k not in INDIRECT)

    print(f"源码里用到的 key：{len(used)} 条")
    print(f"两张表里的 key：  {len(all_keys)} 条"
          f"（core {len(tables['core'])} + App {len(tables['en'])}）")
    print()

    if missing:
        print("✗ 下面这些文案有中文、没有英文：")
        for k in sorted(missing):
            print(f"  {k!r}")
            for where in missing[k][:3]:
                print(f"      用在 {where}")
        print()
        print("修法：把它们补进 Sources/LumoApp/Localization.swift（界面文案）"
              "或 Sources/LumoCore/Localization.swift（Core 里的文案）。")
        return 1

    if extra:
        print(f"提示：有 {len(extra)} 条表里有、代码里没用到（死条目，建议清掉）：")
        for k in extra:
            print(f"  {k!r}")
        print()

    print("✓ 文案本地化完整：用到的每一条都有英文")
    return 0


if __name__ == "__main__":
    sys.exit(main())
