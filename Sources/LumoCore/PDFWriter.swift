// Lumo 原生核心 —— PDF 写出
// 手写 PDF 而不是走 CGPDFContext：后者会把图像重新编码，我们精心选好的
// JPEG2000 / CCITT / Flate 流会被它换掉。自己写才能做到「编码什么就是什么」。
import Foundation
import CoreGraphics

public struct OutputPage: Sendable {
    public let image: EncodedImage
    public let dpi: Int
    public let lines: [OCRLine]?
    /// false = 不可见文字层（可搜索的图像）；true = 可见文字（可编辑的文本和图像）
    public let visibleText: Bool
    /// 分层压缩（MRC）：非 nil 时，image 只是低分辨率背景，文字由蒙版层画上去
    public let mrc: Compressor.MRCPage?

    public init(image: EncodedImage, dpi: Int, lines: [OCRLine]?, visibleText: Bool = false,
                mrc: Compressor.MRCPage? = nil) {
        self.image = image
        self.dpi = dpi
        self.lines = lines
        self.visibleText = visibleText
        self.mrc = mrc
    }
}

public enum PDFWriterError: LocalizedError {
    /// 已经 finish 过的写入器不允许再追加页面
    case alreadyFinished
    /// 输出文件建不出来（权限 / 路径不存在）
    case cannotOpenOutput(URL)
    /// 追加的页数超过了构造时声明的 pageCount——
    /// 编号布局是提前定死的，多出来的页没有位置可放，只能明确报错，
    /// 不能默默写出去（那会得到一份 xref 对不上的文件）
    case tooManyPages(declared: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .alreadyFinished:
            return T("PDF 已经写完，不能再追加页面")
        case .cannotOpenOutput(let u):
            return T("无法写入输出文件：%@", u.lastPathComponent)
        case .tooManyPages(let d, let a):
            return T("写入的页数超出预期（声明 %@ 页，实际写了 %@ 页）", d, a)
        }
    }
}

public enum PDFWriter {
    /// 写进 PDF /Producer 的标识。
    ///
    /// 为什么要绕一圈读 Bundle 而不是写死字符串：版本号曾经散在三处
    /// （这里是 "0.3.0"、Info.plist 是 "0.1.0"、README 又是别的），
    /// 结果打包出来的 DMG 里显示的永远是 plist 那个 0.1.0——
    /// 用户报 bug 时报的版本号跟我们对不上，白折腾。
    /// 现在 Resources/VERSION 是唯一来源，build.sh 注入 Info.plist，
    /// 这里运行时再读回来，两边天然一致。
    /// 读不到（比如 lumo-cli 直接跑、没有 .app 外壳）就用 fallbackVersion 兜底。
    public static var producer: String {
        "Lumo \(version)"
    }

    /// 当前版本号。优先取主 bundle 的 CFBundleShortVersionString。
    public static var version: String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !v.isEmpty, v != "0.0.0" {
            return v
        }
        return fallbackVersion
    }

    /// 兜底版本号：与 Resources/VERSION 保持一致，改动时两边一起改。
    ///
    /// ⚠️ 这里之所以要"两边一起改"，是因为 **CLI 拿不到 bundle 的 Info.plist**：
    /// `Bundle.main` 对可执行文件来说是它所在的目录，没有 `CFBundleShortVersionString`，
    /// 于是 `lumo-cli version` 永远走这条兜底分支。它在 `.app` 里才走 plist。
    /// 换句话说：漏改这里，DMG 里显示 0.3.4、命令行却报 0.3.3 —— 两者都对不上。
    /// CI 里有一条断言盯着这两个数字（见 `.github/workflows/ci.yml` 的「校验版本号一致」）。
    public static let fallbackVersion = "0.0.2"

    /// 一次性写入（保留原接口，供 CLI 与自检使用）。
    ///
    /// 内部委托给流式写入器。之所以留着这个入口：调用方手里已经攒好
    /// 整页数组时（自检造的小图、单页预览），一次写完比流式简单直白。
    public static func write(pages: [OutputPage], to url: URL, title: String) throws -> Int {
        let sw = try StreamingWriter(url: url, title: title, pageCount: pages.count)
        for p in pages { try sw.append(p) }
        try sw.finish()
        return sw.bytesWritten
    }

    // MARK: - 流式写入
    //
    // 为什么需要它：原来 process 会把每一页编码完的 OutputPage 都攒在数组里，
    // 直到最后一页处理完才整体写盘。编码后的数据其实不大（一页几十到几百 KB），
    // 真正的内存大户是**渲染出来的 300dpi 位图**——A4 彩色一页约 33MB。
    // 虽然 OutputPage 不持有位图，但循环里 PDFReader.render / Enhance.apply
    // 产生的 CoreGraphics 对象受 autorelease 管理，不设池就迟迟不回收；
    // 再加上"全部页攒到最后"这个结构，几 MB 的源文件、几十页，
    // 内存轻松到几个 GB——这正是用户反馈的第 4 条。
    //
    // 流式之后：处理完一页立刻写进输出文件并释放该页数据，
    // 峰值只跟"正在处理的那一两页"有关，与总页数无关。
    //
    // 有个约束必须提前解决：PDF 的对象编号布局原本靠扫描整个数组得出
    // （有没有文字层决定字体段占不占位、有没有 MRC 决定每页占 3 还是 4 个号），
    // 而 /Pages 的 /Kids 必须在写第一页之前就写出。流式不能回头扫，
    // 所以这里**从一开始就按最宽的布局留位**：字体段恒占 8 号、每页恒占 4 号，
    // 用不到的槽位写空对象。代价是文件里多几个几十字节的空对象，
    // 换来的是内存与页数彻底解耦——这个交换对一个要处理大文件的工具很划算。
    public final class StreamingWriter {
        private let b: Builder
        private let url: URL
        private let pageCount: Int
        private let fontBase = 8      // 固定：4~7 留给字体
        private let slots = 4         // 固定：页面/内容/图像/蒙版 各一号
        private var pageIndex = 0
        private var finished = false
        private var usedUnits = Set<Int>()

        public private(set) var bytesWritten = 0
        /// 页对象的最后一个编号；ToUnicode CMap 排在它之后，编号 = total
        private var lastPageObject: Int { fontBase + max(0, pageCount - 1) * slots + 3 }

        public init(url: URL, title: String, pageCount: Int) throws {
            self.url = url
            self.pageCount = pageCount
            self.b = Builder(objectCount: pageCount * 4 + 8)

            b.append("%PDF-1.7\n")
            b.append(Data([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]))

            b.begin(1)
            b.append("<< /Type /Catalog /Pages 2 0 R >>\n")
            b.end()

            // /Kids 必须现在就能列全，这就是布局必须提前固定的根本原因
            b.begin(2)
            let kids = (0..<pageCount).map { "\(fontBase + $0 * slots) 0 R" }.joined(separator: " ")
            b.append("<< /Type /Pages /Kids [\(kids)] /Count \(pageCount) >>\n")
            b.end()

            b.begin(3)
            b.append("<< /Producer (\(pdfEscape(producer))) /Title (\(pdfEscape(title))) "
                + "/CreationDate (\(pdfDate())) >>\n")
            b.end()

            // 4~6 字体描述：无论有没有文字层都写。
            // 留着空字体的代价是几十字节，省掉的却是"处理到一半才发现后面某页
            // 有文字层、而编号已经定死"这个死结。
            b.begin(4)
            b.append("<< /Type /Font /Subtype /Type0 /BaseFont /LumoOCR /Encoding /Identity-H "
                + "/DescendantFonts [5 0 R] /ToUnicode \(lastPageObject + 1) 0 R >>\n")
            b.end()
            b.begin(5)
            b.append("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /LumoOCR "
                + "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> "
                + "/FontDescriptor 6 0 R /CIDToGIDMap /Identity /DW 1000 >>\n")
            b.end()
            b.begin(6)
            b.append("<< /Type /FontDescriptor /FontName /LumoOCR /Flags 4 "
                + "/FontBBox [0 -250 1000 900] /ItalicAngle 0 /Ascent 800 /Descent -250 "
                + "/CapHeight 700 /StemV 80 >>\n")
            b.end()

            // 7 号占位：它的位置在 4~6 之后、页对象之前，而 ToUnicode 的实际内容
            // 要等全部页处理完才知道。这里留一个空对象把号占住，
            // 真正的内容放到所有页之后（编号 lastPageObject + 1）。
            // 4 号对象已经指向那边，所以这个 7 号就是个没用的占位——
            // 保留它只为让 4~7 这段编号连续、便于日后对照旧的布局。
            b.begin(7)
            b.append("<< /Length 0 >>\nstream\n\nendstream\n")
            b.end()
        }

        /// 追加一页。处理完一页调一次；返回后这一页的数据就可以被回收了。
        public func append(_ p: OutputPage) throws {
            guard !finished else { throw PDFWriterError.alreadyFinished }
            guard pageIndex < pageCount else {
                throw PDFWriterError.tooManyPages(declared: pageCount, actual: pageIndex + 1)
            }
            let i = pageIndex
            pageIndex += 1

            let pageNo = fontBase + i * slots
            let contentsNo = pageNo + 1
            let imageNo = pageNo + 2
            let maskNo = pageNo + 3
            let pxW = p.mrc?.mask.width ?? p.image.width
            let pxH = p.mrc?.mask.height ?? p.image.height
            let pageW = Double(pxW) * 72.0 / Double(p.dpi)
            let pageH = Double(pxH) * 72.0 / Double(p.dpi)

            for l in p.lines ?? [] { for u in l.text.utf16 { usedUnits.insert(Int(u)) } }

            b.begin(pageNo)
            var res = "/XObject << /Im0 \(imageNo) 0 R"
            if p.mrc != nil { res += " /Im1 \(maskNo) 0 R" }
            res += " >>"
            res += " /Font << /F1 4 0 R >>"
            b.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(f(pageW)) \(f(pageH))] "
                + "/Resources << \(res) >> /Contents \(contentsNo) 0 R >>\n")
            b.end()

            let content = Data(contentStream(for: p, pageW: pageW, pageH: pageH).utf8)
            b.begin(contentsNo)
            b.append("<< /Length \(content.count) >>\nstream\n")
            b.append(content)
            b.append("\nendstream\n")
            b.end()

            b.begin(imageNo)
            var dict = "<< /Type /XObject /Subtype /Image /Width \(p.image.width) "
                + "/Height \(p.image.height) "
                + "/BitsPerComponent \(p.image.bitsPerComponent) /Filter \(p.image.filter) "
            if p.image.filter != "/JPXDecode" { dict += "/ColorSpace \(p.image.colorSpace) " }
            if let dp = p.image.decodeParms { dict += "/DecodeParms \(dp) " }
            dict += "/Length \(p.image.data.count) >>\n"
            b.append(dict)
            b.append("stream\n")
            b.append(p.image.data)
            b.append("\nendstream\n")
            b.end()

            if let m = p.mrc?.mask {
                b.begin(maskNo)
                var mdict = "<< /Type /XObject /Subtype /Image /Width \(m.width) /Height \(m.height) "
                    + "/ImageMask true /Decode \(m.decode) /BitsPerComponent 1 "
                    + "/Filter \(m.filter) "
                if let mdp = m.decodeParms { mdict += "/DecodeParms \(mdp) " }
                mdict += "/Length \(m.data.count) >>\n"
                b.append(mdict)
                b.append("stream\n")
                b.append(m.data)
                b.append("\nendstream\n")
                b.end()
            } else {
                // 空占位：slots 固定 4，没用上的蒙版号也必须指向真实对象，
                // 否则部分阅读器会判定"文件损坏"。这是原有代码就有的做法。
                b.begin(maskNo)
                b.append("<< /Length 0 >>\nstream\n\nendstream\n")
                b.end()
            }

            // 每页写完就倾倒一次。这是"内存与页数解耦"真正生效的地方。
            try flushToDisk()
        }

        /// 收尾：写 ToUnicode CMap、xref、trailer，然后关闭文件。
        public func finish() throws {
            guard !finished else { return }
            finished = true

            let cmapNo = lastPageObject + 1
            let cmap = Data(toUnicodeCMap(units: usedUnits).utf8)
            b.begin(cmapNo)
            b.append("<< /Length \(cmap.count) >>\nstream\n")
            b.append(cmap)
            b.append("\nendstream\n")
            b.end()

            let xrefPos = b.absoluteCount
            let total = cmapNo
            b.append("xref\n0 \(total + 1)\n")
            b.append("0000000000 65535 f \n")
            for i in 0..<total {
                b.append(padded10(b.offsets[i]) + " 00000 n \n")
            }
            b.append("trailer\n<< /Size \(total + 1) /Root 1 0 R /Info 3 0 R >>\n")
            b.append("startxref\n\(xrefPos)\n%%EOF\n")

            try flushToDisk(final: true)
        }

        // MARK: 落盘

        private var handle: FileHandle?
        private var fileOffset = 0

        /// 把 Builder 里已写出的内容追加到文件。
        ///
        /// 关键细节：**Builder 里的 offsets 记的是"相对于已落盘内容的偏移"吗？**
        /// 不是。所以每倾倒一次，就要把这次倾倒的字节数累加到"已落盘前缀长度"上，
        /// 并由 Builder 在下一次 begin() 时把真实文件偏移补进来——
        /// 见 Builder.setBaseOffset 的说明。漏掉这一步的后果是 xref 指向错误的
        /// 位置，文件照样能生成、体积也正常，但在阅读器里打不开，
        /// 而且从体积上完全看不出来。
        private func flushToDisk(final: Bool = false) throws {
            if handle == nil {
                FileManager.default.createFile(atPath: url.path, contents: nil)
                guard let h = FileHandle(forWritingAtPath: url.path) else {
                    throw PDFWriterError.cannotOpenOutput(url)
                }
                handle = h
            }
            let chunk = b.takeOut()
            if !chunk.isEmpty {
                handle?.write(chunk)
                fileOffset += chunk.count
            }
            b.setBaseOffset(fileOffset)
            if final {
                try handle?.close()
                handle = nil
                bytesWritten = fileOffset
            }
        }
    }

    // MARK: - 内容流

    private static func contentStream(for p: OutputPage, pageW: Double, pageH: Double) -> String {
        // 先铺背景（低分辨率、整页尺寸），再用蒙版把文字"印"上去
        var s = "q\n\(f(pageW)) 0 0 \(f(pageH)) 0 0 cm\n/Im0 Do\nQ\n"
        if let m = p.mrc {
            s += "q\n\(f(m.inkR)) \(f(m.inkG)) \(f(m.inkB)) rg\n"
            s += "\(f(pageW)) 0 0 \(f(pageH)) 0 0 cm\n/Im1 Do\nQ\n"
        }
        guard let lines = p.lines, !lines.isEmpty else { return s }
        s += "BT\n/F1 1 Tf\n\(p.visibleText ? "0 Tr 0 g" : "3 Tr")\n"
        for l in lines {
            let t = l.text
            let n = max(1, t.utf16.count)
            let boxW = Double(l.rect.width) * pageW
            let boxH = Double(l.rect.height) * pageH
            let x = Double(l.rect.origin.x) * pageW
            let y = Double(l.rect.origin.y) * pageH
            let sx = boxW / Double(n)
            let sy = boxH * 0.85
            s += "\(f(sx)) 0 0 \(f(sy)) \(f(x)) \(f(y)) Tm\n<\(hexUTF16BE(t))> Tj\n"
        }
        s += "ET\n"
        return s
    }

    private static func hexUTF16BE(_ s: String) -> String {
        var out = ""
        for u in s.utf16 {
            let v = UInt32(u)
            out += String(format: "%04X", v)
        }
        return out
    }

    /// 逐字映射的 ToUnicode CMap：没有它，复制出来的中文会变成一串乱码
    private static func toUnicodeCMap(for pages: [OutputPage]) -> String {
        var units = Set<Int>()
        for p in pages {
            for l in p.lines ?? [] {
                for u in l.text.utf16 { units.insert(Int(u)) }
            }
        }
        return toUnicodeCMap(units: units)
    }

    /// 同上，但直接吃一个字符集合——流式写入器在处理过程中逐页累积，
    /// 到收尾时手上只有这个集合，没有完整的页面数组。
    private static func toUnicodeCMap(units: Set<Int>) -> String {
        let sorted = units.sorted()
        var ranges: [(Int, Int)] = []
        for u in sorted {
            if let last = ranges.last, last.1 + 1 == u {
                ranges[ranges.count - 1] = (last.0, u)
            } else {
                ranges.append((u, u))
            }
        }
        var s = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
        s += "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n"
        s += "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n"
        s += "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
        s += "\(max(1, ranges.count)) beginbfrange\n"
        if ranges.isEmpty {
            s += "<0020> <0020> <0020>\n"
        } else {
            for r in ranges {
                s += String(format: "<%04X> <%04X> <%04X>\n", UInt32(r.0), UInt32(r.1), UInt32(r.0))
            }
        }
        s += "endbfrange\nendcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
        return s
    }

    // MARK: - 小工具

    private static func f(_ v: Double) -> String { String(format: "%.3f", v) }

    /// xref 条目必须恰好 20 字节。手写补零而不用 %010d，免得踩 Int 宽度的坑。
    private static func padded10(_ v: Int) -> String {
        let s = String(v)
        return s.count >= 10 ? String(s.suffix(10))
                             : String(repeating: "0", count: 10 - s.count) + s
    }

    /// 把任意字符串安全地放进 PDF 的 ( ) 字面量里。
    ///
    /// 第一版只转义了 \ 和圆括号，漏掉控制字符——这是个真会写出坏文件的 bug：
    /// 文档标题来自文件名，而文件名里带换行/制表符完全可能（尤其从剪贴板粘来的），
    /// 一个裸 \n 就会让 /Info 字典提前折行，阅读器解析到一半直接放弃整个字典。
    /// PDF 规范里字面量字符串允许的转义：\n \r \t \b \f \( \) \\ 以及 \ddd 八进制。
    /// 这里统一用八进制（\012 这种），因为它是唯一能覆盖**所有**字节的形式，
    /// 其余几个是它的特例——少一套分支就少一处写错的机会。
    private static func pdfEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "(":  out += "\\("
            case ")":  out += "\\)"
            default:
                // 0x20~0x7E 是可打印 ASCII，直接放；其余（含中文等多字节字符）一律
                // 编码成 UTF-8 字节后走八进制。PDF 的字符串本质是一串字节——
                // 直接塞原始 UTF-8 多数阅读器也能猜对，但显式转义才是规范做法，
                // 而且顺带把控制字符（\n \r \t 等）一起收进同一个分支，
                // 不用为它们单开特例。
                if scalar.value >= 0x20 && scalar.value <= 0x7E {
                    out.unicodeScalars.append(scalar)
                } else {
                    for byte in String(scalar).data(using: .utf8) ?? Data() {
                        out += String(format: "\\%03o", byte)
                    }
                }
            }
        }
        return out
    }

    private static func pdfDate() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMddHHmmss"
        return "D:" + df.string(from: Date())
    }

    private final class Builder {
        var out = Data()
        var offsets: [Int]
        init(objectCount: Int) { offsets = [Int](repeating: 0, count: objectCount) }
        var count: Int { out.count }

        /// 当前缓冲在**文件中的绝对位置**。
        ///
        /// 不能用 count：流式写入会多次把 out 倾倒到磁盘并清空它，
        /// 于是 count 只剩"当前这一段缓冲"的长度。想在文件里定位，
        /// 必须加上已经落盘的前缀长度。startxref 用错这个值，
        /// 阅读器就找不到 xref 表——文件生成得出来、体积也正常，但打不开。
        var absoluteCount: Int { baseOffset + out.count }

        /// 已经落盘的前缀长度。
        ///
        /// 流式写入会分多次把 out 倾倒到文件，倾倒后 out 被清空，
        /// 于是这里记的偏移就只是"相对当前缓冲"的——而 xref 要的是
        /// **文件里的绝对偏移**。baseOffset 就是那个落差，begin() 时补上。
        /// 忘了补的后果是 xref 全部指错，文件看着正常却打不开。
        private var baseOffset = 0
        func setBaseOffset(_ v: Int) { baseOffset = v }

        func begin(_ n: Int) {
            offsets[n - 1] = baseOffset + out.count
            append("\(n) 0 obj\n")
        }
        func end() { append("endobj\n") }
        func append(_ s: String) { out.append(Data(s.utf8)) }
        func append(_ d: Data) { out.append(d) }

        /// 取出并清空当前缓冲，供写入器倾倒到磁盘。
        func takeOut() -> Data {
            let d = out
            out = Data()
            return d
        }
    }
}
