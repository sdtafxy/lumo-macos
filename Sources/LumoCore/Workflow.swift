// Lumo 原生核心 —— 智能工作流推荐（Smart 引擎）
// 读懂体检报告后给出「该做什么、跳过什么」，并生成多档压缩方案供对比。
import Foundation

public enum Workflow {
    public static func recommend(_ a: Analysis) -> Recommendation {
        var notes: [String] = []
        let skew = abs(a.skewAngle)
        let noise = a.noiseLevel
        let uneven = a.bgUnevenness
        let color = a.colorMode
        let hasText = a.hasTextLayer

        // —— OCR ——
        let ocr: OCRSpec
        if hasText {
            ocr = OCRSpec(enabled: false, lang: "chi_sim+eng", output: "searchable", skip: true)
            notes.append(T("已检测到文字层 → 跳过 OCR，避免重复识别与伪影"))
        } else {
            ocr = OCRSpec(enabled: true, lang: "chi_sim+eng", output: "searchable", skip: false)
            notes.append(T("未发现文字层 → 建议 OCR 生成可搜索 PDF"))
        }

        // —— 增强 ——
        // 先定「模式」再谈滤镜：用户看到的是效果（黑白 / 增强 / 对比度），
        // 不是「背景去除 + 去网纹 + 锐化」这种只有工程师才读得懂的组合。
        // 彩色文档一律走增强档——因为二值化会把图表、印章、照片一起毁掉，
        // 而这类损失是不可逆的；宁可体积大一点。灰阶文档交给逐页自动判断。
        let preset: EnhancePreset = (color == "color") ? .color : (color == "mono" ? .bw : .auto)
        let needBG = uneven > 0.12
        // 背景清理强度按"这片纸到底有多脏"给一个起点，而不是一律同一个值。
        // 两个指标各自捕捉一种脏：不匀度管阴影/光照渐变，纸白管均匀的灰（偏黄、发灰）。
        // 取两者里更需要清理的那个——用户拿到滑块时起点就是接近合适的，不用自己试。
        let strength = bgStrengthSuggestion(uneven: uneven, paperWhite: a.paperWhite)
        let enhance = EnhanceSpec(preset: preset.rawValue,
                                  deskew: skew > 1.0,
                                  bgRemove: needBG,
                                  descreen: noise > 0.5,
                                  // 黑白档不需要锐化：二值化的输出只有 0 和 255，
                                  // 非锐化掩膜在纯黑白上只会让笔画边缘长出灰边（反而变糊）。
                                  // 其余档才吃锐化。
                                  sharpen: preset.usesBgStrength ? 1.0 : 0,
                                  bgStrength: strength)
        switch preset {
        case .color:
            notes.append(T("彩色文档 → 增强（保住图表与印章，不做二值化）"))
        case .bw:
            notes.append(T("单色文档 → 黑白（局部自适应二值化，文字最锐利、体积最小）"))
        default:
            notes.append(T("灰阶文档 → 自动增强（逐页判断：文字页走黑白，含图页保层次）"))
        }
        if skew > 1.0 { notes.append(String(format: T("检测到倾斜 %.1f° → 启用纠偏"), skew)) }
        if needBG {
            notes.append(String(format: T("背景明暗不匀 %.0f%% → 启用背景去除"), uneven * 100))
        }
        if noise > 0.5 { notes.append(T("疑似半调网纹 → 启用去网纹")) }
        notes.append(T("轻度锐化以还原文字边缘"))

        // —— 压缩 ——
        let compress: CompressSpec
        switch color {
        case "color":
            compress = CompressSpec(adaptive: true, colorMode: "auto",
                                    colorEncoder: "jp2", monoEncoder: "ccitt", quality: 72)
            notes.append(T("彩色文档 → 自适应压缩（文字页转单色 CCITT，插图页走 JPEG2000）"))
        case "gray":
            compress = CompressSpec(adaptive: true, colorMode: "auto",
                                    colorEncoder: "jpeg", monoEncoder: "ccitt", quality: 70)
            notes.append(T("灰阶文档 → 自适应压缩（JPEG / CCITT）"))
        default:
            compress = CompressSpec(adaptive: false, colorMode: "mono",
                                    colorEncoder: "jpeg", monoEncoder: "ccitt", quality: 70)
            notes.append(T("单色文档 → CCITT 组4 极限压缩"))
        }

        return Recommendation(pages: "all", enhance: enhance, ocr: ocr,
                              compress: compress, notes: notes)
    }

    /// 背景清理强度推荐值（0~1）。
    ///
    /// 两个指标各管一种脏，取更需要清理的那个：
    /// · **不匀度** → 阴影 / 光照渐变。0.05 起算，0.20 以上算"明显有阴影"。
    /// · **纸白** → 均匀的灰。250 以上基本不用清，240 以下算明显灰底。
    ///
    /// 斜率是拿示例件三页（纸白 236 / 240 / 188，不匀 0.104 / 0.073 / 0.189）
    /// 反推的，并且刻意**压在上限 0.7 以内**：实测 0.5 就已经是"干净但不抹平"
    /// 的甜点，0.75 往上开始在抹掉纸张层次。把推荐值留在 0.5~0.7 区间，
    /// 用户想更狠再自己拉——推荐值的职责是"起点合适"，不是"替你拉满"。
    static func bgStrengthSuggestion(uneven: Double, paperWhite: Double) -> Double {
        let fromUneven = max(0, min(1, (uneven - 0.05) / 0.15)) * 0.55
        let fromPaper = max(0, min(1, (250.0 - paperWhite) / 14.0)) * 0.70
        return max(0, min(1, max(fromUneven, fromPaper)))
    }

    public static func definePlans(_ a: Analysis) -> [Plan] {
        let color = a.colorMode
        return [
            Plan(id: "extreme", name: T("极限压缩"), desc: T("文件最小，适合归档与传输"),
                 settings: PlanSettings(adaptive: true, colorMode: "auto",
                                        colorEncoder: "jpeg", monoEncoder: "ccitt", quality: 50)),
            Plan(id: "balanced", name: T("均衡（推荐）"), desc: T("体积与清晰度平衡"),
                 settings: PlanSettings(adaptive: true, colorMode: "auto",
                                        colorEncoder: color == "color" ? "jp2" : "jpeg",
                                        monoEncoder: "ccitt", quality: 72),
                 recommended: true),
            Plan(id: "high", name: T("高质量"), desc: T("最大限度保留细节，体积较大"),
                 settings: PlanSettings(adaptive: false, colorMode: color,
                                        colorEncoder: "jp2", monoEncoder: "ccitt", quality: 90)),
        ]
    }
}
