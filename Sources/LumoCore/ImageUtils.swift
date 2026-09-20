// Lumo 原生核心 —— 像素工具
// 全部基于 CoreGraphics / Foundation，没有任何第三方依赖。
import Foundation
import CoreGraphics
import ImageIO

// MARK: - 坐标方向的约定（改动前务必读完）
//
// CGBitmapContext 的坐标原点在左下、y 轴朝上；而 CGImage 的第 0 行是「视觉上的顶行」。
// 两者方向相反，所以凡是 ctx.draw(cgImage, in:) 取像素的地方，都必须先
//   translateBy(0, h) + scaleBy(1, -1)
// 翻一次，否则拿到的位图是上下镜像的。
// 例外是 ctx.drawPDFPage()：PDF 用户空间本来就是 y 轴朝上，与 context 同向，不能再翻。
// 之前这里漏了翻转，packOneBit 出来的单色页会整体上下颠倒——体积看起来正常，画面却是坏的。

/// 8 位灰度位图。用 Swift 数组而不是裸指针：这里的代码一次写对最重要，
/// 页面级图像（~4MB）用数组也不会成为瓶颈。
public struct GrayBitmap {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public var count: Int { width * height }

    /// 从 CGImage 取灰度；maxDim > 0 时先降采样（分析用，省时间）
    public static func from(_ image: CGImage, maxDim: Int = 0) -> GrayBitmap? {
        let srcW = image.width
        let srcH = image.height
        var w = srcW
        var h = srcH
        if maxDim > 0, max(srcW, srcH) > maxDim {
            let s = Double(maxDim) / Double(max(srcW, srcH))
            w = max(1, Int(Double(srcW) * s))
            h = max(1, Int(Double(srcH) * s))
        }
        var buf = [UInt8](repeating: 255, count: w * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        // 不翻：CGBitmapContext 画 CGImage 时，首行本来就落在缓冲区的第一行（=顶行）。
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return GrayBitmap(width: w, height: h, pixels: buf)
    }

    public func toCGImage() -> CGImage? {
        let bytes = pixels
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    public func histogram() -> [Int] {
        var hist = [Int](repeating: 0, count: 256)
        for v in pixels { hist[Int(v)] += 1 }
        return hist
    }

    /// 行均值（投影剖面）。纠偏评分就靠它：文字行越平，行间方差越大。
    public func rowMeans() -> [Double] {
        var out = [Double](repeating: 0, count: height)
        var idx = 0
        for y in 0..<height {
            var sum = 0
            for _ in 0..<width { sum += Int(pixels[idx]); idx += 1 }
            out[y] = Double(sum) / Double(width)
        }
        return out
    }

    /// 相邻行均值之差的平方和：文字行与行距交替出现时最大
    public func rowScore() -> Double {
        let m = rowMeans()
        guard m.count > 2 else { return 0 }
        var acc = 0.0
        for i in 1..<m.count {
            let d = m[i] - m[i - 1]
            acc += d * d
        }
        return acc / Double(m.count)
    }

    public func mean() -> Double {
        guard !pixels.isEmpty else { return 255 }
        var s = 0
        for v in pixels { s += Int(v) }
        return Double(s) / Double(pixels.count)
    }

    /// 直方图对比度（p90 - p10）。
    /// 用它而不是"墨水率"来判断内容有没有被滤镜洗掉：Otsu 阈值会自适应，
    /// 一页被洗成浅灰的文字照样能算出 3% 的墨水率，但对比度会掉到原来的几分之一。
    public func contrast() -> Double {
        let hist = histogram()
        let total = count
        guard total > 0 else { return 0 }
        func percentile(_ p: Double) -> Double {
            var acc = 0
            let target = Int(Double(total) * p)
            for v in 0..<256 {
                acc += hist[v]
                if acc >= target { return Double(v) }
            }
            return 255
        }
        return percentile(0.9) - percentile(0.1)
    }

    /// 拉普拉斯方差：噪声/网纹越强，高频能量越大
    public func laplacianVariance() -> Double {
        let w = width
        let h = height
        guard w > 3, h > 3 else { return 0 }
        var sum = 0.0
        var sumSq = 0.0
        var n = 0
        for y in 1..<(h - 1) {
            let r0 = (y - 1) * w
            let r1 = y * w
            let r2 = (y + 1) * w
            for x in 1..<(w - 1) {
                let c = Int(pixels[r1 + x])
                let v = Double(4 * c - Int(pixels[r0 + x]) - Int(pixels[r2 + x])
                                 - Int(pixels[r1 + x - 1]) - Int(pixels[r1 + x + 1]))
                sum += v
                sumSq += v * v
                n += 1
            }
        }
        guard n > 0 else { return 0 }
        let m = sum / Double(n)
        return max(0, sumSq / Double(n) - m * m)
    }

    /// 噪声 / 网纹强度：拉普拉斯绝对值的**中位数**（再除以 4 归一化成"平均偏离"）。
    ///
    /// 为什么不用拉普拉斯方差：文字笔画本身就是最强的高频，方差一上来就被文字主导，
    /// 结果任何干净扫描件都被判成"噪声 1.0"，去网纹被无脑打开（真实踩过的坑）。
    /// 中位数看的是占画面绝大多数的**平坦区域**——那里有抖动才是真噪声：
    /// 干净页接近 0，压缩噪声页几个灰阶，半调网纹页几十个灰阶。
    /// 用 256 桶计数找中位数，避免给 4MB 像素做一次排序。
    public func noiseScore() -> Double {
        let w = width
        let h = height
        guard w > 3, h > 3 else { return 0 }
        var hist = [Int](repeating: 0, count: 256)
        var n = 0
        for y in 1..<(h - 1) {
            let r0 = (y - 1) * w
            let r1 = y * w
            let r2 = (y + 1) * w
            for x in 1..<(w - 1) {
                let c = Int(pixels[r1 + x])
                let v = abs(4 * c - Int(pixels[r0 + x]) - Int(pixels[r2 + x])
                              - Int(pixels[r1 + x - 1]) - Int(pixels[r1 + x + 1]))
                hist[min(255, v / 4)] += 1
                n += 1
            }
        }
        guard n > 0 else { return 0 }
        var acc = 0
        let target = n / 2
        for i in 0..<256 {
            acc += hist[i]
            if acc >= target { return min(1.0, Double(i) / 12.0) }
        }
        return 0
    }
}

// MARK: - 色彩判定 / 原始采样

/// 三通道最大差值：判断页面是否只有灰阶（无彩色）
public func maxChannelSpread(_ image: CGImage, maxDim: Int = 480) -> Int {
    guard let rgb = rgbSamples(image, maxDim: maxDim) else { return 255 }
    var worst = 0
    var i = 0
    while i + 2 < rgb.bytes.count {
        let r = Int(rgb.bytes[i])
        let g = Int(rgb.bytes[i + 1])
        let b = Int(rgb.bytes[i + 2])
        worst = max(worst, max(abs(r - g), max(abs(g - b), abs(r - b))))
        i += 3
    }
    return worst
}

public struct RGBSamples {
    public let width: Int
    public let height: Int
    public let bytes: [UInt8]      // r,g,b,r,g,b...
}

public func rgbSamples(_ image: CGImage, maxDim: Int = 0) -> RGBSamples? {
    let w0 = image.width
    let h0 = image.height
    var w = w0
    var h = h0
    if maxDim > 0, max(w0, h0) > maxDim {
        let s = Double(maxDim) / Double(max(w0, h0))
        w = max(1, Int(Double(w0) * s))
        h = max(1, Int(Double(h0) * s))
    }
    // 采样用 32bpp（RGBX）而不是 24bpp RGB：后者不在 CoreGraphics 支持的像素格式表里，
    // CGContext/CGImage 会直接返回 nil——曾经就是这里静默失败，
    // 让「ZIP 无损」悄悄退化成了 JPEG，界面上却一点迹象都没有。
    var tmp = [UInt8](repeating: 255, count: w * h * 4)
    guard let ctx = CGContext(data: &tmp, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var bytes = [UInt8](repeating: 255, count: w * h * 3)
    for i in 0..<(w * h) {
        bytes[i * 3] = tmp[i * 4]
        bytes[i * 3 + 1] = tmp[i * 4 + 1]
        bytes[i * 3 + 2] = tmp[i * 4 + 2]
    }
    return RGBSamples(width: w, height: h, bytes: bytes)
}

/// 灰度化：直接画进 DeviceGray context，比手算 ITU-R 权重更快也更一致
public func grayCGImage(from image: CGImage) -> CGImage? {
    let w = image.width
    let h = image.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}

/// 取 8 位灰度原始采样（Flate 编码要用）
public func graySamples(_ image: CGImage) -> (width: Int, height: Int, bytes: [UInt8])? {
    guard let g = GrayBitmap.from(image) else { return nil }
    return (g.width, g.height, g.pixels)
}

// MARK: - 二值化 / 打包 / 压缩

/// Otsu 阈值 + 墨水占比。文字页 ink 通常在 0.2%~10% 之间。
public func otsuThreshold(_ g: GrayBitmap) -> (threshold: UInt8, ink: Double) {
    let hist = g.histogram()
    let total = g.count
    guard total > 0 else { return (128, 0) }
    var sum = 0
    for t in 0..<256 { sum += t * hist[t] }
    var sumB = 0
    var wB = 0
    var best: Double = -1
    var bestT = 128
    for t in 0..<256 {
        wB += hist[t]
        if wB == 0 { continue }
        let wF = total - wB
        if wF == 0 { break }
        sumB += t * hist[t]
        let mB = Double(sumB) / Double(wB)
        let mF = Double(sum - sumB) / Double(wF)
        let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
        if between > best { best = between; bestT = t }
    }
    let thr = UInt8(max(0, min(255, bestT)))
    var ink = 0
    for t in 0...Int(thr) { ink += hist[t] }
    return (thr, Double(ink) / Double(total))
}

/// 打包成 1bit（1 = 白，0 = 黑），PDF 的默认 Decode[0 1] 与 TIFF 的 BlackIsZero 都正好对得上
public func packOneBit(_ g: GrayBitmap, threshold: UInt8) -> Data {
    let rowBytes = (g.width + 7) / 8
    var out = [UInt8](repeating: 0xFF, count: rowBytes * g.height)
    for y in 0..<g.height {
        let src = y * g.width
        let dst = y * rowBytes
        for x in 0..<g.width {
            if g.pixels[src + x] <= threshold {
                out[dst + (x >> 3)] &= ~(0x80 >> (x & 7))
            }
        }
    }
    return Data(out)
}

/// PNG 的 Up 预测器（filter type 2），**不带**行首 filter 字节。
///
/// ⚠️ 这是**错误的** PDF 写法，只作为反例保留给 selftest 的交叉验证：
/// 拿它写出来的 /FlateDecode 图，解回来是**乱码**（实测与正确图像的平均像素差 123）。
///
/// ★ 这里曾经写着「PDF 的预测器行首没有 filter 字节，补了会整页空白」——
/// **那句话是错的**。PDF 规范的 Predictor 10–15 都是 PNG 预测器，
/// 而行格式就是 `[filter byte][filtered bytes]`；一次带 5 种写法的实测（见 selftest）
/// 给出的结论很干脆：带字节的 P12 / P15 逐像素差 **0.00**（完全正确），
/// 不带字节的 P12 差 123——当年的"空白"多半是改了字节又动了别的地方，
/// 而当时用「对比度」当判据也看不出真相（连错的 TIFF 预测器都拿到了 190 的对比度）。
public func pngUpFilter(_ bytes: [UInt8], rowBytes: Int, height: Int) -> [UInt8] {
    guard rowBytes > 0, height > 0 else { return [] }
    var out = [UInt8]()
    out.reserveCapacity(rowBytes * height)
    var prev = [UInt8](repeating: 0, count: rowBytes)
    for y in 0..<height {
        let base = y * rowBytes
        for i in 0..<rowBytes {
            let v = bytes[base + i]
            out.append(UInt8(truncatingIfNeeded: Int(v) - Int(prev[i])))
            prev[i] = v
        }
    }
    return out
}

/// PNG 风格预测器，**按 PDF /Predictor 15 的写法**：每行前面带一个 filter 字节。
///
/// 这与上面 `pngUpFilter` 的差别只有那一个字节，但它决定了哪种写法是对的。
/// PDF 规范（ISO 32000-1 表 8）里 Predictor 10–15 都是「PNG 预测器」，
/// 而 PNG 的行格式本身就是 `[filter byte][filtered bytes]`：
/// **/Predictor 15 必须逐行带这个字节**（15 的含义就是"逐行自己选"）。
/// 10–14 是"整幅固定用某一种"，各家实现对这个字节的处理并不一致——
/// 与其照文档赌，不如两种写法都渲染出来看哪张是正常的（见 selftest 的交叉验证）。
///
/// `filterType` 只允许 0–4：0 None、1 Sub、2 Up、3 Average、4 Paeth。
public func pngPredictorRows(_ bytes: [UInt8], rowBytes: Int, height: Int,
                             filterType: UInt8 = 2) -> [UInt8] {
    guard rowBytes > 0, height > 0 else { return [] }
    var out = [UInt8]()
    out.reserveCapacity(rowBytes * height + height)
    var prev = [UInt8](repeating: 0, count: rowBytes)
    var cur = [UInt8](repeating: 0, count: rowBytes)
    for y in 0..<height {
        let base = y * rowBytes
        for i in 0..<rowBytes { cur[i] = bytes[base + i] }
        out.append(filterType)
        switch filterType {
        case 1:   // Sub：减左邻
            for i in 0..<rowBytes {
                let left = i >= 1 ? cur[i - 1] : 0
                out.append(UInt8(truncatingIfNeeded: Int(cur[i]) - Int(left)))
            }
        case 3:   // Average：减（左 + 上）/2
            for i in 0..<rowBytes {
                let left = i >= 1 ? Int(cur[i - 1]) : 0
                out.append(UInt8(truncatingIfNeeded: Int(cur[i]) - (left + Int(prev[i])) / 2))
            }
        case 4:   // Paeth
            for i in 0..<rowBytes {
                let a = i >= 1 ? Int(cur[i - 1]) : 0
                let b = Int(prev[i])
                let c = i >= 1 ? Int(prev[i - 1]) : 0
                let pp = a + b - c
                let pa = abs(pp - a), pb = abs(pp - b), pc = abs(pp - c)
                let pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c)
                out.append(UInt8(truncatingIfNeeded: Int(cur[i]) - pred))
            }
        default:  // 0 None / 2 Up
            for i in 0..<rowBytes {
                out.append(filterType == 2
                           ? UInt8(truncatingIfNeeded: Int(cur[i]) - Int(prev[i]))
                           : cur[i])
            }
        }
        prev = cur
    }
    return out
}

/// 逐行自选滤波方式的 PNG 预测器（PDF `/Predictor 15` 的真实含义），
/// 每行按 PNG 的经典启发式挑一种：**把滤波后的字节当作有符号数求和，
/// 取绝对值之和最小的那一种**。这是 PNG 编码器通用的做法，
/// 对扫描件（大片渐变 + 硬边）通常比固定用 Up 再省一档。
///
/// 行格式严格按 PNG：`[filter byte][filtered bytes...]`。
public func pngPredictorOptimumRows(_ bytes: [UInt8], rowBytes: Int, height: Int) -> [UInt8] {
    guard rowBytes > 0, height > 0 else { return [] }
    var out = [UInt8]()
    out.reserveCapacity(rowBytes * height + height)
    var prev = [UInt8](repeating: 0, count: rowBytes)
    var cur = [UInt8](repeating: 0, count: rowBytes)
    var best: [UInt8] = []
    for y in 0..<height {
        let base = y * rowBytes
        for i in 0..<rowBytes { cur[i] = bytes[base + i] }
        var bestType: UInt8 = 0
        var bestScore = Int.max
        for t in UInt8(0)...4 {
            var cand = [UInt8](repeating: 0, count: rowBytes)
            var score = 0
            for i in 0..<rowBytes {
                let a = i >= 1 ? Int(cur[i - 1]) : 0
                let b = Int(prev[i])
                let c = i >= 1 ? Int(prev[i - 1]) : 0
                let pred: Int
                switch t {
                case 1:  pred = a
                case 2:  pred = b
                case 3:  pred = (a + b) / 2
                case 4:
                    let pp = a + b - c
                    let pa = abs(pp - a), pb = abs(pp - b), pc = abs(pp - c)
                    pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c)
                default: pred = 0
                }
                let v = UInt8(truncatingIfNeeded: Int(cur[i]) - pred)
                cand[i] = v
                // 有符号解释，取绝对值——PNG 规范的启发式
                score += abs(v < 128 ? Int(v) : Int(v) - 256)
            }
            if score < bestScore {
                bestScore = score; bestType = t; best = cand
            }
        }
        out.append(bestType)
        out.append(contentsOf: best)
        prev = cur
    }
    return out
}

/// zlib 压缩，产出 PDF FlateDecode 需要的 **RFC1950 流**（2 字节头 + 数据 + adler32）。
///
/// 这里曾经直接返回 `NSData.compressed(using: .zlib)` 的结果：它能被同一套 API 解开，
/// 于是"往返自洽"看起来是好的，可读进 PDF 却是空白页——阅读器要求的是带头的 zlib 流，
/// 不是裸 deflate。所以这里按头部特征判断一次，不像就自己把头尾补上。
public func deflate(_ data: Data) -> Data? {
    let ns = data as NSData
    guard let z: NSData = try? ns.compressed(using: .zlib) else { return nil }
    let out = Data(referencing: z)
    return looksLikeZlib(out) ? out : zlibWrap(raw: out, adler: adler32(data))
}

/// RFC1950 头部校验：CM 必须为 8（deflate），且 (CMF<<8 | FLG) 能被 31 整除
private func looksLikeZlib(_ d: Data) -> Bool {
    guard d.count >= 6 else { return false }
    let cmf = Int(d[0])
    let flg = Int(d[1])
    return (cmf & 0x0F) == 8 && (cmf * 256 + flg) % 31 == 0
}

private func zlibWrap(raw: Data, adler: UInt32) -> Data {
    var out = Data([0x78, 0x9C])        // CM=8, CINFO=7, FLEVEL=2
    out.append(raw)
    out.append(UInt8((adler >> 24) & 0xFF))
    out.append(UInt8((adler >> 16) & 0xFF))
    out.append(UInt8((adler >> 8) & 0xFF))
    out.append(UInt8(adler & 0xFF))
    return out
}

/// Adler-32：自己算，不为 4 字节校验和去引一个依赖
public func adler32(_ data: Data) -> UInt32 {
    var a: UInt32 = 1
    var b: UInt32 = 0
    for byte in data {
        a = (a + UInt32(byte)) % 65521
        b = (b + a) % 65521
    }
    return (b << 16) | a
}

/// 按比例缩放（MRC 的背景层用：背景只要个"纸的感觉"，分辨率可以砍到 1/3）
public func resized(_ image: CGImage, scale: Double) -> CGImage? {
    let w = max(1, Int(Double(image.width) * scale))
    let h = max(1, Int(Double(image.height) * scale))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}

/// 局部均值（滑动窗口,O(w·h) 时间、O(w) 内存）。
/// 不用「积分图」是因为 300dpi 的 A4 有 870 万像素,积分图要 70MB 的 Int 数组,
/// 而滑动窗口只需要一行——同样的结果,内存差三个数量级。
public func boxMean(_ g: GrayBitmap, window: Int) -> [Double] {
    let w = g.width
    let h = g.height
    let r = max(1, window / 2)
    var colSum = [Int](repeating: 0, count: w)
    var colCnt = [Int](repeating: 0, count: w)
    var out = [Double](repeating: 255, count: w * h)

    func addRow(_ y: Int, _ sign: Int) {
        guard y >= 0, y < h else { return }
        let base = y * w
        for x in 0..<w { colSum[x] += sign * Int(g.pixels[base + x]); colCnt[x] += sign }
    }

    var top = 0
    var bottom = -1
    for y in 0..<h {
        let wantTop = max(0, y - r)
        let wantBottom = min(h - 1, y + r)
        while bottom < wantBottom { bottom += 1; addRow(bottom, +1) }
        while top < wantTop { addRow(top, -1); top += 1 }
        var sum = 0
        var cnt = 0
        for x in 0...min(r, w - 1) { sum += colSum[x]; cnt += colCnt[x] }
        for x in 0..<w {
            out[y * w + x] = cnt > 0 ? Double(sum) / Double(cnt) : 255
            let add = x + r + 1
            if add < w { sum += colSum[add]; cnt += colCnt[add] }
            let rem = x - r
            if rem >= 0 { sum -= colSum[rem]; cnt -= colCnt[rem] }
        }
    }
    return out
}

/// 打包成 1bit,**1 = 墨**（与 packOneBit 相反）。PDF 的蒙版层要的就是「1 处上色」。
public func packInk(_ g: GrayBitmap) -> Data {
    let rowBytes = (g.width + 7) / 8
    var out = [UInt8](repeating: 0, count: rowBytes * g.height)
    for y in 0..<g.height {
        let src = y * g.width
        let dst = y * rowBytes
        for x in 0..<g.width {
            if g.pixels[src + x] < 128 { out[dst + (x >> 3)] |= (0x80 >> (x & 7)) }
        }
    }
    return Data(out)
}

/// 生成小尺寸预览图（结果页的前后对比用）
public func makePreviewPNG(_ image: CGImage, maxWidth: Int = 560) -> Data? {
    let w = image.width
    let h = image.height
    guard w > 0, h > 0 else { return nil }
    let tw = min(maxWidth, w)
    let th = max(1, Int(Double(h) * Double(tw) / Double(w)))
    guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
    guard let small = ctx.makeImage() else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, small, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
}

// MARK: - 关于「翻转」这件事（血泪）

// 2026-09-11 之前，这里有一个 flipForImage(height:) 辅助，画 CGImage 之前先
// translate(0,h) + scale(1,-1)，并被 7 个调用点当作标准姿势使用。它一直是错的：
// CGBitmapContext 画 CGImage 时，图像首行（顶行）本来就落在缓冲区第一行，
// 再翻一次等于把整页垂直镜像。40 条自检全绿却没人发现，是因为没有一条断言检查过方向
// ——直到用示例扫描件跑对照图，用户看到的才是镜像的页面。
//
// 现在的规矩：
//   · draw(cgImage:in:) 之前不要动 CTM（要旋转就直接 rotate，别顺手翻）；
//   · drawPDFPage 同理，也不要翻；
//   · 方向由 lumo-cli flipscan 在真机上逐环节断言，靠肉眼和端到端推推断不靠谱。
