// Lumo 原生核心 —— 数据模型
// App 与 CLI 共用同一套模型，避免两处各写一份导致字段漂移。
import Foundation

// MARK: - 体检报告

public struct Analysis: Codable, Equatable, Sendable {
    public var pageCount: Int
    public var fileSize: Int
    public var hasTextLayer: Bool
    public var textRatio: Double
    public var colorMode: String          // color | gray | mono
    public var estimatedDpi: Int
    public var skewAngle: Double
    public var noiseLevel: Double
    /// 背景不匀程度（0~1）。与噪声是两件事：噪声是"平坦区域抖不抖"，
    /// 不匀是"白电平在页面上起不起伏"。决定要不要做背景去除的应该是它。
    public var bgUnevenness: Double
    /// 纸白（全页最亮 20% 像素的**下界**，即 p80 分位点，0~255）。
    /// 与不匀度互补：不匀度抓"阴影 / 光照渐变"，纸白抓"均匀的灰"（纸色偏黄、整体发灰）。
    /// 只看不匀度会漏掉后者——而后者恰恰是用户抱怨"画面不干净"最常见的来源。
    ///
    /// 措辞特意写"下界"而不是"均值"：这里曾经写成均值，但那不是实现做的事。
    /// 分位点只看"亮的 20% 那一档有多亮"，不看占多数的那部分有多暗——
    /// 页面里只要有 ≥20% 接近白的区域（白边、留白、双栏空白带），它就会跳到 250+，
    /// 哪怕剩下大半张纸都是灰的。所以判断"要不要清背景"时不能只看这一个数，
    /// 得配 Enhance.paperMean 一起看（见 Enhance.isPaperWhite 的双判据）。
    public var paperWhite: Double
    public var pageModes: [String]

    public init(pageCount: Int = 0, fileSize: Int = 0, hasTextLayer: Bool = false,
                textRatio: Double = 0, colorMode: String = "color",
                estimatedDpi: Int = 300, skewAngle: Double = 0,
                noiseLevel: Double = 0, bgUnevenness: Double = 0,
                paperWhite: Double = 255, pageModes: [String] = []) {
        self.pageCount = pageCount
        self.fileSize = fileSize
        self.hasTextLayer = hasTextLayer
        self.textRatio = textRatio
        self.colorMode = colorMode
        self.estimatedDpi = estimatedDpi
        self.skewAngle = skewAngle
        self.noiseLevel = noiseLevel
        self.bgUnevenness = bgUnevenness
        self.paperWhite = paperWhite
        self.pageModes = pageModes
    }

    enum CodingKeys: String, CodingKey {
        case pageCount = "page_count"
        case fileSize = "file_size"
        case hasTextLayer = "has_text_layer"
        case textRatio = "text_ratio"
        case colorMode = "color_mode"
        case estimatedDpi = "estimated_dpi"
        case skewAngle = "skew_angle"
        case noiseLevel = "noise_level"
        case bgUnevenness = "bg_unevenness"
        case paperWhite = "paper_white"
        case pageModes = "page_modes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pageCount    = try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0
        fileSize     = try c.decodeIfPresent(Int.self, forKey: .fileSize) ?? 0
        hasTextLayer = try c.decodeIfPresent(Bool.self, forKey: .hasTextLayer) ?? false
        textRatio    = try c.decodeIfPresent(Double.self, forKey: .textRatio) ?? 0
        colorMode    = try c.decodeIfPresent(String.self, forKey: .colorMode) ?? "color"
        estimatedDpi = try c.decodeIfPresent(Int.self, forKey: .estimatedDpi) ?? 300
        skewAngle    = try c.decodeIfPresent(Double.self, forKey: .skewAngle) ?? 0
        noiseLevel   = try c.decodeIfPresent(Double.self, forKey: .noiseLevel) ?? 0
        bgUnevenness = try c.decodeIfPresent(Double.self, forKey: .bgUnevenness) ?? 0
        paperWhite   = try c.decodeIfPresent(Double.self, forKey: .paperWhite) ?? 255
        pageModes    = try c.decodeIfPresent([String].self, forKey: .pageModes) ?? []
    }
}

// MARK: - 增强模式（手机扫描 App 里那一排「自动增强 / 增强 / 黑白 / 对比度 / 原图」）

/// 为什么要有「模式」而不是让用户逐项勾滤镜：
/// 扫描全能王 / 布丁扫描 / 汉王扫描 的交互早就证明了——用户不想理解
/// 「背景去除」「去网纹」「自适应阈值」分别是什么，他们只想选一个效果。
/// 所以我们把底层滤镜收敛成 5 个可直接预览效果的模式，滤镜细节仍然可调，
/// 但不再是必答题。
///
/// ## 为什么是这 5 个，而不是照搬布丁扫描那 8 个
///
/// 布丁扫描的清单是：原图 / 增强 / AI 超清 / 增亮 / 去屏纹 / 柔和 / 黑白 / 灰度。
/// 我们逐条对过，结论是**不照搬**，理由分三类：
///
/// 1. **它不是一条轴上的东西。** 八个档里混了三种性质：
///    「原图 / 黑白」是**输出形态**（彩 → 二值），
///    「增强 / 增亮 / 柔和」是**同一组滤镜换强度**，
///    「去屏纹」是**针对特定缺陷的补偿**。并排放会让用户以为它们是互斥的，
///    而实际上「增亮 + 去屏纹」是可以同时要的。
///
/// 2. **有两个我们不能做，也不该做。** 「AI 超清」要深度学习超分模型，
///    macOS 本地 SDK 没有现成入口，引第三方模型直接违背「零依赖、只用本地 SDK」
///    的设计前提；而且超分是**编细节**，用在扫描件上会让 OCR 读到不存在的笔画。
///    「增亮」在扫描件语境下是坏词——用户抱怨的一直是"底灰没清掉"，
///    单纯提亮只会让灰更明显，我们的背景清理（按纸白归一化）才是正解。
///
/// 3. **「灰度」和「对比度」是同一件事的两种说法。** 具体见 `.contrast` 的注释。
///
/// 所以最终留下的 5 个，正好覆盖"输出形态"这条主轴：
/// 保持彩色（增强）/ 压成黑白（黑白）/ 不碰（原图）/ 不确定就让机器逐页判断（自动），
/// 外加一个"我只是想让它别那么灰"的轻量档（对比度）。
public enum EnhancePreset: String, CaseIterable, Codable, Sendable {
    case auto
    case bw
    case color
    case contrast
    case original

    public var title: String {
        switch self {
        case .auto:     return "自动增强"
        case .bw:       return "黑白"
        case .color:    return "增强"
        case .contrast: return "对比度"
        case .original: return "原图"
        }
    }

    /// 每个模式一句话说清"点了会发生什么"。
    ///
    /// 标题去掉「增强」二字之后（彩色增强→增强、黑白增强→黑白），
    /// 描述的担子更重了：标题从「黑白增强」缩到「黑白」，少掉的那半句
    /// 必须由描述补上，否则用户看不出它和「对比度」的区别。
    /// 所以这里的措辞刻意不提算法名，只说**看起来会怎样**。
    public var desc: String {
        switch self {
        case .auto:     return "逐页判断：文字页走黑白，含图页保色彩"
        case .bw:       return "只留纯黑与纯白，底灰、阴影、污渍全部清掉"
        case .color:    return "保留彩色与插图，清背景、校正光照、略提饱和"
        case .contrast: return "仍保持原有色调，只把发灰、太淡的画面拉开反差"
        case .original: return "不做画面处理，只做识别与压缩"
        }
    }

    public var icon: String {
        switch self {
        case .auto: return "✨"
        case .bw: return "⬛"
        case .color: return "🎨"
        case .contrast: return "◐"
        case .original: return "📄"
        }
    }

    /// SF Symbol 名字。UI 优先用它，`icon` 那个 emoji 只留给 CLI 的纯文本输出。
    ///
    /// 为什么两套：CLI 在终端里打印，emoji 是唯一选择；而 App 界面上
    /// 用 emoji 当图标会有三个问题——**不跟随系统字重、深色模式下对比度不受控、
    /// 尺寸与其他图标不一致**。参考《macOS 单窗口玻璃质感设计参考》§6
    /// 明确写着「图标优先 SF Symbols」。所以图案是两份，但语义只此一处，
    /// 免得两处各挑各的图标最后对不上。
    public var symbol: String {
        switch self {
        case .auto:     return "wand.and.stars"
        case .bw:       return "circle.lefthalf.filled"
        case .color:    return "paintpalette"
        case .contrast: return "circle.righthalf.filled"
        case .original: return "doc.plaintext"
        }
    }

    /// 这个模式里"背景清理强度"滑块有没有意义。
    ///
    /// `.bw` 没有：它走的是二值化，阈值由局部均值按窗口自己算，
    /// 强度滑块拧到哪都不会改变结果——UI 上曾经照常显示它，用户拉半天没反应。
    /// `.original` 也没有：它压根不碰画面。
    /// 其余三个（含 `.auto`，它的每条分支都会用 strength）都有意义。
    ///
    /// 放在这里而不是散在 Views 里的原因：这是**模式自身的属性**，
    /// 不是某个界面的显示偏好。CLI 的 selftest 也要用它来判断该不该断言强度生效。
    public var usesBgStrength: Bool {
        switch self {
        case .bw, .original: return false
        case .auto, .color, .contrast: return true
        }
    }

    public init(_ raw: String?) {
        self = EnhancePreset(rawValue: raw ?? "") ?? .auto
    }
}

// MARK: - 工作流规格

public struct EnhanceSpec: Codable, Equatable, Sendable {
    /// 增强模式。nil = 不做模式处理（沿用逐项滤镜的旧语义，CLI 与自检依赖它）
    public var preset: String?
    public var deskew: Bool?
    public var bgRemove: Bool?
    public var descreen: Bool?
    public var sharpen: Double?
    /// 自动裁边 + 透视校正（拍照扫描件四周多余的桌面）。默认关闭：只勾了才做
    public var autoCrop: Bool?
    /// 背景清理强度 0~1，nil 视作 0.75。
    ///
    /// 为什么是连续量而不是「开 / 关」：扫描件之间的"脏"差别极大——
    /// 正版书扫描只是纸色偏黄，手机拍照件却可能带一整片阴影。
    /// 固定强度必然一头不合适：弱了阴影像没处理，强了会把浅色页脚一起清掉。
    /// 0 = 完全不动背景（保留纸张质感），1 = 纸白拉到 255（最干净的观感）。
    public var bgStrength: Double?

    public init(preset: String? = nil, deskew: Bool? = nil, bgRemove: Bool? = nil,
                descreen: Bool? = nil, sharpen: Double? = nil, autoCrop: Bool? = nil,
                bgStrength: Double? = nil) {
        self.preset = preset
        self.deskew = deskew
        self.bgRemove = bgRemove
        self.descreen = descreen
        self.sharpen = sharpen
        self.autoCrop = autoCrop
        self.bgStrength = bgStrength
    }

    enum CodingKeys: String, CodingKey {
        case preset
        case deskew
        case bgRemove = "bg_remove"
        case descreen
        case sharpen
        case autoCrop = "auto_crop"
        case bgStrength = "bg_strength"
    }
}

public struct OCRSpec: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var lang: String
    /// searchable = 不可见文字层；editable = 可见文字层（并附送 .txt）
    public var output: String
    /// 已体检出文字层时为 true：整步跳过，避免重复识别
    public var skip: Bool

    public init(enabled: Bool = true, lang: String = "chi_sim+eng",
                output: String = "searchable", skip: Bool = false) {
        self.enabled = enabled
        self.lang = lang
        self.output = output
        self.skip = skip
    }
}

public struct CompressSpec: Codable, Equatable, Sendable {
    public var adaptive: Bool
    /// auto | color | gray | mono
    public var colorMode: String
    /// jpeg | jp2 | zip
    public var colorEncoder: String
    /// 单色页编码器：ccitt | zip
    ///
    /// 这里曾经写着 `ccitt | jbig2 | zip`，但 jbig2 从来没被实现过——
    /// 那是一条**残留注释**，而它比没有注释更坏：后来读代码的人会以为
    /// "这个引擎支持 JBIG2，只是默认没开"，于是去调它，然后调不动。
    ///
    /// 真实情况是 **macOS 本地 SDK 根本没有 JBIG2 编码器**：
    /// ImageIO 的可写格式清单里没有任何 jbig 字样（`lumo-cli encoders`
    /// 在真机上现场打印过），CoreGraphics 只在解码侧能读 PDF 里内嵌的 JBIG2，
    /// 编码侧没有任何入口。要用它就得自己实现算术编码器 + 模式匹配，
    /// 或者引一个第三方库——前者是无底洞，后者违背零依赖前提。
    ///
    /// 好在**放弃它几乎没有代价**：扫描件单色页的主流本就是 CCITT G4
    /// （fax 时代的通用格式，所有 PDF 阅读器都硬支持），实测示例件
    /// 单色页 CCITT 后只剩 32 字节。JBIG2 的优势在"半调网点"这类
    /// 非文字内容上，而那种页面本来就不该走单色路径。
    public var monoEncoder: String
    public var quality: Int

    public init(adaptive: Bool = true, colorMode: String = "auto",
                colorEncoder: String = "jpeg", monoEncoder: String = "ccitt",
                quality: Int = 72) {
        self.adaptive = adaptive
        self.colorMode = colorMode
        self.colorEncoder = colorEncoder
        self.monoEncoder = monoEncoder
        self.quality = quality
    }

    enum CodingKeys: String, CodingKey {
        case adaptive
        case colorMode = "color_mode"
        case colorEncoder = "color_encoder"
        case monoEncoder = "mono_encoder"
        case quality
    }
}

public struct Recommendation: Codable, Equatable, Sendable {
    public var pages: String
    public var enhance: EnhanceSpec
    public var ocr: OCRSpec
    public var compress: CompressSpec
    public var notes: [String]

    public init(pages: String = "all", enhance: EnhanceSpec = EnhanceSpec(),
                ocr: OCRSpec = OCRSpec(), compress: CompressSpec = CompressSpec(),
                notes: [String] = []) {
        self.pages = pages
        self.enhance = enhance
        self.ocr = ocr
        self.compress = compress
        self.notes = notes
    }
}

public struct PlanSettings: Codable, Equatable, Sendable {
    public var adaptive: Bool
    public var colorMode: String
    public var colorEncoder: String
    public var monoEncoder: String
    public var quality: Int

    public init(adaptive: Bool, colorMode: String, colorEncoder: String,
                monoEncoder: String, quality: Int) {
        self.adaptive = adaptive
        self.colorMode = colorMode
        self.colorEncoder = colorEncoder
        self.monoEncoder = monoEncoder
        self.quality = quality
    }

    enum CodingKeys: String, CodingKey {
        case adaptive
        case colorMode = "color_mode"
        case colorEncoder = "color_encoder"
        case monoEncoder = "mono_encoder"
        case quality
    }

    public var asCompressSpec: CompressSpec {
        CompressSpec(adaptive: adaptive, colorMode: colorMode,
                     colorEncoder: colorEncoder, monoEncoder: monoEncoder,
                     quality: quality)
    }
}

public struct Plan: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var desc: String
    public var settings: PlanSettings
    public var estBytes: Int
    public var estRatio: Double
    public var recommended: Bool?

    public init(id: String, name: String, desc: String, settings: PlanSettings,
                estBytes: Int = 0, estRatio: Double = 0, recommended: Bool? = nil) {
        self.id = id
        self.name = name
        self.desc = desc
        self.settings = settings
        self.estBytes = estBytes
        self.estRatio = estRatio
        self.recommended = recommended
    }

    enum CodingKeys: String, CodingKey {
        case id, name, desc, settings
        case estBytes = "est_bytes"
        case estRatio = "est_ratio"
        case recommended
    }
}

public struct ReportResponse: Codable, Equatable, Sendable {
    public var fileId: String
    public var analysis: Analysis
    public var recommendation: Recommendation
    public var plans: [Plan]
    public var procDpi: Int
    public var availableLangs: [String]

    public init(fileId: String = "", analysis: Analysis = Analysis(),
                recommendation: Recommendation = Recommendation(), plans: [Plan] = [],
                procDpi: Int = 300, availableLangs: [String] = []) {
        self.fileId = fileId
        self.analysis = analysis
        self.recommendation = recommendation
        self.plans = plans
        self.procDpi = procDpi
        self.availableLangs = availableLangs
    }

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case analysis, recommendation, plans
        case procDpi = "proc_dpi"
        case availableLangs = "available_langs"
    }
}

// MARK: - 处理请求 / 结果

public struct ProcessSpec: Codable, Equatable, Sendable {
    public var pages: String
    public var enhance: EnhanceSpec
    public var ocr: OCRSpec
    public var compress: CompressSpec
    public var procDpi: Int?

    public init(pages: String = "all", enhance: EnhanceSpec = EnhanceSpec(),
                ocr: OCRSpec = OCRSpec(), compress: CompressSpec = CompressSpec(),
                procDpi: Int? = nil) {
        self.pages = pages
        self.enhance = enhance
        self.ocr = ocr
        self.compress = compress
        self.procDpi = procDpi
    }

    enum CodingKeys: String, CodingKey {
        case pages, enhance, ocr, compress
        case procDpi = "proc_dpi"
    }
}

public struct ProcessResponse: Codable, Equatable, Sendable {
    public var fileId: String
    public var outPath: String
    public var inSize: Int
    public var outSize: Int
    public var savedPct: Double
    public var pagesProcessed: Int
    public var ocrEngine: String?
    public var ocrChars: Int
    public var steps: [String]
    public var elapsedSec: Double
    public var previewBefore: String?
    public var previewAfter: String?
    public var sidecar: String?
    public var download: String?
    public var warnings: [String]

    public init(fileId: String = "", outPath: String = "", inSize: Int = 0, outSize: Int = 0,
                savedPct: Double = 0, pagesProcessed: Int = 0, ocrEngine: String? = nil,
                ocrChars: Int = 0, steps: [String] = [], elapsedSec: Double = 0,
                previewBefore: String? = nil, previewAfter: String? = nil,
                sidecar: String? = nil, download: String? = nil, warnings: [String] = []) {
        self.fileId = fileId
        self.outPath = outPath
        self.inSize = inSize
        self.outSize = outSize
        self.savedPct = savedPct
        self.pagesProcessed = pagesProcessed
        self.ocrEngine = ocrEngine
        self.ocrChars = ocrChars
        self.steps = steps
        self.elapsedSec = elapsedSec
        self.previewBefore = previewBefore
        self.previewAfter = previewAfter
        self.sidecar = sidecar
        self.download = download
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case outPath = "out_path"
        case inSize = "in_size"
        case outSize = "out_size"
        case savedPct = "saved_pct"
        case pagesProcessed = "pages_processed"
        case ocrEngine = "ocr_engine"
        case ocrChars = "ocr_chars"
        case steps
        case elapsedSec = "elapsed_sec"
        case previewBefore = "preview_before"
        case previewAfter = "preview_after"
        case sidecar, download, warnings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileId         = try c.decodeIfPresent(String.self, forKey: .fileId) ?? ""
        outPath        = try c.decodeIfPresent(String.self, forKey: .outPath) ?? ""
        inSize         = try c.decodeIfPresent(Int.self, forKey: .inSize) ?? 0
        outSize        = try c.decodeIfPresent(Int.self, forKey: .outSize) ?? 0
        savedPct       = try c.decodeIfPresent(Double.self, forKey: .savedPct) ?? 0
        pagesProcessed = try c.decodeIfPresent(Int.self, forKey: .pagesProcessed) ?? 0
        ocrEngine      = try c.decodeIfPresent(String.self, forKey: .ocrEngine)
        ocrChars       = try c.decodeIfPresent(Int.self, forKey: .ocrChars) ?? 0
        steps          = try c.decodeIfPresent([String].self, forKey: .steps) ?? []
        elapsedSec     = try c.decodeIfPresent(Double.self, forKey: .elapsedSec) ?? 0
        previewBefore  = try c.decodeIfPresent(String.self, forKey: .previewBefore)
        previewAfter   = try c.decodeIfPresent(String.self, forKey: .previewAfter)
        sidecar        = try c.decodeIfPresent(String.self, forKey: .sidecar)
        download       = try c.decodeIfPresent(String.self, forKey: .download)
        warnings       = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}

// MARK: - 展示用辅助

extension Analysis {
    public var colorModeText: String {
        ["color": "彩色", "gray": "灰阶", "mono": "单色"][colorMode] ?? colorMode
    }
    public var noiseText: String {
        noiseLevel < 0.22 ? "低" : (noiseLevel < 0.5 ? "中" : "高")
    }
    /// 背景明暗是否均匀。「不匀」才是该做背景去除的信号
    public var bgText: String { bgUnevenness > 0.12 ? "不匀" : "均匀" }
}
