#!/usr/bin/env python3
"""从 Scripts/design_doc.html 生成 Resources/Lumo-设计文档.pdf。

为什么要有个脚本，而不是"改完 HTML 手导出一次"：
这份 PDF 是要随 App 一起打包、用户点侧边栏就能打开的。它和 HTML 是
**同一份内容的两份拷贝**，而手导出意味着"忘了导出"永远可能发生——
设计文档落后于代码正是这么来的（v0.3.1 改了版本号策略、纸白判据、
窗口行为，文档一个字没动）。

固化成脚本之后，CI 就能加一条断言：生成的 PDF 必须和仓库里那份一致。
两者一旦不同就说明有人改了 HTML 没重新导出。**同一份内容有两处拷贝时，
必须让机器盯着它们一致，不能指望人记得。**

字体：用 WeasyPrint 自带的字体解析。CI 上装了 Noto CJK，中文不会掉字；
本地缺字体时 PDF 里会出现方框，但 CI 才是权威。
"""
import os
import sys

from weasyprint import HTML

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Scripts", "design_doc.html")
OUT = os.path.join(ROOT, "Resources", "Lumo-设计文档.pdf")


def main() -> int:
    if not os.path.exists(SRC):
        print(f"error: 找不到源文件 {SRC}", file=sys.stderr)
        return 1
    target = sys.argv[1] if len(sys.argv) > 1 else OUT
    os.makedirs(os.path.dirname(os.path.abspath(target)), exist_ok=True)
    HTML(filename=SRC).write_pdf(target)
    size = os.path.getsize(target)
    if size < 50_000:
        # 太小基本意味着字体没找到、整篇掉字。582KB 是正常量级。
        print(f"error: 生成的 PDF 只有 {size} 字节，八成是中文字体缺失", file=sys.stderr)
        return 1
    print(f"wrote {target} ({size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
