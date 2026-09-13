#!/usr/bin/env python3
"""生成随 App 一起发布的「示例扫描件」。

这份文件的作用是让用户第一次打开 Lumo 就能立刻试一遍完整流程，
而不必先去找一份自己的扫描件。所以它必须**真的像扫描件**：
有倾斜、有光照不匀、有噪点、有 JPEG  artifact——干干净净的合成图
跑出来的效果没有说服力（会让人以为压缩率是我们吹的）。

生成结果直接以 DCTDecode 流写进 PDF，不经任何第三方库，
和 Lumo 自己写 PDF 的思路一致：编码什么就是什么。
"""
import io
import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources", "示例扫描件.pdf")

DPI = 150
W = int(8.27 * DPI)      # A4
H = int(11.69 * DPI)

SANS = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"
SERIF = "/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc"
BOLD = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"


def font(path, size):
    try:
        return ImageFont.truetype(path, size)
    except Exception:
        return ImageFont.load_default()


def new_page():
    img = Image.new("RGB", (W, H), (252, 251, 248))
    return img, ImageDraw.Draw(img)


def wrap(draw, text, f, max_w):
    """按像素宽度折行（中文没有空格，必须逐字量）"""
    lines, cur = [], ""
    for ch in text:
        if ch == "\n":
            lines.append(cur)
            cur = ""
            continue
        trial = cur + ch
        if draw.textlength(trial, font=f) > max_w and cur:
            lines.append(cur)
            cur = ch
        else:
            cur = trial
    if cur:
        lines.append(cur)
    return lines


def paragraph(draw, text, xy, f, fill, max_w, leading):
    x, y = xy
    for ln in wrap(draw, text, f, max_w):
        draw.text((x, y), ln, font=f, fill=fill)
        y += leading
    return y


# MARK: - 三页内容

def page_text_scan():
    """第 1 页：普通中文文档，轻微倾斜 + 光照渐变 + 噪点"""
    img, d = new_page()
    m = int(0.72 * DPI)
    title = font(BOLD, 40)
    body = font(SERIF, 27)
    foot = font(SANS, 20)

    d.text((m, m), "扫描件数字化处理说明", font=title, fill=(24, 26, 30))
    d.line([(m, m + 62), (W - m, m + 62)], fill=(120, 126, 134), width=3)

    y = m + 110
    paras = [
        "纸质文档在扫描或拍照时，几乎不可避免地会带上一系列瑕疵：进纸机构造成的整体倾斜、"
        "光源位置造成的明暗不匀、纸张老化带来的底灰与黄斑、印刷品本身的半调网纹，"
        "以及为了节省存储而被有损压缩过的 JPEG 噪点。",
        "这些瑕疵对人眼的干扰有限，但对后续的文本识别与压缩影响很大。"
        "倾斜会让 OCR 的行切分失准；明暗不匀会让二值化阈值在页面上左右为难，"
        "一边丢字一边留黑；底灰和网纹则会被压缩器当成真实细节认真保存下来，"
        "让最终文件体积成倍膨胀。",
        "因此，扫描件处理的第一步永远是「读懂这一页到底脏在哪」，"
        "而不是把全部滤镜挨个开一遍。开错的滤镜比不开更糟："
        "它带来的损伤是不可逆的，而用户往往要到最后一步才发现。",
        "本页刻意保留了轻度倾斜与光照渐变，用来演示 Lumo 的自动增强效果。",
    ]
    for p in paras:
        y = paragraph(d, p, (m, y), body, (32, 34, 38), W - 2 * m, 46) + 26

    d.text((m, H - m - 24), "示例扫描件 · 第 1 页 · 由 Lumo 生成", font=foot, fill=(140, 145, 152))
    return img, dict(tilt=0.9, shade=0.13, noise=6, jpeg=80)


def page_dark_scan():
    """第 2 页：底灰重、右下有明显阴影的黑白文档 → 黑白档的主场"""
    img, d = new_page()
    # 先铺一层底灰：这一页整体发暗、发黄
    base = Image.new("RGB", (W, H), (214, 208, 196))
    img.paste(base)
    d = ImageDraw.Draw(img)

    m = int(0.72 * DPI)
    title = font(BOLD, 38)
    body = font(SERIF, 26)

    d.text((m, m), "设备巡检记录（节选）", font=title, fill=(38, 38, 40))
    d.line([(m, m + 58), (W - m, m + 58)], fill=(90, 90, 92), width=2)

    y = m + 96
    rows = [
        "一、巡检范围：生产车间全部在用设备，共 42 台，其中关键设备 11 台。",
        "二、巡检周期：日常点检每班一次，专业点检每周一次，精密点检每季度一次。",
        "三、记录要求：逐台填写运行参数，异常项须当场拍照并在备注栏注明。",
        "四、问题闭环：发现的问题按 A/B/C 三级分类，A 类 24 小时内处理。",
        "五、交接班：未完成项必须书面交接，口头交接不作为有效凭据。",
        "六、归档：巡检记录按月装订，保存期限不少于三年。",
    ]
    for r in rows:
        y = paragraph(d, r, (m, y), body, (46, 46, 48), W - 2 * m, 44) + 22

    y += 30
    head = font(BOLD, 26)
    d.text((m, y), "编号      设备名称            状态      责任人", font=head, fill=(30, 30, 32))
    y += 44
    for i in range(1, 11):
        d.text((m, y), f"A-{i:03d}     输送机组 {i:02d} 号       正常      张{i:02d}",
               font=body, fill=(52, 52, 54))
        y += 40

    d.text((m, H - m - 24), "示例扫描件 · 第 2 页 · 底灰与阴影示例", font=font(SANS, 20),
           fill=(120, 118, 112))
    return img, dict(tilt=-1.6, shade=0.30, noise=11, jpeg=72)


def page_color_scan():
    """第 3 页：彩色（蓝色标题 + 红色印章 + 色块表格）→ 增强档与分层压缩的主场"""
    img, d = new_page()
    m = int(0.72 * DPI)
    title = font(BOLD, 42)
    body = font(SERIF, 26)
    small = font(SANS, 21)

    d.rectangle([(m, m), (W - m, m + 74)], fill=(23, 92, 168))
    d.text((m + 22, m + 18), "项目验收单", font=title, fill=(255, 255, 255))

    y = m + 118
    y = paragraph(d, "本页包含彩色元素：蓝色页眉、红色印章与三色状态栏。"
                     "这类页面一旦被二值化，颜色信息就永久丢失了，"
                     "所以 Lumo 对含彩色的页面一律走增强档，而不是压成黑白。",
                  (m, y), body, (32, 34, 38), W - 2 * m, 44) + 30

    # 三色状态栏
    bar_y = y
    cols = [("已完成", (34, 152, 96)), ("进行中", (226, 162, 32)), ("未开始", (180, 186, 194))]
    bw = (W - 2 * m) // 3
    for i, (txt, col) in enumerate(cols):
        x0 = m + i * bw
        d.rectangle([(x0, bar_y), (x0 + bw - 14, bar_y + 62)], fill=col)
        d.text((x0 + 20, bar_y + 16), txt, font=font(BOLD, 26), fill=(255, 255, 255))
    y = bar_y + 92

    y = paragraph(d, "验收结论：全部 11 项关键指标达标，其中 3 项优于合同要求。"
                     "遗留问题 2 项，已列入二期整改计划，不影响本次验收。",
                  (m, y), body, (32, 34, 38), W - 2 * m, 44) + 40

    # 红色印章
    cx, cy = W - m - 190, y + 120
    d.ellipse([(cx - 120, cy - 120), (cx + 120, cy + 120)], outline=(196, 42, 42), width=9)
    d.ellipse([(cx - 96, cy - 96), (cx + 96, cy + 96)], outline=(196, 42, 42), width=3)
    d.text((cx - 62, cy - 30), "验收专用章", font=font(BOLD, 34), fill=(196, 42, 42))
    d.text((cx - 40, cy + 26), "已核验", font=small, fill=(196, 42, 42))

    d.text((m, H - m - 24), "示例扫描件 · 第 3 页 · 彩色与印章示例", font=small, fill=(140, 145, 152))
    return img, dict(tilt=0.5, shade=0.18, noise=7, jpeg=78)


# MARK: - 扫描退化

def degrade(img, tilt, shade, noise, seed=7):
    rnd = random.Random(seed)

    # 1) 光照：左上亮右下暗，再叠一点大尺度起伏（模拟翻页时纸的弯曲）
    px = img.load()
    for yy in range(H):
        fy = yy / H
        for xx in range(W):
            fx = xx / W
            k = 1.0 - shade * (0.55 * fx + 0.45 * fy) \
                - 0.05 * shade * math.sin(fx * 5.1 + 0.7) * math.cos(fy * 4.3)
            r, g, b = px[xx, yy]
            px[xx, yy] = (max(0, min(255, int(r * k))),
                          max(0, min(255, int(g * k))),
                          max(0, min(255, int(b * k - shade * 6))))

    # 2) 轻微失焦：扫描仪/手机对焦都不是完美的
    img = img.filter(ImageFilter.GaussianBlur(radius=0.7))

    # 3) 噪点
    if noise:
        px = img.load()
        for yy in range(0, H, 1):
            for xx in range(0, W, 1):
                n = rnd.randint(-noise, noise)
                r, g, b = px[xx, yy]
                px[xx, yy] = (max(0, min(255, r + n)),
                              max(0, min(255, g + n)),
                              max(0, min(255, b + n)))

    # 4) 整体倾斜
    if abs(tilt) > 0.01:
        img = img.rotate(tilt, resample=Image.BICUBIC, expand=False,
                         fillcolor=(250, 249, 246))
    return img


def to_jpeg(img, quality):
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=quality, optimize=True, subsampling=1)
    return buf.getvalue()


# MARK: - 写 PDF（DCTDecode 直嵌）

def write_pdf(jpegs, sizes, path, dpi=DPI, title="Lumo 示例扫描件"):
    # 对象编号是 1 起的：1 Catalog / 2 Pages / 3 Info，之后每页 3 个（页 / 内容 / 图）
    n = len(jpegs)
    objs = [b""] * (3 + 3 * n)

    def ref(no):
        return str(no).encode() + b" 0 R"

    def page_no(i):
        return 4 + 3 * i

    # PDF 字符串字面量只认 PDFDocEncoding（基本等于 Latin-1），中文必须走十六进制
    # 的 UTF-16BE（带 BOM），否则标题会变成乱码
    def pdf_text(s):
        return b"<FEFF" + s.encode("utf-16-be").hex().upper().encode() + b">"

    kids = b" ".join(ref(page_no(i)) for i in range(n))
    objs[0] = b"<< /Type /Catalog /Pages 2 0 R >>"
    objs[1] = b"<< /Type /Pages /Kids [" + kids + b"] /Count " + str(n).encode() + b" >>"
    objs[2] = (b"<< /Producer (Lumo sample generator) /Title " + pdf_text(title) + b" >>")

    for i, (jp, (w, h)) in enumerate(zip(jpegs, sizes)):
        pn = page_no(i)
        pw = w * 72.0 / dpi
        ph = h * 72.0 / dpi
        objs[pn - 1] = (
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 "
            + ("%.2f %.2f" % (pw, ph)).encode()
            + b"] /Resources << /XObject << /Im0 " + ref(pn + 2) + b" >> >> /Contents "
            + ref(pn + 1) + b" >>"
        )
        cs = ("q\n%.2f 0 0 %.2f 0 0 cm\n/Im0 Do\nQ\n" % (pw, ph)).encode()
        objs[pn] = (b"<< /Length " + str(len(cs)).encode() + b" >>\nstream\n"
                    + cs + b"endstream")
        objs[pn + 1] = (
            b"<< /Type /XObject /Subtype /Image /Width " + str(w).encode()
            + b" /Height " + str(h).encode()
            + b" /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length "
            + str(len(jp)).encode() + b" >>\nstream\n" + jp + b"\nendstream"
        )

    out = bytearray()
    out += b"%PDF-1.7\n%\xE2\xE3\xCF\xD3\n"
    offsets = []
    for i, body in enumerate(objs):
        offsets.append(len(out))
        out += str(i + 1).encode() + b" 0 obj\n" + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 " + str(len(objs) + 1).encode() + b"\n"
    out += b"0000000000 65535 f \n"
    for off in offsets:
        out += ("%010d 00000 n \n" % off).encode()
    out += (b"trailer\n<< /Size " + str(len(objs) + 1).encode()
            + b" /Root 1 0 R /Info 3 0 R >>\nstartxref\n"
            + str(xref).encode() + b"\n%%EOF\n")

    with open(path, "wb") as f:
        f.write(bytes(out))
    return len(out)


def main():
    pages = [page_text_scan(), page_dark_scan(), page_color_scan()]
    jpegs, sizes = [], []
    for i, (img, cfg) in enumerate(pages):
        cfg = dict(cfg)
        quality = cfg.pop("jpeg")
        img = degrade(img, seed=11 + i, **cfg)
        jpegs.append(to_jpeg(img, quality))
        sizes.append(img.size)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    size = write_pdf(jpegs, sizes, OUT)
    print("生成 %s：%d 页，%d 字节（%.0f KB）" % (OUT, len(jpegs), size, size / 1024))


if __name__ == "__main__":
    sys.exit(main())
