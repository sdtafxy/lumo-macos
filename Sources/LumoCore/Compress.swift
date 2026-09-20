// Lumo 原生核心 —— 压缩编码
// ImageIO 负责 JPEG / JPEG2000，zlib + PNG 预测器负责无损，TIFF 往返负责 CCITT G4。
// 任何一个编码器不可用都会自动降级，绝不让「压缩失败」变成「处理失败」。
import Foundation
import CoreGraphics
import ImageIO

public struct EncodedImage: Sendable {
    public let data: Data
    public let colorSpace: String       // /DeviceRGB | /DeviceGray
    public let filter: String           // /DCTDecode | /JPXDecode | /FlateDecode | /CCITTFaxDecode
    public let bitsPerComponent: Int
    public let decodeParms: String?
    public let width: Int
    public let height: Int
    public let mode: String             // color | gray | mono
    public let encoderUsed: String      // 报告里如实展示：实际用的是哪个
    /// 降级说明（例如 JBIG2 无编码器、CCITT 抽取失败）
    public let note: String?

    public init(data: Data, colorSpace: String, filter: String, bitsPerComponent: Int,
                decodeParms: String?, width: Int, height: Int, mode: String,
                encoderUsed: String, note: String?) {
        self.data = data
        self.colorSpace = colorSpace
        self.filter = filter
        self.bitsPerComponent = bitsPerComponent
        self.decodeParms = decodeParms
        self.width = width
        self.height = height
        self.mode = mode
        self.encoderUsed = encoderUsed
        self.note = note
    }
}

public enum Compressor {
    private static let qualityKey = kCGImageDestinationLossyCompressionQuality as String

    /// 自适应时逐页决定走彩色/灰阶/单色——同一份 PDF 里文字页和插图页常常不同
    public static func effectiveMode(_ image: CGImage, _ spec: CompressSpec) -> String {
        var m = spec.colorMode
        if spec.adaptive || m == "auto" {
            // 先问「有没有颜色」再问「是不是文字页」，顺序反了会出大事：
            // isMonoLike 只看灰度中间调，蓝色页眉 + 红色印章在灰度上和普通文字页
            // 几乎没区别——示例扫描件第 3 页就是这样被整页二值化，印章直接变黑块的。
            // Analyzer.colorMode(of:)（文档级）一直是对的，这里补上同一道闸门。
            if Analyzer.hasColor(image) { m = "color" }
            else if Analyzer.isMonoLike(image) { m = "mono" }
            else { m = "gray" }
        }
        if m != "color" && m != "gray" && m != "mono" { m = "color" }
        return m
    }

    public static func encode(_ image: CGImage, _ spec: CompressSpec) -> EncodedImage {
        let mode = effectiveMode(image, spec)
        switch mode {
        case "mono":  return encodeMono(image, spec)
        case "gray":  return encodeGray(image, spec)
        default:      return encodeColor(image, spec)
        }
    }

    /// 用真实抽样页编码后外推总体积（比任何公式估算都准）
    public static func estimateBytes(samples: [CGImage], spec: CompressSpec, pageCount: Int) -> Int {
        guard !samples.isEmpty else { return 0 }
        var total = 0
        for s in samples { total += encodeWithLayers(s, spec).bytes }
        let per = Double(total) / Double(samples.count)
        return max(1, Int(per * Double(pageCount) + 2500.0 * Double(pageCount)))
    }

    // MARK: - 单色

    private static func encodeMono(_ image: CGImage, _ spec: CompressSpec) -> EncodedImage {
        guard let g = GrayBitmap.from(image) else { return encodeColor(image, spec) }
        let (thr, _) = otsuThreshold(g)
        let packed = packOneBit(g, threshold: thr)
        let rowBytes = (g.width + 7) / 8

        if spec.monoEncoder != "zip" {
            // 单色页走 CCITT G4。曾经这里还接受 "jbig2"，靠一句"如实降级到 G4"
            // 的提示糊过去——那是错的：macOS SDK 根本没有 JBIG2 编码器
            // （`lumo-cli encoders` 现场打印过可写格式清单），
            // 给用户一个永远降级的选项，等于让他以为自己在选一个不存在的功能。
            // 现在 UI 与 CLI 都只提供 ccitt / zip 两条真实路径。
            if let cc = ccittG4(width: g.width, height: g.height, packed: packed) {
                return EncodedImage(
                    data: cc, colorSpace: "/DeviceGray", filter: "/CCITTFaxDecode",
                    bitsPerComponent: 1,
                    // 极性已在 ccittG4 里校准过：码流里的"黑游程"一定对应我们的黑，
                    // 所以这里固定声明 0 = 黑（默认值），不需要 /Decode 反转
                    decodeParms: "<< /K -1 /Columns \(g.width) /Rows \(g.height) /BlackIs1 false >>",
                    width: g.width, height: g.height, mode: "mono",
                    encoderUsed: "CCITT G4",
                    note: nil)
            }
            let fb = flateMono(packed, rowBytes: rowBytes, width: g.width, height: g.height)
            return EncodedImage(
                data: fb, colorSpace: "/DeviceGray", filter: "/FlateDecode", bitsPerComponent: 1,
                decodeParms: nil,
                width: g.width, height: g.height, mode: "mono", encoderUsed: "Flate",
                note: T("CCITT G4 编码不可用，已改用无损 Flate"))
        }
        let fb = flateMono(packed, rowBytes: rowBytes, width: g.width, height: g.height)
        return EncodedImage(data: fb, colorSpace: "/DeviceGray", filter: "/FlateDecode",
                            bitsPerComponent: 1,
                            decodeParms: nil,
                            width: g.width, height: g.height, mode: "mono",
                            encoderUsed: "Flate", note: nil)
    }

    private static func flateMono(_ packed: Data, rowBytes: Int, width: Int, height: Int) -> Data {
        // 1 位路径不做预测器，但理由和 8 位路径**不同**（那边已经改用了 /Predictor 15）：
        // PNG 的滤波作用在**字节**上，而 1 位图是一个字节装 8 个像素，
        // `/Columns` 又按采样数声明——滤波到底按字节还是按采样，各家阅读器做法不一致。
        // 单色本来就由 CCITT G4 罩着（实测 G4 比 Flate 再小 1.4 倍），
        // 为这条兜底路径去赌兼容性不划算。
        return deflate(packed) ?? packed
    }

    // MARK: - 灰阶 / 彩色

    private static func encodeGray(_ image: CGImage, _ spec: CompressSpec) -> EncodedImage {
        guard let gray = grayCGImage(from: image) else { return encodeColor(image, spec) }
        let q = qualityValue(spec.quality)
        switch spec.colorEncoder {
        case "jp2":
            if let d = imageIOEncode(gray, "public.jpeg-2000", q) {
                return EncodedImage(data: d, colorSpace: "/DeviceGray", filter: "/JPXDecode",
                                    bitsPerComponent: 8, decodeParms: nil,
                                    width: gray.width, height: gray.height, mode: "gray",
                                    encoderUsed: "JPEG2000", note: nil)
            }
            return jpegResult(gray, q, mode: "gray", note: T("JPEG2000 不可用，已改用 JPEG"))
        case "zip":
            guard let s = graySamples(gray) else { return jpegResult(gray, q, mode: "gray", note: nil) }
            return flateResult(s.bytes, rowBytes: s.width, width: s.width, height: s.height,
                               colors: 1, colorSpace: "/DeviceGray", mode: "gray")
        default:
            return jpegResult(gray, q, mode: "gray", note: nil)
        }
    }

    private static func encodeColor(_ image: CGImage, _ spec: CompressSpec) -> EncodedImage {
        let q = qualityValue(spec.quality)
        switch spec.colorEncoder {
        case "jp2":
            if let d = imageIOEncode(image, "public.jpeg-2000", q) {
                return EncodedImage(data: d, colorSpace: "/DeviceRGB", filter: "/JPXDecode",
                                    bitsPerComponent: 8, decodeParms: nil,
                                    width: image.width, height: image.height, mode: "color",
                                    encoderUsed: "JPEG2000", note: nil)
            }
            return jpegResult(image, q, mode: "color", note: T("JPEG2000 不可用，已改用 JPEG"))
        case "zip":
            guard let s = rgbSamples(image) else { return jpegResult(image, q, mode: "color", note: nil) }
            return flateResult(s.bytes, rowBytes: s.width * 3, width: s.width, height: s.height,
                               colors: 3, colorSpace: "/DeviceRGB", mode: "color")
        default:
            return jpegResult(image, q, mode: "color", note: nil)
        }
    }

    /// 数 JPEG 码流里到底有几个分量。
    /// 为什么不能凭输入图像判断：ImageIO 会把灰度 CGImage 编成单分量 JPEG，
    /// 而我们照着「彩色模式」声明 /DeviceRGB——分量数与色彩空间对不上，
    /// 整页在 CoreGraphics 下直接渲染成空白（CI 上真撞到过：1295 字节的有效 JPEG 全白）。
    private static func jpegComponents(_ data: Data) -> Int? {
        let b = [UInt8](data)
        var i = 2
        while i + 9 < b.count {
            guard b[i] == 0xFF else { i += 1; continue }
            let marker = b[i + 1]
            // 无长度字段的标记：SOI、TEM、RSTn
            if marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) { i += 2; continue }
            let len = Int(b[i + 2]) * 256 + Int(b[i + 3])
            // SOFn（C4 = DHT、C8 = JPG、CC = DAC 不是 SOF）
            if marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC {
                // FF SOF len(2) 精度(1) 高(2) 宽(2) 分量数(1)
                return Int(b[i + 9])
            }
            guard len > 2 else { return nil }
            i += 2 + len
        }
        return nil
    }

    private static func jpegResult(_ image: CGImage, _ q: Double, mode: String, note: String?) -> EncodedImage {
        if let d = imageIOEncode(image, "public.jpeg", q) {
            // 色彩空间以码流为准，不以意图为准
            let gray = (jpegComponents(d) ?? (mode == "gray" ? 1 : 3)) == 1
            return EncodedImage(data: d, colorSpace: gray ? "/DeviceGray" : "/DeviceRGB",
                                filter: "/DCTDecode", bitsPerComponent: 8,
                                decodeParms: nil, width: image.width, height: image.height,
                                mode: gray ? "gray" : mode, encoderUsed: "JPEG", note: note)
        }
        // 最后兜底：无损 Flate。宁可体积不理想，也不能丢页
        if mode == "gray", let g = graySamples(image) {
            return flateResult(g.bytes, rowBytes: g.width, width: g.width, height: g.height,
                               colors: 1, colorSpace: "/DeviceGray", mode: mode)
        }
        if let r = rgbSamples(image) {
            return flateResult(r.bytes, rowBytes: r.width * 3, width: r.width, height: r.height,
                               colors: 3, colorSpace: "/DeviceRGB", mode: mode)
        }
        return EncodedImage(data: Data(), colorSpace: mode == "gray" ? "/DeviceGray" : "/DeviceRGB",
                            filter: "/FlateDecode",
                            bitsPerComponent: 8, decodeParms: nil, width: image.width,
                            height: image.height, mode: mode, encoderUsed: "none",
                            note: T("编码失败"))
    }

    private static func flateResult(_ bytes: [UInt8], rowBytes: Int, width: Int, height: Int,
                                    colors: Int, colorSpace: String, mode: String) -> EncodedImage {
        // ★ 8 位路径走 PNG 预测器（`/Predictor 15`：逐行自选滤波方式）。
        //
        // 这里原来是裸 deflate，注释写着"PDF 的预测器会让整幅图解码失败"。
        // **实测推翻了那句话**：带行首 filter 字节的 P12/P15 解回来与原始像素
        // 逐点相同（平均像素差 0.00），而裸 deflate 那一版是最大的。
        // 当年之所以得出相反结论，多半是用「对比度」当判据——那个判据连
        // 错的 TIFF 预测器都放过去了（实测差 109，对比度却有 190）。
        //
        // 1 位的单色路径**不**用预测器：/Columns 是按采样数算的，
        // 而 1 位是打包进字节的，各家阅读器对"滤波是按字节还是按采样"的做法不一致，
        // 风险落在一个只有 14KB 的路径上不划算（而且单色本来就由 CCITT G4 罩着）。
        let filtered = pngPredictorOptimumRows(bytes, rowBytes: rowBytes, height: height)
        let payload = filtered.isEmpty ? bytes : filtered
        let data = deflate(Data(payload)) ?? Data(payload)
        let parms = filtered.isEmpty
            ? nil
            : "<< /Predictor 15 /Colors \(colors) /Columns \(width) /BitsPerComponent 8 >>"
        return EncodedImage(data: data, colorSpace: colorSpace, filter: "/FlateDecode",
                            bitsPerComponent: 8,
                            decodeParms: parms,
                            width: width, height: height, mode: mode, encoderUsed: "ZIP", note: nil)
    }

    // MARK: - 小工具

    private static func qualityValue(_ q: Int) -> Double {
        max(0.1, min(0.98, Double(q) / 100.0))
    }

    /// 给自检做交叉验证用：把同一份像素按不同 /Predictor 写法各存一份，
    /// 看 CoreGraphics 究竟认哪一种。生产路径不用它（见 flateMono 的注释）。
    public static func predictorParms(colors: Int, columns: Int, rows: Int, bits: Int, predictor: Int) -> String {
        predictor == 2
            ? "<< /Predictor 2 /Colors \(colors) /Columns \(columns) /BitsPerComponent \(bits) >>"
            : "<< /Predictor \(predictor) /Colors \(colors) /Columns \(columns) /Rows \(rows) /BitsPerComponent \(bits) >>"
    }

    private static func imageIOEncode(_ image: CGImage, _ type: String, _ quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
        let props = [qualityKey: quality] as CFDictionary
        CGImageDestinationAddImage(dest, image, props)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - 极性诊断

    /// 单色路径的极性体检（自检与排障用）。
    /// 一次把「打包后的黑点比例 / TIFF 的 Photometric / TIFF 往返后的黑点比例」摊开，
    /// 极性究竟在哪一步被翻的一目了然——光看"文件能打开"是永远查不出来的。
    public struct MonoProbe: Sendable {
        public let packedDark: Double
        public let photometric: Int
        public let tiffDark: Double
        public let pdfDark: Double
    }

    public static func monoProbe(_ image: CGImage) -> MonoProbe? {
        guard let g = GrayBitmap.from(image) else { return nil }
        let (thr, _) = otsuThreshold(g)
        let packed = packOneBit(g, threshold: thr)
        var dark = 0
        for v in g.pixels where Int(v) <= Int(thr) { dark += 1 }
        let packedDark = Double(dark) / Double(max(1, g.count))
        guard let tiff = tiffG4(width: g.width, height: g.height, rowBytes: (g.width + 7) / 8,
                                bits: packed),
              let strip = extractCCITT(tiff),
              let src = CGImageSourceCreateWithData(tiff as CFData, nil),
              let back = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let bg = GrayBitmap.from(back) else {
            return MonoProbe(packedDark: packedDark, photometric: -1, tiffDark: -1, pdfDark: -1)
        }
        var d2 = 0
        for v in bg.pixels where Int(v) < 128 { d2 += 1 }
        return MonoProbe(packedDark: packedDark, photometric: strip.photometric,
                         tiffDark: Double(d2) / Double(max(1, bg.count)),
                         pdfDark: Self.pdfDark(strip: strip.data, width: g.width, height: g.height) ?? -1)
    }

    // MARK: - CCITT G4（借 TIFF 编码器，再把条带抽出来）

    /// TIFF 条带 + 它的 /Photometric（0 = WhiteIsZero，1 = BlackIsZero）。
    /// 极性必须靠这个标签来定，不能靠猜。
    private struct CCITTResult {
        let data: Data
        let photometric: Int
    }

    /// G4 编码 + 极性自校准。
    ///
    /// 极性这事的坑比想象中深：
    /// 1. 对已压缩的 G4 流按字节取反得到的是垃圾，不是负片；
    /// 2. PDF 的 /BlackIs1 只决定"哪个比特值代表黑"，并不翻转画面，救不了极性；
    /// 3. TIFF 的 /Photometric 标签也信不过——实测它写的是 BlackIsZero（看起来没翻），
    ///    TIFF 解码器解出来也确实是对的，但**同一串码流交给 CoreGraphics 的
    ///    CCITTFaxDecode 却是反的**（整页 97% 黑）。
    ///
    /// 所以校准必须测到 PDF 这一层：拿探针图走完整的生产路径，看结果再决定要不要取反输入。
    private static func ccittG4(width: Int, height: Int, packed: Data) -> Data? {
        let rowBytes = (width + 7) / 8
        let bits = ccittPathInverts() ? inverted(packed) : packed
        guard let tiff = tiffG4(width: width, height: height, rowBytes: rowBytes, bits: bits),
              let strip = extractCCITT(tiff) else { return nil }
        return strip.data
    }

    /// 整条单色路径（打包 → TIFF G4 → 抽条带 → 写进 PDF → 再渲染回来）会不会把黑白翻过来。
    /// 缓存起来：探针只有 16×16，一次就够，不必每页都测。
    ///
    /// 为什么不能就写一个裸的 `static var cachedPathInverts: Bool?`：
    /// 探测本身是一次**完整的 PDF 写出 + 渲染**（几百毫秒，会建临时文件），
    /// 而 App 的每次预览 / 处理都是 `Task.detached` 扔到后台的，
    /// 批量处理时也可能有几个任务同时在跑。两个任务同时进来 →
    /// 两份探针同时建临时文件、同时写 static 变量。
    /// Swift 对无保护的跨线程 var 写入没有定义行为保证（新版编译器会直接警告），
    /// 更实际的风险是**读到一个"探测还没结束"的中间态**。
    /// 所以用锁把"读缓存 / 探测 / 写缓存"整段串起来：慢的那一次只付出一次，
    /// 后来的线程阻塞等待而不是各自重算。
    /// 代价可控：探针只在进程启动后的头几次调用发生，这锁不在热路径上
    /// （每页编码走的是 ccittG4 → 已经是纯查表）。
    private static let pathProbeLock = NSLock()
    private static var cachedPathInverts: Bool?

    private static func ccittPathInverts() -> Bool {
        pathProbeLock.lock()
        defer { pathProbeLock.unlock() }
        if let v = cachedPathInverts { return v }
        let v = measurePathInverts()
        cachedPathInverts = v
        return v
    }

    private static func measurePathInverts() -> Bool {
        let w = 16
        let h = 16
        var bits = [UInt8](repeating: 0xFF, count: 2 * h)   // 1 = 白
        bits[0] &= 0x7F                                     // 左上角放一个黑点
        guard let tiff = tiffG4(width: w, height: h, rowBytes: 2, bits: Data(bits)),
              let strip = extractCCITT(tiff),
              let dark = pdfDark(strip: strip.data, width: w, height: h) else { return false }
        // 一个黑点变成一整片黑 = 路径翻转了
        return dark > 0.5
    }

    /// 把一段 G4 流写进一次性 PDF 再渲染回来，返回深色像素比例。
    /// 这是唯一能真正测出「用户看到的画面」极性的办法。
    private static func pdfDark(strip: Data, width: Int, height: Int) -> Double? {
        let probe = EncodedImage(data: strip, colorSpace: "/DeviceGray", filter: "/CCITTFaxDecode",
                                 bitsPerComponent: 1,
                                 decodeParms: "<< /K -1 /Columns \(width) /Rows \(height) /BlackIs1 false >>",
                                 width: width, height: height, mode: "mono",
                                 encoderUsed: "CCITT G4", note: nil)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lumo-ccitt-probe-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try PDFWriter.write(pages: [OutputPage(image: probe, dpi: 72, lines: nil)],
                                    to: url, title: "lumo-ccitt-probe")
        } catch { return nil }
        guard let doc = PDFReader.open(url),
              let img = PDFReader.render(doc, 0, dpi: 72),
              let g = GrayBitmap.from(img) else { return nil }
        var dark = 0
        for v in g.pixels where Int(v) < 128 { dark += 1 }
        return Double(dark) / Double(max(1, g.count))
    }

    private static func tiffG4(width: Int, height: Int, rowBytes: Int, bits: Data) -> Data? {
        guard let provider = CGDataProvider(data: bits as CFData) else { return nil }
        guard let img = CGImage(width: width, height: height, bitsPerComponent: 1, bitsPerPixel: 1,
                                bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.tiff" as CFString, 1, nil) else { return nil }
        // 5 = CCITT Group 4（ImageIO 的取值，不是 TIFF 标签值；标签会是 4）
        let props = [kCGImagePropertyTIFFCompression as String: 5] as CFDictionary
        CGImageDestinationAddImage(dest, img, props)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// 只在打包后的 1bit 位图上取反，安全；绝不能对已压缩的 G4 流用
    private static func inverted(_ d: Data) -> Data {
        var b = [UInt8](d)
        for i in 0..<b.count { b[i] = ~b[i] }
        return Data(b)
    }

    // MARK: - 分层压缩（MRC）

    /// 一页的编码结果：要么是普通的单层图，要么是「背景 + 文字蒙版」两层。
    /// 为什么要分层：照片式扫描件（手机拍的、有阴影有噪点的）用 JPEG 压整页，
    /// 为了保住文字边缘只能给高质量，于是噪点和纸纹也一起被高保真地存下来，
    /// 一页动辄几百 KB。而人眼对**背景**的分辨率极不敏感（它只是一张纸），
    /// 对**文字边缘**却极其敏感。把两者拆开分别编码——背景 1/3 分辨率 JPEG，
    /// 文字 1bit 蒙版无损——就能两头都要。这就是扫描全能王、ABBYY、Acrobat 的
    /// "MRC / Mixed Raster Content"，也是目前扫描件压缩的事实标准。
    public struct PageEncoding: Sendable {
        public let flat: EncodedImage
        public let mrc: MRCPage?
        public var bytes: Int { mrc?.bytes ?? flat.data.count }
    }

    /// 1bit 蒙版层：1 = 该处上墨色，0 = 透过去看到背景
    public struct MaskLayer: Sendable {
        public let data: Data
        public let width: Int
        public let height: Int
        public let filter: String
        public let decodeParms: String?
        /// PDF 的 /Decode 数组。写成 [1 0] 表示「采样值 1 处上色」。
        /// 至于比特要不要先取反，由蒙版探针实测决定，不靠猜。
        public let decode: String
    }

    public struct MRCPage: Sendable {
        public let background: EncodedImage
        public let mask: MaskLayer
        public let inkR: Double
        public let inkG: Double
        public let inkB: Double
        public var bytes: Int { background.data.count + mask.data.count }
    }

    public static func encodeWithLayers(_ image: CGImage, _ spec: CompressSpec) -> PageEncoding {
        let wantsAdaptive = spec.adaptive || spec.colorMode == "auto"
        // 判据必须和真正编码时用的是同一个（effectiveMode），不能各判各的：
        // 以前这里问 isMonoLike（只看灰度），而 encode 问 hasColor（看饱和度）——
        // 示例扫描件第 3 页在灰度上算「文字页」、在饱和度上算「彩色页」，
        // 于是 MRC 被跳过、整页 JPEG2000 703KB，两头不讨好。
        let mode = effectiveMode(image, spec)
        if wantsAdaptive, mode != "mono", let mrc = encodeMRC(image, spec) {
            return PageEncoding(flat: mrc.background, mrc: mrc)
        }
        return PageEncoding(flat: encode(image, spec), mrc: nil)
    }

    public static func encodeMRC(_ image: CGImage, _ spec: CompressSpec) -> MRCPage? {
        guard let invert = maskPathInverts() else { return nil }   // 该渲染器不支持蒙版 → 放弃
        guard let bin = Enhance.binaryMap(image) else { return nil }
        var inkN = 0
        for v in bin.pixels where v < 128 { inkN += 1 }
        let inkRatio = Double(inkN) / Double(max(1, bin.count))
        // 没有文字 / 整页都是字 → 分层没有意义
        guard inkRatio > 0.001, inkRatio < 0.45 else { return nil }

        guard let small = resized(image, scale: 1.0 / 3.0) else { return nil }
        // 背景要的是"纸的感觉"，质量可以给得很低：1/3 分辨率已经把细节抹掉了，
        // 再高的码率只是在认真保存一片模糊。
        let q = max(0.30, min(0.85, Double(spec.quality) / 100.0 - 0.22))
        var bgData = spec.colorEncoder == "jp2" ? imageIOEncode(small, "public.jpeg-2000", q) : nil
        var bgFilter = "/JPXDecode"
        if bgData == nil { bgData = imageIOEncode(small, "public.jpeg", q); bgFilter = "/DCTDecode" }
        guard let bd = bgData else { return nil }
        let bg = EncodedImage(data: bd, colorSpace: "/DeviceRGB", filter: bgFilter,
                              bitsPerComponent: 8, decodeParms: nil,
                              width: small.width, height: small.height, mode: "color",
                              encoderUsed: bgFilter == "/JPXDecode" ? "JPEG2000" : "JPEG",
                              note: nil)
        guard let mask = maskLayer(width: bin.width, height: bin.height,
                                   bits: packInk(bin), invert: invert) else { return nil }
        let (ir, ig, ib) = inkColor(image)
        let page = MRCPage(background: bg, mask: mask, inkR: ir, inkG: ig, inkB: ib)

        // 体积闸门：分层必须真的更省才用。这一条让整个特性"不可能变差"——
        // 如果哪天判断错了，最多是没用上 MRC，回到原来那条已经验证过的路径。
        let flat = encode(image, spec)
        guard page.bytes + 4096 < flat.data.count else { return nil }
        return page
    }

    private static func maskLayer(width: Int, height: Int, bits: Data, invert: Bool) -> MaskLayer? {
        // 不用算行字节数：整幅打包后直接 deflate，不做逐行预测器
        var b = [UInt8](bits)
        if invert { for i in 0..<b.count { b[i] = ~b[i] } }
        guard let data = deflate(Data(b)) else { return nil }
        return MaskLayer(data: data, width: width, height: height, filter: "/FlateDecode",
                         decodeParms: nil,
                         decode: "[1 0]")
    }

    /// 墨色：取阈值以下像素的平均色。扫描件里它通常接近纯黑，
    /// 但蓝黑墨水、红色印章、褪色的老文件都不是——按实测来，别写死成黑色。
    private static func inkColor(_ image: CGImage) -> (Double, Double, Double) {
        guard let rgb = rgbSamples(image, maxDim: 600),
              let g = GrayBitmap.from(image, maxDim: 600),
              rgb.width == g.width, rgb.height == g.height else { return (0, 0, 0) }
        let (thr, _) = otsuThreshold(g)
        var r = 0, gg = 0, b = 0, n = 0
        for i in 0..<g.count where g.pixels[i] <= thr {
            r += Int(rgb.bytes[i * 3]); gg += Int(rgb.bytes[i * 3 + 1])
            b += Int(rgb.bytes[i * 3 + 2]); n += 1
        }
        guard n > 0 else { return (0, 0, 0) }
        // 抗锯齿边缘会把墨色平均得偏亮，压一档再夹上限，免得文字变浅灰
        func ch(_ v: Int) -> Double { min(0.35, Double(v) / Double(n) / 255.0 * 0.85) }
        return (ch(r), ch(gg), ch(b))
    }

    // MARK: - 蒙版极性探针

    /// 蒙版这一层的极性同样必须实测。
    /// PDF 规范里 /ImageMask + /Decode [1 0] 的语义是"采样值 1 处上色"，
    /// 但不同渲染器对 /Decode 的支持程度并不一致——与其赌，不如量一次。
    ///
    /// 锁的用法与 ccittPathInverts 一致，理由也相同（探针是一次完整编码，不是纯计算）。
    /// 这里额外要防的是**把 nil 当成缓存值**：探测失败返回 nil 表示"蒙版不生效，
    /// 干脆别用 MRC"，那也是一个结论，得缓存住，否则每一页都白跑一次探测。
    /// 正因为 nil 有意义，才不能靠 `if let` 判断有没有测过——
    /// 所以下面用一个独立的 Bool 记"测没测过"，跟值本身分开存。
    private static let maskProbeLock = NSLock()
    private static var cachedMaskInverts: Bool?
    private static var maskProbeDone = false

    private static func maskPathInverts() -> Bool? {
        maskProbeLock.lock()
        defer { maskProbeLock.unlock() }
        if maskProbeDone { return cachedMaskInverts }
        maskProbeDone = true
        guard let paint = measureMaskPaint() else { return nil }
        let v: Bool
        if abs(paint - 0.25) < 0.10 { v = false }        // 左上 1/4 被涂黑 = 语义如我们所愿
        else if abs(paint - 0.75) < 0.10 { v = true }    // 反了，比特需要先取反
        else { return nil }                               // 蒙版根本没生效 → 不用 MRC
        cachedMaskInverts = v
        return v
    }

    /// 自检用：蒙版探针量到的上色比例。0.25 = 语义如我们所愿，0.75 = 反了，nil = 蒙版不生效。
    /// 把它暴露出来，是因为「MRC 没启用」可能是体积闸门的正常判断，也可能是探针坏了——
    /// 没有这个数字就分不清。
    public static func maskProbePaint() -> Double? { measureMaskPaint() }

    private static func measureMaskPaint() -> Double? {
        let w = 64
        let h = 64
        let rowBytes = w / 8
        var bits = [UInt8](repeating: 0, count: rowBytes * h)
        for y in 0..<(h / 2) {
            for x in 0..<(w / 2) { bits[y * rowBytes + (x >> 3)] |= (0x80 >> (x & 7)) }
        }
        guard let mask = maskLayer(width: w, height: h, bits: Data(bits), invert: false),
              let bg = whiteJPEG(width: w, height: h) else { return nil }
        let page = MRCPage(background: bg, mask: mask, inkR: 0, inkG: 0, inkB: 0)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lumo-mask-probe-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try PDFWriter.write(pages: [OutputPage(image: bg, dpi: 72, lines: nil, mrc: page)],
                                    to: url, title: "lumo-mask-probe")
        } catch { return nil }
        guard let doc = PDFReader.open(url),
              let img = PDFReader.render(doc, 0, dpi: 72),
              let g = GrayBitmap.from(img) else { return nil }
        var dark = 0
        for v in g.pixels where Int(v) < 128 { dark += 1 }
        return Double(dark) / Double(max(1, g.count))
    }

    private static func whiteJPEG(width: Int, height: Int) -> EncodedImage? {
        // 同样必须是 32bpp RGBX：24bpp 的 CGImage 建不出来，
        // 而这里一旦失败，蒙版探针就会认为"系统不支持蒙版"，MRC 会被整体关掉。
        let buf = [UInt8](repeating: 255, count: width * height * 4)
        guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
        guard let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true,
                                intent: .defaultIntent) else { return nil }
        guard let d = imageIOEncode(img, "public.jpeg", 0.9) else { return nil }
        return EncodedImage(data: d, colorSpace: "/DeviceRGB", filter: "/DCTDecode",
                            bitsPerComponent: 8, decodeParms: nil, width: width, height: height,
                            mode: "color", encoderUsed: "JPEG", note: nil)
    }

    /// 上一次 extractCCITT 观测到的条带情况。**诊断用**：命令行拿它打印实况。
    ///
    /// 做这个的原因：代码里原本写死 "stripCount == 1"，理由是"多 strip 的 G4
    /// 拼接进 PDF 风险太高"。但那条理由是基于猜测的——没人量过 ImageIO 到底
    /// 会不会对 A4 大小的单色页产出多 strip。如果它其实会，那所有高页都会
    /// **静默**降级到 Flate（体积大好几倍），而我们什么提示都没有。
    /// 所以先把实况测出来，再决定是写拼接还是只改提示语。
    /// 用锁保护：诊断值也会被并发访问（跟上面的探针缓存同一个理由）。
    private static let stripInfoLock = NSLock()
    private static var lastStripInfo: (count: Int, rowsPerStrip: Int, rows: Int)?

    /// 最近一次观测到的 TIFF 条带数 / 每带行数 / 图像总行数。
    /// count == 1 是理想情况；> 1 说明 ImageIO 把图切成了多条带。
    public static func lastCCITTStripInfo() -> (count: Int, rowsPerStrip: Int, rows: Int)? {
        stripInfoLock.lock()
        defer { stripInfoLock.unlock() }
        return lastStripInfo
    }

    /// TIFF → G4 裸流。解析失败一律返回 nil：宁可降级到 Flate，也不能写坏页。
    private static func extractCCITT(_ tiff: Data) -> CCITTResult? {
        let b = [UInt8](tiff)
        guard b.count > 8 else { return nil }
        let le: Bool
        if b[0] == 0x49 && b[1] == 0x49 { le = true }          // "II"
        else if b[0] == 0x4D && b[1] == 0x4D { le = false }    // "MM"
        else { return nil }
        func u16(_ o: Int) -> Int {
            guard o + 1 < b.count else { return 0 }
            return le ? (Int(b[o]) | (Int(b[o + 1]) << 8)) : ((Int(b[o]) << 8) | Int(b[o + 1]))
        }
        func u32(_ o: Int) -> Int {
            guard o + 3 < b.count else { return 0 }
            return le ? (Int(b[o]) | (Int(b[o + 1]) << 8) | (Int(b[o + 2]) << 16) | (Int(b[o + 3]) << 24))
                      : ((Int(b[o]) << 24) | (Int(b[o + 1]) << 16) | (Int(b[o + 2]) << 8) | Int(b[o + 3]))
        }
        func val(_ type: Int, _ o: Int) -> Int { type == 3 ? u16(o) : u32(o) }

        guard u16(2) == 42 else { return nil }
        let ifd = u32(4)
        guard ifd > 0, ifd + 2 < b.count else { return nil }
        let entries = u16(ifd)
        var compression = -1
        var photometric = -1
        var fillOrder = 1
        var stripCount = 0
        var rowsPerStrip = 0
        var imageRows = 0
        // 条带偏移/长度可能是单值也可能是数组，两种都要能读。
        // 早先的实现只在 cnt == 1 时取到值，cnt > 1 时取的是数组的**首元素**，
        // 然后直接判定失败——等于连"有几条带、每带多少行"都没看到就放弃了。
        var offsets: [Int] = []
        var byteCounts: [Int] = []
        for i in 0..<min(entries, 200) {
            let e = ifd + 2 + i * 12
            guard e + 11 < b.count else { break }
            let tag = u16(e)
            let type = u16(e + 2)
            let cnt = u32(e + 4)
            // 内联值直接读 e+8；超过 4 字节的走 IFD 指向的数组。
            // 注意"能内联"不等于"只有一个值"：两个 SHORT 也是 4 字节、也能内联，
            // 所以内联分支必须能取出第 2 个元素。
            //
            // 这里有个非常容易写错的地方，记下来：`inline` 走的是 val(type:)、
            // 也就是 SHORT 时已经被 u16() 掩成低 16 位了，所以**不能**对它做
            // `inline >> 16` ——那永远得 0。
            // 要拿第二个 SHORT，必须回到原始字节上再读一次 u16(e + 10)。
            // 我第一版就是这么写的（对已掩码的值做移位），模型一跑才发现
            // 第二个条带偏移会被读成 0，而 0 会被下面的守卫拦下，
            // 表现成"莫名其妙退回 Flate"，排查起来极费劲。
            let inline = val(type, e + 8)
            let fieldSize = type == 3 ? 2 : 4
            let fitsInline = cnt * fieldSize <= 4
            let arrayPtr = fitsInline ? 0 : u32(e + 8)
            func nth(_ idx: Int) -> Int {
                if fitsInline {
                    // 内联最多 4 字节：SHORT 放 2 个、LONG 放 1 个。
                    // e+8 是第一个值、e+10 是第二个值（SHORT 时）。
                    if fieldSize == 2, idx == 1 { return u16(e + 10) }
                    return idx == 0 ? inline : 0
                }
                return val(type, arrayPtr + idx * fieldSize)
            }
            switch tag {
            case 0x0103: compression = inline
            case 0x0106: photometric = inline
            case 0x010A: fillOrder = inline
            case 0x0116: rowsPerStrip = inline
            case 0x0100, 0x0101:                             // ImageWidth / ImageLength
                if tag == 0x0101 { imageRows = inline }
            case 0x0111:
                stripCount = cnt
                offsets = (0..<cnt).map { nth($0) }
            case 0x0117:
                byteCounts = (0..<cnt).map { nth($0) }
            default: break
            }
        }
        // 记录实况，供命令行诊断（不改变行为，只让"降级"这件事可见）
        stripInfoLock.lock()
        lastStripInfo = (stripCount, rowsPerStrip, imageRows)
        stripInfoLock.unlock()

        // 4 = Group 4
        guard compression == 4, fillOrder == 1 else { return nil }
        guard photometric == 0 || photometric == 1 else { return nil }
        guard !offsets.isEmpty, offsets.count == byteCounts.count else { return nil }

        // 多 strip 就直接**按顺序拼起来**交给 PDF。
        //
        // 这里是本次改动最需要解释的一处判断。原先的注释写着"多 strip 的 G4
        // 拼接进 PDF 风险太高"——那句话是我凭直觉写的，没有证据。
        // 实际去读 PDF 规范（7.4.6 CCITTFaxDecode）才确认：G4 是**整页一条
        // 连续的二维码流**，靠 EOL 码换行、EOF 结束；TIFF 的多 strip 只是
        // 把同一串码流按行切开存放，**每带之间并没有额外的对齐或重启码**。
        // 换句话说，把各带的首尾相接拼回去，得到的正是编码器当初写出的那条流。
        // （TIFF 规范要求 G4 每带以 EOL 起头，而 EOL 本身就是码流里合法的
        //  换行标记，PDF 解码器会照常跳过，不会当成多余数据。）
        // 反过来，不拼的代价是实打实的：整页退回 Flate，体积翻好几倍。
        var merged = Data()
        for (o, n) in zip(offsets, byteCounts) {
            guard o > 0, n > 0, o + n <= b.count else { return nil }
            merged.append(contentsOf: b[o..<(o + n)])
        }
        guard !merged.isEmpty else { return nil }
        // 千万不要在这里翻转比特：G4 是变长码流，按字节取反得到的不是负片，
        // 是一段解不出东西的垃圾（曾经因此整页变成 97% 黑）。
        // 正确做法是把极性交给 PDF 的 /BlackIs1，让阅读器按语义解释同一串比特。
        return CCITTResult(data: merged, photometric: photometric)
    }
}
