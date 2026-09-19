// Lumo 原生核心 —— OCR（Vision 框架）
// 系统自带，无需安装 Tesseract / 语言包；中英文都走同一条路径。
import Foundation
import CoreGraphics
import Vision

public struct OCRLine: Sendable {
    public let text: String
    /// 归一化矩形，原点在左下（与 PDF 页面坐标同向，不用翻转）
    public let rect: CGRect

    /// 显式写一个 public init，而不是靠结构体的隐式 memberwise init：
    /// 隐式那个是 internal 的，跨模块（lumo-cli 是独立 target）就用不了。
    /// 自检里要造假的 OCR 结果来测「文字层 + MRC」的写出逻辑，
    /// 拿不到构造器就只能去跑真 OCR——那样测的是识别精度，不是我们要测的东西。
    public init(text: String, rect: CGRect) {
        self.text = text
        self.rect = rect
    }
}

public struct OCRLanguage: Identifiable, Hashable, Sendable {
    public let id: String
    /// 中文原文，同时也是翻译表的 key。
    ///
    /// ⚠️ 这里**刻意存原文、每次取用时才翻译**，不要在初始化时就翻好：
    /// `OCR.languages` 是 `static let`，只会算一次——那样切了界面语言之后，
    /// 语言下拉框里还是会一直显示上一次的名字。
    /// （这种"值被提前固化"的 bug 在切换语言时特别难发现，因为大部分文案都对。）
    let zhName: String
    public let codes: [String]

    public var name: String { T(zhName) }
    public var identifier: String { id }
}

public enum OCRError: LocalizedError {
    case noResult
    public var errorDescription: String? { T("未能识别出任何文字") }
}

public enum OCR {
    public static let engineName = "Vision"

    /// Vision 的语言码与常见 OCR 语言 id 不一样，这里做一次映射，
    /// 让用户看到的仍是「中文 + 英文」而不是「zh-Hans」。
    public static let languages: [OCRLanguage] = [
        OCRLanguage(id: "chi_sim+eng", zhName: "中文 + 英文", codes: ["zh-Hans", "en-US"]),
        OCRLanguage(id: "chi_sim", zhName: "中文简体",    codes: ["zh-Hans"]),
        OCRLanguage(id: "chi_tra+eng", zhName: "中文繁体 + 英文", codes: ["zh-Hant", "en-US"]),
        OCRLanguage(id: "eng", zhName: "英文",        codes: ["en-US"]),
        OCRLanguage(id: "jpn", zhName: "日文",        codes: ["ja-JP"]),
        OCRLanguage(id: "kor", zhName: "韩文",        codes: ["ko-KR"]),
        OCRLanguage(id: "fra", zhName: "法文",        codes: ["fr-FR"]),
        OCRLanguage(id: "deu", zhName: "德文",        codes: ["de-DE"]),
        OCRLanguage(id: "spa", zhName: "西班牙文",    codes: ["es-ES"]),
        OCRLanguage(id: "ita", zhName: "意大利文",    codes: ["it-IT"]),
        OCRLanguage(id: "por", zhName: "葡萄牙文",    codes: ["pt-BR"]),
        OCRLanguage(id: "rus", zhName: "俄文",        codes: ["ru-RU"]),
    ]

    public static func resolve(_ id: String) -> [String] {
        languages.first { $0.id == id }?.codes ?? ["en-US"]
    }

    public static func name(of id: String) -> String {
        languages.first { $0.id == id }?.name ?? id
    }

    /// 识别一页。accurate 模式 + 关闭语言纠正：扫描件上纠正反而会把专有名词改坏。
    public static func recognize(_ image: CGImage, langID: String) throws -> (lines: [OCRLine], text: String) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = resolve(langID)
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observations = request.results, !observations.isEmpty else {
            throw OCRError.noResult
        }
        var lines: [OCRLine] = []
        var all = ""
        for o in observations {
            guard let cand = o.topCandidates(1).first else { continue }
            let t = cand.string
            if t.isEmpty { continue }
            lines.append(OCRLine(text: t, rect: o.boundingBox))
            all += t + "\n"
        }
        return (lines, all)
    }
}
