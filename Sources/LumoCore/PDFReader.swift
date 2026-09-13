// Lumo 原生核心 —— PDF 读取
// 只用 CoreGraphics + Foundation：CGPDFDocument 渲染，文本层靠展开内容流探测。
import Foundation
import CoreGraphics

public enum PDFReader {
    public static func open(_ url: URL) -> CGPDFDocument? {
        CGPDFDocument(url as CFURL)
    }

    public static func pageCount(_ doc: CGPDFDocument) -> Int { doc.numberOfPages }

    /// 读回 /Info 字典里的 /Title。
    ///
    /// 为什么需要它：验证 PDF 字符串转义时，"文件里没有裸控制字符"这种
    /// 字节层面的间接判据很容易误伤——PDF 头部紧跟着就是二进制图像流，
    /// 流里出现任意字节都是合法的，扫描范围稍微放宽就会把正常数据判成缺陷。
    /// 直接把标题读回来比对，才是"转义正确"的直接证据：写进去什么，
    /// 解开就得是什么。
    ///
    /// 返回 UTF-8 解码后的字符串；PDF 里的 ( ) 字面量存的是字节，
    /// 中文会以八进制形式落盘，这里按 UTF-8 拼回来。
    public static func infoTitle(_ doc: CGPDFDocument) -> String? {
        guard let info = doc.info else { return nil }
        var s: CGPDFStringRef?
        // 注意：CGPDFDictionaryGetString 的第二个参数是 UnsafeMutablePointer<CGPDFStringRef?>，
        // 拿到的是 CFString 风格的引用，要用 CGPDFStringGetBytePtr/Length 取原始字节，
        // 不能直接当 C 字符串用（PDF 的 ( ) 字面量里存的是字节，不保证有结尾 0）。
        guard CGPDFDictionaryGetString(info, "Title", &s), let str = s else { return nil }
        // 注意函数名：CoreGraphics 这套是 CGPDFStringGetLength / CGPDFStringGetBytePtr，
        // 带 Get。写成 CGPDFStringLength 是跟 CFStringGetLength 记混了，编译期就报错。
        let len = Int(CGPDFStringGetLength(str))
        guard len > 0, let bytes = CGPDFStringGetBytePtr(str) else { return "" }
        return String(data: Data(bytes: bytes, count: len), encoding: .utf8)
    }

    /// 页面尺寸（点，1pt = 1/72 inch）
    public static func mediaBox(_ doc: CGPDFDocument, _ index: Int) -> CGRect {
        guard let p = doc.page(at: index + 1) else {
            return CGRect(x: 0, y: 0, width: 595, height: 842)
        }
        return p.getBoxRect(.mediaBox)
    }

    /// 把第 index 页（0-based）光栅化。
    /// 注意：PDF 用户空间与 CGBitmapContext 同为 y 轴朝上，这里**不能**像 draw(cgImage:) 那样翻转，
    /// 翻了反而上下颠倒。
    public static func render(_ doc: CGPDFDocument, _ index: Int, dpi: Int, gray: Bool = false) -> CGImage? {
        guard let page = doc.page(at: index + 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let scale = CGFloat(dpi) / 72.0
        var w = max(1, Int(round(box.width * scale)))
        var h = max(1, Int(round(box.height * scale)))
        // /Rotate 90/270 的页面，drawPDFPage 会在框内转 90°，画布得跟着换方向
        let rot = ((page.rotationAngle % 360) + 360) % 360
        if rot == 90 || rot == 270 { swap(&w, &h) }
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let info: UInt32 = gray ? CGImageAlphaInfo.none.rawValue
                                : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
        if gray {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        } else {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        }
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
        ctx.interpolationQuality = .high
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    // MARK: - 页码选择

    /// "all" | "3" | "1,3,5" | "2-6,9" | "7-"（1-based）
    public static func parsePageSelection(_ total: Int, _ sel: String) -> [Int] {
        let txt = sel.trimmingCharacters(in: .whitespacesAndNewlines)
        if txt.isEmpty || txt == "all" { return Array(0..<total) }
        var out: [Int] = []
        for part in txt.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { continue }
            if let dash = p.firstIndex(of: "-") {
                let a = Int(p[p.startIndex..<dash]) ?? 1
                let after = p.index(after: dash)
                let bStr = String(p[after...])
                let b = bStr.isEmpty ? total : (Int(bStr) ?? total)
                out.append(contentsOf: (a - 1)...(b - 1))
            } else if let n = Int(p) {
                out.append(n - 1)
            }
        }
        return Array(Set(out.filter { $0 >= 0 && $0 < total })).sorted()
    }

    // MARK: - 文字层探测（决定要不要跳过 OCR）

    /// 估算 PDF 里已有文字的字符数。
    /// 手法：把能解开的流都解一遍，只统计**真正的内容流**里的文字。
    public static func existingTextChars(_ url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        var total = 0
        var budgetBytes = 96 * 1024 * 1024
        var streams = 0
        for raw in eachStream(data) {
            streams += 1
            if streams > 400 { break }
            budgetBytes -= raw.count
            if budgetBytes < 0 { break }
            guard let plain = decoded(raw) else { continue }
            guard looksLikeContentStream(plain) else { continue }
            guard let s = String(data: plain, encoding: .isoLatin1) else { continue }
            total += countTextChars(s)
        }
        return total
    }

    /// 内容流是纯文本；图像流解出来是像素，可打印字符比例必然很低。
    /// 少了这道过滤就要出事：JPEG 的像素数据里随手就能撞出 "BT" 和 "Tf" 两个字节，
    /// 于是纯图像的扫描件被判成「已有文字层」，OCR 被整步跳过——CI 里真的发生过。
    private static func looksLikeContentStream(_ plain: Data) -> Bool {
        guard !plain.isEmpty else { return false }
        var printable = 0
        for b in plain where b == 0x09 || b == 0x0A || b == 0x0D || (b >= 0x20 && b < 0x7F) {
            printable += 1
        }
        guard Double(printable) / Double(plain.count) > 0.95 else { return false }
        guard let s = String(data: plain, encoding: .isoLatin1) else { return false }
        return hasToken(s, "BT") && hasToken(s, "Tf") && (hasToken(s, "Tj") || hasToken(s, "TJ"))
    }

    /// PDF 的分隔符。用来确认匹配到的是一个完整的算子而不是别的词里的一段。
    private static let tokenDelims: Set<Character> =
        [" ", "\t", "\n", "\r", "\u{0C}", "<", ">", "(", ")", "[", "]", "{", "}", "/", "%"]

    private static func hasToken(_ s: String, _ token: String) -> Bool {
        var search = s.startIndex..<s.endIndex
        while let r = s.range(of: token, options: [], range: search) {
            let before = r.lowerBound == s.startIndex ? " " : s[s.index(before: r.lowerBound)]
            let after = r.upperBound == s.endIndex ? " " : s[r.upperBound]
            if tokenDelims.contains(before), tokenDelims.contains(after) { return true }
            if r.upperBound >= s.endIndex { break }
            search = r.upperBound..<s.endIndex
        }
        return false
    }

    /// 统计内容流里的文字字符数。
    /// 括号字面量 (...) 按字符算；十六进制串 <...> Tj 按字节对数算——
    /// Lumo 自己的产物就是后者，漏掉它会导致「刚处理完的 PDF 再打开一次又被判成没有文字层」。
    private static func countTextChars(_ s: String) -> Int {
        let u = Array(s.unicodeScalars)
        var count = 0
        var i = 0
        while i < u.count {
            let c = u[i]
            if c == "(" {
                i += 1
                var depth = 1
                while i < u.count {
                    let d = u[i]
                    if d == "\\" { i += 2; count += 1; continue }
                    if d == "(" { depth += 1 } else if d == ")" {
                        depth -= 1
                        if depth == 0 { i += 1; break }
                    } else {
                        count += 1
                    }
                    i += 1
                }
                continue
            }
            if c == "<" {
                var j = i + 1
                var hex = 0
                while j < u.count, isHexDigit(u[j]) { hex += 1; j += 1 }
                if hex > 1, j < u.count, u[j] == ">" {
                    var k = j + 1
                    while k < u.count, u[k] == " " || u[k] == "\n" || u[k] == "\r" || u[k] == "\t" {
                        k += 1
                    }
                    if k + 1 < u.count, u[k] == "T" {
                        if u[k + 1] == "j" || u[k + 1] == "J" { count += hex / 2 }
                    }
                    i = j + 1
                    continue
                }
            }
            i += 1
        }
        return count
    }

    private static func isHexDigit(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        return (v >= 48 && v <= 57) || (v >= 97 && v <= 102) || (v >= 65 && v <= 70)
    }

    private static func eachStream(_ data: Data) -> [Data] {
        // 用 Data.range(of:)（底层 memmem）而不是逐字节建数组比较：
        // 后者在 50MB 的扫描件上会产生几千万次临时数组分配
        let needle = Data("stream".utf8)
        let endNeedle = Data("endstream".utf8)
        var out: [Data] = []
        var search = data.startIndex..<data.endIndex
        while out.count < 400,
              let r = data.range(of: needle, options: [], in: search) {
            var s = r.upperBound
            if s < data.endIndex, data[s] == 0x0D { s = data.index(after: s) }
            if s < data.endIndex, data[s] == 0x0A { s = data.index(after: s) }
            guard let e = data.range(of: endNeedle, options: [], in: s..<data.endIndex) else { break }
            if s < e.lowerBound { out.append(data[s..<e.lowerBound]) }
            search = e.upperBound..<data.endIndex
        }
        return out
    }

    private static func decoded(_ raw: Data) -> Data? {
        let ns = raw as NSData
        if let z: NSData = try? ns.decompressed(using: .zlib) { return Data(referencing: z) }
        return raw
    }

    // MARK: - 分辨率探测

    /// 从内嵌图像的 /Width 反推 DPI。找不到就按 300 处理——这个值只用于展示与
    /// 选择处理分辨率（最终会被夹到 200~300），猜错也不会把结果做坏。
    ///
    /// 直接扫 /Width 而不是把整份文件转成 String 再上正则：
    /// 50MB 的 PDF 转 String 会瞬时吃掉几百 MB 内存，只为猜一个 DPI 不值得。
    public static func estimateDPI(_ url: URL, pageWidthPt: CGFloat) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 300 }
        let needle = Data("/Width".utf8)
        var best = 0
        var search = data.startIndex..<data.endIndex
        var hits = 0
        while hits < 200, let r = data.range(of: needle, options: [], in: search) {
            hits += 1
            search = r.upperBound..<data.endIndex
            var i = r.upperBound
            while i < data.endIndex, data[i] == 0x20 || data[i] == 0x0A || data[i] == 0x0D {
                i = data.index(after: i)
            }
            var digits = 0
            var value = 0
            while i < data.endIndex, data[i] >= 0x30, data[i] <= 0x39, digits < 8 {
                value = value * 10 + Int(data[i] - 0x30)
                digits += 1
                i = data.index(after: i)
            }
            if digits > 0, value > best, value < 40000 { best = value }
        }
        if best == 0 { return 300 }
        let inches = Double(pageWidthPt) / 72.0
        guard inches > 0.1 else { return 300 }
        return Int(min(1200, max(72, round(Double(best) / inches))))
    }
}
