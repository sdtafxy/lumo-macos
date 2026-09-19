// lumo-cli —— Lumo 核心的命令行入口
// 存在的意义有两个：给批处理/自动化留一个无 GUI 的入口；
// 更重要的是 `selftest`：CI 里在真机 macOS 上跑完整条流水线并断言结果，
// 它替我们挡住过「CCITT 出空白页」「纠偏角度符号反了」这类只看体积发现不了的 bug。
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import LumoCore

// MARK: - 自检用的合成扫描件

func drawTextLine(_ ctx: CGContext, _ text: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat) {
    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let key = NSAttributedString.Key(rawValue: kCTFontAttributeName as String)
    let attr = NSAttributedString(string: text, attributes: [key: font])
    let line = CTLineCreateWithAttributedString(attr as CFAttributedString)
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

/// 生成一页「像扫描件」的图：白底 + 若干行英文 + 整体倾斜
func makeScanPage(width: Int, height: Int, tilt: Double, seed: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    let lines = [
        "Lumo scan enhancement self test",
        "Page \(seed + 1) of the synthetic document",
        "The quick brown fox jumps over the lazy dog",
        "Adaptive compression and OCR pipeline",
        "Skew correction removes the scanner tilt",
        "Background removal flattens uneven lighting",
        "Descreen filter kills the halftone pattern",
        "Text sharpening restores the letter edges",
        "Searchable image keeps the invisible layer",
        "Estimated size is sampled not guessed",
        "Lumo sense smart light design philosophy",
        "End of synthetic page number \(seed + 1)",
    ]
    var y = height - 170
    for l in lines {
        drawTextLine(ctx, l, 90, CGFloat(y), 34)
        y -= 82
        if y < 140 { break }
    }
    guard let img = ctx.makeImage() else { return nil }
    guard abs(tilt) > 0.01 else { return img }
    return Enhance.rotated(img, degrees: tilt)
}

func makeScanPDF(at url: URL, dpi: Int = 150, pagePx: (Int, Int) = (1240, 1754)) throws -> Int {
    let tilts = [3.0, -1.5, 0.4]
    var pages: [OutputPage] = []
    for (i, t) in tilts.enumerated() {
        guard let img = makeScanPage(width: pagePx.0, height: pagePx.1, tilt: t, seed: i) else { continue }
        let enc = Compressor.encode(img, CompressSpec(adaptive: false, colorMode: "color",
                                                     colorEncoder: "jpeg", monoEncoder: "ccitt",
                                                     quality: 88))
        pages.append(OutputPage(image: enc, dpi: dpi, lines: nil))
    }
    return try PDFWriter.write(pages: pages, to: url, title: "Lumo selftest")
}

/// 生成一页「像手机拍照扫描」的图：白纸 + 文字 + 光照渐变 + 噪点。
/// 与 makeScanPage 的区别就是它故意不干净——这正是分层压缩（MRC）要解决的那一类输入。
func makePhotoPage(width: Int, height: Int, seed: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1))
    let lines = [
        "Lumo mixed raster content test",
        "Photo-like scan with uneven light",
        "Background keeps only low detail",
        "Text layer stays razor sharp",
        "The quick brown fox jumps over",
        "Adaptive threshold splits them",
        "End of the photo page"
    ]
    var y = height - 240
    for l in lines {
        drawTextLine(ctx, l, 110, CGFloat(y), 46)
        y -= 130
        if y < 280 { break }
    }
    guard let img = ctx.makeImage(), let rgb = rgbSamples(img) else { return nil }
    var bytes = [UInt8](repeating: 255, count: rgb.width * rgb.height * 4)
    var rng: UInt64 = UInt64(seed) &* 2862933555777941757 &+ 3037000493
    for py in 0..<rgb.height {
        let fy = Double(py) / Double(max(1, rgb.height))
        for px in 0..<rgb.width {
            let fx = Double(px) / Double(max(1, rgb.width))
            let shade = 1.0 - 0.20 * fx - 0.14 * fy - 0.08 * fx * fy
            rng = rng &* 2862933555777941757 &+ 3037000493
            let n = Double(Int((rng >> 33) % 25) - 12)
            let i = (py * rgb.width + px) * 4
            let s = (py * rgb.width + px) * 3
            for c in 0..<3 {
                let v = Double(rgb.bytes[s + c]) * shade + n
                bytes[i + c] = UInt8(max(0, min(255, Int(round(v)))))
            }
        }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(width: rgb.width, height: rgb.height, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: rgb.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true,
                   intent: .defaultIntent)
}

func makePhotoPDF(at url: URL, dpi: Int = 200, pagePx: (Int, Int) = (1654, 2339)) throws -> Int {
    var pages: [OutputPage] = []
    for i in 0..<2 {
        guard let img = makePhotoPage(width: pagePx.0, height: pagePx.1, seed: i + 1) else { continue }
        let enc = Compressor.encode(img, CompressSpec(adaptive: false, colorMode: "color",
                                                     colorEncoder: "jpeg", monoEncoder: "ccitt",
                                                     quality: 90))
        pages.append(OutputPage(image: enc, dpi: dpi, lines: nil))
    }
    return try PDFWriter.write(pages: pages, to: url, title: "Lumo photo selftest")
}

/// 造一页「桌上的纸」：深色桌面 + 中间一张白纸（可带旋转）。
///
/// 自动裁边为什么要用合成件而不是真实照片：断言需要**确定的答案**——
/// "纸的四角应该在这里、裁完应该是这个尺寸"。真实照片给不出这种答案，
/// 只能退化成"看着还行"。合成件的桌面亮度、纸面位置、旋转角全部可控，
/// 断言才写得出"四角误差 < 5%、裁后尺寸 = 纸的实际像素尺寸"这种可证伪的形式。
///
/// marker 是方向基准：在纸内左上角（视觉左上 = 高 y、小 x）放一个黑方块。
/// 裁边中间要过一次坐标映射（Vision 的归一化坐标 → CIPerspectiveCorrection
/// 的像素坐标），那是整个功能唯一容易写错的地方，而写错的表现就是**画面被镜像**。
/// 放个角标，裁完看它落在哪个象限，方向对不对一测便知——
/// 这与 flipscan 立下的规矩一致：方向必须用绝对基准单独测，不许靠端到端推断。
func makeDeskPhotoPage(width: Int, height: Int, margin: Double, rotate: Double,
                       marker: Bool = true, text: Bool = true) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    // 桌面：深灰 + 一道水平渐变。刻意做成"又暗又不匀"——
    // 这正是真实拍照件里桌子该有的样子，也是裁边判据要认出来的特征。
    for x in 0..<width {
        let t = Double(x) / Double(width)
        let l = 0.34 - 0.12 * t
        ctx.setFillColor(CGColor(red: l, green: l, blue: l, alpha: 1))
        ctx.fill(CGRect(x: x, y: 0, width: 1, height: height))
    }
    ctx.saveGState()
    ctx.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
    ctx.rotate(by: CGFloat(rotate * .pi / 180.0))
    ctx.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
    let mx = Double(width) * margin
    let my = Double(height) * margin
    let rect = CGRect(x: mx, y: my, width: Double(width) - 2 * mx, height: Double(height) - 2 * my)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(rect)
    if marker {
        // 内缩 12%/14% 再画：让四角的采样区（约 6%）避开它，
        // 否则"裁完四角该是纸白"这条断言会被标记本身污染（第一版就栽在这）。
        let s = rect.width * 0.08
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: rect.minX + rect.width * 0.12, y: rect.maxY - rect.height * 0.14,
                        width: s, height: s))
    }
    if text {
        ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1))
        var y = rect.maxY - rect.height * 0.26
        while y > rect.minY + rect.height * 0.05 {
            ctx.fill(CGRect(x: rect.minX + rect.width * 0.06, y: y,
                            width: rect.width * 0.88, height: 12))
            y -= 48
        }
    }
    ctx.restoreGState()
    return ctx.makeImage()
}

/// 黑像素落在哪个象限。与 quadrantOfBox 的区别在于**它读像素的方式**：
/// quadrantOfBox 直接摸 CGImage 的 dataProvider 裸字节，只适合 8bpp 灰度图；
/// 而裁边产物来自 CIContext，像素格式不保证（可能是 32bpp 甚至浮点），
/// 必须绕一次 CGContext 转成灰度才读得准。用错工具会得到"无黑块"，然后误判成没问题。
func darkQuadrant(_ img: CGImage?) -> String {
    guard let img, let g = GrayBitmap.from(img, maxDim: 0) else { return "nil" }
    var c = [0, 0, 0, 0]
    for y in 0..<g.height {
        for x in 0..<g.width where g.pixels[y * g.width + x] < 96 {
            c[(y < g.height / 2 ? 0 : 2) + (x < g.width / 2 ? 0 : 1)] += 1
        }
    }
    let names = ["左上", "右上", "左下", "右下"]
    let mi = c.indices.max { c[$0] < c[$1] } ?? 0
    if c[mi] < 50 { return "无黑块（\(c)）" }
    return "\(names[mi])（\(c)）"
}

/// 打开失败时把文件首尾打印出来——手写 PDF 出错时，光看一句 cannotOpen 没法定位
func dumpPDFDiagnostics(_ url: URL) {
    guard let data = try? Data(contentsOf: url) else {
        print("  （读不回产物）")
        return
    }
    let head = data.prefix(220)
    let tail = data.suffix(420)
    print("  文件共 \(data.count) 字节")
    print("  head: \(String(data: head, encoding: .isoLatin1) ?? "")")
    print("  tail: \(String(data: tail, encoding: .isoLatin1) ?? "")")
}

// MARK: - 校验

struct PageStats {
    var std: Double = 0
    var dark: Double = 0
}

func pageStats(_ g: GrayBitmap) -> PageStats {
    guard g.count > 0 else { return PageStats() }
    var sum = 0.0
    for v in g.pixels { sum += Double(v) }
    let mean = sum / Double(g.count)
    var acc = 0.0
    var dark = 0
    for v in g.pixels {
        let d = Double(v) - mean
        acc += d * d
        if v < 128 { dark += 1 }
    }
    return PageStats(std: sqrt(acc / Double(g.count)),
                     dark: Double(dark) / Double(g.count))
}

/// 把产物重新打开、重新光栅化，确认「每一页都还有内容」——
/// 只看文件体积是骗人的：压成空白页体积最小。
func verifyOutput(_ url: URL, expectPages: Int, label: String) -> Bool {
    guard let doc = PDFReader.open(url) else {
        print("  ✗ [\(label)] 无法重新打开产物")
        return false
    }
    let n = PDFReader.pageCount(doc)
    guard n == expectPages else {
        print("  ✗ [\(label)] 页数不对：期望 \(expectPages)，实际 \(n)")
        return false
    }
    var ok = true
    for i in 0..<n {
        guard let img = PDFReader.render(doc, i, dpi: 100) else {
            print("  ✗ [\(label)] 第 \(i + 1) 页渲染失败")
            ok = false
            continue
        }
        guard let g = GrayBitmap.from(img, maxDim: 900) else {
            print("  ✗ [\(label)] 第 \(i + 1) 页取灰度失败")
            ok = false
            continue
        }
        let s = pageStats(g)
        guard s.std > 3.0, s.dark > 1e-4 else {
            print("  ✗ [\(label)] 第 \(i + 1) 页看起来是空的：std=\(String(format: "%.2f", s.std)) dark=\(String(format: "%.5f", s.dark))")
            dumpPDFDiagnostics(url)
            ok = false
            continue
        }
        // 整页发黑 = 单色极性反了。这个必须单独断言：
        // 「不是空白」和「不是负片」是两件事，只看 std 的话负片照样分数很高。
        guard s.dark < 0.5 else {
            print("  ✗ [\(label)] 第 \(i + 1) 页几乎全黑（dark=\(String(format: "%.4f", s.dark))），单色极性可能反了")
            ok = false
            continue
        }
        print(String(format: "  ✓ [%@] 第 %lld 页 std=%.2f dark=%.4f", label, Int64(i + 1), s.std, s.dark))
    }
    return ok
}

// MARK: - selftest

func selftest() -> Int32 {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lumo-selftest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let src = tmp.appendingPathComponent("scan.pdf")
    var failures = 0
    // 断言条数必须自己数出来、并且打在汇总行里。
    // 为什么：屏幕上那些 "  ✓" 里混着一批**进度信息行**（例如「页数=3 文字层=无 …」
    // 和每档压缩的「std=36.62 dark=0.0290」），用 `grep -c ✓` 去数会**虚高**——
    // 实测同一份输出：grep 数到 112 个 ✓，而真正的断言只有 90 条。
    // 文档里写"107 条断言"那种数，就是这么来的（口径含糊、还会随信息行增减而漂）。
    // 所以这里让程序自己报数，任何人不用再猜。
    var assertions = 0
    func check(_ ok: Bool, _ msg: String) {
        assertions += 1
        if ok { print("  ✓ \(msg)") } else { print("  ✗ \(msg)"); failures += 1 }
    }

    print("==> 生成合成扫描件")
    do {
        let n = try makeScanPDF(at: src)
        print("  ✓ \(src.lastPathComponent) \(n) 字节，3 页")
        check(n > 20_000, "源文件体积合理（\(n) 字节）")
    } catch {
        print("  ✗ 生成失败：\(error)")
        return 1
    }

    print("==> 体检")
    var report: ReportResponse?
    do {
        report = try Pipeline.report(fileURL: src)
        let a = report!.analysis
        print(String(format: "  ✓ 页数=%lld 文字层=%@ 色彩=%@ DPI=%lld 倾斜=%.2f° 噪声=%.3f 背景不匀=%.3f",
                     Int64(a.pageCount), a.hasTextLayer ? "有" : "无", a.colorMode,
                     Int64(a.estimatedDpi), a.skewAngle, a.noiseLevel, a.bgUnevenness))
        check(a.pageCount == 3, "页数 = 3")
        check(!a.hasTextLayer, "合成扫描件没有文字层（应当建议 OCR）")
        check(abs(a.skewAngle) > 0.5, "检测到倾斜（\(String(format: "%.2f", a.skewAngle))°）")
        let total = report!.plans.reduce(0) { $0 + $1.estBytes }
        check(total > 0, "三档方案都有体积预估")
    } catch {
        print("  ✗ 体检失败：\(error)")
        dumpPDFDiagnostics(src)
        return 1
    }

    print("==> 纠偏一致性（旋转 → 检测 → 回正）")
    if let img = makeScanPage(width: 1240, height: 1754, tilt: 2.5, seed: 0) {
        let before = Enhance.detectSkew(img)
        let after = Enhance.detectSkew(Enhance.deskew(img, degrees: before) ?? img)
        print(String(format: "  ✓ 检测到 %.2f°，回正后残余 %.2f°", before, after))
        check(abs(before) > 1.0, "能检测出 2.5° 的倾斜")
        check(abs(after) < 0.5, "回正后残余倾斜 < 0.5°（符号若反了这里必然失败）")
    } else {
        check(false, "生成倾斜测试页")
    }

    print("==> 完整处理（自适应 + OCR）")
    let balanced = tmp.appendingPathComponent("balanced.pdf")
    var spec = report!.recommendation
    spec.ocr = OCRSpec(enabled: true, lang: "eng", output: "searchable", skip: false)
    spec.enhance.deskew = true
    do {
        let r = try Pipeline.process(fileURL: src,
                                     spec: ProcessSpec(pages: "all", enhance: spec.enhance,
                                                       ocr: spec.ocr, compress: spec.compress,
                                                       procDpi: report!.procDpi),
                                     outURL: balanced, previewDir: tmp)
        print(String(format: "  ✓ %lld → %lld 字节（省 %.1f%%），OCR %lld 字符，用时 %.1fs",
                     Int64(r.inSize), Int64(r.outSize), r.savedPct, Int64(r.ocrChars), r.elapsedSec))
        check(r.outSize < r.inSize, "产物比源文件小")
        check(r.ocrChars >= 10, "OCR 识别出文字（\(r.ocrChars) 字符）")
        check(r.outSize > 1000, "产物不是空壳")
        if !verifyOutput(balanced, expectPages: 3, label: "balanced") { failures += 1 }
        if let d = PDFReader.open(balanced) {
            let img = PDFReader.render(d, 0, dpi: 150)
            if let im = img {
                let resid = abs(Enhance.detectSkew(im))
                check(resid < 0.6, "第 1 页残余倾斜 < 0.6°（实测 \(String(format: "%.2f", resid))°）")
            }
        }
    } catch {
        print("  ✗ 处理失败：\(error)")
        failures += 1
    }

    print("==> 单色 CCITT G4 路径")
    let mono = tmp.appendingPathComponent("mono.pdf")
    do {
        let r = try Pipeline.process(fileURL: src,
                                     spec: ProcessSpec(pages: "all",
                                                       enhance: EnhanceSpec(),
                                                       ocr: OCRSpec(enabled: false, lang: "eng", output: "searchable", skip: true),
                                                       compress: CompressSpec(adaptive: false, colorMode: "mono",
                                                                              colorEncoder: "jpeg", monoEncoder: "ccitt",
                                                                              quality: 70),
                                                       procDpi: 250),
                                     outURL: mono)
        print(String(format: "  ✓ %lld → %lld 字节（省 %.1f%%）", Int64(r.inSize), Int64(r.outSize), r.savedPct))
        if !r.warnings.isEmpty { print("    说明：\(r.warnings.joined(separator: "；"))") }
        if let d = PDFReader.open(src), let im = PDFReader.render(d, 0, dpi: 150),
           let p = Compressor.monoProbe(im) {
            print(String(format: "    单色探针：打包黑点=%.4f TIFF Photometric=%lld TIFF往返黑点=%.4f PDF渲染黑点=%.4f",
                         p.packedDark, Int64(p.photometric), p.tiffDark, p.pdfDark))
        }
        if !verifyOutput(mono, expectPages: 3, label: "ccitt") { failures += 1 }
    } catch {
        print("  ✗ CCITT 处理失败：\(error)")
        failures += 1
    }

    print("==> JPEG2000 路径")
    let jp2 = tmp.appendingPathComponent("jp2.pdf")
    do {
        let r = try Pipeline.process(fileURL: src,
                                     spec: ProcessSpec(pages: "1",
                                                       enhance: EnhanceSpec(),
                                                       ocr: OCRSpec(enabled: false, lang: "eng", output: "searchable", skip: true),
                                                       compress: CompressSpec(adaptive: false, colorMode: "color",
                                                                              colorEncoder: "jp2", monoEncoder: "ccitt",
                                                                              quality: 80),
                                                       procDpi: 250),
                                     outURL: jp2)
        print(String(format: "  ✓ %lld → %lld 字节", Int64(r.inSize), Int64(r.outSize)))
        if !r.warnings.isEmpty { print("    说明：\(r.warnings.joined(separator: "；"))") }
        if !verifyOutput(jp2, expectPages: 1, label: "jp2") { failures += 1 }
    } catch {
        print("  ✗ JPEG2000 处理失败：\(error)")
        failures += 1
    }

    // 像素格式这条最容易踩：24bpp RGB 不在 CoreGraphics 支持列表里，
    // 一旦有人改回去，ZIP 会静默退化成 JPEG，界面上却看不出任何异常。
    print("==> RGB 采样与像素格式")
    if let d = PDFReader.open(src), let img = PDFReader.render(d, 0, dpi: 120) {
        check(rgbSamples(img) != nil, "RGB 采样可用（ZIP 无损与墨色估计都靠它）")
        check(Compressor.encode(img, CompressSpec(adaptive: false, colorMode: "color",
                                                  colorEncoder: "zip", monoEncoder: "zip",
                                                  quality: 80)).filter == "/FlateDecode",
              "ZIP 真的走了 Flate（不是偷偷退回 JPEG）")
        check(Enhance.removeBackground(img) != nil, "背景去除能出图（像素格式踩坑曾让它静默失效）")
        check(Enhance.stretchContrast(img) != nil, "对比度拉伸能出图")
    } else {
        check(false, "渲染取样页")
    }
    if let paint = Compressor.maskProbePaint() {
        check(abs(paint - 0.25) < 0.12 || abs(paint - 0.75) < 0.12,
              String(format: "PDF 蒙版层生效（探针上色比例 %.2f）", paint))
    } else {
        check(false, "PDF /ImageMask 在这台机器上不生效（分层压缩会被自动关掉）")
    }

    // Flate + 预测器在 CoreGraphics 上的真实行为只能实测：
    // PNG 文件格式与 PDF /Predictor 的语义差别很微妙，错了就是整页空白，
    // 而"空白页"在体积上还特别好看——所以这里必须把每种写法都量一遍。
    print("==> Flate 与 /Predictor 交叉验证")
    do {
        let w = 64, h = 64
        var raw = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let v: UInt8 = ((x / 8 + y / 8) % 2 == 0) ? 20 : 235
                let i = (y * w + x) * 3
                raw[i] = v; raw[i + 1] = v; raw[i + 2] = v
            }
        }
        if let z = deflate(Data(raw)) {
            print(String(format: "  · deflate 头部：%02x %02x %02x %02x（78 = RFC1950 头）",
                         z[0], z[1], z[2], z[3]))
            check(z[0] == 0x78, "deflate 产出的是带头的 zlib 流（PDF 只认这种）")
            // Apple 的 .zlib 两头对称：压出来和解得开的都是**裸 deflate**，
            // 所以拿它自己的解压器只能验裸流，带头的那一份要交给 PDF 阅读器验。
            if let rz = try? (Data(raw) as NSData).compressed(using: .zlib),
               let back = try? rz.decompressed(using: .zlib) {
                check(Data(referencing: back) == Data(raw), "裸 deflate 往返一致（\(rz.count) 字节）")
            } else {
                check(false, "裸 deflate 往返")
            }
        } else {
            check(false, "deflate 出流")
        }
        func variant(_ p: Int?) -> Double {
            var payload = Data(raw)
            var dp: String? = nil
            if let p {
                if p >= 10 { payload = Data(pngUpFilter(raw, rowBytes: w * 3, height: h)) }
                dp = Compressor.predictorParms(colors: 3, columns: w, rows: h, bits: 8, predictor: p)
            }
            guard let z = deflate(payload) else { return -1 }
            let enc = EncodedImage(data: z, colorSpace: "/DeviceRGB", filter: "/FlateDecode",
                                   bitsPerComponent: 8, decodeParms: dp, width: w, height: h,
                                   mode: "color", encoderUsed: "ZIP", note: nil)
            let u = tmp.appendingPathComponent(p == nil ? "flate-none.pdf" : "flate-p\(p!).pdf")
            _ = try? PDFWriter.write(pages: [OutputPage(image: enc, dpi: 72, lines: nil)], to: u, title: "flate")
            guard let d = PDFReader.open(u), let im = PDFReader.render(d, 0, dpi: 72),
                  let g = GrayBitmap.from(im) else { return -1 }
            return g.contrast()
        }
        let c0 = variant(nil), c12 = variant(12), c2 = variant(2)
        print(String(format: "  · 对比度（>20 才算有内容）：无预测器 %.0f / Predictor 12(Up) %.0f / Predictor 2(TIFF) %.0f",
                     c0, c12, c2))
        check(c0 > 20, "无预测器的 Flate 图能正常显示（生产路径用的就是这种）")
    }

    print("==> ZIP 无损路径")
    let zipOut = tmp.appendingPathComponent("zip.pdf")
    do {
        let r = try Pipeline.process(fileURL: src,
                                     spec: ProcessSpec(pages: "1",
                                                       enhance: EnhanceSpec(sharpen: 1.0),
                                                       ocr: OCRSpec(enabled: false, lang: "eng", output: "searchable", skip: true),
                                                       compress: CompressSpec(adaptive: false, colorMode: "color",
                                                                              colorEncoder: "zip", monoEncoder: "zip",
                                                                              quality: 80),
                                                       procDpi: 250),
                                     outURL: zipOut)
        print(String(format: "  ✓ %lld → %lld 字节", Int64(r.inSize), Int64(r.outSize)))
        if !verifyOutput(zipOut, expectPages: 1, label: "zip") { failures += 1 }
    } catch {
        print("  ✗ ZIP 处理失败：\(error)")
        failures += 1
    }

    // 单色的 Flate 路径单独再验一次：默认走 CCITT，这条分支平时没人跑，
    // "行首多一个字节"这种 bug 正是藏在这种地方。
    let monoZip = tmp.appendingPathComponent("mono-zip.pdf")
    do {
        let r = try Pipeline.process(fileURL: src,
                                     spec: ProcessSpec(pages: "1", enhance: EnhanceSpec(),
                                                       ocr: OCRSpec(enabled: false, lang: "eng", output: "searchable", skip: true),
                                                       compress: CompressSpec(adaptive: false, colorMode: "mono",
                                                                              colorEncoder: "zip", monoEncoder: "zip",
                                                                              quality: 80),
                                                       procDpi: 250),
                                     outURL: monoZip)
        print(String(format: "  ✓ 单色 Flate：%lld → %lld 字节", Int64(r.inSize), Int64(r.outSize)))
        if !verifyOutput(monoZip, expectPages: 1, label: "mono-zip") { failures += 1 }
    } catch {
        print("  ✗ 单色 Flate 失败：\(error)")
        failures += 1
    }

    print("==> 可编辑文本 + OCR 中文")
    let editable = tmp.appendingPathComponent("editable.pdf")
    do {
        let r = try Pipeline.process(fileURL: src,
                                     spec: ProcessSpec(pages: "1", enhance: EnhanceSpec(),
                                                       ocr: OCRSpec(enabled: true, lang: "chi_sim+eng",
                                                                    output: "editable", skip: false),
                                                       compress: CompressSpec(adaptive: true, colorMode: "auto",
                                                                              colorEncoder: "jpeg", monoEncoder: "ccitt",
                                                                              quality: 72),
                                                       procDpi: 250),
                                     outURL: editable)
        check(r.ocrChars >= 10, "中英文 OCR 有结果（\(r.ocrChars) 字符）")
        check(r.sidecar != nil, "生成了 .txt 伴生文件")
        if !verifyOutput(editable, expectPages: 1, label: "editable") { failures += 1 }
        // 二次体检必须认得出我们自己写的文字层。
        // 否则用户「处理完再打开一次」会被建议重做 OCR——那正是这个产品要消灭的重复劳动。
        if let rep = try? Pipeline.report(fileURL: editable) {
            check(rep.analysis.hasTextLayer, "产物再体检一次要认出文字层")
        } else {
            check(false, "产物能被再次体检")
        }
    } catch {
        print("  ✗ 可编辑模式失败：\(error)")
        failures += 1
    }

    print("==> 增强模式（自动 / 黑白 / 增强 / 对比度 / 原图）")
    if let img = makePhotoPage(width: 1240, height: 1754, seed: 7) {
        for p in EnhancePreset.allCases {
            let out = Enhance.apply(img, spec: EnhanceSpec(preset: p.rawValue))
            guard let g = GrayBitmap.from(out, maxDim: 800) else {
                check(false, "\(p.title)：取灰度失败")
                continue
            }
            // 「有内容」不能只看对比度：二值化结果的 p90 与 p10 都是 255，
            // 直方图对比度恒为 0，但那恰恰是黑白档成功的样子。所以墨水率也算数。
            var inkN = 0
            for v in g.pixels where Int(v) < 128 { inkN += 1 }
            let ir = Double(inkN) / Double(max(1, g.count))
            check(g.contrast() > 20 || (ir > 0.0005 && ir < 0.6),
                  String(format: "%@ 之后页面仍有内容（对比度 %.0f，墨水率 %.2f%%）",
                         p.title, g.contrast(), ir * 100))
        }
        let bw = Enhance.apply(img, spec: EnhanceSpec(preset: "bw"))
        // 全分辨率测量：降采样本身就会把纯黑白重新混出中间调，测小图等于自己骗自己
        if let gb = GrayBitmap.from(bw) {
            var mid = 0, ink = 0
            for v in gb.pixels {
                if Int(v) > 60 && Int(v) < 195 { mid += 1 }
                if Int(v) < 128 { ink += 1 }
            }
            let mr = Double(mid) / Double(max(1, gb.count))
            let ir = Double(ink) / Double(max(1, gb.count))
            print(String(format: "  · 黑白：中间调 %.1f%% 墨水率 %.2f%%", mr * 100, ir * 100))
        if let bm = Enhance.binaryMap(img) {
            var k = 0
            for v in bm.pixels where Int(v) < 128 { k += 1 }
            print(String(format: "  · binaryMap：可用，墨水率 %.2f%%", Double(k) / Double(max(1, bm.count)) * 100))
        } else {
            print("  · binaryMap：nil")
        }
        print("  · adaptiveBinarize：\(Enhance.adaptiveBinarize(img) == nil ? "nil（已退回原图）" : "成功")")
            check(mr < 0.06, "黑白档基本只剩纯黑白（中间调 \(String(format: "%.1f", mr * 100))%）")
            check(ir > 0.0005 && ir < 0.45, "墨水率落在「有字但不糊」区间")
        }
    } else {
        check(false, "生成拍照扫描测试页")
    }

    print("==> 分层压缩（MRC：低分辨率背景 + 1bit 文字蒙版）")
    let photoSrc = tmp.appendingPathComponent("photo.pdf")
    do {
        let n = try makePhotoPDF(at: photoSrc)
        print("  ✓ \(photoSrc.lastPathComponent) \(n) 字节，2 页（模拟手机拍照扫描件）")
        if let d = PDFReader.open(photoSrc), let im = PDFReader.render(d, 0, dpi: 200) {
            print(String(format: "    该页体检：单色页=%@ 噪声=%.3f 背景不匀=%.3f",
                         Analyzer.isMonoLike(im) ? "是" : "否",
                         Analyzer.noiseLevel(im), Analyzer.backgroundUnevenness(im)))
        }
        func run(_ adaptive: Bool, _ out: URL) throws -> ProcessResponse {
            try Pipeline.process(fileURL: photoSrc,
                                 spec: ProcessSpec(pages: "all", enhance: EnhanceSpec(),
                                                   ocr: OCRSpec(enabled: false, lang: "eng", output: "searchable", skip: true),
                                                   compress: CompressSpec(adaptive: adaptive,
                                                                          colorMode: adaptive ? "auto" : "color",
                                                                          colorEncoder: "jpeg",
                                                                          monoEncoder: "ccitt", quality: 72),
                                                   procDpi: 200),
                                 outURL: out)
        }
        let rFlat = try run(false, tmp.appendingPathComponent("photo-flat.pdf"))
        let rMRC = try run(true, tmp.appendingPathComponent("photo-mrc.pdf"))
        print(String(format: "  ✓ 单层 JPEG %lld 字节 → 自适应 %lld 字节（省 %.1f%%）",
                     Int64(rFlat.outSize), Int64(rMRC.outSize),
                     (1.0 - Double(rMRC.outSize) / Double(max(1, rFlat.outSize))) * 100))
        check(rMRC.outSize < rFlat.outSize, "自适应（含分层）比单层更省")
        if !verifyOutput(tmp.appendingPathComponent("photo-mrc.pdf"), expectPages: 2, label: "mrc") { failures += 1 }
    } catch {
        print("  ✗ 分层压缩失败：\(error)")
        failures += 1
    }

    print("==> 页码范围")
    do {
        let r = try Pipeline.process(fileURL: src,
                                     spec: ProcessSpec(pages: "2-3", enhance: EnhanceSpec(),
                                                       ocr: OCRSpec(enabled: false, lang: "eng", output: "searchable", skip: true),
                                                       compress: CompressSpec(adaptive: true, colorMode: "auto",
                                                                              colorEncoder: "jpeg", monoEncoder: "ccitt",
                                                                              quality: 60),
                                                       procDpi: 200),
                                     outURL: tmp.appendingPathComponent("range.pdf"))
        check(r.pagesProcessed == 2, "2-3 页选中了 2 页")
    } catch {
        print("  ✗ 页码范围失败：\(error)")
        failures += 1
    }

    print("==> 单页效果预览（App 里「先看再跑」用的就是它）")
    if let pair = PagePreview.beforeAfter(fileURL: photoSrc, page: 1,
                                          spec: EnhanceSpec(preset: "bw"), dpi: 100, maxDim: 600) {
        check(pair.before.count > 1000, "原图预览 PNG \(pair.before.count) 字节")
        check(pair.after.count > 1000, "增强后预览 PNG \(pair.after.count) 字节")
        check(pair.before != pair.after, "增强前后确实不同（否则预览等于没做）")
    } else {
        check(false, "生成单页预览")
    }

    print("==> 含色页面不许被二值化（印章/图表要活下来）")
    do {
        // 白底 + 黑字 + 一块大红：若压缩端把这种页判成单色，红块会变成黑块。
        // 示例扫描件第 3 页就是这么被毁掉的——增强端把颜色保得好好的，
        // 压缩端一个「只看灰度」的判定又给丢了。
        guard let ctx = CGContext(data: nil, width: 400, height: 560, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw NSError(domain: "selftest", code: 1) }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 560))
        drawTextLine(ctx, "Color retention test", 24, 480, 22)
        ctx.setFillColor(CGColor(red: 0.80, green: 0.12, blue: 0.10, alpha: 1))
        ctx.fill(CGRect(x: 250, y: 400, width: 130, height: 100))
        guard let colorPage = ctx.makeImage() else { throw NSError(domain: "selftest", code: 2) }
        let enc = Compressor.encode(colorPage, CompressSpec(adaptive: true, colorMode: "auto",
                                                            colorEncoder: "jpeg", monoEncoder: "ccitt", quality: 72))
        check(enc.mode == "color", "含红色块的页被判为彩色页（实际 \(enc.mode)，\(enc.encoderUsed)）")
        // 落到 PDF 再渲染回来，红块必须还是红的（r 明显压过 g/b）
        let colorPdf = tmp.appendingPathComponent("colorpage.pdf")
        _ = try PDFWriter.write(pages: [OutputPage(image: enc, dpi: 72, lines: nil)], to: colorPdf, title: "color")
        if let back = PDFReader.open(colorPdf), let im = PDFReader.render(back, 0, dpi: 72),
           let data = im.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
            let bpr = im.bytesPerRow
            // 红块中心：画布坐标 (315, 450)（y 朝上）→ CGImage 行 0 是顶行 → row = 560-450
            let o = (560 - 450) * bpr + 315 * 4
            let (r, g, b) = (Int(bytes[o]), Int(bytes[o + 1]), Int(bytes[o + 2]))
            check(r > 120 && r > g + 60 && r > b + 60,
                  "红块渲染回来还是红的（rgb=\(r),\(g),\(b)）")
        } else {
            check(false, "含色页渲染回读")
        }
    } catch {
        print("  ✗ 含色页测试失败：\(error)")
        failures += 1
    }

    print("==> 背景清理：强度必须真的改变底灰，且彩色页要真的被判为需要清理")
    do {
        // 造一页"均匀的灰底"——这是旧实现漏掉的那种脏：
        // 不匀度低（没有阴影），但纸白本身就暗，观感是"蒙了一层灰"。
        guard let ctx = CGContext(data: nil, width: 400, height: 560, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw NSError(domain: "selftest", code: 1) }
        ctx.setFillColor(CGColor(red: 0.90, green: 0.90, blue: 0.87, alpha: 1))   // 纸色偏灰黄
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 560))
        drawTextLine(ctx, "Scan cleanup test", 24, 480, 22)
        guard let grayPage = ctx.makeImage() else { throw NSError(domain: "selftest", code: 2) }

        // 1) 判据：这种页必须被认定为"需要清理"。
        //    旧门槛只看 backgroundUnevenness，这页不匀度很低，会被直接跳过——
        //    而它恰恰就是用户说的"增强完了背景还留着"。
        check(Enhance.needsBackgroundClean(grayPage),
              "均匀灰底页被判定为需要清理（纸白 \(Int(Enhance.paperLevel(grayPage))), 不匀 \(String(format: "%.3f", Analyzer.backgroundUnevenness(grayPage)))）")

        // 2) 强度必须单调有效：拉得越高，纸白越高。
        //    这里刻意用**纸白**而不是 bgLevel 来断言：bgLevel 取的是"中位数以上的像素均值"，
        //    当整页都被清成白纸时，这个均值会顶到 255 本身，差值反而看不出来
        //    （第一次写就用它断言，结果 247 → 255 只差 8，被阈值判为失败）。
        //    纸白没有这个饱和问题：它是从亮端往暗端数的分位点，对"整体抬了多少"更敏感。
        let low = Enhance.paperLevel(Enhance.apply(grayPage, spec: EnhanceSpec(preset: "color", bgStrength: 0.0)))
        let high = Enhance.paperLevel(Enhance.apply(grayPage, spec: EnhanceSpec(preset: "color", bgStrength: 1.0)))
        check(high > low + 3,
              String(format: "强度 0→1 纸白确实抬升（%.0f → %.0f）", low, high))

        // 3) 强度 1.0 时纸面要接近纯白，才算真的"干净"。
        let white = Enhance.paperLevel(Enhance.apply(grayPage, spec: EnhanceSpec(preset: "color", bgStrength: 1.0)))
        check(white > 252, String(format: "强度 1.0 时纸白接近纯白（%.0f）", white))

        // 4) 清理不能把文字也洗掉：墨水率得留着。
        let after = Enhance.apply(grayPage, spec: EnhanceSpec(preset: "color", bgStrength: 0.6))
        if let g = GrayBitmap.from(after) {
            var ink = 0
            for v in g.pixels where v < 128 { ink += 1 }
            let ratio = Double(ink) / Double(max(1, g.count))
            check(ratio > 0.0005, String(format: "清理后文字仍在（墨水率 %.2f%%）", ratio * 100))
        } else {
            check(false, "清理结果可读")
        }

        // 5) 强度 0 时不该动背景（用户要"保留纸张质感"就得真的保留）。
        let zero = Enhance.paperLevel(Enhance.apply(grayPage, spec: EnhanceSpec(preset: "color", bgStrength: 0.0)))
        check(abs(zero - Enhance.paperLevel(grayPage)) < 8,
              String(format: "强度 0 时纸白基本不变（%.0f → %.0f）", Enhance.paperLevel(grayPage), zero))

        // 6) **覆盖面**：滑块不能只对彩色页有效。
        //    第一版把 auto 档的灰阶页丢给 stretchContrast（只拉直方图、不清背景），
        //    于是 CI 实测四档强度下第 1 页底灰恒为 239.4、第 2 页恒为 202.3 ——
        //    滑块拉到底画面纹丝不动。这条断言就是那次漏检的守卫。
        //
        //    验收指标用**清理步骤本身**的输出，而不是整个 apply 的结果：
        //    stretchContrast 会把灰底页一次性拉到接近纯白（实测 229 灰底 → 254），
        //    它自己就把强度差异抹平了。所以要用 removeBackground 的直接结果来断言——
        //    这正是「指标的性质决定了它能测什么」那条教训的又一次应用。
        let autoLow = Enhance.paperLevel(Enhance.removeBackground(grayPage, strength: 0.35) ?? grayPage)
        let autoHigh = Enhance.paperLevel(Enhance.removeBackground(grayPage, strength: 1.0) ?? grayPage)
        check(autoHigh > autoLow + 2,
              String(format: "清理强度对灰阶页有效（纸白 %.0f → %.0f）", autoLow, autoHigh))

        // 7) 灰阶路径确实接上了清理：apply(auto) 的结果不能比原图更灰。
        let autoOut = Enhance.apply(grayPage, spec: EnhanceSpec(preset: "auto", bgStrength: 1.0))
        check(Enhance.paperLevel(autoOut) >= Enhance.paperLevel(grayPage) - 1,
              String(format: "auto 档不会让灰底页更脏（%.0f → %.0f）",
                     Enhance.paperLevel(grayPage), Enhance.paperLevel(autoOut)))

        // 8) **白平衡**：清理必须把纸面拉成中性白，而不只是整体提亮。
        //    这是"够不够白"的分水岭——纸色偏黄时，三通道乘同一个 factor 只会得到
        //    "更亮的黄"，永远到不了布丁扫描那种中性白。断言方式：
        //    造一页明显偏黄的纸，清理后纸面的 R 与 B 必须几乎相等。
        guard let warmCtx = CGContext(data: nil, width: 400, height: 560, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw NSError(domain: "selftest", code: 3) }
        // 偏黄的暗纸：R 明显高于 B（模拟泛黄纸张）
        warmCtx.setFillColor(CGColor(red: 0.82, green: 0.79, blue: 0.68, alpha: 1))
        warmCtx.fill(CGRect(x: 0, y: 0, width: 400, height: 560))
        drawTextLine(warmCtx, "Warm paper white balance", 24, 480, 20)
        guard let warmPage = warmCtx.makeImage() else { throw NSError(domain: "selftest", code: 4) }
        let cleaned = Enhance.removeBackground(warmPage, strength: 1.0) ?? warmPage
        // 取最亮 15% 像素（纸面）的三通道均值
        if let data = cleaned.dataProvider?.data, let bp = CFDataGetBytePtr(data) {
            let bpr = cleaned.bytesPerRow
            var sr = 0.0, sb = 0.0
            var n = 0
            // 隔 4 像素采一次就够，自检不必逐像素
            for y in stride(from: 0, to: cleaned.height, by: 4) {
                for x in stride(from: 0, to: cleaned.width, by: 4) {
                    let o = y * bpr + x * 4
                    let r = Int(bp[o]), g = Int(bp[o + 1]), b = Int(bp[o + 2])
                    guard max(r, max(g, b)) > 200 else { continue }   // 只看纸面
                    sr += Double(r); sb += Double(b); n += 1
                }
            }
            if n > 0 {
                let diff = abs(sr / Double(n) - sb / Double(n))
                check(diff < 6,
                      String(format: "偏黄纸被拉成中性白（R−B 差 %.1f）", diff))
            } else {
                check(false, "白平衡测试能采到纸面像素")
            }
        } else {
            check(false, "白平衡测试能读到像素")
        }
    } catch {
        print("  ✗ 背景清理测试失败：\(error)")
        failures += 1
    }

    print("==> 背景强度：判据不该成为滑块的门闩（L4 的守卫）")
    do {
        // 这一节守的是 2026-09-12 本地接手时发现的 L4：
        // 一页被判为「已经够干净」之后，背景强度滑块就彻底失效——
        // 同一页传 0 / 0.35 / 0.75 / 1 四档，产出**逐字节完全相同**，
        // 用户看到的是一个怎么拉都不动的控件。
        // 根因：cleanThenContrast / boostColor 把 needsBackgroundClean 当成了闸门。
        //
        // 约定已改成：**强度恒定生效，判据只负责提示**。
        // 所以下面有三类断言：强度确实生效、干净页别被弄脏、提示真的发出来。
        // 最后一条同样重要——放开闸门之后，"这页本来就不脏"这件事如果不说出来，
        // 用户还是会以为控件坏了，等于白改。
        guard let cctx = CGContext(data: nil, width: 400, height: 560, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw NSError(domain: "selftest", code: 20)
        }
        // 纸面 252、光照均匀：判据（纸白 < 249 才算脏）会明确判它"干净"。
        // 取 252 而不是 255，是为了给强度留出可动的余量（mark 最高就是 255）。
        cctx.setFillColor(CGColor(red: 252.0 / 255.0, green: 252.0 / 255.0,
                                  blue: 253.0 / 255.0, alpha: 1))
        cctx.fill(CGRect(x: 0, y: 0, width: 400, height: 560))
        drawTextLine(cctx, "Already clean page", 24, 470, 22)
        drawTextLine(cctx, "strength should still work", 24, 420, 18)
        guard let cleanPage = cctx.makeImage() else { throw NSError(domain: "selftest", code: 21) }

        // 前提断言：这页**必须**被判为干净。否则下面测的根本不是那条分支，
        // 整节断言都会变成"在一个不相干的分支上真空通过"。
        check(!Enhance.needsBackgroundClean(cleanPage),
              String(format: "干净页确实被判为干净（纸白 %.0f）", Enhance.paperLevel(cleanPage)))

        func pixelSignature(_ img: CGImage) -> String {
            guard let g = GrayBitmap.from(img, maxDim: 400) else { return "nil" }
            var h: UInt64 = 1469598103934665603
            for v in g.pixels { h = (h ^ UInt64(v)) &* 1099511628211 }
            return String(h)
        }

        let a0 = Enhance.apply(cleanPage, spec: EnhanceSpec(preset: "contrast", bgStrength: 0.0))
        let a1 = Enhance.apply(cleanPage, spec: EnhanceSpec(preset: "contrast", bgStrength: 1.0))
        check(Enhance.paperLevel(a1) > Enhance.paperLevel(a0),
              String(format: "干净页上强度依然生效（纸白 %.0f → %.0f）",
                     Enhance.paperLevel(a0), Enhance.paperLevel(a1)))
        // 这条是 L4 的正面守卫：把闸门加回去，它立刻变红。
        check(pixelSignature(a0) != pixelSignature(a1),
              "干净页上两档强度的产出不再逐字节相同（L4 的正面守卫）")

        // 放开闸门引入的新风险：干净页也被清一次，会不会反而变灰？
        // removeBackground 的 mark = 245+10s，决定了纸面只会被拉到 245~255，
        // 所以任何强度下纸白都不该掉到 245 以下。这条守的是"修好一个 bug 别换来另一个"。
        var worst = 255.0
        for s in [0.2, 0.4, 0.6, 0.8, 1.0] {
            worst = min(worst, Enhance.paperLevel(
                Enhance.apply(cleanPage, spec: EnhanceSpec(preset: "contrast", bgStrength: s))))
        }
        check(worst >= 245, String(format: "干净页在任何强度下都不会被弄脏（最差纸白 %.0f）", worst))

        // 提示通路：结论与文案都要随 applyReporting 出来，
        // 否则 UI 上就没有任何东西解释"为什么看不出变化"。
        let repClean = Enhance.applyReporting(cleanPage, spec: EnhanceSpec(preset: "contrast", bgStrength: 0.6))
        check(repClean.judgedClean && repClean.notes.contains(where: { $0.contains("够干净") }),
              "干净页的判定与提示都随 applyReporting 返回")

        // 反面：脏页不许误报。误报会让这条提示变成"狼来了"，
        // 用户下次见到它就直接忽略——那比没有提示更糟。
        guard let dctx = CGContext(data: nil, width: 400, height: 560, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw NSError(domain: "selftest", code: 22)
        }
        dctx.setFillColor(CGColor(red: 0.90, green: 0.90, blue: 0.87, alpha: 1))
        dctx.fill(CGRect(x: 0, y: 0, width: 400, height: 560))
        drawTextLine(dctx, "Dirty page", 24, 470, 22)
        guard let dirtyPage = dctx.makeImage() else { throw NSError(domain: "selftest", code: 23) }
        check(Enhance.needsBackgroundClean(dirtyPage), "脏页确实被判为需要清理")
        check(!Enhance.applyReporting(dirtyPage, spec: EnhanceSpec(preset: "contrast", bgStrength: 0.6)).judgedClean,
              "脏页不会被误报成「已经够干净」")

        // 黑白 / 原图两档不该发这条提示：它们的滑块本来就该是禁用的，
        // 发提示等于去解释一个本不该出现的控件。
        check(!Enhance.usesBackgroundStrength(EnhanceSpec(preset: "bw", bgStrength: 0.6))
              && !Enhance.usesBackgroundStrength(EnhanceSpec(preset: "original", bgStrength: 0.6))
              && Enhance.usesBackgroundStrength(EnhanceSpec(preset: "auto", bgStrength: 0.6)),
              "「有没有强度这个概念」只认模式声明（usesBgStrength）")
    } catch {
        print("  ✗ 背景强度覆盖面测试失败：\(error)")
        failures += 1
    }

    print("==> 自动裁边：只在看得见桌面时才动手")
    do {
        // 这一节分**两层**测，理由见 Enhance.autoCrop(_:quad:) 的注释：
        //
        //   ① **几何层**：闸门判断 + 透视校正。用**显式构造的四边形**驱动，
        //      不经过 Vision，所以结果与系统版本无关，两个 CI 系统都跑。
        //   ② **检出层**：Vision 能不能从图里找出那张纸。这是 ML，随系统版本变，
        //      所以只留一条断言，且写成"检出就必须几何正确／没检出就必须原样不动"
        //      —— 两种情况下都有真东西被验证，不会空转。
        //
        // 为什么值得这么拆：2026-09-12 的 CI 上，这一节原本是一坨，
        // macos-14 的 Vision 检不出这张合成件 → **7 条几何断言全红**，
        // 而产品行为完全正确（没检出就原样返回）。几何的错和模型的差异，
        // 必须能分开读出来，否则红一片的时候根本不知道该改哪里。
        //
        // ⚠️ 跨系统提醒：几何数值仍刻意放宽（尺寸 ±18%），因为
        // CIPerspectiveCorrection 的取整在不同系统上也会差一两个像素。
        // 真正的护栏（满幅页／纸几乎铺满不许裁、方向不许镜像、边缘不留桌面）
        // 写得很死 —— 它们是这个功能的立身之本。
        let pw = 1360, ph = 1768      // margin .16 时纸的实际像素尺寸（2000×2600 的画布）
        guard let deskPage = makeDeskPhotoPage(width: 2000, height: 2600, margin: 0.16,
                                              rotate: 0, marker: true, text: true) else {
            throw NSError(domain: "selftest", code: 30)
        }
        // 纸在归一化坐标里的四边形（**原点左下**，与 Vision 同向）。
        // 这张合成件的纸就是 margin .16 那一圈，四角可以直接写出来，不需要 Vision。
        let paperQuad = Enhance.DocumentQuad.upright(x0: 0.16, y0: 0.16, x1: 0.84, y1: 0.84)

        /// 造"歪着拍的纸"：归一化四边形绕画布中心转 degrees 度。
        /// 这是真实拍照件的常态，也是"裁完还残留窄边"最容易发生的场景。
        func rotatedPaperQuad(margin: Double, degrees: Double) -> Enhance.DocumentQuad {
            let r = degrees * .pi / 180, cs = cos(r), sn = sin(r)
            func rot(_ x: Double, _ y: Double) -> CGPoint {
                let dx = x - 0.5, dy = y - 0.5
                return CGPoint(x: 0.5 + dx * cs - dy * sn, y: 0.5 + dx * sn + dy * cs)
            }
            let a = margin, b = 1 - margin
            return Enhance.DocumentQuad(topLeft: rot(a, b), topRight: rot(b, b),
                                        bottomLeft: rot(a, a), bottomRight: rot(b, a),
                                        coverage: (b - a) * (b - a))
        }

        // ================= ① 几何层（不经过 Vision） =================

        // 1) 给出正确的四边形时确实裁了，且尺寸就是那张纸
        let crop = Enhance.autoCrop(deskPage, quad: paperQuad)
        check(crop.applied, "给出纸的四边形时确实执行了裁边（\(crop.note ?? "无说明")）")
        let dw = abs(crop.image.width - pw), dh = abs(crop.image.height - ph)
        check(dw <= pw * 18 / 100 && dh <= ph * 18 / 100,
              "裁后尺寸接近纸的实际大小（\(crop.image.width)×\(crop.image.height)，期望约 \(pw)×\(ph)）")

        // 2) 桌面被裁掉了：四角该是纸白
        if let g = GrayBitmap.from(crop.image, maxDim: 0) {
            let bw = max(1, g.width / 16), bh = max(1, g.height / 16)
            var lo = 255
            for (ox, oy) in [(0, 0), (g.width - bw, 0), (0, g.height - bh), (g.width - bw, g.height - bh)] {
                var s = 0, n = 0
                for y in oy..<min(g.height, oy + bh) {
                    for x in ox..<min(g.width, ox + bw) { s += Int(g.pixels[y * g.width + x]); n += 1 }
                }
                lo = min(lo, s / max(1, n))
            }
            check(lo >= 200, "裁后四角是纸面、桌面已被切掉（最暗角均 \(lo)，原图约 90）")
        } else {
            check(false, "裁边结果能取到灰度")
        }

        // 3) ★ 方向：纸内左上角的黑方块，裁完必须还在左上。
        //    用"只有标记、没有文字"的图，象限判定才不会被文字行冲淡
        //    （带文字的版本里文字像素比标记多两个数量级，象限结论会被文字带跑）。
        if let markerOnly = makeDeskPhotoPage(width: 2000, height: 2600, margin: 0.16,
                                              rotate: 0, marker: true, text: false) {
            let mc = Enhance.autoCrop(markerOnly, quad: paperQuad)
            let q = darkQuadrant(mc.image)
            check(mc.applied && q.hasPrefix("左上"),
                  "裁边没有镜像画面：纸内左上角的标记裁完仍在左上（实测 \(q)）")
        } else {
            check(false, "能造出方向基准图")
        }

        // 4) ★ 边缘不许残留桌面。旋转页上四角会差一两个像素，
        //    修边不修的话结果里就是一条被二值化染黑的窄边（约 1% 宽）。
        if let rotDesk = makeDeskPhotoPage(width: 2000, height: 2600, margin: 0.16,
                                           rotate: 3.5, marker: true, text: true) {
            let rc = Enhance.autoCrop(rotDesk, quad: rotatedPaperQuad(margin: 0.16, degrees: 3.5))
            if let g = GrayBitmap.from(rc.image, maxDim: 0) {
                let bw = max(1, Int(Double(g.width) * 0.02))
                let bh = max(1, Int(Double(g.height) * 0.02))
                var s = 0, n = 0, dark = 0
                for y in 0..<g.height {
                    for x in 0..<g.width {
                        let on = x < bw || x >= g.width - bw || y < bh || y >= g.height - bh
                        if on {
                            let v = Int(g.pixels[y * g.width + x])
                            s += v; n += 1
                            // 「残留桌面」的直接证据：二值化会把这个窄条染成近黑。
                            // **必须用占比而不是均值** —— 残留桌面只占约 1% 宽，
                            // 混进整圈里对均值几乎没有影响（实测 254 → 247），
                            // 用均值当判据的断言**永远不会红**。
                            if v < 128 { dark += 1 }
                        }
                    }
                }
                let mean = s / max(1, n)
                let darkRatio = Double(dark) / Double(max(1, n))
                // ⚠️ 这条断言的第一版是**假的**，而且它自己不知道。
                //    第一版判据是 `mean >= 235`。实测把修边整个关掉之后，
                //    边圈均值只从 254 掉到 247 —— **照样绿**。
                //    换判据：数暗像素占比。关掉修边 3.26% vs 开着 0.12%，
                //    差 27 倍；门槛取 1%，两边都有余量。
                //    —— 「一条不会红的断言，等于没有断言。」
                check(rc.applied && darkRatio < 0.01,
                      String(format: "旋转页裁完贴边一圈没有残留桌面（暗像素 %d/%d = %.2f%%，边圈均值 %d；桌面约 85）",
                             dark, n, darkRatio * 100, mean))
            } else {
                check(false, "旋转页裁边结果能取到灰度")
            }
        } else {
            check(false, "能造出旋转的桌面测试件")
        }

        // 5) 闸门 1（自交／畸变）：把左下和右下换个位置，四边形就拧了。
        //    CIPerspectiveCorrection 遇到这种输入会安静地产出一张扭坏的图，
        //    所以必须有闸门拦。**note 必须点名"畸变"** —— 只断言"没裁"
        //    说明不了是哪道闸门起的作用（别的闸门也拦得下）。
        let twisted = Enhance.DocumentQuad(topLeft: CGPoint(x: 0.16, y: 0.84),
                                           topRight: CGPoint(x: 0.84, y: 0.84),
                                           bottomLeft: CGPoint(x: 0.84, y: 0.16),
                                           bottomRight: CGPoint(x: 0.16, y: 0.16),
                                           coverage: 0.46)
        let tw = Enhance.autoCrop(deskPage, quad: twisted)
        check(!tw.applied && (tw.note ?? "").contains("畸变"),
              "闸门1（畸变）：自交四边形被拦下（\(tw.note ?? "无说明")）")

        // 6) 闸门 2（占比）：给出一个"铺满整幅"的四边形
        let wholeQuad = Enhance.DocumentQuad.upright(x0: 0, y0: 0, x1: 1, y1: 1, coverage: 0.968)
        let whole = Enhance.autoCrop(deskPage, quad: wholeQuad)
        check(!whole.applied && (whole.note ?? "").contains("铺满整幅"),
              "闸门2（占比）：检出占比 97% 时跳过（\(whole.note ?? "无说明")）")

        // 7) 闸门 3（形状）：又窄又长的一条
        let sliverQuad = Enhance.DocumentQuad.upright(x0: 0.40, y0: 0.05, x1: 0.60, y1: 0.95)
        let sliver = Enhance.autoCrop(deskPage, quad: sliverQuad)
        check(!sliver.applied && (sliver.note ?? "").contains("狭长"),
              "闸门3（形状）：又窄又长的四边形被拦下（\(sliver.note ?? "无说明")）")

        // 8) ★ 闸门 4（外侧亮）—— **这才是真正拦住满幅扫描页的那条**。
        //    造一页满幅白纸 + 黑文字的"扫描件"（压根没有桌面），
        //    给它一个内缩 2% 的四边形：占比 0.92，既不 ≥0.96 也不 <0.10，
        //    形状也是正常矩形 —— 闸门 1/2/3 全都放它过去。
        //    唯一能拦住它的是"边界外侧必须暗下去"，因为外侧还是纸。
        //    note 必须点名"外侧"，否则可能是被别的闸门顺带拦下的。
        guard let wctx = CGContext(data: nil, width: 1600, height: 2200, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw NSError(domain: "selftest", code: 31)
        }
        wctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        wctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 2200))
        wctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1))
        var yy = 2100.0
        while yy > 80 { wctx.fill(CGRect(x: 60, y: yy, width: 1480, height: 14)); yy -= 60 }
        guard let fullPage = wctx.makeImage() else { throw NSError(domain: "selftest", code: 32) }
        let insetQuad = Enhance.DocumentQuad.upright(x0: 0.02, y0: 0.02, x1: 0.98, y1: 0.98)
        let full = Enhance.autoCrop(fullPage, quad: insetQuad)
        check(!full.applied && (full.note ?? "").contains("外侧"),
              "闸门4（外侧亮）：满幅扫描页没被裁，且是被外侧判据拦下的（\(full.note ?? "无说明")）")
        check(full.image.width == fullPage.width && full.image.height == fullPage.height,
              "满幅页裁后尺寸不变（\(full.image.width)×\(full.image.height)）")

        // 9) 闸门 4 的另一个现场：**纸几乎铺满整幅**。
        //    实测这张图（margin .04）真实占比 0.846，而 Vision 只报 0.597 ——
        //    覆盖率**低估**，照它裁会切掉 15% 正文。
        //    这一条要拆成一对来测，因为"该不该裁"取决于**四边形准不准**，
        //    而不是取决于"纸大不大"：
        //      · 四边形是准的 → 外侧确实是那 4% 的桌面 → **该裁**；
        //      · 四边形低估了 → 外侧还是纸 → **必须拦**。
        //    只测后者会让读者以为"纸大就不裁"，那是错的；
        //    只测前者则完全丢了守则的意义。
        if let tight = makeDeskPhotoPage(width: 2000, height: 2600, margin: 0.04,
                                         rotate: 0, marker: true, text: true) {
            let trueQuad = Enhance.DocumentQuad.upright(x0: 0.04, y0: 0.04, x1: 0.96, y1: 0.96)
            let tc = Enhance.autoCrop(tight, quad: trueQuad)
            check(tc.applied && abs(tc.image.width - 1840) <= 40,
                  "四边形给准时，纸几乎铺满也照裁（\(tc.image.width)×\(tc.image.height)，期望约 1840）")

            // 模拟 Vision 的那次低估：面积 0.597 ⇒ 边长 √0.597 ≈ 0.773，
            // 于是四角落在 0.1136 / 0.8864。这个盒子完全在纸内，
            // 所以"盒外薄带"采到的**还是纸**（纸从 0.04 才开始）。
            // 注意 0.597 既不 ≥0.96 也不 <0.10，形状也是正常矩形 ——
            // 闸门 1/2/3 全放它过去，唯一拦得住的是外侧判据。
            let underestimated = Enhance.DocumentQuad.upright(x0: 0.1136, y0: 0.1136,
                                                              x1: 0.8864, y1: 0.8864,
                                                              coverage: 0.597)
            let t = Enhance.autoCrop(tight, quad: underestimated)
            check(!t.applied && (t.note ?? "").contains("外侧"),
                  "闸门4（外侧亮）：同图同上，边界被低估时宁可不动手（\(t.note ?? "无说明")）")
        } else {
            check(false, "能造出「纸几乎铺满」的测试件（准四边形那组）")
            check(false, "能造出「纸几乎铺满」的测试件（低估四边形那组）")
        }

        // 10) 默认必须是关的：字段留了这么久就是"只勾了才做"。
        //     没勾却被裁，等于用户没同意就丢了像素。
        let off = Enhance.applyReporting(deskPage, spec: EnhanceSpec(preset: "auto"))
        check(!off.cropApplied && off.image.width == deskPage.width,
              "没开自动裁边时不动画面（尺寸 \(off.image.width)×\(off.image.height)）")

        // 11) 裁边必须排在纠偏之前。用"同时开两个"来验：
        //     若顺序写反，纠偏会先在带桌面的整幅图上算倾斜（桌沿的直线会把
        //     投影剖面带偏），裁完的尺寸也会不一样。这里断言结果尺寸仍是纸的尺寸。
        //
        //     ⚠️ 必须走 `cropQuad:` 这条不经过 Vision 的入口 —— 否则本系统的
        //     Vision 一检不出来，裁边就不动手，"顺序"这件事根本无从观察，
        //     这条断言会退化成"什么都没发生也算过"。v0.3.4 第一次推送时，
        //     整节 7 条红里有 1 条就是它（拆了 autoCrop 却漏了 applyReporting）。
        let both = Enhance.applyReporting(deskPage, spec: EnhanceSpec(preset: "auto", deskew: true,
                                                                      autoCrop: true, bgStrength: 0.5),
                                          cropQuad: paperQuad).image
        check(both.width < deskPage.width * 90 / 100,
              "裁边 + 纠偏同时开时，裁边确实先生效（\(deskPage.width) → \(both.width)）")

        // ================= ② 检出层（唯一依赖 Vision 的断言） =================

        // 这一层**两个系统上的期望值本来就不同**，所以不能写成"必须检出"：
        //   · macos-26 的 Vision 模型能检出这张合成件；
        //   · macos-14 的模型检不出（实测：同样这份代码、同样这张图）。
        // 于是写成二选一，但**两支都是有意义的要求**，而且各放**两条**断言
        // —— 两支条数必须相等，否则汇总行里的"共 N 条"会随系统变，
        // 文档里那个数字就又要漂了（这正是 #34 那个坑）。
        if let q = Enhance.documentQuad(deskPage) {
            let errs = [abs(Double(q.topLeft.x) - 0.16), abs(Double(q.topLeft.y) - 0.84),
                        abs(Double(q.topRight.x) - 0.84), abs(Double(q.topRight.y) - 0.84),
                        abs(Double(q.bottomLeft.x) - 0.16), abs(Double(q.bottomLeft.y) - 0.16),
                        abs(Double(q.bottomRight.x) - 0.84), abs(Double(q.bottomRight.y) - 0.16)]
            let worstErr = errs.max() ?? 9
            print("  · 本系统的 Vision 文档分割：**能检出**合成件（覆盖率 \(String(format: "%.2f", q.coverage))）")
            check(worstErr < 0.08,
                  String(format: "检出的四角位置正确（最大偏差 %.3f，覆盖率 %.2f）", worstErr, q.coverage))
            // 顺带端到端跑一次真实的"检出 → 裁"通路（几何层已经分别测过了）
            let e2e = Enhance.autoCrop(deskPage)
            check(e2e.applied && e2e.image.width < deskPage.width,
                  "端到端：检出后确实裁小了（\(deskPage.width) → \(e2e.image.width)）")
        } else {
            print("  · 本系统的 Vision 文档分割：**检不出**合成件（macos-14 的模型就是这样，已记录在案）")
            let none = Enhance.autoCrop(deskPage)
            check(!none.applied && none.image.width == deskPage.width,
                  "检不出边界时一个像素都不动（尺寸 \(none.image.width)×\(none.image.height)）")
            check((none.note ?? "").contains("没检出"),
                  "并且给出了可读的原因，不是静默跳过（\(none.note ?? "无说明")）")
        }
    } catch {
        print("  ✗ 自动裁边测试失败：\(error)")
        failures += 1
    }

    print("==> 二值化：把「为什么没用 Sauvola」这件事钉成断言")
    do {
        // 这一节的存在不是为了验证某个算法"对"，而是把一次**被实测否决的升级**
        // 固化成回归测试。上一轮我一度把 binarize 换成 Sauvola
        // （T = μ[1 − k(1 − σ/R)]，k=0.34、R=128），看着更"标准"，
        // 实测却是**退步**：光照渐变页的亮侧整片被抹白（墨水率 3.87% → 1.45%）。
        //
        // 根因是 R=128 的量纲——它是按高对比度文档标定的，而真实扫描件
        // 笔画 σ 常只有 10~20，于是 factor 掉到 0.66，浅笔画全部掉到阈值以上。
        // 把 k 压到 0.10 能救回来，但那与旧的 `μ×0.90` **逐像素相同**
        // （沙箱实测差 0.000%），等于绕一圈回到原点。
        //
        // 所以下面两条断言是"反向守卫"：它们**不是**在测旧算法多好，
        // 而是在拦"以后有人觉得 Sauvola 更学术就顺手换掉"这件事。
        // 换回去的那天，这两条会红，而注释里写着为什么当初换掉了。

        // —— 断言 A：光照渐变页，左右的墨水率必须相当 ——
        // 这是 Sauvola(R=128) 当初翻车的那张页。造一页横向渐变：
        // 纸白从 250 缓降到 150，两侧铺同样的字。
        //
        // 判据用**比值**而非差值：两侧都只有百分之几的墨水时，
        // 绝对差没有判别力，而"Sauvola 把亮侧抹白"会让亮侧直接变成 0
        // （沙箱实测：亮侧 0.00% / 暗侧 3.62%）。
        guard let gctx = CGContext(data: nil, width: 600, height: 800, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw NSError(domain: "selftest", code: 10)
        }
        // 逐列画渐变底色：CoreGraphics 的 CGGradient 不好在 draw 流程里精确控制，
        // 逐列 fill 虽然土，但每个像素的灰度完全可控，断言才有确定性。
        for x in 0..<600 {
            let t = Double(x) / 599.0
            let level = (250.0 - 100.0 * t) / 255.0      // 纸白 250 → 150
            gctx.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
            gctx.fill(CGRect(x: x, y: 0, width: 1, height: 800))
        }
        // 两侧铺同样的文字：同样的字、同样字号 → 同样的墨水覆盖。
        //
        // **字色是关键，不能随手用纯黑。** 我把「字比纸面暗多少」扫了一遍：
        // Sauvola(R=128) 只在**中等对比度**上翻车——
        // 字比纸暗 120 以上（接近纯黑）时两套算法输出完全相同，
        // 而暗 40~80 这一段（褪色件、复印件、浅墨扫描件的常态）它会把
        // 暗侧整片抹白。用纯黑的话两条算法都过，断言就成了摆设
        // （第一版正是这么写的，写完自查才发现）。
        //
        // 取 0.55（≈140）是因为它同时满足两件事：亮侧（纸 250）比它亮 110，
        // 暗侧（纸 175）只比它亮 35 —— 对比度一高一低，
        // 正好把"两套算法在暗侧/亮侧的分歧"逼出来。沙箱实测：
        //   旧 μ×0.90         亮 2.92%  暗 2.68%  比 0.92x  → 过
        //   Sauvola k=.34 R=128 亮 2.92%  暗 0.00%  比 0.00x  → 红（就是它该红的样子）
        //   Sauvola k=.10 R=128 亮 2.92%  暗 2.76%  比 0.95x  → 过（退化成旧算法）
        //
        // 另外**必须显式设色**：drawTextLine 自己不设 fillColor，
        // 用它就会沿用上下文当前颜色，而上面刚画完渐变的最后一列（灰 150）。
        gctx.setFillColor(CGColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1))
        for i in 0..<4 {
            let y = CGFloat(620 - i * 90)
            drawTextLine(gctx, "Gradient lit test", 40, y, 26)
            drawTextLine(gctx, "Gradient lit test", 340, y, 26)
        }
        guard let gradientPage = gctx.makeImage() else { throw NSError(domain: "selftest", code: 11) }
        if let bin = Enhance.binaryMap(gradientPage) {
            // 只统计文字所在的纵向区间（4 行字在 y=620/530/440/350 附近，
            // 每行约 26pt 高），避开上下大片空白——空白区域的墨水率只反映
            // "背景有没有被误判"，会把"笔画有没有丢"这件事稀释掉。
            func sideInk(_ x0: Int, _ x1: Int) -> Double {
                var ink = 0, total = 0
                for y in 340..<min(660, bin.height) {
                    let base = y * bin.width
                    for x in x0..<min(x1, bin.width) {
                        if bin.pixels[base + x] < 128 { ink += 1 }
                        total += 1
                    }
                }
                return total > 0 ? Double(ink) / Double(total) : 0
            }
            let litInk = sideInk(40, 300)        // 亮侧：纸白 ≈ 250
            let darkInk = sideInk(340, 600)      // 暗侧：纸白 ≈ 175 ~ 150
            let ratio = litInk > 0.0005 ? darkInk / litInk : 99
            check(ratio > 0.4 && ratio < 2.5,
                  String(format: "光照渐变页两侧墨水率相当（亮侧 %.2f%% / 暗侧 %.2f%% = %.2fx）",
                         litInk * 100, darkInk * 100, ratio))
            // 亮侧不能是 0：Sauvola(R=128) 当初就是把亮侧抹成 0 的。
            // 这条单独拎出来，因为"比值"在亮侧=0 时会退化成 99，同样是红，
            // 但报出来的数字（99.00x）不如"亮侧 0%"直观。
            check(litInk > 0.005,
                  String(format: "渐变页亮侧的笔画没被抹掉（亮侧墨水率 %.2f%%）", litInk * 100))
        } else {
            check(false, "光照渐变页能二值化")
        }

        // —— 断言 B：均匀背景上的孤立浅噪点不该变成黑斑 ——
        // 纸白 250 上撒 400 个 230 的孤立噪点（每个周围都是纯背景）。
        // 旧算法：窗口内 μ≈250，阈值 225，噪点 230 高于它 → 不判墨。
        // 这条同时守住"以后改阈值系数时别把背景改脏"。
        guard let nctx = CGContext(data: nil, width: 500, height: 500, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw NSError(domain: "selftest", code: 12)
        }
        nctx.setFillColor(CGColor(red: 250.0 / 255, green: 250.0 / 255, blue: 250.0 / 255, alpha: 1))
        nctx.fill(CGRect(x: 0, y: 0, width: 500, height: 500))
        nctx.setFillColor(CGColor(red: 230.0 / 255, green: 230.0 / 255, blue: 230.0 / 255, alpha: 1))
        // 固定种子的线性同余，保证每次跑噪点位置完全一致——
        // 否则断言会随机的红一下绿一下，那种断言比没有更坏。
        var seed: UInt64 = 987654321
        func rnd(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        for _ in 0..<400 {
            // 留 20px 边距，避开窗口越界处的边界效应
            nctx.fill(CGRect(x: 20 + rnd(460), y: 20 + rnd(460), width: 1, height: 1))
        }
        guard let noisyPage = nctx.makeImage() else { throw NSError(domain: "selftest", code: 13) }
        if let bin = Enhance.binaryMap(noisyPage) {
            var ink = 0
            for v in bin.pixels where v < 128 { ink += 1 }
            let ir = Double(ink) / Double(bin.count)
            check(ir < 0.0005,
                  String(format: "均匀背景上的孤立噪点没被放大成黑斑（墨水率 %.3f%%，400 个噪点占 %.3f%%）",
                         ir * 100, 400.0 / 250000.0 * 100))
        } else {
            check(false, "噪点页能二值化")
        }
    } catch {
        print("  ✗ 二值化测试失败：\(error)")
        failures += 1
    }

    print("==> 纸白判据：分位点会被大面积白块骗过去，均值这一支必须兜住")
    do {
        // ★ 这条断言的第一版写错了前提，改过之后反而更有价值，记下来：
        //   我原本以为"撒几粒纯白噪点就能把 p80 推到 255"，于是断言用 0.3% 噪点。
        //   实际在沙箱里用 numpy 复刻这个判据扫了一遍才发现**根本不成立**：
        //   p80 要往上跳，需要接近 20% 的像素都在亮端——0.3% 的噪点离得远着呢
        //   （实测：240 的灰纸撒 25% 白点，分位点才从 240 跳到 255；15% 时纹丝不动）。
        //   换句话说"抗噪点"是个假命题，分位点对稀疏噪点相当稳健。
        //
        //   分位点真正的失效模式是**结构性的**：页面里有一大块接近白的区域。
        //   这在真实文档里一点不罕见——未印满的页、大面积留白、页眉白边、
        //   双栏排版中间的空白带、表格空行。只要白块占比 ≥20%，
        //   分位点就看不出剩下的大半张纸是灰的。
        //   所以断言改成造这个场景：整页 230 的灰纸 + 25% 的 250 白块。
        guard let ctx = CGContext(data: nil, width: 400, height: 560, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw NSError(domain: "selftest", code: 1) }
        ctx.setFillColor(CGColor(red: 0.902, green: 0.902, blue: 0.902, alpha: 1))  // ≈230 的灰纸
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 560))
        // 一块占 25% 面积的接近白区域（用 250，不是纯白——更贴近真实的"白边"）
        ctx.setFillColor(CGColor(red: 0.980, green: 0.980, blue: 0.980, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 140))   // 140/560 = 25%
        drawTextLine(ctx, "Paper white criterion", 24, 400, 22)
        guard let mixed = ctx.makeImage() else { throw NSError(domain: "selftest", code: 2) }

        let q = Enhance.paperLevel(mixed)
        let m = Enhance.paperMean(mixed)
        print(String(format: "  · 灰纸(230) + 25%%白块(250)：分位点 %.0f，真实均值 %.0f", q, m))
        // 1) 分位点确实被骗了——留证据，说明单判据在这里会漏判
        check(q >= 249, String(format: "分位点被大面积白块推高到 %.0f（这正是单判据会漏判的原因）", q))
        // 2) 均值没被骗
        check(m < 250, String(format: "真实均值没被骗（%.0f，应当低于 250）", m))
        // 3) 双判据的结论：仍需要清理
        check(Enhance.needsBackgroundClean(mixed),
              String(format: "灰纸 + 白块被判为需要清理（分位点 %.0f / 均值 %.0f）", q, m))
        // 4) 反向守卫：白块占比低于 20% 时，分位点**不该**被骗
        //    （15% 白块时分位点仍落在灰纸那一档，说明这条判据没被调得过松）
        guard let ctx2 = CGContext(data: nil, width: 400, height: 560, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw NSError(domain: "selftest", code: 3) }
        ctx2.setFillColor(CGColor(red: 0.902, green: 0.902, blue: 0.902, alpha: 1))
        ctx2.fill(CGRect(x: 0, y: 0, width: 400, height: 560))
        ctx2.setFillColor(CGColor(red: 0.980, green: 0.980, blue: 0.980, alpha: 1))
        ctx2.fill(CGRect(x: 0, y: 0, width: 400, height: 84))    // 84/560 = 15%
        guard let small = ctx2.makeImage() else { throw NSError(domain: "selftest", code: 4) }
        print(String(format: "  · 灰纸(230) + 15%%白块：分位点 %.0f，真实均值 %.0f",
                     Enhance.paperLevel(small), Enhance.paperMean(small)))
        check(Enhance.needsBackgroundClean(small), "15% 白块的灰纸同样判为需要清理")
    } catch {
        print("  ✗ 纸白判据测试失败：\(error)")
        failures += 1
    }

    print("==> PDF 字符串转义：控制字符不许写坏 Info 字典")
    do {
        // 标题里的换行曾经会原样写进 ( ) 字面量，让 /Info 字典提前断行。
        // 这是真会发生的：标题取自文件名，而文件名带换行完全可能。
        // 断言方式：写一个含 \n \r \t 和括号反斜杠的标题，再打开 PDF 读 /Title——
        // 能原样读回来才算转义正确。
        let weird = "Lumo\ntest\t(括号)\\反斜杠\r结束"
        let escPdf = tmp.appendingPathComponent("escape.pdf")
        guard let quad = makeQuadImage() else { throw NSError(domain: "selftest", code: 1) }
        let enc = Compressor.encode(quad, CompressSpec(adaptive: false, colorMode: "gray", quality: 80))
        _ = try PDFWriter.write(pages: [OutputPage(image: enc, dpi: 72, lines: nil)],
                                to: escPdf, title: weird)
        // 1) 文件本身必须是合法 PDF：能被 CGPDFDocument 打开就说明结构没坏
        guard let doc = PDFReader.open(escPdf) else {
            check(false, "含控制字符标题的 PDF 能打开")
            throw NSError(domain: "selftest", code: 3)
        }
        check(PDFReader.pageCount(doc) == 1, "含控制字符标题的 PDF 页数正确")
        // 2) 直接判据：把 /Title 读回来，必须和写进去的一字不差。
        //    这是"转义正确"的直接证据——写进去什么，CoreGraphics 解开就得是什么。
        //    原先这里用的是"前 2KB 不许出现裸控制字节"，那条断言是错的：
        //    PDF 头部紧跟着就是 JPEG 数据流，流里出现任意字节都合法。
        //    实测（CI run 50）：前 2KB 里 294 个裸控制字节，全部落在图像流内，
        //    PDF 结构部分（文件头 + 对象字典）一个都没有。断言红了但代码是对的，
        //    真正的缺陷在我的断言里——扫描范围盖住了合法数据。
        if let got = PDFReader.infoTitle(doc) {
            check(got == weird, "标题读回来一字不差（写 \(weird.count) 字 / 读 \(got.count) 字）")
        } else {
            check(false, "能从 /Info 读回标题")
        }
        // 3) 再补一条字节层面的守卫，但只查 PDF 结构区——即第一个二进制流开始之前。
        //    这样既保留了"不许有裸控制字节"的意图，又不会误伤图像数据。
        if let raw = try? Data(contentsOf: escPdf) {
            let body = [UInt8](raw)
            // 结构区 = 文件头 + 全部对象字典，直到第一个 'stream' 关键字。
            // 找不到 stream（理论上不可能）就退回整体检查。
            let streamPos = body.withUnsafeBufferPointer { buf -> Int in
                let kw = Array("stream".utf8)
                for i in 0...(buf.count - kw.count) where Array(buf[i..<(i + kw.count)]) == kw { return i }
                return buf.count
            }
            var rawControls = 0
            for b in body.prefix(streamPos) where (b < 0x09) || (b > 0x0D && b < 0x20) { rawControls += 1 }
            check(rawControls == 0,
                  "PDF 结构区（前 \(streamPos) 字节）没有裸控制字符（发现 \(rawControls) 个）")
        } else {
            check(false, "能读回 PDF 字节")
        }
        // 4) 简单标题的往返：确认转义没有把正常字符弄坏（过度转义的守卫）
        let plainPdf = tmp.appendingPathComponent("plain.pdf")
        _ = try PDFWriter.write(pages: [OutputPage(image: enc, dpi: 72, lines: nil)],
                                to: plainPdf, title: "Lumo 普通标题")
        if let pdoc = PDFReader.open(plainPdf) {
            check(PDFReader.infoTitle(pdoc) == "Lumo 普通标题", "普通标题读回来一字不差")
        } else {
            check(false, "普通标题的 PDF 依旧能打开")
        }
    } catch {
        print("  ✗ PDF 转义测试失败：\(error)")
        failures += 1
    }

    print("==> 流式写入：xref 偏移必须指向真实对象（页数一多就藏不住）")
    do {
        // 为什么单列这一条：流式写入器为了把内存和页数解耦，会把已写好的字节
        // 分批倾倒到磁盘、清空缓冲。于是 Builder 里记的偏移只是"相对当前缓冲"的，
        // 必须叠加"已落盘前缀长度"。**漏加的话 startxref 会指到文件开头附近**，
        // 表现是文件生成得出来、体积也正常，但阅读器打不开——
        // 从体积上完全看不出来，所以必须在这里真的把字节拆开逐个核对。
        //
        // 用 6 页、且刻意让每页图像大小不同：如果各页长度凑巧一样，
        // 偏移误差会被"每页同样大小"掩盖掉，测不出问题。
        var variantPages: [OutputPage] = []
        for i in 0..<6 {
            guard let p = makeScanPage(width: 620 + i * 40, height: 877 + i * 40, tilt: 0, seed: i + 1)
            else { throw NSError(domain: "selftest", code: 1) }
            let spec = CompressSpec(adaptive: false, colorMode: "gray",
                                   colorEncoder: "jpeg", quality: 55 + i * 5)
            variantPages.append(OutputPage(image: Compressor.encode(p, spec), dpi: 100, lines: nil))
        }
        let swPdf = tmp.appendingPathComponent("stream.pdf")
        let written = try PDFWriter.write(pages: variantPages, to: swPdf, title: "Lumo stream selftest")
        check(written > 0, "流式写入返回了字节数（\(written)）")
        // 文件长度必须与返回值一致——返回值拿的是落盘累计量，
        // 如果 flush 记账有误，这两个数就对不上。
        if let raw = try? Data(contentsOf: swPdf) {
            check(raw.count == written,
                  "落盘字节数与返回值一致（文件 \(raw.count) / 返回 \(written)）")
            let bytes = [UInt8](raw)
            // 1) startxref 指向的必须是 "xref"
            //
            // 解码方式必须用 latin-1，**不能用 `.ascii`**：整份 PDF 从第 10 个
            // 字节起就带着标准的二进制标记注释 `%\xe2\xe3\xcf\xd3`，再加上
            // JPEG / CCITT 码流，文件里大约一半的字节 ≥0x80。而
            // `String(data:encoding:.ascii)` 只要撞见**一个**高位字节就整体返回
            // nil，于是断言直接掉进 else 分支、报"文件里有 startxref"失败——
            // **产物是好的，是这条断言的解码方式太脆**（本机 Swift 6.4 上实测复现；
            // 这类"解码器行为随平台变"的坑和踩坑清单里的静默失效同一族）。
            // latin-1 对任意字节都有定义、且与字节 1:1 对应，搜出来的偏移可以
            // 直接当字节偏移用，正好满足下面逐个核对 xref 条目的需要。
            let asciiText = String(data: raw, encoding: .isoLatin1)
            if let sx = asciiText?.range(of: "startxref") {
                let after = asciiText![sx.upperBound...]
                let numStr = after.drop(while: { $0 == "\n" || $0 == "\r" })
                    .prefix(while: { $0.isNumber })
                let pos = Int(numStr) ?? -1
                let at = pos >= 0 && pos + 4 <= bytes.count
                    ? String(decoding: bytes[pos..<(pos + 4)], as: UTF8.self) : "越界"
                check(at == "xref", "startxref 指向 xref 表（\(pos) 处是 \(at)）")
                // 2) 逐个对象核对：xref 里记的偏移处必须是 "<n> 0 obj"
                //
                // 这里的解析有两个坑，我第一次全踩了，值得写下来：
                //   · xref 段落形如 "xref\n0 N\n<自由项>\n<对象1>\n<对象2>…"，
                //     条目是 20 字节定长，格式 "OOOOOOOOOO GGGGG n \n"——
                //     第二段是代号（00000），第三段才是 n/f。拿 parts[1] 判 n
                //     会一个都匹配不上，于是"核对 0 个、错位 0 个"**真空通过**。
                //   · 对象号不能在过滤掉自由项之后用 enumerated() 的下标去推，
                //     必须自己独立计数：n 条目按出现顺序依次对应对象 1、2、3…
                //     前者在跳过自由项后会整体错位一位。
                var bad = 0
                var checked = 0
                let text = asciiText ?? ""
                if let xr = text.range(of: "xref\n0 ") {
                    let lines = text[xr.upperBound...]
                        .split(separator: "\n", omittingEmptySubsequences: false)
                        .dropFirst()          // 跳过 "N 65535 f" 这一行（自由项）
                    var objNo = 1
                    for line in lines {
                        let parts = line.split(separator: " ")
                        guard parts.count >= 3, parts[2] == "n" else { continue }
                        guard let off = Int(parts[0]) else { bad += 1; objNo += 1; continue }
                        let expect = "\(objNo) 0 obj"
                        checked += 1
                        if off + expect.count > bytes.count
                            || String(decoding: bytes[off..<(off + expect.count)], as: UTF8.self) != expect {
                            bad += 1
                        }
                        objNo += 1
                    }
                }
                // 先断言"真的核对了对象"，否则这条断言会退化成真空通过。
                // 这正是本轮反复出现的教训：**断言除了"过不过"，还得问"能不能不过"。**
                check(checked >= 12, "确实核对到了 xref 条目（\(checked) 个）")
                check(bad == 0, "每个 xref 条目都指向自己的对象（核对 \(checked) 个，错位 \(bad) 个）")
            } else {
                check(false, "文件里有 startxref")
            }
        } else {
            check(false, "能读回流式写入的 PDF 字节")
        }
        // 3) 最终判据：产物得能被 CoreGraphics 打开、页数对得上
        if let sdoc = PDFReader.open(swPdf) {
            check(PDFReader.pageCount(sdoc) == 6, "流式产物页数正确（6）")
        } else {
            check(false, "流式产物能被 CGPDFDocument 打开")
        }
    } catch {
        print("  ✗ 流式写入测试失败：\(error)")
        failures += 1
    }

    print("==> 文字层 + MRC 同时开启（这对组合此前从未跑过）")
    do {
        // 为什么单列这一条：现有的 MRC 测试全都把 OCR 关掉，现有的文字层测试
        // 又全都把 MRC 关掉——两条最重要的通路各自跑得好好的，
        // 但"同一页既有分层压缩又有文字层"从没被端到端验证过。
        // 而这两者会争对象编号：MRC 页要多占一个对象号，文字层要多占整整 4 个。
        // 编号错一位的后果是"文件能打开但内容错位"，体积断言完全发现不了。
        // 所以这里必须真的把两件事同时打开，再渲染回来确认画面还在。
        guard let page = makeScanPage(width: 1240, height: 1754, tilt: 0, seed: 0) else {
            throw NSError(domain: "selftest", code: 1)
        }
        let mrcSpec = CompressSpec(adaptive: false, colorMode: "color", colorEncoder: "jpeg",
                                   monoEncoder: "ccitt", quality: 60)
        guard let layered = Compressor.encodeMRC(page, mrcSpec) else {
            check(false, "能生成 MRC 分层页")
            throw NSError(domain: "selftest", code: 2)
        }
        print("  · MRC 已生成：背景 \(layered.background.data.count) 字节 + 蒙版 \(layered.mask.data.count) 字节")
        // 造两行假 OCR 结果（不需要真去识别，测的是写出逻辑不是识别精度）。
        // rect 是归一化坐标、原点在左下——跟 PDF 页坐标同向。
        let lines = [
            OCRLine(text: "Lumo selftest line one", rect: CGRect(x: 0.10, y: 0.80, width: 0.60, height: 0.03)),
            OCRLine(text: "Lumo selftest line two", rect: CGRect(x: 0.10, y: 0.74, width: 0.60, height: 0.03)),
        ]
        let bothPdf = tmp.appendingPathComponent("mrc-text.pdf")
        _ = try PDFWriter.write(pages: [OutputPage(image: layered.background, dpi: 150,
                                                   lines: lines, visibleText: false, mrc: layered)],
                                to: bothPdf, title: "Lumo MRC + text selftest")
        guard let doc = PDFReader.open(bothPdf) else {
            check(false, "MRC + 文字层的 PDF 能打开")
            throw NSError(domain: "selftest", code: 3)
        }
        check(PDFReader.pageCount(doc) == 1, "MRC + 文字层的 PDF 页数正确")
        // 关键：渲染回来画面必须有内容（对象编号错位会渲染出空白或错位图）
        if let im = PDFReader.render(doc, 0, dpi: 150), let g = GrayBitmap.from(im) {
            var ink = 0
            for v in g.pixels where v < 128 { ink += 1 }
            let ratio = Double(ink) / Double(max(1, g.count))
            check(ratio > 0.001, String(format: "MRC + 文字层渲染回来仍有内容（墨水率 %.2f%%）", ratio * 100))
        } else {
            check(false, "MRC + 文字层能渲染")
        }
        // 文字层是否真的落盘：用 CLI 一直在用的 existingTextChars 数回来。
        // 不另造一个 hasTextLayer API——多一个入口就多一处可能跟真实读取不一致。
        let chars = PDFReader.existingTextChars(bothPdf)
        check(chars > 0, "文字层真的写进去了（读回 \(chars) 个字符）")
    } catch {
        print("  ✗ MRC + 文字层测试失败：\(error)")
        failures += 1
    }

    print("==> CCITT 条带：多 strip 必须拼接而不是静默降级")
    do {
        // 先实测 ImageIO 会不会切条带——这条断言本身就是"先量再改"的产物。
        guard let tall = makeScanPage(width: 1240, height: 1754, tilt: 0, seed: 1) else {
            throw NSError(domain: "selftest", code: 1)
        }
        let monoSpec = CompressSpec(adaptive: false, colorMode: "mono", monoEncoder: "ccitt")
        let out = Compressor.encode(tall, monoSpec)
        check(out.encoderUsed == "CCITT G4",
              "单色页走的确实是 CCITT G4（实际 \(out.encoderUsed)）")
        if let s = Compressor.lastCCITTStripInfo() {
            print("  · 条带实况：count=\(s.count) rowsPerStrip=\(s.rowsPerStrip) rows=\(s.rows)")
            check(s.count >= 1, "拿到了条带信息（count=\(s.count)）")
        } else {
            check(false, "能读到 TIFF 条带信息")
        }
        // 往返一致性：拼接如果错了，画面会花，墨水率必然对不上。
        // 这是唯一能证明"拼接正确"的判据——只报条带数证明不了任何事。
        let monoPdf = tmp.appendingPathComponent("strip.pdf")
        _ = try PDFWriter.write(pages: [OutputPage(image: out, dpi: 150, lines: nil)],
                                to: monoPdf, title: "Lumo strip selftest")
        guard let doc = PDFReader.open(monoPdf), let back = PDFReader.render(doc, 0, dpi: 150) else {
            check(false, "单色页往返渲染")
            throw NSError(domain: "selftest", code: 2)
        }
        // 墨水率只用「原图」和「解码回来的图」两张，所以直接在 CGImage 上算。
        //
        // 这里原本写的是 GrayBitmap.from(..., maxDim: 600)：把两张图缩到 600px
        // 之后，1px 宽的字体笔画被重采样抹平，两边都掉到 0.000 附近，差值恒为 0——
        // **断言退化成永真**。它之所以能红，只是因为缩图时更早的一步返回了 nil，
        // 让 guard 走了 else 分支。也就是说：断言红的原因是"图缩不了"，
        // 而不是"拼接错了"。这种假绿比不测更危险，因为它在报告里长得像通过。
        //
        // 用全分辨率算墨水率才是真正有效的判据：拼接错位会把笔画推到别的行上，
        // 但更关键的是它会让黑白比例整体漂移，全分辨率下一定看得出来。
        func inkRatio(_ img: CGImage) -> Double {
            var tmpBytes = [UInt8](repeating: 0, count: img.width * img.height)
            // 转灰度是必须的：下面按单通道读字节，彩色图（每像素 4 字节）直接读会
            // 把 A 通道也算进暗像素里，导致墨水率虚高。
            guard let ctx = CGContext(data: &tmpBytes, width: img.width, height: img.height,
                                      bitsPerComponent: 8, bytesPerRow: img.width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return -1
            }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            var dark = 0
            for v in tmpBytes where v < 128 { dark += 1 }
            return Double(dark) / Double(max(1, tmpBytes.count))
        }
        let a = inkRatio(tall), b = inkRatio(back)
        check(a >= 0 && b >= 0 && a > 0.0005,
              String(format: "测试页本身有笔画可测（墨水率 %.4f）", a))
        check(abs(a - b) < 0.05,
              String(format: "CCITT 往返墨水率一致（%.4f → %.4f）", a, b))
    } catch {
        print("  ✗ CCITT 条带测试失败：\(error)")
        failures += 1
    }

    print("==> 并发安全：多条流水线同时跑不许互相踩")
    do {
        // 为什么必须测：App 的批处理是并发跑 Pipeline.process 的，而核心里有
        // 若干 static 缓存（CCITT 极性探针、蒙版极性探针）。那些探针各自会
        // 建临时文件、写 static 变量——裸 static var 在多线程下没有定义行为保证。
        // 这条断言的用法是「并发跑，然后检查结果与串行一致」：
        // 竞态未必每次都炸，但只要结果对不上就是真的有问题。
        // 用 3 个并发任务跑同一张图，各自独立写出，最后比对这些文件的页数和体积是否一致。
        let concurrent = 3
        let group = DispatchGroup()
        let lock = NSLock()
        // 用一个数组元素类型明确的普通元组。带标签的元组做元素时，
        // 闭包里再赋不带标签的字面量容易踩类型推断的边角（标签要不要参与
        // 类型相等判断，各版本编译器行为不完全一致），这里不冒这个险。
        var results: [(Bool, Int, String)] = []
        // 先串行跑一次作为基准
        let refPdf = tmp.appendingPathComponent("concurrent-ref.pdf")
        let refSpec = ProcessSpec(pages: "all",
                                  enhance: EnhanceSpec(preset: "auto", deskew: false,
                                                       bgRemove: true, descreen: false,
                                                       sharpen: 1.0, bgStrength: 0.6),
                                  ocr: OCRSpec(enabled: false, skip: true),
                                  compress: CompressSpec(adaptive: true, colorMode: "auto",
                                                         monoEncoder: "ccitt", quality: 60),
                                  procDpi: 100)
        var refBytes = 0
        do {
            let r = try Pipeline.process(fileURL: src, spec: refSpec, outURL: refPdf)
            refBytes = r.outSize
        } catch {
            check(false, "并发测试的基准跑通：\(error)")
        }
        for i in 0..<concurrent {
            DispatchQueue.global().async(group: group) {
                let out = tmp.appendingPathComponent("concurrent-\(i).pdf")
                // 每份用略微不同的强度，确保它们真的在同时做编码工作
                var s = refSpec
                s.enhance.bgStrength = 0.5 + Double(i) * 0.05
                var entry: (Bool, Int, String) = (false, 0, "")
                do {
                    let r = try Pipeline.process(fileURL: src, spec: s, outURL: out)
                    entry = (true, r.outSize, "")
                } catch {
                    entry = (false, 0, "\(error)")
                }
                lock.lock()
                results.append(entry)
                lock.unlock()
            }
        }
        group.wait()
        let okCount = results.filter { $0.0 }.count
        check(okCount == concurrent, "\(concurrent) 个并发任务全部成功（成功 \(okCount) 个）")
        // 体积一致性：强度不同会带来体积差异，但差异不该是数量级的
        // （数量级差异通常意味着某个任务拿到了错误的静态缓存，编码走了完全不同的分支）
        let sizes = results.filter { $0.0 }.map { $0.1 }
        if let mn = sizes.min(), let mx = sizes.max(), refBytes > 0 {
            print("  · 基准 \(refBytes) 字节，并发 \(sizes.sorted()) 字节")
            check(mx <= refBytes * 3 && mn >= refBytes / 3,
                  "并发结果与基准同量级（\(mn)~\(mx) vs \(refBytes)）")
        }
        for e in results where !e.0 {
            print("    · 失败详情：\(e.2)")
        }
    }

    print("==> 方向探针（每一层都不能把画面镜像）")
    let flipFailures = flipscan()
    if flipFailures != 0 { failures += 1 }

    print()
    // ★ 「0 条失败」必须同时断言「确实跑了足够多条」。
    //   否则一个把整节 check 全注释掉的改动，也会让自检高高兴兴地报"全绿"——
    //   「因为没跑，所以全绿」这一类失败，只能靠这条守住。所以把它做成**最后一条断言**；
    //   +1 是因为这一条自己也会被计数，这样消息里的数字和汇总行的数字对得上。
    //   门槛 85：当前实际 91 条，余量 6 条。各节的规模是「L4 节 8 条 / 裁边节 13 条 /
    //   方向与编码节更多」，所以**任何一节被整段跳过都会低于 85 而变红**，
    //   而零星删改不会误报。
    //   反证已做：把 85 临时改成 999 → 自检退出码 1，报 "✗ 断言数量足够多（本次共 91 条）"。
    let expectedTotal = assertions + 1
    check(expectedTotal >= 85, "断言数量足够多（本次共 \(expectedTotal) 条），没有哪一节被整段跳过")

    if failures == 0 {
        print("✓ 自检通过（\(assertions) 条断言全过，方向探针无镜像）")
        return 0
    }
    print("✗ 自检失败：\(failures) 项（共 \(assertions) 条断言）")
    return 1
}

// MARK: - flipscan：方向探针（哪一层在偷偷镜像画面）

/// 造一张「左上角带空心方框」的测试图。
/// 为什么不用四块灰度拼象限：自适应二值化会把均匀灰块整个吃掉、把实心黑块掏空，
/// 只有细线轮廓在所有处理路径下都能活下来。结论靠「黑像素落在哪个象限」来下，
/// 和灰度值无关，所以对灰度/二值/彩色路径一视同仁。
/// 输入 160x120：黑框只出现在左上象限。输出若黑框跑到左下＝垂直镜像，右上＝水平镜像，右下＝转了 180°。
func makeQuadImage() -> CGImage? {
    let w = 160, h = 120
    var px = [UInt8](repeating: 255, count: w * h)
    // 线宽给到 6px：细线会被 JPEG 抹掉，那样探针只能报「无黑框」，等于没测
    func dot(_ x: Int, _ y: Int) { px[y * w + x] = 0 }
    for t in 0..<24 {
        for k in 0..<6 {
            dot(28 + t, 18 + k); dot(28 + t, 36 + k)   // 上边 / 下边
            dot(28 + k, 18 + t); dot(46 + k, 18 + t)   // 左边 / 右边
        }
    }
    let data = Data(px) as CFData
    guard let prov = CGDataProvider(data: data) else { return nil }
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                   space: CGColorSpaceCreateDeviceGray(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                   provider: prov, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)
}

/// 读出黑框落在哪个象限。
/// 数据来源是 CGImage 的 dataProvider 原始字节——按定义行 0 就是顶行，
/// 不经过任何 CGContext，所以它本身就是全场的「绝对方向基准」。
func quadrantOfBox(_ img: CGImage?) -> String {
    guard let im = img, let data = im.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data) else { return "nil" }
    let w = im.width, h = im.height, bpr = im.bytesPerRow, bpp = max(1, im.bitsPerPixel / 8)
    var count = [0, 0, 0, 0]   // tl tr bl br
    for y in 0..<h {
        let halfV = y < h / 2
        for x in 0..<w where bytes[y * bpr + x * bpp] < 96 {
            let halfH = x < w / 2
            count[(halfV ? 0 : 2) + (halfH ? 0 : 1)] += 1
        }
    }
    let names = ["左上", "右上", "左下", "右下"]
    let maxIdx = count.indices.max { count[$0] < count[$1] } ?? 0
    if count[maxIdx] < 20 { return "无黑框（\(count)）" }
    let verdict: String
    switch maxIdx {
    case 0: verdict = "正立 ✓"
    case 1: verdict = "水平镜像 ✗"
    case 2: verdict = "垂直镜像 ✗"
    default: verdict = "旋转180° ✗"
    }
    return "黑框在\(names[maxIdx])（\(count)）→ \(verdict)"
}

/// 逐个环节过一遍测试图，谁翻转了当场曝光。
/// 之前的教训：三个环节各自翻转、互相抵消，40 条自检全绿但整条链路是倒的。
/// 自此立规矩：方向必须用「绝对基准」单独测，不许靠端到端推断。
func flipscan() -> Int32 {
    guard let src = makeQuadImage() else { print("error: 造不出测试图"); return 1 }
    print("基准输入：\(quadrantOfBox(src))")
    // 探针必须能 fail：只要有一处不是正立，CI 就得红——
    // 方向这件事靠肉眼看不出来，只能靠机器兜底
    var bad = 0
    func judge(_ name: String, _ f: () -> CGImage?) {
        let v = quadrantOfBox(f())
        print("  · \(name)：\(v)")
        if !v.contains("正立") { bad += 1 }
    }

    judge("resized(scale:0.5)") { resized(src, scale: 0.5) }
    judge("GrayBitmap.from → toCGImage") { GrayBitmap.from(src, maxDim: 0)?.toCGImage() }
    judge("grayCGImage") { grayCGImage(from: src) }
    judge("Enhance.rotated(0°)（纯重绘）") { Enhance.rotated(src, degrees: 0.0) }

    print("—— 增强路径 ——")
    judge("预设 bw（局部自适应二值化）") {
        Enhance.apply(src, spec: EnhanceSpec(preset: "bw"))
    }
    judge("预设 auto（bgRemove 开）") {
        Enhance.apply(src, spec: EnhanceSpec(preset: "auto", bgRemove: true))
    }
    judge("预设 auto（bgRemove 关）") {
        Enhance.apply(src, spec: EnhanceSpec(preset: "auto", bgRemove: false))
    }
    judge("预设 color（增强）") {
        Enhance.apply(src, spec: EnhanceSpec(preset: "color"))
    }

    print("—— PDF 往返（写入 → 再渲染） ——")
    for (label, spec) in [("JPEG 彩色", CompressSpec(adaptive: false, colorMode: "color",
                                                     colorEncoder: "jpeg", monoEncoder: "ccitt", quality: 85)),
                          ("CCITT 单色", CompressSpec(adaptive: false, colorMode: "mono",
                                                      colorEncoder: "jpeg", monoEncoder: "ccitt", quality: 80)),
                          ("ZIP 无损", CompressSpec(adaptive: false, colorMode: "color",
                                                    colorEncoder: "zip", monoEncoder: "zip", quality: 90))] {
        let enc = Compressor.encode(src, spec)
        print("    编码：mode=\(enc.mode) encoder=\(enc.encoderUsed) \(enc.data.count) 字节 note=\(enc.note ?? "-")")
        do {
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("flip-\(label).pdf")
            _ = try PDFWriter.write(pages: [OutputPage(image: enc, dpi: 72, lines: nil)], to: url, title: "flipscan")
            if ProcessInfo.processInfo.environment["LUMO_DUMP_PDF"] == "1",
               let raw = try? Data(contentsOf: url) {
                print("    PDFBASE64:\(label):\(raw.base64EncodedString())")
            }
            if let back = PDFReader.open(url) {
                judge("写入(\(label)) → render") { PDFReader.render(back, 0, dpi: 72) }
            } else {
                print("  ✗ 写入(\(label))：产物打不开")
            }
        } catch {
            print("  ✗ 写入(\(label))：\(error.localizedDescription)")
        }
    }

    print("—— 落盘编码往返（App 预览用的就是这条路） ——")
    if let d = PagePreview.png(src), let back = CGImageSourceCreateWithData(d as CFData, nil),
       let img = CGImageSourceCreateImageAtIndex(back, 0, nil) {
        judge("PagePreview.png → 解码") { img }
    } else {
        print("  ✗ PNG 往返失败")
        bad += 1
    }

    print()
    if bad == 0 {
        print("✓ 方向探针通过：所有环节都没有镜像画面")
        return 0
    }
    print("✗ 方向探针失败：\(bad) 处把画面镜像了")
    return 1
}

// MARK: - demo：把示例扫描件真跑一遍，导出前后对照图

func bytesText(_ n: Int) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowedUnits = [.useKB, .useMB]
    return f.string(fromByteCount: Int64(n))
}

/// 一页图的「看得见」的指标。
/// 中间调比例最能说明问题：扫描件原图到处是灰（背景渐变+噪点），
/// 增强完中间调应该塌到接近 0，只剩纯黑白——这就是「变干净了」的量化说法。
func pageStats(_ img: CGImage) -> (mid: Double, ink: Double, contrast: Double) {
    guard let g = GrayBitmap.from(img) else { return (0, 0, 0) }
    var mid = 0, ink = 0
    for v in g.pixels {
        if v > 40 && v < 215 { mid += 1 }
        if v < 128 { ink += 1 }
    }
    return (Double(mid) / Double(max(1, g.count)),
            Double(ink) / Double(max(1, g.count)),
            g.contrast())
}

/// 底灰：非文字区域的**白电平**（亮端分位点）。
///
/// 为什么要单独做一个 demo 指标、而不是直接用「对比度」或「均值」：
/// 用户抱怨的「背景还留着」说的是**那层灰还在**，是背景的绝对亮度问题，
/// 不是反差问题。
///
/// 这里踩过一次坑，记下来免得再犯：最初实现取的是"中位数以上像素的均值"，
/// 结果整页被清白之后这个均值自身顶到 255（因为"中位数以上"里已经几乎没有暗像素），
/// 于是四档强度测出来几乎一样，看起来像"参数没生效"。那是**测量工具的饱和**，
/// 不是算法没做事。改用亮端分位点（默认 p80）就没有这个问题：
/// 它对"纸面整体抬了多少"是单调敏感的。
func bgLevel(_ img: CGImage, percentile: Double = 80) -> Double {
    guard let g = GrayBitmap.from(img, maxDim: 800) else { return -1 }
    let hist = g.histogram()
    let total = g.count
    guard total > 0 else { return -1 }
    let target = Int(Double(total) * percentile / 100.0)
    var acc = 0
    for v in 0..<256 {
        acc += hist[v]
        if acc >= target { return Double(v) }
    }
    return 255
}

/// 条带探针：ImageIO 到底会不会把单色页切成多条带？
///
/// 这个命令的由来是一次典型的「凭直觉写下的假设没人验证」：
/// extractCCITT 里原本写着 `stripCount == 1`，注释理由是"多 strip 拼接风险太高"。
/// 但没人量过真实页面到底出几条带——如果 ImageIO 真会切，那所有页面都在
/// 静默降级到 Flate（体积翻几倍），用户只会觉得"压不动"，我们查都查不到。
/// 所以先给一个能问出答案的工具，拿真文件跑一遍再决定怎么修。
///
/// 用法：lumo-cli stripprobe <input.pdf|一张图> [页号]
func stripprobe(_ args: [String]) -> Int32 {
    guard let path = args.first else { printUsage(); return 2 }
    let url = URL(fileURLWithPath: path)
    let pageNo = args.count >= 2 ? (Int(args[1]) ?? 1) : 1

    // 图片文件也支持：造一张"高瘦"的单色图直接喂进来，比找 PDF 更快
    var img: CGImage?
    if let d = PDFReader.open(url) {
        img = PDFReader.render(d, pageNo - 1, dpi: 300)
    } else if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
        img = CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
    guard let base = img else { print("error: 打不开或渲染不了 \(path)"); return 1 }

    print("输入 \(path) 第 \(pageNo) 页：\(base.width)×\(base.height)")
    // 按单色路径走一遍，看几条带
    let monoSpec = CompressSpec(adaptive: false, colorMode: "mono", monoEncoder: "ccitt")
    // encode 返回的是非可选的 EncodedImage（它内部保证任何失败都会降级到
    // 某个可用的编码器，绝不用 nil 表示失败——这是核心的设计承诺）。
    // 所以这里不能写 guard let，直接接住即可。
    let out = Compressor.encode(base, monoSpec)
    print("编码器实际使用：\(out.encoderUsed)")
    if let note = out.note { print("备注：\(note)") }
    if let s = Compressor.lastCCITTStripInfo() {
        print("TIFF 条带实况：count=\(s.count) rowsPerStrip=\(s.rowsPerStrip) 图像行数=\(s.rows)")
        if s.count > 1 {
            print("→ ImageIO 切了 \(s.count) 条带。已按顺序拼接成 PDF 的连续码流。")
        } else {
            print("→ 单条带，无需拼接。")
        }
    } else {
        print("→ 没拿到条带信息（TIFF 解析在更早的步骤就失败了）")
    }

    // 关键交叉验证：解码回来还认得出原图吗？
    // 只报"条带数"是不够的——拼接错了照样能写出文件、也照样能打开，
    // 只是画面是花的。所以必须走完整往返，比对墨水率。
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lumo-stripprobe-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: tmp) }
    do {
        _ = try PDFWriter.write(pages: [OutputPage(image: out, dpi: 300, lines: nil)], to: tmp,
                                title: "lumo-stripprobe")
    } catch { print("error: 写 PDF 失败 \(error)"); return 1 }
    guard let doc = PDFReader.open(tmp), let back = PDFReader.render(doc, 0, dpi: 300),
          let g0 = GrayBitmap.from(base, maxDim: 600), let g1 = GrayBitmap.from(back, maxDim: 600) else {
        print("error: 往返渲染失败"); return 1
    }
    func ink(_ g: GrayBitmap) -> Double {
        var d = 0
        for v in g.pixels where Int(v) < 128 { d += 1 }
        return Double(d) / Double(max(1, g.count))
    }
    let a = ink(g0), b = ink(g1)
    print(String(format: "往返墨水率：原图 %.4f → 解码回来 %.4f（差 %.4f）", a, b, abs(a - b)))
    // 画面被切花的典型特征是"黑的比例暴涨或暴跌"，阈值放到 0.05 足够灵敏
    if abs(a - b) > 0.05 {
        print("→ ✗ 往返后墨水率对不上，条带拼接可能有问题")
        return 1
    }
    print("→ ✓ 多 strip 拼接后往返一致")
    return 0
}

/// 为什么要单独做一个 demo 命令：
/// 沙箱是 Linux，没有 CoreGraphics / Vision，「跑一遍给你看」这件事
/// 只能交给 CI 那台 macos-14 真机。demo 把整条链路的产物（对照图 + 最终 PDF）
/// 一次落到磁盘，再作为 artifact 带回来给人眼验收。
func cmdDemo(_ args: [String]) -> Int32 {
    guard args.count >= 2 else { printUsage(); return 2 }
    let inURL = URL(fileURLWithPath: args[0])
    let outDir = URL(fileURLWithPath: args[1])
    func value(_ flag: String, _ def: String) -> String {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return def }
        return args[i + 1]
    }
    // 默认跑三个模式：这才是「模式系统」值不值钱的地方——同一份底图并排看
    let presets = value("--presets", "auto,bw").split(separator: ",").map(String.init)
    let maxDim = Int(value("--max-dim", "1100")) ?? 1100
    let quality = Int(value("--quality", "72")) ?? 72
    let dpiArg = Int(value("--dpi", "0")) ?? 0
    // 背景清理强度：支持 "0.0,0.5,1.0" 这种多档扫描，用来对比"干净到什么程度"。
    // 传单一值也行；不传就用体检推荐出来的那个。
    let strengthArg = value("--bg-strength", "")
    let strengths: [Double] = strengthArg.isEmpty
        ? [Double.nan]
        : strengthArg.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    // 自动裁边：默认关。demo 里打开它是为了**用眼睛验收**——
    // 桌面被切掉多少、纸有没有被拉伸、方向有没有翻，只有看图才算数。
    let autoCrop = value("--auto-crop", "off") == "on"

    do { try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) }
    catch { print("error: 建目录失败：\(error)"); return 1 }

    let inSize = (try? inURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard let doc = PDFReader.open(inURL) else { print("error: 打不开 \(inURL.path)"); return 1 }
    let n = PDFReader.pageCount(doc)
    print("==> 源文件 \(inURL.lastPathComponent)：\(bytesText(inSize))，\(n) 页")

    guard let rep = try? Pipeline.report(fileURL: inURL) else { print("error: 体检失败"); return 1 }
    let a = rep.analysis
    print(String(format: "==> 体检：色彩=%@ 预估DPI=%d 倾斜=%.2f° 噪声=%.3f 背景不匀=%.3f 纸白=%.0f 文字层=%@",
                 a.colorMode, a.estimatedDpi, a.skewAngle, a.noiseLevel,
                 a.bgUnevenness, a.paperWhite, a.hasTextLayer ? "有" : "无"))
    for nt in rep.recommendation.notes { print("    · \(nt)") }
    for p in rep.plans { print("    · \(p.name)：预估 \(bytesText(p.estBytes))") }

    // 渲染分辨率沿用流水线自己的规则（不放大、不低于 150）
    let renderDpi = dpiArg > 0 ? dpiArg : Pipeline.procDpi(a.estimatedDpi)
    // 底图只渲染一次并缓存：几个模式必须吃同一张图，否则对比没有意义
    var raws: [CGImage] = []
    for i in 0..<n {
        guard let im = PDFReader.render(doc, i, dpi: renderDpi) else { continue }
        raws.append(im)
    }
    guard !raws.isEmpty else { print("error: 一页都渲染不出来"); return 1 }

    /// 对照图一律存 JPEG：PNG 存扫描件一页要 1MB 上下，九张图就是十几兆，
    /// 而这里是给人眼看的——JPEG q82 在屏幕上和 PNG 没有可见差别，却能小一个数量级。
    func write(_ img: CGImage, _ name: String) -> Int {
        let scale = Double(maxDim) / Double(max(img.width, img.height))
        let small = scale < 1.0 ? (resized(img, scale: scale) ?? img) : img
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return 0 }
        CGImageDestinationAddImage(dest, small,
                                   [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest), out.count > 0 else { return 0 }
        do { try (out as Data).write(to: outDir.appendingPathComponent(name)); return out.count }
        catch { return 0 }
    }

    for (i, raw) in raws.enumerated() {
        let st = pageStats(raw)
        let wrote = write(raw, String(format: "p%d-原图.jpg", i + 1))
        print(String(format: "  · 第%d页 原图 %dx%d 中间调 %.1f%% 墨水率 %.2f%% 对比度 %.0f → %@",
                     i + 1, raw.width, raw.height, st.mid * 100, st.ink * 100,
                     st.contrast, wrote > 0 ? bytesText(wrote) : "落盘失败"))
    }

    for preset in presets {
        for strength in strengths {
            var enh = rep.recommendation.enhance
            enh.preset = preset
            // 只在显式传了强度时才覆盖体检推荐；否则保持"开箱默认"的语义
            if !strength.isNaN { enh.bgStrength = strength }
            if autoCrop { enh.autoCrop = true }
            let tag = strength.isNaN ? preset
                                     : String(format: "%@-s%02d", preset, Int(strength * 100))
            print("==> 模式 \(tag)  背景清理强度=\(enh.bgStrength.map { String(format: "%.2f", $0) } ?? "体检推荐")")
            for (i, raw) in raws.enumerated() {
                let out = Enhance.apply(raw, spec: enh)
                let st = pageStats(out)
                let wrote = write(out, String(format: "p%d-%@.jpg", i + 1, tag))
                // 底灰（背景区域的平均灰度）单独打出来：这是"画面干不干净"
                // 最直接的量化指标，比"对比度"更贴用户的那句"背景还留着"。
                let bg = bgLevel(out)
                print(String(format: "  · 第%d页 中间调 %.1f%% 墨水率 %.2f%% 对比度 %.0f 底灰 %.1f (纸白 %.0f) → %@",
                             i + 1, st.mid * 100, st.ink * 100, st.contrast,
                             bg, Enhance.paperLevel(out),
                             wrote > 0 ? bytesText(wrote) : "落盘失败"))
            }
            // 完整流水线：增强 + OCR + 压缩，出来的才是用户真正会拿走的东西
            var comp = rep.recommendation.compress
            comp.quality = quality
            let spec = ProcessSpec(pages: "all", enhance: enh, ocr: rep.recommendation.ocr,
                                   compress: comp, procDpi: renderDpi)
            let outURL = outDir.appendingPathComponent("lumo-\(tag).pdf")
            do {
                let r = try Pipeline.process(fileURL: inURL, spec: spec, outURL: outURL)
                print(String(format: "  ✓ 产物 %@：%@ → %@（省 %.1f%%），OCR %d 字符，%.1fs",
                             outURL.lastPathComponent, bytesText(r.inSize),
                             bytesText(r.outSize), r.savedPct, r.ocrChars, r.elapsedSec))
                for s in r.steps { print("      · \(s)") }
                // warnings 里装着两件必须让人看见的事：裁边的结论（它丢了像素）
                // 与"这几页已经够干净"（它解释了滑块为什么看不出变化）。
                for w in r.warnings { print("      ! \(w)") }
                // 产物回看：把最终 PDF 重新打开、重新光栅化。
                // 增强再好看，压缩阶段再二值化一次就全白做了——这一步专门盯这种事。
                if let back = PDFReader.open(outURL), let backImg = PDFReader.render(back, 0, dpi: renderDpi) {
                    let st = pageStats(backImg)
                    let w = write(backImg, "\(tag)-产物回看.jpg")
                    print(String(format: "  · 产物第1页回看：中间调 %.1f%% 墨水率 %.2f%% 对比度 %.0f 底灰 %.1f → %@",
                                 st.mid * 100, st.ink * 100, st.contrast, bgLevel(backImg), bytesText(w)))
                } else {
                    print("  ✗ 产物回看失败：重新打开或渲染不了")
                }
            } catch {
                print("  ✗ 流水线失败：\(error.localizedDescription)")
            }
        }
    }
    return 0
}

// MARK: - 子命令

func printUsage() {
    print("""
    lumo-cli —— Lumo 核心命令行

      lumo-cli selftest
      lumo-cli version
      lumo-cli report <input.pdf>
      lumo-cli process <input.pdf> <output.pdf> [options]
      lumo-cli demo <input.pdf> <outdir> [options]   # 前后对照图 + 最终 PDF
      lumo-cli flipscan       # 方向探针：逐环节测谁在镜像画面
      lumo-cli encoders       # 列出系统 ImageIO 真正支持的编解码格式
      lumo-cli presets        # 列出增强模式
      lumo-cli filters        # 列出可用的 Core Image 滤镜
      lumo-cli langs
      lumo-cli monoprobe <input.pdf> [page]
      lumo-cli stripprobe <input.pdf> [page]   # 单色 TIFF 条带实况

    options:
      --pages all|1,3|2-6       默认 all
      --ocr on|off              默认 on
      --lang <id>               默认 chi_sim+eng（lumo-cli langs 可列）
      --output searchable|editable
      --preset auto|bw|color|contrast|original
      --quality 1-100
      --color-encoder jpeg|jp2|zip
      --mono-encoder ccitt|zip
      --color-mode auto|color|gray|mono
      --dpi <n>
      --bg-strength 0~1         背景清理强度（demo 支持 "0,0.35,0.75,1" 多档扫描）
      --auto-crop on|off        自动裁边 + 透视校正，默认 off（会丢像素，只对拍照件有用）
    """)
}

func cmdReport(_ path: String) -> Int32 {
    let url = URL(fileURLWithPath: path)
    do {
        let r = try Pipeline.report(fileURL: url)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(r)
        print(String(data: data, encoding: .utf8) ?? "")
        return 0
    } catch {
        print("error: \(error.localizedDescription)")
        return 1
    }
}

func cmdProcess(_ args: [String]) -> Int32 {
    guard args.count >= 2 else { printUsage(); return 2 }
    let inURL = URL(fileURLWithPath: args[0])
    let outURL = URL(fileURLWithPath: args[1])

    func value(_ flag: String, _ def: String) -> String {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return def }
        return args[i + 1]
    }

    let pages = value("--pages", "all")
    let ocrOn = value("--ocr", "on") == "on"
    let lang = value("--lang", "chi_sim+eng")
    let output = value("--output", "searchable")
    let quality = Int(value("--quality", "72")) ?? 72
    let colorEncoder = value("--color-encoder", "jpeg")
    let monoEncoder = value("--mono-encoder", "ccitt")
    let colorMode = value("--color-mode", "auto")
    let preset = value("--preset", "auto")
    let dpi = Int(value("--dpi", "0"))
    // 自动裁边默认关：它会丢像素，必须是用户明确要求的（与 EnhanceSpec.autoCrop 的默认值一致）
    let autoCrop = value("--auto-crop", "off") == "on"

    let ocr = OCRSpec(enabled: ocrOn, lang: lang, output: output, skip: !ocrOn)
    let spec = ProcessSpec(pages: pages,
                           enhance: EnhanceSpec(preset: preset, deskew: true,
                                                bgRemove: false, descreen: false, sharpen: 1.0,
                                                autoCrop: autoCrop ? true : nil),
                           ocr: ocr,
                           compress: CompressSpec(adaptive: colorMode == "auto", colorMode: colorMode,
                                                  colorEncoder: colorEncoder, monoEncoder: monoEncoder,
                                                  quality: quality),
                           procDpi: dpi == 0 ? nil : dpi)
    do {
        let r = try Pipeline.process(fileURL: inURL, spec: spec, outURL: outURL) { p, msg in
            print(String(format: "  [%3.0f%%] %@", p * 100, msg))
        }
        print(String(format: "完成：%lld → %lld 字节（省 %.1f%%），%lld 页，OCR %lld 字符，%.1fs",
                     Int64(r.inSize), Int64(r.outSize), r.savedPct, Int64(r.pagesProcessed), Int64(r.ocrChars), r.elapsedSec))
        for s in r.steps { print("  · \(s)") }
        for w in r.warnings { print("  ! \(w)") }
        return 0
    } catch {
        print("error: \(error.localizedDescription)")
        return 1
    }
}

// MARK: - 入口

let argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first else { printUsage(); exit(2) }
switch cmd {
case "version", "--version", "-v":
    // 版本号走 PDFWriter.version 这条唯一来源，别在这里再写死一份。
    print("lumo-cli \(PDFWriter.version)")
    exit(0)
case "selftest":
    exit(selftest())
case "report":
    guard argv.count >= 2 else { printUsage(); exit(2) }
    exit(cmdReport(argv[1]))
case "process":
    exit(cmdProcess(Array(argv.dropFirst())))
case "demo":
    exit(cmdDemo(Array(argv.dropFirst())))
case "flipscan":
    exit(flipscan())
case "stripprobe":
    exit(stripprobe(Array(argv.dropFirst())))
case "langs":
    for l in OCR.languages { print("\(l.id)\t\(l.name)") }
    exit(0)
case "monoprobe":
    // 单色极性的现场诊断：拿真文件跑一遍，看黑白在哪一步被翻
    guard argv.count >= 2 else { printUsage(); exit(2) }
    let u = URL(fileURLWithPath: argv[1])
    let page = Int(argv.count >= 3 ? argv[2] : "1") ?? 1
    guard let d = PDFReader.open(u), let im = PDFReader.render(d, page - 1, dpi: 150) else {
        print("error: 打不开或渲染不了 \(argv[1]) 第 \(page) 页"); exit(1)
    }
    guard let p = Compressor.monoProbe(im) else { print("error: 取灰度失败"); exit(1) }
    print(String(format: "打包后黑点比例 %.4f（应约等于页面墨水率）", p.packedDark))
    print("TIFF Photometric = \(p.photometric)  （0=WhiteIsZero，1=BlackIsZero，-1=解析失败）")
    print(String(format: "TIFF 往返后黑点比例 %.4f", p.tiffDark))
    print(String(format: "写进 PDF 再渲染回来的黑点比例 %.4f", p.pdfDark))
    if abs(p.pdfDark - p.packedDark) > 0.2 {
        print("→ PDF 路径翻转了黑白，编码前会先把输入取反抵消")
    } else {
        print("→ PDF 路径未翻转")
    }
    exit(0)
case "encoders":
    // 「macOS SDK 到底能不能压 JBIG2」这件事，与其靠记忆下结论，不如现场问一次系统。
    // CGImageDestinationCopyTypeIdentifiers 就是 ImageIO 能写的全部格式清单。
    let write = (CGImageDestinationCopyTypeIdentifiers() as? [String])?.sorted() ?? []
    let read = (CGImageSourceCopyTypeIdentifiers() as? [String])?.sorted() ?? []
    print("ImageIO 可编码（写）\(write.count) 种：")
    for t in write { print("  \(t)") }
    print("ImageIO 可解码（读）\(read.count) 种：")
    for t in read { print("  \(t)") }
    let jb = (write + read).filter { $0.lowercased().contains("jbig") }
    if jb.isEmpty {
        print("→ 结论：系统里没有任何 JBIG2 编解码入口（能读 PDF 内嵌的 JBIG2，那是 CoreGraphics 私有的解码器）")
    } else {
        print("→ 发现 JBIG2 相关类型：\(jb)")
    }
    let pdfish = write.filter { $0.contains("pdf") || $0.contains("tiff") || $0.contains("jpeg") || $0.contains("png") }
    print("→ 我们实际用到的写入格式：\(pdfish.joined(separator: ", "))")
    exit(0)
case "presets":
    for p in EnhancePreset.allCases { print("\(p.rawValue)\t\(p.title)\t\(p.desc)") }
    exit(0)
case "filters":
    for f in Enhance.availableFilters() { print(f) }
    exit(0)
default:
    printUsage()
    exit(2)
}
