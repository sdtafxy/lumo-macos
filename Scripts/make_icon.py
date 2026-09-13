#!/usr/bin/env python3
"""生成 Lumo.icns。

为什么不借助 iconutil：CI 上没有素材、也不想为一个图标引入额外工具链。
ICNS 的容器格式本身极简（magic + 总长 + 若干 [type,len,data] 条目），
macOS 10.7+ 起所有条目都可以直接放 PNG，所以这里用 Pillow 画完再手写字节。

**这个脚本的唯一基准是 App 侧边栏左上角的那个 Logo**（LumoApp/Views.swift
的 SidebarView）：青绿渐变圆角方块 + 居中一颗深墨绿的四角星芒。

为什么非要跟那个小图标对齐：用户桌面上看到的是 .icns，打开 App 第一眼看到的是
侧边栏那个小方块，两者不一致就等于"这个 App 有两个 logo"。
之前就是这么错的——.icns 画的是「白色文档 + 折角 + 压角白星芒」，
而 App 里是「深墨绿星芒居中」，六项参数（圆角比 / 渐变方向 / 渐变色 /
星芒颜色 / 星芒大小 / 有无文档图形）没有一项对得上。
现在把所有参数都写成下面这组常量，改一处两边一起改。

（App 内的 ✦ 是 U+2726 BLACK FOUR POINTED STAR，标准字形就是四角、
凹边、内顶点落在 45° 方向——和下面 star() 画出来的完全同构，
所以「字符」和「手绘多边形」这两个实现能长得一样。）
"""
import os
import struct
import sys

from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(__file__), "..", "Resources", "Lumo.icns")

# ---- 唯一基准：App 侧边栏 Logo 的参数（改这里，两边一起变） ----
# 渐变：LumoDesign.primary -> 0x34D399，方向 topLeading -> bottomTrailing
GRAD_START = (0x14, 0xB8, 0xA6)   # #14B8A6 primary
GRAD_END = (0x34, 0xD3, 0x99)     # #34D399
STAR_INK = (0x04, 0x20, 0x1C)     # #04201C 深墨绿（App 里 ✦ 的 foregroundColor）

# 圆角比：App 是 12/40 = 0.30。macOS 图标习惯留出边距，
# 但这里要的是"和 App 里那个方块看起来是同一个东西"，所以照搬 0.30。
CORNER_RATIO = 0.30
# 星芒占方块的比例（外顶点半径 / 方块边长）。
# App 里方块 40pt、✦ 字号 20pt，字面墨迹直径约等于字号即 20pt，
# 占方块的 0.50 -> 半径占比 0.25。图标四周还要留一点呼吸感，取 0.28。
# （一开始写的 0.36 直径占到 72%，星芒顶到边缘，明显比 App 里"重"。）
STAR_RATIO = 0.28
# 内顶点 / 外顶点。✦ 的字形凹得比较深，0.30 比默认的 1/√2(0.707) 更接近。
STAR_INNER_RATIO = 0.30

S = 1024  # 设计稿基准尺寸


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def star(cx, cy, R, r):
    """四角星芒：外顶点 R，内顶点 r，内顶点落在 45° 方向（故乘 1/√2 投影）。

    这就是 U+2726 ✦ 的标准字形构造——四个尖角分别指向正上/右/下/左，
    四个内凹点落在对角线上。
    """
    k = 0.70710678
    p = [
        (cx, cy - R), (cx + r * k, cy - r * k), (cx + R, cy), (cx + r * k, cy + r * k),
        (cx, cy + R), (cx - r * k, cy + r * k), (cx - R, cy), (cx - r * k, cy - r * k),
    ]
    return [(round(x), round(y)) for x, y in p]


def draw(size: int) -> Image.Image:
    f = size / S  # 所有坐标按 1024 设计稿缩放
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    radius = int(round(S * CORNER_RATIO * f))

    # 1) 底板：圆角矩形 + 对角渐变。
    #    注意渐变方向是「左上 -> 右下」，不是竖向——
    #    竖向渐变会让图标边缘发暗，跟 App 里那个方块的观感完全不同（踩过）。
    #
    #    实现上不用逐像素 point()（1024² 要跑 100 万次，慢到没法忍受），
    #    改成先造一张小的对角渐变再放大——渐变本身是平滑的，
    #    放大不会引入阶梯；圆角由 mask 保证锐利，两者分开处理。
    bg = Image.new("L", (size, size), 0)
    bgd = ImageDraw.Draw(bg)
    bgd.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    gsmall = Image.new("RGB", (256, 256))
    gp = gsmall.load()
    for y in range(256):
        for x in range(256):
            gp[x, y] = lerp(GRAD_START, GRAD_END, (x + y) / 510.0)
    grad = gsmall.resize((size, size), Image.BILINEAR).convert("RGBA")
    img.paste(grad, (0, 0), bg)

    # 2) 星芒：居中、深墨绿。App 里是 Text("✦") 居中放在方块正中，
    #    图标这里必须一样——之前把星芒压到右上折角上，才是"看起来不像"的主因。
    R = S * STAR_RATIO
    r = R * STAR_INNER_RATIO
    d.polygon([(int(round(x * f)), int(round(y * f))) for x, y in star(S / 2, S / 2, R, r)],
              fill=STAR_INK + (255,))

    # bg 是 L 模式的圆角 mask，直接当 alpha 用
    img.putalpha(bg)
    return img


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

    # 设计规范：中心像素应是星芒墨色，四角应是透明的（圆角留白）。
    # 这两条一卡，渐变方向错了、星芒跑到角上、忘了挖圆角，都会当场失败。
    big = Image.open(io.BytesIO(dict(seen)[b"ic10"])).convert("RGBA")
    W, _ = big.size
    # 星芒是居中多边形，取正中心一小块的平均色来判，避免抗锯齿边缘干扰
    cx = W // 2
    patch = [big.getpixel((cx + dx, cx + dy))
             for dx in range(-W // 40, W // 40)
             for dy in range(-W // 40, W // 40)]
    avg = tuple(sum(c[i] for c in patch) // len(patch) for i in range(4))
    ck(abs(avg[0] - STAR_INK[0]) <= 12
       and abs(avg[1] - STAR_INK[1]) <= 12
       and abs(avg[2] - STAR_INK[2]) <= 12,
       f"中心是深墨绿星芒（实测 RGB{avg[:3]}，期望 {STAR_INK}）")
    ck(avg[3] > 250, f"中心不透明（alpha={avg[3]}）")

    corner = big.getpixel((0, 0))
    ck(corner[3] == 0, f"左上角透明（圆角生效，alpha={corner[3]}）")

    # 渐变方向：左上应比右下暗（#14B8A6 比 #34D399 暗）。
    # 竖向渐变也会「上暗下亮」，所以顺带比一下左下与右上：
    # 真对角渐变下这两处的亮度应当接近，竖向渐变则会明显不同。
    def lum(p):
        return 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]

    q = W // 4
    tl = big.getpixel((q, q))
    br = big.getpixel((W - q, W - q))
    bl = big.getpixel((q, W - q))
    tr = big.getpixel((W - q, q))
    ck(lum(tl) < lum(br), f"左上比右下暗，说明是左上→右下渐变（{lum(tl):.0f} < {lum(br):.0f}）")
    ck(abs(lum(bl) - lum(tr)) < abs(lum(tl) - lum(br)),
       f"左下与右上亮度接近（{lum(bl):.0f} vs {lum(tr):.0f}），确认是对角而非竖向渐变")

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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
