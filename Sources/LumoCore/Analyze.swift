// Lumo 原生核心 —— 页面体检（色彩 / 噪声 / 倾斜）
import Foundation
import CoreGraphics

public enum PageMode: String {
    case color
    case gray
    case mono
}

public enum Analyzer {
    /// 三通道差值 > 16 的像素占比低于 0.5%，就当作纯灰阶页（扫描仪常有轻微色偏）。
    /// 用「占比」而不是「最大值」：JPEG 的色度亚采样会在文字边缘留下一两个彩色噪点，
    /// 取最大值的话**一个像素**就能把整页判成彩色页，然后走 JPEG2000，压完反而更大。
    public static func isGrayOnly(_ image: CGImage) -> Bool {
        guard let rgb = rgbSamples(image, maxDim: 480) else { return false }
        var bad = 0
        var n = 0
        var i = 0
        while i + 2 < rgb.bytes.count {
            let r = Int(rgb.bytes[i])
            let g = Int(rgb.bytes[i + 1])
            let b = Int(rgb.bytes[i + 2])
            if max(abs(r - g), max(abs(g - b), abs(r - b))) > 16 { bad += 1 }
            n += 1
            i += 3
        }
        guard n > 0 else { return false }
        return Double(bad) / Double(n) < 0.005
    }

    /// 是否「可以安全丢掉灰度」。
    /// 判据是中间调占比：落在 60~195 之间（既不算黑也不算白）的像素要足够少。
    /// 文字页只有一圈抗锯齿边缘，这类像素通常只有 3%~6%；照片和渐变背景则是 30% 以上。
    /// 之前用「Otsu 阈值 ±25 的过渡带」来判，太窄了——重采样一下就超阈值，
    /// 干净的黑白扫描件被判成彩色页走 JPEG2000，压完反而比源文件还大。
    public static func isMonoLike(_ image: CGImage) -> Bool {
        guard let g = GrayBitmap.from(image, maxDim: 1200) else { return false }
        let (_, ink) = otsuThreshold(g)
        guard ink > 0.002, ink < 0.6 else { return false }
        var mid = 0
        for v in g.pixels where Int(v) > 60 && Int(v) < 195 { mid += 1 }
        return Double(mid) / Double(max(1, g.count)) < 0.12
    }

    public static func colorMode(of image: CGImage) -> PageMode {
        if hasColor(image) { return .color }
        return isMonoLike(image) ? .mono : .gray
    }

    /// 是否真的有「值得为它保留彩色编码」的颜色。
    ///
    /// 两个坑，都踩过：
    /// 1. 用「通道差 > 16」这种绝对差 → JPEG 的色度噪声在平坦白底上就能刷出一大片，
    ///    示例扫描件 1、2 页被判成彩色页走 JPEG2000，产物从 57KB 涨到 **1.5MB**。
    /// 2. 只看灰度（isMonoLike）→ 蓝色页眉 + 红色印章在灰度上和普通文字页没区别，
    ///    示例扫描件第 3 页整页被二值化，绿/蓝/红全变黑块。
    ///
    /// 所以按**饱和度**（(max−min)/max）而不是绝对差来判，并且要求成片出现：
    /// 彩色印章 / 图表饱和度高且成片（实测 6.2%），噪声又小又散（实测 0.18%），
    /// 中间隔了 30 倍，阈值取 0.6% 两边都够安全。
    /// 另外太暗的像素（文字笔画本身）不参与：黑点上的通道差没有意义。
    public static func hasColor(_ image: CGImage, minSat: Double = 0.22,
                                minArea: Double = 0.006) -> Bool {
        guard let rgb = rgbSamples(image, maxDim: 600) else { return false }
        var hit = 0
        var n = 0
        var i = 0
        while i + 2 < rgb.bytes.count {
            let r = Double(rgb.bytes[i])
            let g = Double(rgb.bytes[i + 1])
            let b = Double(rgb.bytes[i + 2])
            let mx = max(r, max(g, b))
            let mn = min(r, min(g, b))
            if mx > 60 {
                if (mx - mn) / mx > minSat { hit += 1 }
                n += 1
            }
            i += 3
        }
        guard n > 0 else { return false }
        return Double(hit) / Double(n) > minArea
    }

    /// 噪声 / 网纹强度（0~1）。看的是平坦区域的抖动，不是文字边缘的能量。
    public static func noiseLevel(_ image: CGImage) -> Double {
        guard let g = GrayBitmap.from(image, maxDim: 800) else { return 0 }
        return g.noiseScore()
    }

    /// 背景不匀程度（0~1）：切成 12×12 块，比较各块的"白电平"（块内最亮 20% 像素的均值）。
    /// 有阴影 / 泛黄 / 光照渐变的扫描件，白电平会在块间明显起伏；干净页面基本恒定。
    /// 用这个而不是"噪声"来决定要不要做背景去除——两者描述的根本不是一回事。
    public static func backgroundUnevenness(_ image: CGImage) -> Double {
        guard let g = GrayBitmap.from(image, maxDim: 900) else { return 0 }
        let w = g.width
        let h = g.height
        let grid = 12
        var levels: [Double] = []
        levels.reserveCapacity(grid * grid)
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
                    for x in x0..<x1 { hist[Int(g.pixels[base + x])] += 1; n += 1 }
                }
                guard n > 0 else { continue }
                var acc = 0
                var thr = 255
                let target = Int(Double(n) * 0.80)
                for v in 0..<256 {
                    acc += hist[v]
                    if acc >= target { thr = v; break }
                }
                var sum = 0
                var m = 0
                for v in thr..<256 { sum += v * hist[v]; m += hist[v] }
                levels.append(m > 0 ? Double(sum) / Double(m) : 255)
            }
        }
        guard levels.count >= 4 else { return 0 }
        let sorted = levels.sorted()
        let lo = sorted[Int(Double(sorted.count) * 0.1)]
        let hi = sorted[Int(Double(sorted.count) * 0.9)]
        guard hi > 1 else { return 0 }
        return max(0, min(1, (hi - lo) / hi))
    }
}
