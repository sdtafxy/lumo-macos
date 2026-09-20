#!/usr/bin/env python3
"""生成 Lumo.icns 与 docs/logo.png。

为什么不用 iconutil：CI 上没有素材、也不想为一个图标引入额外工具链。
ICNS 的容器格式本身极简（magic + 总长 + 若干 [type,len,data] 条目），
macOS 10.7+ 起所有条目都可以直接放 PNG，所以这里用 Pillow 画完再手写字节。

**这个脚本与 App 共用一组常量**：`Sources/LumoApp/Design.swift` 里的
`LumoDesign.LumoMark` 是唯一基准，下面这些数字照着它写，两边文件头互相注明。
改一处就要改两处——这不是建议，是规范；否则用户桌面上看到一个 logo、
打开 App 又看到另一个，就不是同一个产品了。

两处产出的差别只有**画布形状**：
  · `Resources/Lumo.icns`：正方形（macOS 的图标槽位就是正方形，非正方会被
    Dock 拉变形）——这是**平台约束**，不是设计选择；
  · `docs/logo.png`：竖版 1 : 1.30，与 App 里显示的那个完全同形。
除画布比例外，渐变、圆角、星芒的位置与大小全部同一组数。

标识的构图（一页纸 + 一束光，星芒在左上、右下的留白是有意的）见
`Design.swift` 里那段注释——那里有完整的"为什么"。
"""
import os
import struct
import sys

from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(__file__), "..", "Resources", "Lumo.icns")
DOCS_LOGO = os.path.join(os.path.dirname(__file__), "..", "docs", "logo.png")

# ---- 唯一基准：与 LumoDesign.LumoMark 逐项对应（改这里，两边一起变） ----
GRAD_START = (0x14, 0xB8, 0xA6)   # #14B8A6 accent
GRAD_END   = (0x34, 0xD3, 0x99)   # #34D399
STAR_FILL  = (0xFF, 0xFF, 0xFF)   # #FFFFFF emblemStar 纯白

CORNER_RATIO = 0.26        # 圆角 / 边长
STAR_SIZE_RATIO = 0.28     # 星芒边长 / 边长（**高宽同值 = 正四角，不拉长**）
STAR_INSET_L = 0.13        # 星芒左留白 / 边长（比右侧小得多：偏移是构图的一部分）
STAR_INNER_RATIO = 0.30    # 内顶点 / 外顶点

# 注意这里**没有**"纵向拉长"这个旋钮，也**没有**上留白：
# 星芒是正四角（高=宽），垂直位置由几何推出来（居中）。
# 曾经的深墨绿 + 纵向拉长 2.00 + 偏在左上角，读起来像"一张脸上一道疤"，
# 三样一起改掉之后既不像疤、重心也正了。

# 画布一律**正方形**：图标、欢迎页、关于页、README 里的 logo 是同一份几何。
# （曾经把底座做成竖版过，代价是同一个标识在桌面和窗口里是两种形状——
#   又回到"这个 App 有两个 logo"。方形底座把这个解释成本直接消掉。）
S = 1024  # 设计稿基准尺寸



def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def star_pts(cx, cy, rx, ry, inner=STAR_INNER_RATIO):
    """四角星芒：横竖两个方向的半径**分开**给。

    「纵向拉长」不能靠把字形拉一下缩放——那会让竖着的两笔跟着变粗、
    四个尖一起钝掉（Pillow 里反过来也一样）。手绘多边形才能让"细长"是真的细长。

    构造：四个外顶点指向正上 / 右 / 下 / 左，四个内凹点落在对角线上
    （所以横竖各乘 1/√2 投影）。与 Swift 侧 `LumoStar` 的路径完全同构。
    """
    k = 0.70710678
    ix, iy = rx * inner * k, ry * inner * k
    p = [(cx, cy - ry), (cx + ix, cy - iy), (cx + rx, cy), (cx + ix, cy + iy),
         (cx, cy + ry), (cx - ix, cy + iy), (cx - rx, cy), (cx - ix, cy - iy)]
    return [(round(x), round(y)) for x, y in p]


def star_box(unit: float):
    """星芒的包围盒 (x, y, w, h)，全部按给定"边长基准"取比例。

    · 高 = 宽 → **正四角星**，不拉长；
    · 纵向居中由几何推出来（`(unit - w) / 2`）而不是一个独立的常量——
      这样"不拉长"和"纵向居中"就不可能只改一半。

    ★ 统一用 `unit` 这一个量做基准（而不是宽用一个、高用另一个），
      所以任何尺寸、任何画布比例下构图都不会走样。
    """
    w = unit * STAR_SIZE_RATIO
    return unit * STAR_INSET_L, (unit - w) / 2, w, w


def diagonal_gradient(w: int, h: int) -> Image.Image:
    """左上 → 右下的对角渐变，与 App 的 LinearGradient(topLeading→bottomTrailing) 一致。

    ⚠️ 必须是**对角**，不能图省事改成竖向：竖向渐变会让左右两侧亮度不同，
    和 App 里那个方块一眼就不是一件东西（历史上这么错过一次）。
    1024² 逐像素算要跑一百万次，慢到不能忍；先造 256² 再放大——
    渐变本身是平滑的，放大不引入阶梯，锐利的地方由圆角 mask 负责。
    """
    g = Image.new("RGB", (256, 256))
    gp = g.load()
    for y in range(256):
        for x in range(256):
            gp[x, y] = lerp(GRAD_START, GRAD_END, (x + y) / 510.0)
    return g.resize((w, h), Image.BILINEAR).convert("RGBA")


def draw(size: int) -> Image.Image:
    """方形图标（.icns 的每一档）。星芒位置与比例和竖版标记完全一致。"""
    radius = int(round(size * CORNER_RATIO))
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)

    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    img.paste(diagonal_gradient(size, size), (0, 0), mask)

    x, y, w, h = star_box(size)
    ImageDraw.Draw(img).polygon(star_pts(x + w / 2, y + h / 2, w / 2, h / 2),
                                fill=STAR_FILL + (255,))
    img.putalpha(mask)   # mask 是 L 模式的圆角形状，直接当 alpha
    return img


def draw_mark(width: int) -> Image.Image:
    """画**竖版标识**（与 App 里显示的完全同形，也是 README 顶部那个 logo）。

    为什么 README 的 logo 不直接截 App 的图：那样每改一次品牌参数就要记得重截一次，
    迟早对不上。同一个脚本、同一组常量、**同一个画布形状**，就不存在"两处各长各的"。
    """
    h = width
    radius = int(round(width * CORNER_RATIO))
    mask = Image.new("L", (width, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, width - 1, h - 1], radius=radius, fill=255)

    img = Image.new("RGBA", (width, h), (0, 0, 0, 0))
    img.paste(diagonal_gradient(width, h), (0, 0), mask)

    x, y, w, hh = star_box(width)
    ImageDraw.Draw(img).polygon(star_pts(x + w / 2, y + hh / 2, w / 2, hh / 2),
                                fill=STAR_FILL + (255,))
    img.putalpha(mask)
    return img


def write_mark(out_path: str, width: int = 512) -> None:
    img = draw_mark(width)
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    img.save(out_path, format="PNG", optimize=True)
    print(f"wrote {out_path} ({img.width}x{img.height})")


def png_bytes(size: int) -> bytes:
    import io
    buf = io.BytesIO()
    draw(size).save(buf, format="PNG", optimize=True)
    return buf.getvalue()


# 期望的 ICNS 条目：(类型, 像素边长)
EXPECTED = [
    (b"ic07", 128), (b"ic08", 256), (b"ic09", 512), (b"ic10", 1024),
    (b"ic11", 32), (b"ic12", 64), (b"ic13", 256), (b"ic14", 512),
    (b"icp4", 16), (b"icp5", 32), (b"icp6", 64),
]


def verify(path: str) -> int:
    """独立解析生成的 icns，确认容器结构与设计规范。

    为什么要有这一步：图标这种「看一眼就知道对不对」的东西，
    恰恰最容易在改动中被悄悄改坏而没人发现——用户这次反馈的第 1 条
    就是这么积累出来的。CI 里跑一遍相当于把「看一眼」固化成机器动作。

    注意这里是**独立解析字节**（自己拆 TLV），不走 Pillow 的 icns 读取，
    否则就变成「用生成器验证自己的输出」，看不出容器层面的问题。
    """
    import io
    from PIL import Image

    with open(path, "rb") as fh:
        raw = fh.read()

    bad = 0

    def ck(cond, msg):
        nonlocal bad
        print(("  ✓ " if cond else "  ✗ ") + msg)
        if not cond:
            bad += 1

    ck(raw[:4] == b"icns", "magic 是 'icns'")
    declared = struct.unpack(">I", raw[4:8])[0]
    ck(declared == len(raw), f"文件头声明的总长({declared}) 等于实际长度({len(raw)})")

    # 逐条拆 TLV，长度字段必须自洽且不能越界
    off, seen = 8, []
    while off < len(raw):
        if off + 8 > len(raw):
            ck(False, f"偏移 {off} 处残留 {len(raw) - off} 字节，凑不出下一个条目头")
            break
        t = raw[off:off + 4]
        ln = struct.unpack(">I", raw[off + 4:off + 8])[0]
        if ln < 8 or off + ln > len(raw):
            ck(False, f"条目 {t!r} 声明长度 {ln} 越界")
            break
        seen.append((t, raw[off + 8:off + ln]))
        off += ln
    ck(off == len(raw), "条目长度之和正好铺满整个文件（没有多余或缺失字节）")
    ck(len(seen) == len(EXPECTED), f"条目数 {len(seen)} == {len(EXPECTED)}")

    # 每个条目都得是能解开的 PNG，且边长符合类型约定
    want = dict(EXPECTED)
    sizes = set()
    for t, data in seen:
        try:
            im = Image.open(io.BytesIO(data))
            im.load()
        except Exception as e:                      # noqa: BLE001
            ck(False, f"条目 {t!r} 不是合法 PNG: {e}")
            continue
        w, h = im.size
        sizes.add(w)
        ck(w == h == want.get(t, -1), f"条目 {t.decode()} 是 {w}×{h} 的 PNG")
        ck(im.mode == "RGBA", f"条目 {t.decode()} 带 alpha 通道（mode={im.mode}）")

    # macOS 需要的几档尺寸一个都不能少
    for need in (16, 32, 64, 128, 256, 512, 1024):
        ck(need in sizes, f"覆盖 {need}px 档位")

    # ── 设计规范。这一段每一条都**能失败**，而且都是在真实改动里失败过的方向 ──
    big = Image.open(io.BytesIO(dict(seen)[b"ic10"])).convert("RGBA")
    W, _ = big.size

    def star_bbox(im):
        """扫出**白色**像素的包围盒 —— 星芒实际落在哪、多大。

        注意判据是"接近纯白"而不是"接近某个深色"：星芒从深墨绿改成白色之后，
        这里要是没跟着改，断言会变成"找不到星芒"而红。
        用通道差值 + 阈值做 mask 再 getbbox()，别逐像素跑 Python 循环（1024² 太慢）。
        """
        from PIL import ImageChops
        ref = Image.new("RGB", im.size, STAR_FILL)
        diff = ImageChops.difference(im.convert("RGB"), ref).convert("L")
        hit = diff.point(lambda v: 255 if v <= 30 else 0)
        alpha = im.split()[3].point(lambda v: 255 if v > 200 else 0)
        return ImageChops.multiply(hit, alpha).getbbox()

    def check_star(im, unit, what):
        """星芒的几何：偏左、正四角、纵向居中，以及"它确实不在正中间"。"""
        box = star_bbox(im)
        if box is None:
            ck(False, f"{what}：找不到星芒（画面上没有接近纯白的像素）")
            return
        x0, y0, x1, y1 = box
        bw, bh = x1 - x0, y1 - y0
        ck(abs(x0 - STAR_INSET_L * unit) <= 0.02 * unit,
           f"{what}：星芒左边距 {x0}px（期望 {STAR_INSET_L * unit:.0f}px）—— 偏左")
        ck(abs(bw - bh) <= max(2, 0.02 * unit),
           f"{what}：星芒是正四角（宽 {bw} × 高 {bh}）—— 没有拉长")
        cy = (y0 + y1) / 2
        ck(abs(cy - unit / 2) <= 0.02 * unit,
           f"{what}：星芒纵向居中（中心 {cy:.0f}px，画布中线 {unit / 2:.0f}px）")
        ck(x1 < unit * 0.5,
           f"{what}：星芒没有越过中线（右缘 {x1}px < {unit * 0.5:.0f}px）")
        # ★ 这一条钉住"偏左"这个构图：画面正中必须是渐变，不能是星芒。
        cr, cg, cb, ca = im.getpixel((im.size[0] // 2, im.size[1] // 2))
        is_star = cr > 240 and cg > 240 and cb > 240
        ck(not is_star and ca > 250,
           f"{what}：正中心是渐变而非星芒（实测 RGB{(cr, cg, cb)}）—— 星芒偏左，不在中间")

    check_star(big, W, "Lumo.icns")

    # 圆角：左上角必须透出去
    ck(big.getpixel((0, 0))[3] == 0, "Lumo.icns 左上角透明（圆角生效）")

    # 渐变方向：左上比右下暗；且左下与右上亮度应当接近（说明是**对角**而非竖向）。
    # 采样点刻意避开星芒——它现在压在左上角，老版的采样点会取到墨色上，
    # 于是"渐变对不对"这一条会因为星芒而被误判（这种假红比假绿更浪费时间）。
    def lum(p):
        return 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]

    tl = big.getpixel((int(W * 0.30), int(W * 0.06)))
    br = big.getpixel((int(W * 0.70), int(W * 0.90)))
    bl = big.getpixel((int(W * 0.06), int(W * 0.90)))
    tr = big.getpixel((int(W * 0.90), int(W * 0.06)))
    ck(lum(tl) < lum(br), f"左上比右下暗，说明是左上→右下渐变（{lum(tl):.0f} < {lum(br):.0f}）")
    ck(abs(lum(bl) - lum(tr)) < abs(lum(tl) - lum(br)),
       f"左下与右上亮度接近（{lum(bl):.0f} vs {lum(tr):.0f}），确认是对角而非竖向渐变")

    # README 顶部那个 logo：各自结构都要对。
    # 只查**结构**（比例、星芒位置、圆角），不比字节——
    # 不同 Pillow 版本压出来的 PNG 字节本来就不一样，字节比对会假红。
    if os.path.exists(DOCS_LOGO):
        mark = Image.open(DOCS_LOGO).convert("RGBA")
        w, h = mark.size
        ck(w == h, f"docs/logo.png 是正方形（{w}×{h}）—— 与图标同形")
        check_star(mark, w, "docs/logo.png")
        ck(mark.getpixel((0, 0))[3] == 0, "docs/logo.png 左上角透明（圆角生效）")
    else:
        ck(False, f"docs/logo.png 不存在（跑一次 python3 Scripts/make_icon.py 就有了）")

    print()
    if bad:
        print(f"图标自检失败：{bad} 项不符合预期")
        return 1
    print("图标自检通过 ✓")
    return 0


def build_icns(path: str) -> None:
    # 每项 = 类型 + 长度(含 8 字节头) + 数据；均为 PNG，兼容 macOS 10.7+
    # 条目清单与 verify() 共用 EXPECTED，避免两边各写一份对不上。
    blobs = []
    for t, px in EXPECTED:
        data = png_bytes(px)
        blobs.append(t + struct.pack(">I", len(data) + 8) + data)

    body = b"".join(blobs)
    out = b"icns" + struct.pack(">I", len(body) + 8) + body
    path = os.path.abspath(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(out)
    print(f"wrote {path} ({len(out)} bytes, {len(blobs)} entries)")


def main() -> int:
    args = sys.argv[1:]
    if args and args[0] == "--verify":
        # 不带路径时验证仓库里那份；带路径时验证指定文件。
        return verify(args[1] if len(args) > 1 else OUT)
    build_icns(args[0] if args else OUT)
    # README 顶部的 logo 也在这里产出：它和图标必须来自同一组常量，
    # 否则"改完品牌参数、只更新了一处"这种漂移一定会发生。
    if not args:
        write_mark(DOCS_LOGO)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
