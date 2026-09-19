// Lumo 原生核心 —— 扫描增强
// 用 Core Image 取代 OpenCV：同样有中值滤波、非锐化掩膜，
// 但不需要额外装 50MB 的 OpenCV。
import Foundation
import CoreGraphics
import CoreImage
import Vision

public enum Enhance {
    /// CIContext 创建开销不小，整个进程复用一个
    static let ci = CIContext()

    /// 背景清理强度的默认值。
    ///
    /// 为什么是 0.5 而不是"拉满"：拿示例件实测过一整排强度——第 3 页（均匀偏灰）
    /// 在 0.35 就已经接近全白，而第 2 页（带阴影）要到 0.55 才干净。
    /// 同一份文件里两页的"脏"程度就能差这么多，所以固定值是妥协的产物：
    /// 取 0.5 让默认档"干净但还留一点纸张层次"，剩下交给滑块。
    public static let defaultStrength: Double = 0.5

    /// 纠偏时旋转方向的符号。
    /// 注意：正确性**不依赖**这个符号——deskew 会把两个方向都试一遍，取行剖面更平的那个。
    /// 它只影响 detectSkew 报出来的角度正负号（UI 上展示的是绝对值）。
    static let rotationSign: Double = -1.0

    // MARK: - 纠偏

    /// 投影剖面法：文字行越平，行均值的相邻差分平方和越大。
    /// 先 1° 粗扫再 0.1° 细扫，比一次性 0.1° 扫 200 次快 5 倍。
    public static func detectSkew(_ image: CGImage, maxAngle: Double = 10.0) -> Double {
        guard let small = GrayBitmap.from(image, maxDim: 640) else { return 0 }
        func score(at deg: Double) -> Double {
            guard let r = rotatedGray(small, deg) else { return -1 }
            return r.rowScore()
        }
        var bestDeg = 0.0
        var bestScore = -1.0
        var d = -maxAngle
        while d <= maxAngle + 0.0001 {
            let s = score(at: d)
            if s > bestScore { bestScore = s; bestDeg = d }
            d += 1.0
        }
        // 在粗扫最优点附近 ±1° 细扫
        let lo = bestDeg - 1.0
        var f = lo
        while f <= lo + 2.0 + 0.0001 {
            let s = score(at: f)
            if s > bestScore { bestScore = s; bestDeg = f }
            f += 0.1
        }
        if abs(bestDeg) < 0.15 { return 0 }
        return max(-maxAngle, min(maxAngle, bestDeg))
    }

    /// 按给定角度回正，空白处填白。
    /// 两个方向都试、取分更高的那个：这样"角度符号"这种最容易写错的东西，
    /// 不再能决定结果对错——投影剖面打分才是最终裁判。
    public static func deskew(_ image: CGImage, degrees: Double) -> CGImage? {
        guard abs(degrees) >= 0.15 else { return image }
        let a = rotated(image, degrees: degrees)
        let b = rotated(image, degrees: -degrees)
        let sa = flatness(a)
        let sb = flatness(b)
        if sa >= sb, let a { return a }
        if let b { return b }
        return image
    }

    private static func flatness(_ image: CGImage?) -> Double {
        guard let image, let g = GrayBitmap.from(image, maxDim: 640) else { return -1 }
        return g.rowScore()
    }

    public static func rotated(_ image: CGImage, degrees: Double) -> CGImage? {
        let w = image.width
        let h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: CGFloat(rotationSign * degrees * .pi / 180.0))
        ctx.translateBy(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
        // 不要翻：翻一次会垂直镜像（详见 ImageUtils 末的踩坑记）
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func rotatedGray(_ g: GrayBitmap, _ degrees: Double) -> GrayBitmap? {
        guard let img = g.toCGImage() else { return nil }
        guard let r = rotated(img, degrees: degrees) else { return nil }
        return GrayBitmap.from(r)
    }

    // MARK: - 背景去除（光照归一化）

    /// 不用 Core Image 的混合模式：那个除法的语义在不同版本上不可控，
    /// 曾经把整页洗成浅灰（文字还在，OCR 甚至能读，但人眼看是一片白）。
    /// 这里改成确定性的做法：用 24×24 网格估计每块的"白电平"，
    /// 双线性插值成逐像素背景，再按 factor = 255/背景 归一化。
    ///
    /// mark（要拉到多白）决定了两件事，而且是**一起**变的：
    /// 1. **提亮能力**。背景是 200 时 factor=1.275，背景 150 时 factor=1.7。
    /// 2. **压暗能力**。factor 下限从 1.0 放开到 0.82 —— 这是「画面不干净」的根因：
    ///    原实现只提亮不压暗，而扫描件往往纸色本来就是 235~245（"白但发灰"），
    ///    255/245 = 1.041 几乎什么都没做，那层灰就一直留着。
    ///    放开下限后，factor = mark/背景 会把纸**压**到 mark 附近，灰才真的被清掉。
    ///
    /// mark 由用户可调的 bgStrength 映射而来（0.5 → 250）。注意下限是 245 而不是 255：
    /// 真正的纯白要留给"纸比 mark 还亮"的那种页（factor < 1 自然压下去），
    /// 否则整页会被推成 255 的硬白，丢掉的正是纸张本身的层次。
    public static func removeBackground(_ image: CGImage, strength: Double = defaultStrength) -> CGImage? {
        let s = max(0, min(1, strength))
        // 强度 0 = 明确什么都不做。这一条必须有，否则界面上滑块拉到最左
        // 画面却还在变（mark 固定 245，factor = 245/背景 仍会抬 10 来个灰度），
        // 用户会觉得"这个滑块不老实"。宁可让 0 成为真正的关，语义才干净。
        guard s > 0.001 else { return image }
        guard let gray = GrayBitmap.from(image) else { return nil }
        guard let rgb = rgbSamples(image), rgb.width == gray.width, rgb.height == gray.height else { return nil }
        let w = gray.width
        let h = gray.height
        let grid = 24
        let mark = 245.0 + 10.0 * s          // 0+ → 245（只清阴影），1 → 255（纯白）
        // 下限随强度放开：强度低时保守（不许压暗），强度高时允许压到 0.82
        let floorFactor = 1.0 - 0.18 * s

        // 每个网格块记三个通道各自的背景电平。
        //
        // 关键在"选像素"和"记数值"是两件事：
        // · **选**哪些像素算背景，用灰度阈值选（最亮 15% 就是纸面，与颜色无关）；
        // · 选中之后，**分别**记下这些像素的 R/G/B 均值 —— 它们之间的差就是纸的偏色。
        // 如果这里只记一个灰度值，后面就只剩"等比提亮"一条路，黄底永远去不掉。
        var chanLevel = [Double](repeating: 255, count: grid * grid * 3)
        for gy in 0..<grid {
            let y0 = gy * h / grid
            let y1 = max(y0 + 1, (gy + 1) * h / grid)
            for gx in 0..<grid {
                let x0 = gx * w / grid
                let x1 = max(x0 + 1, (gx + 1) * w / grid)
                var hist = [Int](repeating: 0, count: 256)
                var n = 0
                for y in y0..<y1 {
                    let base = y * w
                    for x in x0..<x1 { hist[Int(gray.pixels[base + x])] += 1; n += 1 }
                }
                guard n > 0 else { continue }
                // 取最亮 15% 像素的阈值作为这块背景的下界
                var acc = 0
                var thr = 255
                let target = Int(Double(n) * 0.85)
                for v in 0..<256 {
                    acc += hist[v]
                    if acc >= target { thr = v; break }
                }
                // 再扫一遍，把超过阈值的像素分通道求和
                var sr = 0.0, sg = 0.0, sb = 0.0
                var m = 0
                for y in y0..<y1 {
                    let gbase = y * w
                    let cbase = y * w * 3
                    for x in x0..<x1 {
                        guard Int(gray.pixels[gbase + x]) >= thr else { continue }
                        sr += Double(rgb.bytes[cbase + x * 3])
                        sg += Double(rgb.bytes[cbase + x * 3 + 1])
                        sb += Double(rgb.bytes[cbase + x * 3 + 2])
                        m += 1
                    }
                }
                let o = (gy * grid + gx) * 3
                if m > 0 {
                    chanLevel[o]     = sr / Double(m)
                    chanLevel[o + 1] = sg / Double(m)
                    chanLevel[o + 2] = sb / Double(m)
                }
            }
        }

        // 输出用 32bpp RGBX：24bpp RGB 不是 CoreGraphics 支持的格式，
        // CGImage 会直接返回 nil——背景去除曾经就这样"看起来开着、其实没生效"。
        //
        // **每通道各自归一**（而不是三通道乘同一个 factor）——这一步是"够不够白"的关键。
        // 等比例提亮只能整体变亮，**永远去不掉纸的黄色偏色**：米黄的纸等比乘 1.2 之后
        // 还是米黄，只是更亮的米黄。所以要把三个通道**各自**除以其背景电平，
        // 纸面才会被拉到中性白（R=G=B=mark），黄底这才真的消失。
        // 实测示例件第 2 页：同 factor 时拉满也留着明显米黄（纸面 R-B = 16.8）；
        // 改成逐通道后 R-B = 0.1，米黄彻底消失。
        //
        // 顺带纠正一个我先入为主的担心：原以为白平衡会让浅色内容（页脚小灰字）变淡，
        // 实测恰恰相反——页脚小字相对纸面的反差是 2 → 116。
        // 因为等比模式下纸面和字的亮度被同一个 factor 一起缩放，两者之比不变，
        // 本来就"糊在一起"；白平衡把纸单独拉到白、字照旧是灰，反差这才出来。
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let fy = Double(y) * Double(grid) / Double(h) - 0.5
            let gy0 = max(0, min(grid - 1, Int(floor(fy))))
            let gy1 = min(grid - 1, gy0 + 1)
            let ty = max(0, min(1, fy - Double(gy0)))
            for x in 0..<w {
                let fx = Double(x) * Double(grid) / Double(w) - 0.5
                let gx0 = max(0, min(grid - 1, Int(floor(fx))))
                let gx1 = min(grid - 1, gx0 + 1)
                let tx = max(0, min(1, fx - Double(gx0)))
                let src = (y * w + x) * 3
                let i = (y * w + x) * 4
                // 逐通道取该像素位置的背景电平（同一套双线性权重，成本只是多两次插值）
                for c in 0..<3 {
                    let c00 = chanLevel[((gy0 * grid + gx0) * 3) + c]
                    let c10 = chanLevel[((gy0 * grid + gx1) * 3) + c]
                    let c01 = chanLevel[((gy1 * grid + gx0) * 3) + c]
                    let c11 = chanLevel[((gy1 * grid + gx1) * 3) + c]
                    let bgc = (c00 * (1 - tx) + c10 * tx) * (1 - ty)
                            + (c01 * (1 - tx) + c11 * tx) * ty
                    let factor = min(3.0, max(floorFactor, mark / max(1.0, bgc)))
                    out[i + c] = clamp255(Double(rgb.bytes[src + c]) * factor)
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    private static func clamp255(_ v: Double) -> UInt8 {
        UInt8(max(0, min(255, Int(round(v)))))
    }

    // MARK: - 去网纹

    public static func descreen(_ image: CGImage) -> CGImage? {
        let ci0 = CIImage(cgImage: image)
        guard let med = CIFilter(name: "CIMedianFilter") else { return image }
        med.setValue(ci0, forKey: kCIInputImageKey)
        guard let m = med.outputImage else { return image }
        guard let sharp = CIFilter(name: "CIUnsharpMask") else { return render(m, size: (image.width, image.height)) }
        sharp.setValue(m, forKey: kCIInputImageKey)
        sharp.setValue(1.2, forKey: kCIInputRadiusKey)
        sharp.setValue(0.7, forKey: kCIInputIntensityKey)
        guard let out = sharp.outputImage else { return render(m, size: (image.width, image.height)) }
        return render(out, size: (image.width, image.height))
    }

    // MARK: - 锐化

    public static func sharpen(_ image: CGImage, amount: Double = 1.0) -> CGImage? {
        guard amount > 0 else { return image }
        let ci0 = CIImage(cgImage: image)
        guard let f = CIFilter(name: "CIUnsharpMask") else { return image }
        f.setValue(ci0, forKey: kCIInputImageKey)
        f.setValue(1.4, forKey: kCIInputRadiusKey)
        f.setValue(max(0.1, min(1.5, amount * 0.6)), forKey: kCIInputIntensityKey)
        guard let out = f.outputImage else { return image }
        return render(out, size: (image.width, image.height))
    }

    /// 把滤镜结果按原尺寸重新渲染，保证尺寸不漂（模糊类滤镜的 extent 会外扩）
    private static func render(_ ciImage: CIImage, size: (Int, Int)) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: size.0, height: size.1)
        if let cg = ci.createCGImage(ciImage, from: rect), cg.width == size.0, cg.height == size.1 {
            return cg
        }
        // 兜底：自己铺白底再画一次
        guard let cg = ci.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        guard let ctx = CGContext(data: nil, width: size.0, height: size.1, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: rect)
        return ctx.makeImage()
    }

    // MARK: - 增强模式（手机扫描 App 那一排效果）

    /// 局部自适应二值化的结果（0 / 255 灰度图）。MRC 的蒙版层也复用它。
    ///
    /// 算法：`v < 局部均值 × beta → 黑，否则白`，beta 默认 0.90。
    ///
    /// ## 为什么不用 Sauvola（一次被实测否决的升级）
    ///
    /// 这个算法看起来"不够学术"——扫描件二值化的文献标准答案是
    /// Sauvola（`T = μ[1 − k(1 − σ/R)]`，k=0.2~0.5、R=128）或 Wolf。
    /// 我一度改成了 Sauvola（k=0.34、R=128），然后在沙箱里用 numpy
    /// 把两套算法逐像素复刻、在同一批合成页上对照，结果**新算法更差**：
    ///
    /// | 页面 | 局部均值×0.90 | Sauvola(k=.34,R=128) |
    /// |---|---|---|
    /// | 均匀白纸 + 黑字 | 3.87% | 3.87% |
    /// | 光照渐变页（250→150） | **3.87%，左右均衡** | **1.45%，亮侧整片消失** |
    /// | 均匀背景 + 孤立浅噪点 | 0% | 0% |
    /// | 暗页(纸白 200) + 黑字 | 3.87% | 3.87% |
    ///
    /// 根因在 **R 的量纲**。R=128 是拿"高对比度文档"标定的：
    /// 只有当笔画与纸面的反差足够大、σ 能到几十上百时，`σ/R` 才会有意义。
    /// 而真实扫描件经过 JPEG 与光学模糊之后，笔画 σ 常常只有 10~20，
    /// 于是 `1 − σ/R ≈ 0.9`，`factor = 1 − k(1−σ/R) ≈ 0.66` ——
    /// 阈值被压到均值的 0.66 倍，**亮侧那些本来就浅的笔画全部掉到阈值以上**，
    /// 整个亮半页被抹成白的。旧算法虽然土，但它固定的 0.90 反而更接近
    /// 这类低对比度文档的实际情况。
    ///
    /// 把 k 调小能不能救？能，但那就等于承认 Sauvola 不适用：
    /// k=0.10、R=128 时它在上面三张页上与 `μ×0.90` 的输出**逐像素相同**
    /// （实测差 0.000%）。Sauvola 的全部价值来自 σ 项，而把 k 压到
    /// 不产生副作用时，σ 项已经小到不起作用了。**与其引一个名字更漂亮
    /// 但需要把参数调到退化才有同等效果、还多一遍 boxMeanSq 开销的算法，
    /// 不如留着现在这个，并把这件事写下来。**
    ///
    /// 顺带记一个中途踩的坑：Sauvola 实现里求局部方差必须用
    /// `E[X²] − (E[X])²`（两次滑动窗口），我第一版用积分图算，边缘语义
    /// 与滑动窗口不同步，内部区域就差了 30 多个灰阶，据此得出的
    /// "旧算法很稳/新算法不行"两个结论都是错的。**测量工具本身要先被验证。**
    public static func binaryMap(_ image: CGImage, beta: Double = 0.90) -> GrayBitmap? {
        // 二值化会把孤立噪点也放大成黑斑，先中值滤一下（只在真的有噪声时）
        let src = Analyzer.noiseLevel(image) > 0.06 ? (medianFilter(image) ?? image) : image
        guard let g = GrayBitmap.from(src) else { return nil }
        return binarize(g, beta: beta)
    }

    private static func binarize(_ g: GrayBitmap, beta: Double) -> GrayBitmap {
        // 窗口跟着分辨率走：太小学不像"局部",太大会把整页糊成一坨。
        // 110 分之一是经验值——1240px 宽的页取 11,2480px 取 23,都约等于半个字高。
        //
        // 已知边界（写下来免得下次又当新发现）：窗口下限是 9px，当页面本身
        // 很窄（< 1000px 宽）时窗口会贴到 9px，此时若笔画粗到能填满整个窗口，
        // 窗口内 μ 就等于笔画灰度，任何 `μ × f (f<1)` 形式的阈值都判不出墨，
        // 笔画内部会被"挖空"。这是**所有局部阈值法（含 Sauvola/Wolf/Niblack）
        // 的共性**，不是这个实现的缺陷：它们都依赖窗口里同时含纸和字。
        // 真实 A4@150dpi 是 1240px 宽 → 窗口 11px，笔画 1~3px，不会触发。
        let win = max(9, (g.width / 110) | 1)
        let means = boxMean(g, window: win)
        var out = g.pixels
        for i in 0..<out.count {
            out[i] = Double(out[i]) < means[i] * beta ? 0 : 255
        }
        return GrayBitmap(width: g.width, height: g.height, pixels: out)
    }

    /// 局部自适应二值化。带退化保护：结果"几乎全黑"或"几乎全白"时退回 Otsu 全局阈值，
    /// 再不行就返回 nil 让调用方用原图——宁可没增强，也不能给用户一页纯黑。
    public static func adaptiveBinarize(_ image: CGImage, beta: Double = 0.90) -> CGImage? {
        guard let g = GrayBitmap.from(image) else { return nil }
        let bin = binarize(g, beta: beta)
        if acceptable(bin) { return bin.toCGImage() }
        let (thr, _) = otsuThreshold(g)
        var p = g.pixels
        for i in 0..<p.count { p[i] = p[i] <= thr ? 0 : 255 }
        let fallback = GrayBitmap(width: g.width, height: g.height, pixels: p)
        return acceptable(fallback) ? fallback.toCGImage() : nil
    }

    /// 墨水率必须落在「有字但不是糊成一片」的区间
    private static func acceptable(_ g: GrayBitmap) -> Bool {
        var ink = 0
        for v in g.pixels where v < 128 { ink += 1 }
        let ratio = Double(ink) / Double(max(1, g.count))
        return ratio > 0.0004 && ratio < 0.45
    }

    /// 只做中值滤波（去孤立噪点），不像 descreen 那样再叠一层锐化
    public static func medianFilter(_ image: CGImage) -> CGImage? {
        let ci0 = CIImage(cgImage: image)
        guard let f = CIFilter(name: "CIMedianFilter") else { return nil }
        f.setValue(ci0, forKey: kCIInputImageKey)
        guard let out = f.outputImage else { return nil }
        return render(out, size: (image.width, image.height))
    }

    /// 对比度档：按分位数把 [lo, hi] 拉满到 [0, 255]。
    /// 针对「发灰 / 太淡」的扫描件——这类页面的直方图缩在中间一小段，
    /// 全局拉伸一下比任何滤镜都管用，而且不会引入伪影。
    public static func stretchContrast(_ image: CGImage, lowPct: Double = 0.02,
                                       highPct: Double = 0.98) -> CGImage? {
        guard let small = GrayBitmap.from(image, maxDim: 800) else { return nil }
        let hist = small.histogram()
        let total = small.count
        guard total > 0 else { return nil }
        func pct(_ p: Double) -> Int {
            var acc = 0
            let target = Int(Double(total) * p)
            for v in 0..<256 { acc += hist[v]; if acc >= target { return v } }
            return 255
        }
        let lo = pct(lowPct)
        let hi = pct(highPct)
        guard hi - lo >= 18 else { return nil }      // 本来就是全白页，没什么可拉
        var lut = [UInt8](repeating: 0, count: 256)
        for v in 0..<256 {
            let t = (Double(v) - Double(lo)) * 255.0 / Double(hi - lo)
            lut[v] = UInt8(max(0, min(255, Int(round(t)))))
        }
        guard let rgb = rgbSamples(image) else { return nil }
        var bytes = rgb.bytes
        for i in 0..<bytes.count { bytes[i] = lut[Int(bytes[i])] }
        return rgbImage(bytes, width: rgb.width, height: rgb.height)
    }

    /// 增强档（原「彩色增强」）：保住色彩与插图的前提下，校正光照 + 提一点饱和度与对比。
    /// 这类页面**不能**二值化——图表、印章、照片一旦二值化就毁了。
    ///
    /// 关于「不够干净」：原实现有两处让彩色页几乎清不掉背景，都已修：
    /// 1. 门槛 `backgroundUnevenness > 0.12` 太高。示例件第 3 页实测 0.104 —— 差 0.016
    ///    就整步跳过，于是那页只做了 +6% 饱和 / +6% 对比，人眼看到的"一层灰"原样留着。
    ///    均匀的底灰（纸色偏黄、整体发灰）恰恰是**不均匀度低**的，用"不匀"当门槛
    ///    本身就找错了指标。现在门槛降到 0.05，并且补一条"纸白偏暗"的判据：
    ///    纸白 < 250 就该清，不论它匀不匀。
    /// 2. 强度没有传导：去背景只提亮不压暗（见 removeBackground 注释），
    ///    而彩色页的纸白常在 235~248，提亮几乎无效。现在强度直通，允许压暗。
    public static func boostColor(_ image: CGImage, strength: Double = defaultStrength) -> CGImage? {
        var out = image
        let s = max(0, min(1, strength))
        // 强度 0 → 不碰背景，与 removeBackground 的"0 就是关"保持一致。
        //
        // ★ 这里**不再**用 needsBackgroundClean 当闸门（2026-09-12 改）。
        // 原来的写法是 `if s > 0.001, needsBackgroundClean(image)`，结果是：
        // 判据说"这页已经够干净"时，滑块无论拉到哪产出都逐字节相同——
        // 用户看到的是一个怎么拉都不动的控件。
        // 现在强度恒定生效，判据只负责**提示**（见 applyReporting 的 judgedClean）。
        // 代价是干净页也会被轻微归一化，但 mark ≥ 245 决定了幅度在 ±3 个灰阶以内，
        // 而 selftest 另有一条断言专门守"干净页不许被弄脏"。
        if s > 0.001 {
            out = keepContent(out, removeBackground(out, strength: s))
        }
        // 对比与饱和随强度走：强度高一点就稍微推狠一点，但都有上限，
        // 免得把"干净"做成"浓艳"——扫描件要的是清楚，不是好看。
        if let f = CIFilter(name: "CIColorControls") {
            f.setValue(CIImage(cgImage: out), forKey: kCIInputImageKey)
            f.setValue(1.06 + 0.14 * s, forKey: kCIInputSaturationKey)
            f.setValue(1.04 + 0.10 * s, forKey: kCIInputContrastKey)
            if let o = f.outputImage, let cg = render(o, size: (out.width, out.height)) {
                out = keepContent(out, cg)
            }
        }
        return keepContent(out, sharpen(out, amount: 0.6))
    }

    /// 这次 spec 会不会用到背景清理强度。
    ///
    /// 只用于**提示**，不看图像：真正会用到强度的路径才该告诉用户
    /// "这页已经够干净、滑块可能看不出变化"。`.bw` 走二值化（强度不参与运算）、
    /// `.original` 压根不碰画面，这两档不该发这条提示——它们的滑块本来就该是禁用的，
    /// 提示了反而像是在解释一个本来就不该出现的控件。
    public static func usesBackgroundStrength(_ spec: EnhanceSpec) -> Bool {
        if let name = spec.preset { return EnhancePreset(name).usesBgStrength }
        return spec.bgRemove == true
    }

    /// 这一页值不值得做背景清理。
    ///
    /// 两个判据取或的关系，因为"脏"有两种互不相干的形态：
    /// · **不匀**（阴影、光照渐变）→ backgroundUnevenness 高；
    /// · **平匀的灰**（纸色偏黄、整体发灰）→ 不匀度低，但纸白本身就暗，也该清。
    /// 只看前者就会漏掉第二种——那正是"画面不够干净"最典型的来源。
    /// 公开：CLI 的自检要直接断言这个判据（这条正是本次修的那个 bug 的守卫）
    public static func needsBackgroundClean(_ image: CGImage,
                                            uneven: Double = 0.05,
                                            paperWhite: Double = 249.0) -> Bool {
        if Analyzer.backgroundUnevenness(image) > uneven { return true }
        return !isPaperWhite(image, threshold: paperWhite)
    }

    /// 这页的纸面算不算"白"。
    ///
    /// 为什么是两个判据，而不是只看分位点：
    /// 分位点（下面 paperLevel 取的那个 p80）问的是"第 80 百分位有多亮"，
    /// 它**只看数量占比，不看占多数的那部分有多暗**。只要页面里有 ≥20% 的
    /// 接近白的区域，分位点就跳到 250+，哪怕剩下 80% 是发灰的纸。
    /// 而"≥20% 接近白"在真实文档里一点都不罕见：未印满的页、大面积留白、
    /// 页眉的白边、双栏排版中间的空白带、表格的空行……
    /// 实测（沙箱里用 numpy 复刻这条判据扫过一遍）：
    ///   · 整页 230 的灰纸 + 25% 的 250 白块 → 分位点 249（判为"白"），真实均值只有 234.8
    ///   · 同样条件下白块占比 15% → 分位点仍是 230，不会误判
    /// 也就是说单看分位点，会把"大半张灰纸 + 一条白边"这种页判成干净页而跳过清理。
    ///
    /// 补一个**真实均值**判据：均值是加权平均，白块再亮也摊不过去——
    /// 上面那个例子里均值只有 234.8，稳稳低于阈值。
    /// 两个判据取与，各堵对方的盲区：
    /// · 分位点管"整体亮度够不够"（对"大部分区域都亮"敏感）；
    /// · 均值管"白块有没有把分位点骗过去"（对"局部极亮"不敏感）。
    ///
    /// 顺带纠正一个我一开始就写错的前提：我原以为"撒几粒纯白噪点"就能骗过
    /// 分位点，实测根本不是——稀疏噪点占比远低于 20%，分位点纹丝不动
    /// （240 灰纸上撒 15% 白点都没反应，25% 才跳）。这个判据的真正软肋是
    /// **结构性的大面积亮区**，不是噪点。
    ///
    /// 阈值 250 比纸白阈值 249 略宽，是因为均值天然比亮端分位点低几个数，
    /// 用同一个数值会把大量正常的白纸也拖进清理流程。
    public static func isPaperWhite(_ image: CGImage, threshold: Double = 249.0) -> Bool {
        guard let g = GrayBitmap.from(image, maxDim: 900) else { return true }
        let hist = g.histogram()
        let total = g.count
        guard total > 0 else { return true }
        // 真实均值：直方图加权，不用再扫一遍像素
        var sum = 0
        for v in 0..<256 { sum += v * hist[v] }
        let mean = Double(sum) / Double(total)
        return paperLevel(image) >= threshold && mean >= 250.0
    }

    /// 纸白估计：全页**最亮 20% 像素的下界**（也就是 p80 分位点），0~255。
    ///
    /// 注意这个措辞——早先这里的注释写的是"最亮 20% 像素的均值"，那是错的，
    /// 实现从来都是分位点。两者都叫"纸白"但数值差好几级：
    /// 均值会被偏暗的少数纸面拉低，分位点只看边界。语义弄错会连带
    /// Analysis.paperWhite 的文档、阈值取值全部建立在错误理解上。
    ///
    /// 选分位点而不是均值的原因是**单调性**：清理得越干净，分位点越高，
    /// 强度滑块的效果才量得出来。均值在页面上还有大量文字时被墨水压住，
    /// 拉满强度也涨不了几个数，看上去像"滑块没生效"。
    /// （但反过来，分位点会被大面积亮区顶高——所以调用方要用 isPaperWhite
    ///  的双判据，而不是直接拿这个数比大小。）
    ///
    /// 用降采样版本（900px）纯粹为了快——这只是一个阈值判断，不需要全分辨率。
    /// 公开：CLI 输出底灰/纸白指标、自检断言都要用
    public static func paperLevel(_ image: CGImage) -> Double {
        guard let g = GrayBitmap.from(image, maxDim: 900) else { return 255 }
        let hist = g.histogram()
        let total = g.count
        guard total > 0 else { return 255 }
        // 从亮端往回数，取占 20% 的那条线
        var acc = 0
        let target = Int(Double(total) * 0.80)
        for v in stride(from: 255, through: 0, by: -1) {
            acc += hist[v]
            if acc >= total - target { return Double(v) }
        }
        return 255
    }

    /// 纸面真实平均亮度。分位点的对照物，也是双判据里"防局部极亮"的那一半：
    /// 大面积白块能把分位点顶上去，但摊不过均值。
    /// 公开：CLI 诊断输出要跟分位点并排显示，才看得出"分位点被骗了"。
    public static func paperMean(_ image: CGImage) -> Double {
        guard let g = GrayBitmap.from(image, maxDim: 900) else { return 255 }
        let hist = g.histogram()
        let total = g.count
        guard total > 0 else { return 255 }
        var sum = 0
        for v in 0..<256 { sum += v * hist[v] }
        return Double(sum) / Double(total)
    }

    /// 按模式处理一页。strength 是背景清理强度（0~1），只对保色彩/灰阶那几条路径有意义。
    public static func applyPreset(_ image: CGImage, _ preset: EnhancePreset,
                                   strength: Double = defaultStrength) -> CGImage {
        switch preset {
        case .original:
            return image
        case .bw:
            // 这里刻意**不**过 keepContent：二值化结果的 p90 与 p10 都是 255，
            // 直方图对比度算出来是 0，会被"内容保护"误判成洗掉了内容而退回原图，
            // 于是「黑白」看起来毫无效果。adaptiveBinarize 自带墨水率闸门，
            // 它说 OK 就够了。
            return adaptiveBinarize(image) ?? image
        case .contrast:
            return cleanThenContrast(image, strength: strength)
        case .color:
            return boostColor(image, strength: strength) ?? image
        case .auto:
            // 逐页判断是这个模式的全部价值所在：同一份 PDF 里,
            // 文字页和插图页该走完全不同的处理。
            //
            // 判据必须和压缩阶段的 effectiveMode 一致（颜色优先问饱和度）：
            // 这里曾经用 isGrayOnly（通道绝对差），它对 JPEG 色度噪声敏感、
            // 对"大片浅色"迟钝，和压缩端的判断打架，于是出现
            // 「增强按灰色处理、压缩按彩色处理」这种两头不讨好的组合。
            if Analyzer.hasColor(image) { return boostColor(image, strength: strength) ?? image }
            if Analyzer.isMonoLike(image) { return keepContent(image, adaptiveBinarize(image)) }
            // 灰阶非文字页（含老照片、灰度插图）也必须清背景，
            // 否则 auto 档的滑块对它们完全失效——第一版就是这么漏的。
            return cleanThenContrast(image, strength: strength)
        }
    }

    /// 灰阶连续调页面：先清背景，再拉对比。
    ///
    /// 为什么顺序不能反、也不能只做后者：底灰是**绝对亮度**问题（纸白只有 238，
    /// 整页蒙着一层灰），而 stretchContrast 是把 [p2, p98] 线性拉到 [0, 255] 的
    /// **相对**操作。一页如果通体都在 230~245 这个窄带里，拉伸只会把这点窄带
    /// 铺开、对比度变大，但那层灰依然"灰"——因为拉伸是等比例的，没有把纸白
    /// 单独拎到 255。所以必须先按背景电平归一化（把纸压白、把文字压黑），
    /// 再拉伸才轮得到它干活。
    ///
    /// 第一版把 auto 档的灰页直接丢给 stretchContrast，结果是滑块拉满四档、
    /// 底灰纹丝不动（CI 实测 239.4 / 202.3 全无变化）——滑块形同虚设。
    private static func cleanThenContrast(_ image: CGImage, strength: Double) -> CGImage {
        var out = image
        let s = max(0, min(1, strength))
        // 同样不再以 needsBackgroundClean 为闸门——理由见 boostColor 里那段。
        // 这条路径是 L4 问题的现场：示例件第 1 页在这里被判成"已经够干净"，
        // 于是四档强度产出逐字节相同。现在强度照常生效。
        if s > 0.001 {
            out = keepContent(out, removeBackground(out, strength: s))
        }
        return keepContent(out, stretchContrast(out))
    }

    private static func rgbImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        // 24bpp RGB 不受支持（CGImage 会返回 nil），一律走 32bpp RGBX
        var out = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            out[i * 4] = bytes[i * 3]
            out[i * 4 + 1] = bytes[i * 3 + 1]
            out[i * 4 + 2] = bytes[i * 3 + 2]
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    // MARK: - 自动裁边 + 透视校正

    /// 检出的页面四边形（归一化坐标，原点左下——与 Vision、Core Image 同向）。
    public struct DocumentQuad {
        public let topLeft: CGPoint
        public let topRight: CGPoint
        public let bottomLeft: CGPoint
        public let bottomRight: CGPoint
        /// 占整幅的面积比（1.0 = 铺满整幅）
        public let coverage: Double

        public var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

        // 显式构造入口：给"不经过 Vision、直接测几何"的调用方用（CI 自检就是）。
        // 见 autoCrop(_:quad:) 的注释——检出是 ML、闸门是几何，两者要能分开测。
        public init(topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint,
                    bottomRight: CGPoint, coverage: Double) {
            self.topLeft = topLeft
            self.topRight = topRight
            self.bottomLeft = bottomLeft
            self.bottomRight = bottomRight
            self.coverage = coverage
        }

        /// 按归一化矩形造一个正立的四边形（**原点左下**，与 Vision 同向）。
        /// `coverage` 不传就按矩形面积算。省得每处都手写四个角、也省得把
        /// 上下写反——那正是这块最容易犯的错。
        public static func upright(x0: Double, y0: Double, x1: Double, y1: Double,
                                   coverage: Double? = nil) -> DocumentQuad {
            DocumentQuad(topLeft: CGPoint(x: x0, y: y1), topRight: CGPoint(x: x1, y: y1),
                         bottomLeft: CGPoint(x: x0, y: y0), bottomRight: CGPoint(x: x1, y: y0),
                         coverage: coverage ?? max(0, min(1.2, (x1 - x0) * (y1 - y0))))
        }
    }

    /// 自动裁边的结论。
    ///
    /// 为什么 coverage / note 要一起带回来，而不是只返回一张图：
    /// 裁边是整个流水线里**唯一会主动丢掉像素**的一步，而且丢错了不可逆
    /// ——把正文当桌面裁掉，用户拿到的是一份残缺的 PDF。
    /// 所以调用方必须能拿到"为什么裁 / 为什么没裁"，把它写进处理日志与 warnings，
    /// 让用户有机会复核。**静默裁掉半页正文是这个功能最坏的失败方式。**
    public struct CropOutcome {
        public let image: CGImage
        public let applied: Bool
        public let coverage: Double
        public let note: String?
    }

    /// 让 Vision 找页面四角。
    ///
    /// 为什么用 `VNDetectDocumentSegmentationRequest` 而不是 `VNDetectRectanglesRequest`：
    /// 后者找的是"任意矩形"——表格框、印章、插图、名片都会命中；前者是**专为文档
    /// 边界训练的**，自带"这是一张纸"的先验。裁边要的正是后者。
    ///
    /// 为什么先缩到 1200px 再检：一是快（300dpi 的 A4 有 870 万像素），
    /// 二是稳（降采样顺手把拍照件的纸纹噪声抹平一层）。坐标本来就是归一化的，
    /// 缩与不缩不影响结果，乘回原尺寸即可。
    ///
    /// 这段坐标映射是本功能**唯一容易写错的地方**——它和 ImageUtils 开头那套
    /// "画 CGImage 前要先翻一次"的规矩是两回事：那套管的是 CGBitmapContext 取像素，
    /// 而 Vision 与 Core Image 的原点都在左下、彼此同向，**直接乘宽高即可**。
    /// 实测验证方式见 selftest 的裁边一节（纸内左上角放黑块，裁完必须还在左上）。
    public static func documentQuad(_ image: CGImage) -> DocumentQuad? {
        let maxDim = 1200
        let probe: CGImage
        if max(image.width, image.height) > maxDim {
            guard let s = resized(image, scale: Double(maxDim) / Double(max(image.width, image.height)))
            else { return nil }
            probe = s
        } else {
            probe = image
        }
        let req = VNDetectDocumentSegmentationRequest()
        do { try VNImageRequestHandler(cgImage: probe, options: [:]).perform([req]) }
        catch { return nil }
        guard let q = req.results?.first else { return nil }

        var acc = 0.0
        let pts = [q.topLeft, q.topRight, q.bottomRight, q.bottomLeft]
        for i in 0..<4 {
            acc += Double(pts[i].x * pts[(i + 1) % 4].y - pts[(i + 1) % 4].x * pts[i].y)
        }
        return DocumentQuad(topLeft: q.topLeft, topRight: q.topRight,
                            bottomLeft: q.bottomLeft, bottomRight: q.bottomRight,
                            coverage: min(1.2, abs(acc / 2)))
    }

    /// 自动裁边 + 透视校正。
    ///
    /// **保守护栏是这里的主体，不是附庸。** 一组实测数据（2026-09-12，本机 macOS，
    /// 合成"桌上的纸" + 项目自带示例扫描件）说明为什么：
    ///
    /// | 输入 | Vision 报的覆盖率 | 真实占比 | 外侧最亮带 | 盒内纸面 | 余量 |
    /// | --- | --- | --- | --- | --- | --- |
    /// | 桌上纸 margin .16 | 0.460 | 0.462 | 101 | 200 | **+99** |
    /// | 桌上纸 margin .30（纸很小） | 0.158 | 0.168 | 140 | 199 | **+60** |
    /// | 桌上纸 margin .04（纸几乎铺满） | 0.597 | **0.846** | 254 | 196 | **−58** |
    /// | 满幅页（压根没有桌面） | 0.698 | 1.000 | 255 | 194 | **−61** |
    /// | 本项目示例件 第1页 | 0.982 | 1.000 | 246 | 228 | **−19** |
    /// | 本项目示例件 第2页 | 0.967 | 1.000 | 219 | 172 | **−47** |
    /// | 本项目示例件 第3页 | 0.978 | 1.000 | 244 | 221 | **−22** |
    ///
    /// 三件事值得单独说：
    ///
    /// 1. **"有没有桌面"不能只看覆盖率。** 满幅页上 Vision 照样返回一个四边形
    ///    ——它不知道那是编的。示例件第 1 页报 0.982（看着像"整幅"），
    ///    而 margin .04 那行更阴：真实占比 0.846，Vision 只报 0.597，
    ///    照它裁会切掉 15% 正文。**既是高估也是低估，方向还不固定。**
    ///
    /// 2. **真正稳的判据是"边界外侧有没有暗下去"。** 真边界之外必然是桌面，
    ///    假边界之外还是纸。上表最后一列就是它：正例最低 +60、反例最高 −19，
    ///    中间隔着一大段空白，阈值取 30 两边都不贴边。这也是本项目一贯的取舍：
    ///    **宁可没裁，也不能裁掉正文**（与"宁可没增强，也不给一页纯黑"同源）。
    ///
    /// 3. **示例件的三页全部落在"不该裁"一侧**，这很重要：那三页是扫描仪出来的
    ///    满幅纸，本来就该一动不动。自动裁边是给**拍照件**用的。
    public static func autoCrop(_ image: CGImage) -> CropOutcome {
        guard image.width >= 64, image.height >= 64 else {
            return CropOutcome(image: image, applied: false, coverage: 1, note: nil)
        }
        guard let q = documentQuad(image) else {
            return CropOutcome(image: image, applied: false, coverage: 1,
                               note: T("裁边：没检出页面边界，这一页保持原样"))
        }
        return autoCrop(image, quad: q)
    }

    /// 已经拿到四边形时的裁边 —— **不碰 Vision**。
    ///
    /// 为什么要把这一半单独留出来：**检出是 ML，闸门与透视校正是几何。**
    /// 前者随系统版本变化，后者是确定的。实测（2026-09-12 的 CI 现场）：
    /// 同一张合成件，**macOS 26 的 Vision 能检出、macos-14 的模型检不出**，
    /// 于是那一节 7 条几何断言在 macos-14 上全红 —— **而产品行为其实完全正确**
    /// （没检出就原样返回，正是该做的事）。真正的毛病在教学层面：
    /// **别让一整节确定性断言，被一个不确定的依赖绑死。**
    /// 现在几何用显式构造的四边形测（两个系统都跑，见 selftest），
    /// 检出能力单独用一条断言盯。
    public static func autoCrop(_ image: CGImage, quad q: DocumentQuad) -> CropOutcome {
        let kept = { (note: String?) in
            CropOutcome(image: image, applied: false, coverage: q.coverage, note: note)
        }
        let w = Double(image.width)
        let h = Double(image.height)
        func px(_ p: CGPoint) -> CGPoint {
            CGPoint(x: max(0, min(1, p.x)) * w, y: max(0, min(1, p.y)) * h)
        }
        let tl = px(q.topLeft), tr = px(q.topRight), bl = px(q.bottomLeft), br = px(q.bottomRight)

        // 闸门 1：自交 / 畸变。Vision 一般不会给出自交四边形，但真给出时
        // CIPerspectiveCorrection 会安静地产出一张扭坏的图——那种失败不报错，
        // 只能靠这里拦。
        guard isConvexQuad(tl, tr, br, bl) else {
            return kept(T("裁边：检出的四边形畸变，已跳过（保持原样）"))
        }

        // 闸门 2：占比。≥0.96 说明检出的是整幅画布，裁了也没什么可裁；
        // <0.10 则多半是把页面上某个小方框（印章、表格、插图）当成了纸。
        if q.coverage >= 0.96 {
            return kept(String(format: T("裁边：页面已铺满整幅（占比 %.0f%%），无需裁切"), q.coverage * 100))
        }
        if q.coverage < 0.10 {
            return kept(String(format: T("裁边：检出区域只占整幅 %.0f%%，疑似误检，已跳过"), q.coverage * 100))
        }

        // 闸门 3：包围盒不能太窄太扁（误检的典型形状）
        let xs = [tl.x, tr.x, bl.x, br.x], ys = [tl.y, tr.y, bl.y, br.y]
        let bw = (xs.max() ?? 0) - (xs.min() ?? 0)
        let bh = (ys.max() ?? 0) - (ys.min() ?? 0)
        guard bw >= w * 0.25, bh >= h * 0.25 else {
            return kept(T("裁边：检出区域过于狭长，疑似误检，已跳过"))
        }

        // 闸门 4：外侧必须真的暗下去（见函数注释第 2 点，这是最要紧的一条）
        guard let bc = boundaryContrast(image, quad: q.corners) else {
            return kept(T("裁边：判不出边界外侧的明暗，为稳妥起见已跳过"))
        }
        guard bc.inside - bc.outside > 30 else {
            return kept(String(format: T("裁边：边界外侧依然是纸面（里 %.0f / 外 %.0f），判定为满幅扫描页，已跳过"),
                               bc.inside, bc.outside))
        }

        guard let f = CIFilter(name: "CIPerspectiveCorrection") else {
            return kept(T("裁边：系统没有 CIPerspectiveCorrection，已跳过"))
        }
        f.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        f.setValue(CIVector(cgPoint: tl), forKey: "inputTopLeft")
        f.setValue(CIVector(cgPoint: tr), forKey: "inputTopRight")
        f.setValue(CIVector(cgPoint: bl), forKey: "inputBottomLeft")
        f.setValue(CIVector(cgPoint: br), forKey: "inputBottomRight")
        guard let out = f.outputImage else {
            return kept(T("裁边：透视校正没有输出，已跳过"))
        }
        let rect = out.extent.integral
        guard rect.width >= 64, rect.height >= 64, let cg = ci.createCGImage(out, from: rect) else {
            return kept(T("裁边：校正结果尺寸异常，已跳过"))
        }
        let (trimmed, trimPct) = trimResidualBorder(cg)
        let extra = trimPct > 0.001 ? String(format: T("，并修掉 %.1f%% 的残留纸边"), trimPct * 100) : ""
        return CropOutcome(image: trimmed, applied: true, coverage: q.coverage,
                           note: String(format: T("裁边：检出页面占比 %.0f%%，已裁到 %d×%d 并校正透视%@"),
                                        q.coverage * 100, trimmed.width, trimmed.height, extra))
    }

    /// 裁完之后修一次边。
    ///
    /// 为什么需要这一步：检出四角难免差一两个像素，页面又是歪的，
    /// 这点误差在结果里就是**边缘残留一条桌面**（实测约 1% 宽）。而增强阶段
    /// 会把这个窄条染成黑——它在纸面旁边，局部均值很高，二值化必然把它判成墨
    /// （见"二值化会把暗桌面染成纯黑"那条老经验），于是页面边上多出一条显眼的黑线。
    /// 桌面 85 / 纸面 255，两者差得足够远，所以用"边缘这一行/列的平均亮度"
    /// 就能看出它还脏不脏——不需要再加一套颜色判据。
    ///
    /// **实测证据**（`selftest` 每次都会打印，可复现）：
    /// 旋转 3.5° 的合成件，看结果**贴边一圈的暗像素占比**——
    /// 关掉修边 **6127/188018 = 3.26%**，开着修边 **228/187436 = 0.12%**，差 27 倍。
    /// ⚠️ 别改用"边圈均值"当判据：残留桌面只占约 1% 宽，混进整圈后均值只从
    /// 254 掉到 247，**看不出问题**——第一版断言就是这么写的，
    /// 结果它把修边整个关掉都照样是绿的（详见 main.swift 里那段注释）。
    ///
    /// **上限 2% 是刻意留的。** 这一步毕竟是在主动丢像素，而判据万一被
    /// 内容骗了（比如页面顶边印着一整条黑色页眉），有上限才不会一路吃进去。
    /// 宁可留一点脏边，也不能吃正文——与本功能一贯的取舍一致。
    public static func trimResidualBorder(_ image: CGImage, maxTrim: Double = 0.02) -> (CGImage, Double) {
        guard let g = GrayBitmap.from(image, maxDim: 900) else { return (image, 0) }
        let w = g.width
        let h = g.height
        guard w > 8, h > 8 else { return (image, 0) }
        // "还像纸"的下沿。桌面 85 / 纸面 255，中间空得很，所以这个数不敏感：
        // 实测取 230 与 240 结果完全一样（旋转页边缘黑像素都是 130、尺寸同为 792×1116）。
        // 取 240 只是略微更倾向"判定为脏"，**并不会更危险**——真会吃正文的那种
        // 情形（页面顶边印着一整条黑页眉，整行均值被拉到 100 上下）在 230 和 240 下
        // 都会被吃，能兜住的始终是上面那个 2% 上限，而不是这里的门限。
        let paperish = 240.0

        func lineMean(_ fixed: Int, _ horizontal: Bool) -> Double {
            var s = 0.0
            if horizontal {
                for x in 0..<w { s += Double(g.pixels[fixed * w + x]) }
                return s / Double(w)
            }
            for y in 0..<h { s += Double(g.pixels[y * w + fixed]) }
            return s / Double(h)
        }

        let capY = max(1, Int(Double(h) * maxTrim))
        let capX = max(1, Int(Double(w) * maxTrim))
        var top = 0
        while top < capY, lineMean(top, true) < paperish { top += 1 }
        var bottom = 0
        while bottom < capY, lineMean(h - 1 - bottom, true) < paperish { bottom += 1 }
        var left = 0
        while left < capX, lineMean(left, false) < paperish { left += 1 }
        var right = 0
        while right < capX, lineMean(w - 1 - right, false) < paperish { right += 1 }

        let fTop = Double(top) / Double(h)
        let fBottom = Double(bottom) / Double(h)
        let fLeft = Double(left) / Double(w)
        let fRight = Double(right) / Double(w)
        let worst = max(max(fTop, fBottom), max(fLeft, fRight))
        guard worst > 0.0005 else { return (image, 0) }

        // CGImage.cropping 用的是"行 0 在上"的图像坐标，所以上边收掉 = 抬高 y 起点
        let px = CGRect(x: Double(image.width) * fLeft,
                        y: Double(image.height) * fTop,
                        width: Double(image.width) * (1 - fLeft - fRight),
                        height: Double(image.height) * (1 - fTop - fBottom))
        guard px.width >= 64, px.height >= 64, let cropped = image.cropping(to: px) else {
            return (image, 0)
        }
        return (cropped, worst)
    }

    /// 边界外侧的"桌面亮度"与盒内纸面亮度。
    ///
    /// 做法：取检出四边形的**包围盒**（不求精确投影，见下），在盒外上/下/左/右
    /// 各取一条薄带求均值，取最亮的那条当 `outside`；盒内中心 60% 取均值当 `inside`。
    ///
    /// 为什么用包围盒而不是四边形本身：页面在照片里往往是**歪的**，包围盒比四边形大，
    /// 于是"盒外的薄带"一定在真纸面之外——判据偏保守，而保守正是这里要的方向
    /// （宁可漏裁，不可错裁）。反过来若用四边形本身，斜角处会采到纸面，判据会失真。
    ///
    /// 为什么取**最亮**而不是平均：边界被低估时（margin .04 那种），四条带里
    /// 只有一部分还是纸、另一部分确实是桌面，平均下来会被稀释掉。
    /// 最亮的那条一票就能否掉——实测正是靠它把 margin .04 从 +21 拉到 −58。
    ///
    /// 返回 nil 表示"判不出来"（比如四边形的包围盒已经贴住画幅边缘，采不到外带），
    /// 调用方按"跳过"处理：判不出来就不许动像素。
    static func boundaryContrast(_ image: CGImage, quad: [CGPoint]) -> (inside: Double, outside: Double)? {
        guard let g = GrayBitmap.from(image, maxDim: 900) else { return nil }
        let w = g.width
        let h = g.height
        // 归一化（原点左下）→ 像素行列。灰度缓冲的行 0 是视觉顶行，所以要 1-y 翻过来。
        let xs = quad.map { $0.x * Double(w) }
        let ys = quad.map { (1 - $0.y) * Double(h) }
        guard let xmin = xs.min(), let xmax = xs.max(),
              let ymin = ys.min(), let ymax = ys.max() else { return nil }
        let x0 = max(0, Int(xmin)), x1 = min(w - 1, Int(xmax))
        let y0 = max(0, Int(ymin)), y1 = min(h - 1, Int(ymax))
        guard x1 > x0 + 2, y1 > y0 + 2 else { return nil }
        let band = max(2, Int(Double(min(w, h)) * 0.02))

        func mean(_ ax0: Int, _ ax1: Int, _ ay0: Int, _ ay1: Int) -> Double? {
            let sx0 = max(0, ax0), sx1 = min(w - 1, ax1)
            let sy0 = max(0, ay0), sy1 = min(h - 1, ay1)
            guard sx1 > sx0, sy1 > sy0 else { return nil }
            var s = 0.0
            var n = 0
            for y in sy0...sy1 {
                let base = y * w
                for x in sx0...sx1 { s += Double(g.pixels[base + x]); n += 1 }
            }
            return n > 0 ? s / Double(n) : nil
        }

        let strips = [mean(x0, x1, y0 - band, y0 - 1),
                      mean(x0, x1, y1 + 1, y1 + band),
                      mean(x0 - band, x0 - 1, y0, y1),
                      mean(x1 + 1, x1 + band, y0, y1)].compactMap { $0 }
        // 少于两条能采到就不敢下结论：信息不够时宁可不动像素
        guard strips.count >= 2 else { return nil }
        // 盒内取 20%~80%：避开页边的文字行与那个方向基准黑块
        let inx0 = x0 + (x1 - x0) / 5, inx1 = x1 - (x1 - x0) / 5
        let iny0 = y0 + (y1 - y0) / 5, iny1 = y1 - (y1 - y0) / 5
        guard let inside = mean(inx0, inx1, iny0, iny1) else { return nil }
        return (inside, strips.max() ?? inside)
    }

    /// 凸四边形判定：相邻三点的叉积符号必须一致（有向面积同正或同负）。
    private static func isConvexQuad(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        let pts = [a, b, c, d]
        var sign = 0
        for i in 0..<4 {
            let p = pts[i], q = pts[(i + 1) % 4], r = pts[(i + 2) % 4]
            let cross = (q.x - p.x) * (r.y - q.y) - (q.y - p.y) * (r.x - q.x)
            if abs(cross) < 1e-6 { continue }
            let s = cross > 0 ? 1 : -1
            if sign == 0 { sign = s } else if s != sign { return false }
        }
        return sign != 0
    }

    /// 哪些滤镜在当前系统可用（用于自检，不至于静默降级）
    public static func availableFilters() -> [String] {
        ["CIMedianFilter", "CIUnsharpMask", "CIColorControls"].filter { CIFilter(name: $0) != nil }
    }

    // MARK: - 串起来

    /// `applyReporting` 的结果。
    ///
    /// 为什么不只返回 CGImage：有两个"过程事实"是调用方（CLI 日志、App 提示）需要
    /// 而图像本身表达不了的：
    /// · `judgedClean` —— 这一页被判为"已经够干净"。强度在这页上照常生效，
    ///   但视觉上多半看不出变化，得提示用户，否则他会以为滑块坏了（L4 的收尾）；
    /// · `cropApplied` —— 这一页真的被裁过。裁边是唯一会丢像素的步骤，
    ///   调用方值得知道它动过手。
    public struct ApplyOutcome {
        public let image: CGImage
        public let judgedClean: Bool
        public let cropApplied: Bool
        public let notes: [String]
    }

    /// 依次应用滤镜，并把"这次做了什么、为什么"一并带回来。
    ///
    /// 顺序是有讲究的：**先裁边**（它改变几何）→ 纠偏 → 去网纹 → 再做模式处理 → 最后锐化。
    /// 去网纹必须在二值化之前，否则网点会被二值化固化成永久噪点。
    ///
    /// 裁边为什么排在最前：后面每一步都建立在"画面上只有纸"这个前提上——
    /// 纠偏的投影剖面会被桌沿的直线带偏，背景去除的 24×24 网格会把桌面也当成
    /// 纸面去算白电平，二值化的局部窗口也会被桌面撑坏。先把纸裁出来，后面每一步都更准。
    /// `cropQuad` 是给"已经知道纸的四角"的调用方留的出口：传进来就不跑 Vision，
    /// 直接按这个四边形裁。两个真实用途：
    ///   ① 调用方在体检阶段已经检出过，没必要为每一页再跑一次 ML；
    ///   ② **自检**——见 `autoCrop(_:quad:)` 的注释：几何断言必须能绕开 ML，
    ///      否则一个模型的系统差异就能让它们红一片（v0.3.4 第一次推送就是这么翻的：
    ///      拆了 `autoCrop` 却漏了这一条，于是它又成了 7 条红里最后剩下的那 1 条）。
    /// 默认 nil = 老老实实跑 `VNDetectDocumentSegmentationRequest`。
    public static func applyReporting(_ image: CGImage, spec: EnhanceSpec,
                                      cropQuad: DocumentQuad? = nil) -> ApplyOutcome {
        var out = image
        var notes: [String] = []
        let strength = max(0, min(1, spec.bgStrength ?? defaultStrength))

        var cropApplied = false
        if spec.autoCrop == true {
            let c = cropQuad.map { autoCrop(out, quad: $0) } ?? autoCrop(out)
            out = c.image
            cropApplied = c.applied
            if let n = c.note { notes.append(n) }
        }
        if spec.deskew == true {
            let s = detectSkew(out)
            if let r = deskew(out, degrees: s) { out = r }
        }
        if spec.descreen == true {
            out = keepContent(out, descreen(out))
        }

        // 判据要在做清理**之前**取：清理做完之后页面当然"够干净"了，
        // 那时候再判只能得到一个恒为真的答案（第一版就是这么写错的）。
        let judgedClean = usesBackgroundStrength(spec) && strength > 0.001
                         && !needsBackgroundClean(out)

        // 背景去除只在「没选模式」时单独跑：模式内部会自己做光照校正，
        // 两处都做会把同一页提亮两次（实测会明显发灰）。
        if spec.preset == nil && spec.bgRemove == true {
            out = keepContent(out, removeBackground(out, strength: strength))
        }
        if let name = spec.preset {
            out = applyPreset(out, EnhancePreset(name), strength: strength)
        }
        if let amt = spec.sharpen, amt > 0 {
            out = keepContent(out, sharpen(out, amount: amt))
        }

        if judgedClean {
            notes.append(T("这一页体检判定为已经够干净：背景强度仍按设定应用，但视觉上可能看不出变化"))
        }
        return ApplyOutcome(image: out, judgedClean: judgedClean,
                            cropApplied: cropApplied, notes: notes)
    }

    /// 只要图、不要过程信息的调用方（预览、体检抽样、自检）走这个薄壳。
    public static func apply(_ image: CGImage, spec: EnhanceSpec) -> CGImage {
        applyReporting(image, spec: spec).image
    }

    /// 滤镜不许把内容洗掉。
    /// 判据是"对比度"（直方图 p90 - p10）而不是墨水率：Otsu 阈值会自适应，
    /// 一页被洗成浅灰的文字照样能算出 3% 的墨水率，但对比度会掉到原来的几分之一。
    private static func keepContent(_ original: CGImage, _ filtered: CGImage?) -> CGImage {
        // 注意：这个"内容保护"只对**连续调**的结果有效。
        // 纯黑白（二值）结果的 p90 与 p10 都是同一端，对比度恒为 0，会被误判成内容丢失，
        // 所以二值化那条路径不要走这里（见 applyPreset(.bw)）。
        guard let f = filtered else { return original }
        guard let go = GrayBitmap.from(original, maxDim: 800),
              let gf = GrayBitmap.from(f, maxDim: 800) else { return original }
        let co = go.contrast()
        let cf = gf.contrast()
        guard co > 20 else { return f }            // 原图本身就没内容，没什么好护的
        return cf >= co * 0.6 ? f : original
    }
}
