// LumoCore — 文案与界面语言
//
// 为什么这条表放在 Core 而不是 App 里：
// OCR 语言名、增强模式名、流水线步骤说明、错误信息——这些**都是用户看得见的字**，
// 而它们产生在 Core 里。如果只在 App 侧翻译，英文界面下会漏一片中文
// （最典型的是语言下拉框里全是"中文 + 英文"这种）。
//
// 所以：Core 拥有自己这张表；App 在启动时把界面文案那张表挂到 `extra` 上。
// 查表顺序是 App 表 → Core 表 → 原样返回中文。两张表没有重叠的 key。
//
// 命令行工具（lumo-cli）不设置 `current`，所以它永远是中文——
// 它是给脚本用的，输出语言稳定比"跟着系统变"更重要。

import Foundation

public enum LumoTextLang: String, Sendable {
    case zh, en
}

public enum LumoText {
    /// 当前生效的语言。由 App 侧在启动/切换时写入；命令行不写，保持中文。
    nonisolated(unsafe) public static var current: LumoTextLang = .zh

    /// App 侧挂进来的界面文案表（见 LumoApp/Localization.swift）。
    nonisolated(unsafe) public static var extra: [String: String] = [:]

    /// 取文案。中文侧原样返回；英文侧查表，查不到**退回中文**——
    /// 漏翻的表现是"这一句还是中文"，不是一个空白或一串 key。
    public static func t(_ zh: String) -> String {
        guard current != .zh else { return zh }
        return extra[zh] ?? core[zh] ?? zh
    }

    /// Core 自己的英文表。key 是源码里的中文原文。
    static let core: [String: String] = [
        // ---- 增强模式 ----
        "自动增强": "Auto",
        "黑白": "Black & White",
        "增强": "Enhance",
        "对比度": "Contrast",
        "原图": "Original",
        "逐页判断：文字页走黑白，含图页保色彩":
            "Decided per page: text pages go monochrome, pages with images keep their colour",
        "只留纯黑与纯白，底灰、阴影、污渍全部清掉":
            "Pure black and white only — background grey, shadows and stains are all removed",
        "保留彩色与插图，清背景、校正光照、略提饱和":
            "Keeps colour and images; cleans the background, corrects lighting, lifts saturation a little",
        "仍保持原有色调，只把发灰、太淡的画面拉开反差":
            "Keeps the original tones, just adds contrast to flat, washed-out pages",
        "不做画面处理，只做识别与压缩": "No image processing — recognition and compression only",

        // ---- 体检指标 ----
        "彩色": "Colour",
        "灰阶": "Greyscale",
        "单色": "Monochrome",
        "低": "Low",
        "中": "Medium",
        "高": "High",
        "不匀": "Uneven",
        "均匀": "Even",

        // ---- OCR ----
        "未能识别出任何文字": "No text was recognised",
        "中文 + 英文": "Chinese + English",
        "中文简体": "Chinese (Simplified)",
        "中文繁体 + 英文": "Chinese (Traditional) + English",
        "英文": "English",
        "日文": "Japanese",
        "韩文": "Korean",
        "法文": "French",
        "德文": "German",
        "西班牙文": "Spanish",
        "意大利文": "Italian",
        "葡萄牙文": "Portuguese",
        "俄文": "Russian",

        // ---- 自动裁边的结论 ----
        "裁边：没检出页面边界，这一页保持原样":
            "Crop: no page boundary detected — this page is left as is",
        "裁边：检出的四边形畸变，已跳过（保持原样）":
            "Crop: the detected quad is distorted — skipped, left as is",
        "裁边：页面已铺满整幅（占比 %.0f%%），无需裁切":
            "Crop: the page already fills the frame (%.0f%%) — nothing to trim",
        "裁边：检出区域只占整幅 %.0f%%，疑似误检，已跳过":
            "Crop: the detected area covers only %.0f%% — looks like a false positive, skipped",
        "裁边：检出区域过于狭长，疑似误检，已跳过":
            "Crop: the detected area is too narrow — looks like a false positive, skipped",
        "裁边：判不出边界外侧的明暗，为稳妥起见已跳过":
            "Crop: can't tell how bright it is outside the boundary — skipped to be safe",
        "裁边：边界外侧依然是纸面（里 %.0f / 外 %.0f），判定为满幅扫描页，已跳过":
            "Crop: the area outside the boundary is still paper (%.0f inside / %.0f outside) — "
            + "treated as a full-page scan, skipped",
        "裁边：系统没有 CIPerspectiveCorrection，已跳过":
            "Crop: CIPerspectiveCorrection is unavailable on this system — skipped",
        "裁边：透视校正没有输出，已跳过":
            "Crop: perspective correction produced no output — skipped",
        "裁边：校正结果尺寸异常，已跳过":
            "Crop: the corrected result has an unexpected size — skipped",
        "，并修掉 %.1f%% 的残留纸边":
            ", and trimmed %.1f%% of leftover paper edge",
        "裁边：检出页面占比 %.0f%%，已裁到 %d×%d 并校正透视%@":
            "Crop: the page covered %.0f%% of the frame; cropped to %d×%d and corrected for perspective%@",
        "这一页体检判定为已经够干净：背景强度仍按设定应用，但视觉上可能看不出变化":
            "This page is already clean — the background strength is still applied, "
            + "but you may not see any difference",

        // ---- 编码器降级提示 ----
        "CCITT G4 编码不可用，已改用无损 Flate":
            "CCITT G4 is unavailable; fell back to lossless Flate",
        "JPEG2000 不可用，已改用 JPEG": "JPEG 2000 is unavailable; fell back to JPEG",
        "编码失败": "Encoding failed",

        // ---- 流水线 / 撰写器 ----
        "PDF 已经写完，不能再追加页面":
            "The PDF has already been finished; no more pages can be appended",
        "无法写入输出文件：%@": "Couldn't write the output file: %@",
        "写入的页数超出预期（声明 %@ 页，实际写了 %@ 页）":
            "More pages were written than expected (declared %@, wrote %@)",
        "无法打开 PDF：%@": "Couldn't open the PDF: %@",
        "页码范围没有选中任何页面": "The page range doesn't select any pages",
        "页面渲染失败，文件可能已损坏": "Rendering failed — the file may be damaged",
        "已选择 %@ 页": "Selected %@ page(s)",
        "处理中 %@/%@ 页": "Processing page %@ of %@",
        "第 %@ 页未识别出文字": "No text recognised on page %@",
        "第 %@ 页体检判定为已经够干净：背景强度照常按设定应用，但这几页视觉上可能看不出变化":
            "Page %@ is already clean — the background strength is still applied as set, "
            + "but these pages may show no visible change",
        "处理 %@ 页": "Processed %@ page(s)",
        "增强模式：%@": "Enhance mode: %@",
        "自动裁边 + 透视校正": "Auto crop + perspective correction",
        "纠偏": "Deskew",
        "背景去除": "Background removal",
        "去网纹": "Descreen",
        "文本锐化": "Text sharpening",
        "背景清理强度 %@%%": "Background strength %@%%",
        "OCR 识别（%@）": "OCR (%@)",
        "跳过 OCR": "OCR skipped",
        "自适应": "Adaptive",
        "压缩：%@ / %@+%@ / 质量%@": "Compression: %@ / %@+%@ / quality %@",
        "%@ 页启用分层（MRC）：文字 1bit 蒙版 + 低分辨率背景":
            "%@ page(s) use layered compression (MRC): 1-bit text mask + low-resolution background",

        // ---- 体检后的建议（工作流） ----
        "已检测到文字层 → 跳过 OCR，避免重复识别与伪影":
            "Existing text layer detected → OCR skipped, avoiding duplicate work and artefacts",
        "未发现文字层 → 建议 OCR 生成可搜索 PDF":
            "No text layer found → OCR recommended, to produce a searchable PDF",
        "彩色文档 → 增强（保住图表与印章，不做二值化）":
            "Colour document → Enhance (keeps charts and stamps, no binarisation)",
        "单色文档 → 黑白（局部自适应二值化，文字最锐利、体积最小）":
            "Monochrome document → Black & White (local adaptive binarisation: sharpest text, smallest file)",
        "灰阶文档 → 自动增强（逐页判断：文字页走黑白，含图页保层次）":
            "Greyscale document → Auto (decided per page: text pages go monochrome, image pages keep their tones)",
        "检测到倾斜 %.1f° → 启用纠偏": "Skew of %.1f° detected → deskew enabled",
        "背景明暗不匀 %.0f%% → 启用背景去除":
            "Background unevenness of %.0f%% → background removal enabled",
        "疑似半调网纹 → 启用去网纹": "Halftone screen suspected → descreen enabled",
        "轻度锐化以还原文字边缘": "Light sharpening to restore text edges",
        "彩色文档 → 自适应压缩（文字页转单色 CCITT，插图页走 JPEG）":
            "Colour document → adaptive compression (text pages to monochrome CCITT, image pages to JPEG)",
        "灰阶文档 → 自适应压缩（JPEG / CCITT）":
            "Greyscale document → adaptive compression (JPEG / CCITT)",
        "单色文档 → CCITT 组4 极限压缩":
            "Monochrome document → CCITT Group 4 maximum compression",
        "极限压缩": "Maximum compression",
        "文件最小，适合归档与传输": "Smallest file — best for archiving and sending",
        "均衡（推荐）": "Balanced (recommended)",
        "体积与清晰度平衡": "A balance between size and clarity",
        "高质量": "High quality",
        "最大限度保留细节，体积较大": "Keeps as much detail as possible; larger file",
    ]
}

/// 取当前语言的文案。Core 内部与 App 都用它。
public func T(_ zh: String) -> String { LumoText.t(zh) }

/// 带占位符的版本。
///
/// ⚠️ 用 `%@` 而**不是** `\( )` 插值：插值会把运行时的值拼进 key，
/// 于是英文表永远查不到，切了英文那句还是中文。占位符让 key 保持稳定。
///
/// ⚠️⚠️ 参数类型故意收成 `Any...` 而不是 `CVarArg...`，并且**统一转成字符串**再交给
/// `String(format:)`。这不是为了好看，是为了修一个**必崩**的 bug：
/// 表里统一用 `%@`，而 `%@` 只接受对象——原样把 `Int` 交给 `String(format:)`，
/// CFString 会把那个整数当成指针去解引用，**直接 SIGSEGV**
/// （实测：`T("%@ 页", pageCount)` 一载入文件就崩，栈顶是 `String(format:)`
/// 里的 `objc_opt_respondsToSelector`，崩在地址 0x3——正好是那个整数）。
///
/// 转成字符串之后，`%@` 与参数类型就**永远对得上**，无论传进来的是 Int、
/// Double、Substring 还是别的。代价只是多一次 `String(describing:)`，
/// 而这发生在拼一句话的时候，不在热路径上。
///
/// 因此：**表里的格式串只允许用 `%@` 和 `%%`**（不要 `%d` / `%.1f`），
/// `Scripts/check_localization.py` 会检查这一条。
public func T(_ zh: String, _ args: Any...) -> String {
    let fmt = LumoText.t(zh)
    guard !args.isEmpty else { return fmt }
    let strings = args.map { arg -> String in
        if let s = arg as? String { return s }
        return String(describing: arg)
    }
    return String(format: fmt, arguments: strings)
}
