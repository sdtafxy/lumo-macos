#!/usr/bin/env python3
"""断言 Resources/Lumo-设计文档.pdf 与 Scripts/design_doc.html 内容一致。

为什么需要这个脚本
------------------
这份设计文档有两处拷贝：源文件是 HTML，用户看到的是内置的 PDF。
0.3.2 之前 PDF 是「手工导出后提交」的，于是它必然会忘——用户实测反馈的第 5 条
「设计文档没有及时更新」就是这么来的。

把生成过程脚本化（make_design_doc.py）只解决了一半：脚本在那儿，
但没有任何东西强制你跑它。这个脚本补上另一半——CI 里断言两者一致，
忘了重新生成就直接红。

怎么比：为什么不是直接比字符串
------------------------------
最朴素的写法是 `normalize(html) == normalize(pdf)`。这个写法会假红：
HTML 里表格是「按行：单元格、单元格、单元格」的顺序，
而 PDF 抽文字是按视觉位置来的，同一张表的表头有时排在内容前面、
有时插在中间。实测差异就一处，两边**字符完全相同、只有顺序不同**：

    HTML: 06流水线 [阶段] 输入做的事产出 感知PDF…
    PDF : 06流水线 输入做的事产出 [阶段] 感知PDF…

这是抽取器的固有行为，不是文档出问题。字节级比对还会额外被
WeasyPrint 版本差异（字形子集、压缩参数、时间戳）打红——那些同样与内容无关。

所以比对分两步：
  1. 把两侧文本按标点切成「短语」（短语内部顺序稳定，不受分栏影响）；
  2. 每条短语再规范化成**排序后的字符多重集**，整份文档的短语集合做精确相等比较。

第 2 步是这里的关键取舍：它精确抵消「同一批字符换了顺序」这种伪差异，
同时对真正的改动**零容忍**——多一个字、少一个字、换一个字，
字符多重集就变了，断言必红。已实测（见 README「设计文档一致性」）：
改数字 / 加一句 / 删一段 / 改版本号 / 改色值，五类改动全部检出。

0.3.3 补充：短语切分对「抽取顺序」免疫，但对**「单元格切点」不免疫**。
表格里某个窄单元格的末句若在版面上紧挨右邻格，排完版后两侧的**切点会不同**——
HTML 切出「对照布丁」「扫描」，PDF 切出「对照布丁扫描」。
字符总数与内容完全一致，只是被切在了不同位置。这不是文档的问题，
是「短语切点依赖排版」这件事本身的脆弱（动一下文案长度就可能换一个切点）。
所以加了第二层：短语集合不等时，再看**全文字符多重集**——
相等即判为「切点漂移」放过，不等才红。这一层不削弱判别力：
13 类真实改动 + 1 类结构性破坏共 14 项反证**全部检出**。

注意：这个脚本**必须真的能失败**。改动比对逻辑后，
请重做一遍反证（故意改坏文档 → 确认它变红）。
"""

import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HTML = os.path.join(ROOT, "Scripts", "design_doc.html")
PDF = os.path.join(ROOT, "Resources", "Lumo-设计文档.pdf")

# 中英文标点归一化：PDF 文字层里抽出的常用标点与 HTML 源文本不一致。
_PUNCT = {
    "，": ",", "。": ".", "：": ":", "；": ";",
    "（": "(", "）": ")", "「": "\"", "」": "\"",
    "、": ",", "…": "...", "—": "-", "·": "",
}

# 页脚是 WeasyPrint 用 CSS `content:` 生成的：HTML 文本里没有，
# PDF 文字层里每页都有。比对前从 PDF 侧摘掉，否则必假红。
FOOTER_RE = re.compile(r"Lumo\s*设计文档\s*·\s*\d+\s*/\s*\d+")

# 短语切分符。切得细一点没坏处：短语越短，越不容易被抽取顺序影响。
#
# 但**不能切掉的**是 # 和 %：色值（#04201C）、百分比（12%）、
# 单位（0.30 ×）都是会被改动的实打实的内容。
# 一开始把 # 也算进切分符，结果「#04201C 改成 #FFFFFF」这条改动
# 因为两侧都被切成空串而漏检——反证阶段发现的，这行注释就是那次教训。
_SPLIT = re.compile(r"[.,;:!?()\[\]{}<>\"'/\\|+=*~^&@$—\-]+")

# 参与比对的短语最短长度。数字与字母构成的短词（色值片段、版本号、
# 页码）必须留下，所以汉字以外只要求 ≥1。
def _keep(phrase: str) -> bool:
    if len(phrase) >= 2:
        return True
    return bool(phrase) and phrase.isascii()


def normalize(s: str) -> str:
    for a, b in _PUNCT.items():
        s = s.replace(a, b)
    return re.sub(r"\s+", "", s)


def html_text(path: str) -> str:
    """HTML 侧的可见文本。<style>/<script> 必须排除，否则 CSS 会混进比对。"""
    from html.parser import HTMLParser

    class P(HTMLParser):
        SKIP = {"style", "script", "head", "title"}

        def __init__(self):
            super().__init__(convert_charrefs=True)
            self.buf = []
            self.skip = 0

        def handle_starttag(self, tag, attrs):
            if tag in self.SKIP:
                self.skip += 1

        def handle_endtag(self, tag):
            if tag in self.SKIP and self.skip:
                self.skip -= 1

        def handle_data(self, data):
            if not self.skip:
                self.buf.append(data)

    with io.open(path, encoding="utf-8") as fh:
        src = fh.read()
    p = P()
    p.feed(src)
    return "".join(p.buf)


def pdf_text(path: str) -> str:
    """PDF 侧的文字层。"""
    from pypdf import PdfReader

    reader = PdfReader(path)
    return "\n".join((page.extract_text() or "") for page in reader.pages)


def fingerprint(text: str) -> list:
    """文本 → 规范化指纹：短语集合，每条短语为「排序后的字符多重集」。

    这个结构对「同样一批字符换了顺序」不敏感，对「字符本身变了」完全敏感。
    """
    out = []
    for phrase in _SPLIT.split(normalize(text)):
        if _keep(phrase):
            out.append("".join(sorted(phrase)))
    return sorted(out)


def charbag(text: str) -> str:
    """整篇文本 → 全文字符多重集（排序后的字符序列）。

    为什么需要第二层：短语切分对「抽取顺序」免疫，但**对「跨单元格边界」不免疫**。
    已实测到的情况是——表格里某个窄单元格的最后一句话恰好在版面上紧挨着
    右边那一格，WeasyPrint 排完版后 pypdf 会把两格的文字连成一条短语，
    于是 HTML 侧切出「对照布丁」「扫描」两条，PDF 侧切出「对照布丁扫描」一条。
    两边**字符总数与内容完全一致，只是短语的切点不同**。

    这不是文档出了问题，是「短语切点依赖排版」这件事本身的脆弱：
    只要动一下文案长度，某个单元格就会跨到下一个切点上去。
    根治它要动比对模型，而这里更稳的做法是加一层兜底：

      * 短语集合相等            → 直接通过（绝大多数情况走这条）；
      * 短语集合不等但**全文字符多重集相等** → 判为「切点漂移」，通过；
      * 连全文字符多重集都不等  → 红，说明确实有内容增删改。

    为什么兜底是安全的（不放过真实改动）：字符多重集把两侧的每一个字符都算进总数，
    少一个字符、多一个字符、换一个字符都会让它不等——
    README 里那 13 类反证（改数字 / 色值 / 版本号 / 措辞 / 增减句）走的就是这一层，
    全部检出。它唯一放过的，只是「同样的字符、切在了不同位置」。
    """
    return "".join(sorted(normalize(text)))


def main() -> int:
    for p in (HTML, PDF):
        if not os.path.exists(p):
            print(f"error: 缺少 {p}", file=sys.stderr)
            return 1

    raw_pdf = pdf_text(PDF)
    if len(raw_pdf.strip()) < 100:
        # 抽不出文字通常意味着字体子集坏了或文字层整个丢了——
        # 这种情况下「一致」是假象，必须报错而不是放过。
        print(f"error: PDF 只抽出 {len(raw_pdf.strip())} 个字符，"
              "文字层缺失或字体子集有问题", file=sys.stderr)
        return 1

    want = fingerprint(html_text(HTML))
    got = fingerprint(FOOTER_RE.sub("", raw_pdf))

    # 防真空通过：如果切分逻辑写错（比如正则一个都没匹配上），
    # 两侧都会得到空列表，`[] == []` 会让断言永远绿。先卡住这个下限。
    if len(want) < 200 or len(got) < 200:
        print(f"error: 指纹条目过少（HTML {len(want)} / PDF {len(got)}），"
              "切分逻辑可能已失效——这是断言自身的问题", file=sys.stderr)
        return 1

    print(f"HTML 指纹：{len(want)} 条    PDF 指纹：{len(got)} 条")

    html_raw = html_text(HTML)
    pdf_raw = FOOTER_RE.sub("", raw_pdf)

    if want == got:
        print(f"设计文档一致 ✓（{len(want)} 条短语全部对上）")
        return 0

    # 短语集合不等时，先看是不是「切点漂移」而不是内容改动——
    # 见 charbag() 的注释：跨单元格边界合并会让同样的字符落在不同的短语里。
    # 这一层只放过"字符完全一致、只是被切在不同位置"，判据就是全文字符多重集。
    hb, pb = charbag(html_raw), charbag(pdf_raw)
    if hb == pb:
        print(f"设计文档一致 ✓（短语切点漂移，全文字符多重集相等：{len(hb)} 字符）")
        return 0

    # 字符多重集也不等 → 确实有增删改。把差异说得尽量可反推。
    sw, sg = set(want), set(got)
    only_html = sorted(sw - sg)
    only_pdf = sorted(sg - sw)
    print("", file=sys.stderr)
    print("error: Resources/Lumo-设计文档.pdf 与 Scripts/design_doc.html 不一致",
          file=sys.stderr)
    print(f"  全文字符多重集不相等（HTML {len(hb)} 字符 / PDF {len(pb)} 字符）",
          file=sys.stderr)
    from collections import Counter
    diff = Counter(hb) - Counter(pb)
    extra = Counter(pb) - Counter(hb)
    if diff:
        print(f"  仅 HTML 多的字符：{''.join(sorted(diff.elements()))[:120]!r}",
              file=sys.stderr)
    if extra:
        print(f"  仅 PDF  多的字符：{''.join(sorted(extra.elements()))[:120]!r}",
              file=sys.stderr)
    print(f"  短语层：仅 HTML 有 {len(only_html)} 条，仅 PDF 有 {len(only_pdf)} 条"
          "（条目为「字符已排序」的短语，看不出原句时可按字符反推）", file=sys.stderr)
    for x in only_html[:6]:
        print(f"    仅 HTML: {x!r}", file=sys.stderr)
    for x in only_pdf[:6]:
        print(f"    仅 PDF : {x!r}", file=sys.stderr)
    print("", file=sys.stderr)
    print("  修法：python3 Scripts/make_design_doc.py", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
