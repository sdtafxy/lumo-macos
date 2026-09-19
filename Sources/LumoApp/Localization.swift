// Lumo — 界面语言
//
// 三条取舍，都不显然，先写在这里：
//
// ① **不引入 .lproj / NSLocalizedString。**
//    本项目的 .app 是手工组装的（Scripts/build.sh 拷 Resources 再签名），
//    没有走 SwiftPM 资源包那条链路。引 .lproj 就要动打包脚本、还要在 CI 上
//    再加一条"资源到底有没有拷进包里"的断言——而我们要的只有两种语言。
//
// ② **中文侧不维护副本，只维护一张英文表。**
//    源码里的中文原文就是 key（`T("添加 PDF")`）。中文界面下原样返回；
//    英文界面下查表，查不到退回中文——所以"漏翻"的表现是"这一句还是中文"，
//    不会是空白或一串 key。代价是英文侧可能悄悄漏翻，所以有
//    `Scripts/check_localization.py` 在 CI 里把每个用到的 key 都核一遍。
//
// ③ **语言变了就重建界面，而不是让每个 View 各自订阅。**
//    界面语言是全局的、极少改的东西。让十几个 View 各自 `@Environment` 订阅，
//    很容易漏掉一两个——而"切了英文但某处还是中文"这种瑕疵，不看根本发现不了。
//    所以三个界面入口（主窗口 / 设置窗口 / 阅读器）在语言变化时把内容整棵重建一次。
//    代价是丢一点瞬时视图状态（悬停、滚动位置），可以接受。
//
// 翻译表本身在文件末尾，分「主界面 / 设置 / 更新 / 通用」四块。

import Foundation
import LumoCore

/// 界面语言。默认跟随系统。
enum LumoLanguage: String, CaseIterable, Identifiable {
    case system, zh, en

    var id: String { rawValue }

    /// 设置页里的显示名。
    /// **三项按各自的写法显示，不随界面语言变**——把 "English" 翻成"英语"
    /// 反而让人认不出来；"跟随系统"这种就中英并排写。
    /// 设置页里的显示名。
    ///
    /// **语言自称不翻译**（"简体中文" 和 "English" 各自那个样子，翻成"Chinese"反而更难认），
    /// 但"跟随系统"是一个界面概念、不是语言名，所以它跟着界面语言走。
    /// 另外它要放进分段控件，所以都得短。
    var title: String {
        switch self {
        case .system: return T("跟随系统")
        case .zh:     return "简体中文"
        case .en:     return "English"
        }
    }
}

/// 语言状态的唯一出处。改 `choice` 会立刻持久化、重新解析，并让界面重建。
@MainActor
final class LumoLanguageStore: ObservableObject {
    static let shared = LumoLanguageStore()
    private static let key = "LumoLanguage"

    /// 用户在设置里选的那一项（可能是"跟随系统"）
    @Published var choice: LumoLanguage {
        didSet {
            UserDefaults.standard.set(choice.rawValue, forKey: Self.key)
            apply()
        }
    }

    /// 真正生效的语言（把 `system` 解析掉之后）。界面按它重建。
    @Published private(set) var resolved: LumoLanguage = .zh

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.key) ?? ""
        choice = LumoLanguage(rawValue: saved) ?? .system
        apply()
    }

    private func apply() {
        resolved = Self.resolve(choice)
        LumoText.current = (resolved == .en) ? .en : .zh
        // 界面文案那张表挂进 Core 的查表链（先查 App 表，再查 Core 表）。
        LumoText.extra = LumoAppText.en
    }

    /// 「跟随系统」的含义：系统首选语言是中文 → 中文，其余一律英文。
    ///
    /// 用 `Locale.preferredLanguages`（用户在"语言与地区"里排的顺序），
    /// 而不是 `Locale.current`：后者对"这个应用支持哪些语言"一无所知，
    /// 只看区域设置，在"系统语言是英文但区域选了中国"的机器上会判错。
    static func resolve(_ c: LumoLanguage) -> LumoLanguage {
        switch c {
        case .zh, .en:
            return c
        case .system:
            let pref = Locale.preferredLanguages.first ?? "en"
            return pref.hasPrefix("zh") ? .zh : .en
        }
    }
}

/// 界面文案的英文表。key 是源码里的中文原文（**改了中文要同步改这里**）。
enum LumoAppText {
    static let en: [String: String] = [
        // ==================== 品牌 ====================
        "流明": "Lumo",
        "扫描件焕新": "Scans, refreshed",
        "流明 · 扫描件焕新": "Lumo · Scans, refreshed",

        // ==================== 主界面 ====================
        "拖入 PDF 文件开始处理": "Drop a PDF file to start",
        "添加 PDF": "Add PDF",
        "换一个文件": "Choose another file",
        "清空": "Clear",
        "清空当前文件": "Clear the current file",
        "保存到…": "Save to…",
        "在访达中显示": "Show in Finder",
        "开始处理": "Start",
        "处理中…": "Working…",
        "再处理一次": "Run again",
        "正在体检…": "Analysing…",
        "正在分析文件体质…": "Analysing the file…",
        "正在处理…": "Working…",
        "选择要处理的 PDF（也可以拖进来，或按 ⌘O）":
            "Choose a PDF to process (or drag one in, or press ⌘O)",
        "回到空态，当前文件与结果都会清掉":
            "Back to the start — the current file and result will be cleared",
        "重新体检这个文件": "Re-analyse this file",
        "载入示例扫描件": "Open the sample scan",
        "查看设计文档": "Read the design document",
        "查看示例扫描件": "View the sample scan",
        "设置（⌘,）": "Settings (⌘,)",
        "引擎就绪": "Engine ready",
        "引擎就绪 · 处理全部在本机完成": "Engine ready · everything runs on this Mac",
        "只认 PDF。拖进来的是别的类型，或者不是本机文件。":
            "PDF only — that was another file type, or not a local file.",
        "跳过 OCR": "OCR skipped",
        "新版本已下载并校验完成，去设置里重启更新":
            "The new version is downloaded and verified — restart from Settings to update",

        // ==================== 工作区 ====================
        "效果预览": "Preview",
        "生成预览": "Generate preview",
        "刷新预览": "Refresh preview",
        "载入后自动生成预览": "Build a preview automatically after loading",
        "关掉后需要手动点「刷新预览」。批量处理很多文件时关掉它更省事。":
            "When off, use “Refresh preview” manually. Handy when processing many files in a row.",
        "处理后": "After",
        "上一页": "Previous page",
        "下一页": "Next page",
        "输入页码后回车跳转": "Type a page number and press Return to jump",
        "这一页渲染不出来（文件可能已损坏）":
            "This page can't be rendered — the file may be damaged",

        "体检报告": "Report",
        "扫描增强": "Scan enhancement",
        "文本识别": "Text recognition",
        "智能压缩": "Smart compression",
        "处理完成": "Done",
        "微调": "Fine-tuning",
        "只在少数文件上才需要": "Only needed for some files",
        "高级选项": "Advanced",
        "输出": "Output",
        "推荐": "Recommended",

        "自动裁边": "Auto crop",
        "裁到纸张边缘，校正透视": "Trim to the paper edge and correct perspective",
        "纠偏": "Deskew",
        "自动旋转回正": "Straighten automatically",
        "去网纹": "Descreen",
        "消去印刷网点": "Remove the printed halftone pattern",
        "文本锐化": "Sharpen text",
        "非锐化掩膜": "Unsharp mask",
        "背景清理": "Background cleanup",
        "轻度清理": "Light cleanup",
        "保留纸张质感": "Keep the paper texture",

        "色彩": "Colour",
        "分辨率": "Resolution",
        "倾斜": "Skew",
        "背景": "Background",
        "干净": "Clean",
        "很干净（接近纯白）": "Very clean (nearly pure white)",
        "原始": "Original",
        "自动": "Auto",

        "作用范围": "Page range",
        "全部页面": "All pages",
        "当前页": "Current page",
        "指定范围": "Custom range",
        "例如 1-3,5": "e.g. 1-3,5",

        "彩色 / 灰度编码": "Colour / greyscale codec",
        "单色编码": "Monochrome codec",
        "CCITT 组4": "CCITT Group 4",
        "ZIP 无损": "ZIP (lossless)",
        "自适应压缩（按页选最省编码）": "Adaptive (pick the smallest codec per page)",
        "原图": "Original",
        "压缩": "Compression",
        "体积已预估": "Size estimated",
        "自动读出来的，不用你填": "Read automatically — nothing to fill in",
        "选一种效果，左边的预览会按这一页实时算":
            "Pick an effect — the preview on the left recalculates for this page",
        "语言与输出方式在设置里（⌘,）": "Language and output options are in Settings (⌘,)",
        "已跳过（文件自带文字层）": "Skipped (the file already has a text layer)",
        "生成可搜索 PDF": "Create a searchable PDF",

        // ==================== 设置 ====================
        "Lumo 设置": "Lumo Settings",
        "外观": "Appearance",
        "偏好": "Preferences",
        "主界面": "General",
        "识别": "Recognition",
        "存储": "Storage",
        "更新": "Updates",
        "关于": "About",
        "窗口": "Window",

        "界面语言": "Language",
        "外观模式": "Appearance",
        "玻璃质感": "Glass",
        "不透明": "Opaque",
        "玻璃": "Glass",
        "通透": "Clear",
        "内容完全不透明，可读性最好": "Fully opaque content — the most readable",
        "控件层有玻璃，内容层留一点底色":
            "Glass on the chrome; the content area keeps a little colour underneath",
        "整窗透出桌面，最接近系统原生观感":
            "The desktop shows through the whole window — closest to the system look",
        "深浅两套是独立设计的，不是把颜色反过来":
            "Light and dark are designed separately, not inverted from each other",
        "控件层用系统材质、内容层留出底色。点一下立刻生效":
            "System materials on the chrome, a tinted base under the content. Takes effect immediately",
        "深色": "Dark",
        "浅色": "Light",
        "跟随系统": "Follow the system",
        "动效": "Motion",
        "遵循「减弱动态效果」": "Respect “Reduce Motion”",
        "在系统设置里开启后，本应用的转场会变成瞬时切换。":
            "When enabled in System Settings, transitions here become instant.",
        "记住窗口大小与位置": "Remember window size and position",
        "载入文件后自动生成预览": "Build a preview automatically after loading",

        "文本识别默认值": "Recognition defaults",
        "文档语言": "Document language",
        "输出方式": "Output",
        "可搜索图像": "Searchable image",
        "可编辑文本": "Editable text",
        "这些是「新文件」的默认值；单个文件的语言可以在主界面里改":
            "These apply to new files; you can change the language for the current file on the main screen",

        "预览缓存": "Preview cache",
        "当前占用": "Currently using",
        "清理": "Clean up",
        "只清预览图；处理产物不会被清掉":
            "Clears preview images only — your processed output is not touched",
        "处理产物所在的目录由系统管理，退出 App 后会被回收。":
            "The folder for processed output is managed by the system and reclaimed after you quit.",
        "「没保存的产物」不会被当成可清理的东西删掉——那是你还没拿走的东西，":
            "Output you haven't saved is never treated as “cleanable” — ",
        "把它算进「缓存」里就成了陷阱。":
            "counting it as cache would be a trap.",
        "恢复默认": "Restore defaults",
        "恢复默认设置": "Restore default settings",
        "恢复默认设置？": "Restore default settings?",
        "只重置识别默认值与载入行为，不会动你的文件。":
            "This only resets recognition defaults and load behaviour — your files are untouched.",

        "内置文档": "Built-in documents",
        "随 App 一起打包，不用联网、不用另找素材":
            "Bundled with the app — no download, no sample files to hunt for",
        "零第三方依赖：仅使用 CoreGraphics / Core Image / Vision / ImageIO / PDFKit / zlib。\n":
            "No third-party dependencies: CoreGraphics / Core Image / Vision / ImageIO / PDFKit / zlib only.\n",

        // ==================== 更新 ====================
        "更新方式": "How Lumo updates",
        "自动检查更新": "Check for updates automatically",
        "启动约 10 秒后检查一次，之后每天一次。":
            "Checks once about 10 seconds after launch, then once a day.",
        "自动下载并安装": "Download and install automatically",
        "会退出并重启 App，所以默认关闭——那是要你点头的事。":
            "Quits and reopens the app, so it's off by default — that's your call to make.",
        "状态": "Status",
        "正在检查…": "Checking…",
        "立即检查": "Check now",
        "待检查": "Not checked yet",
        "当前版本": "Current version",
        "可以点上面的「立即检查」重试": "Use “Check now” above to try again",
        "跳过这个版本": "Skip this version",
        "重启并更新": "Restart and update",
        "现在重启并更新？": "Restart and update now?",
        "Lumo 会退出，由后台助手替换应用包，然后自动重新打开。你已经打开的文件不受影响。":
            "Lumo will quit, a background helper will swap the app bundle, and it will reopen. "
            + "Files you have open are not affected.",
        "正在替换应用包…": "Replacing the app bundle…",
        "查看更新日志": "Open the update log",
        "更新源": "Update source",
        "更新是唯一的联网功能，且只访问更新源。":
            "Updating is the only thing that uses the network, and it only contacts the update source.",
        "关掉「自动检查更新」后，Lumo 一行网络请求都不会发。":
            "Turn off “Check for updates automatically” and Lumo sends no requests at all.",
        "Lumo 唯一的联网功能就是这里": "The only network access in Lumo happens right here",
        "，或到 Releases 手动下载。": ", or download it manually from Releases.",
        "手动下载": "Download manually",

        // ==================== 错误与提示 ====================
        "好": "OK",
        "取消": "Cancel",
        "没找到内置示例（安装包可能不完整）":
            "The built-in sample is missing (the app bundle may be incomplete)",
        "产物文件已经不在临时目录里了，请重新处理一次。":
            "The output file is no longer in the temporary folder — please run it again.",
        "剪贴板里没有 PDF。可以复制一个 PDF 文件，或复制它的完整路径再试。":
            "No PDF on the clipboard. Copy a PDF file, or copy its full path and try again.",
        "从剪贴板打开": "Open from clipboard",

        "下载到 0 字节": "The download was 0 bytes",
        "还没有下载好的更新包": "No update has been downloaded yet",
        "更新源的返回看不懂（可能接口变了）":
            "Couldn't make sense of the update source's response (the API may have changed)",
        "客户端拿不到发布信息。": "the client can't read release information.",
        "自动更新需要「公开」的仓库——私有的仓库不允许匿名读取，":
            "Automatic updates need a public repository — private ones can't be read anonymously, ",
        "访问 GitHub 太频繁被限流了。过一会儿再试，或到 Releases 页面手动下载。":
            "GitHub is rate-limiting us. Try again in a while, or download from the Releases page.",
        "签名校验失败——包的内容和签名对不上，已拒绝安装":
            "Signature check failed — the package doesn't match its signature, so the install was refused",
        "这个发布没有任何校验信息，已拒绝安装":
            "This release carries no verification data at all, so the install was refused",

        "解压结果里没有 .app": "The extracted archive contains no .app",
        "解出来的东西不是 macOS App 包（没有 Info.plist）":
            "What came out isn't a macOS app bundle (no Info.plist)",
        "包里没有版本号": "The package has no version number",


        // ==================== 带占位符的（%@ 配 T("…", 值) 用）====================
        // ⚠️ 这些 key 在源码里是 `T("…%@…", 值)` 的形式，**不要**改回 \( ) 插值——
        //    插值会把运行时的值拼进 key，英文表就永远查不到了。
        "%@ 页": "%@ pages",
        "%@ 页 · %@ · %@ · %@ DPI": "%@ pages · %@ · %@ · %@ DPI",
        "%@ 已就绪": "%@ ready",
        "%@ 这个发布里没有可用的安装包（.zip）": "Release %@ has no usable package (.zip)",
        "/ %@ 页": "/ %@",
        "上次检查：%@": "Last checked: %@",
        "尚未检查过": "Not checked yet",
        "下载中 %@%%": "Downloading %@%%",
        "正在下载… %@%%": "Downloading… %@%%",
        "增强 %@ 项": "%@ enhancements",
        "已是最新版本（%@）": "Up to date (%@)",
        "ditto 退出码 %@": "ditto exited with code %@",
        "发现新版本 %@": "Version %@ is available",
        "发现新版本 %@，去设置里查看": "Version %@ is available — open Settings to see it",
        "包标识是 %@，不是 %@": "The bundle identifier is %@, not %@",
        "包里的版本是 %@，与预期的 %@ 不符": "The package contains version %@, but %@ was expected",
        "预计输出 %@": "Estimated output %@",
        "更新源 %@ 不可访问（多半是私有仓库，或仓库名写错了）。":
            "The update source %@ can't be read (most likely a private repository, a typo in the name, "
            + "or the repository has no releases yet).",
        "更新助手脚本没能通过语法检查，这次更新已中止（App 保持原样）：%@":
            "The update helper script failed its syntax check, so this update was aborted "
            + "(the app is unchanged): %@",
        "关于更新": "About updates",
        "安装包 %@": "Package %@",
        "%@ 已就绪，重启即可完成更新": "%@ is ready — restart to finish updating",
        "这个安装包缺少必要的签名文件，已拒绝安装。":
            "This package is missing a required signature, so it was not installed.",
        "更新源地址不合法：%@（应形如 owner/repo）":
            "The update source is malformed: %@ (expected owner/repo)",
        "更新源返回 HTTP %@": "The update source returned HTTP %@",
        "有新版 %@": "Version %@ available",
        "校验和不符（期望 %@…，实际 %@…），包可能在传输中损坏":
            "Checksum mismatch (expected %@…, got %@…) — the package may have been damaged in transit",
        "没找到内置的「%@」（安装包可能不完整）":
            "The built-in “%@” is missing (the app bundle may be incomplete)",
        "没能打开这个文件：%@": "Couldn't open this file: %@",
        "没有权限替换 %@。把 App 拖到「应用程序」文件夹，或手动下载新版安装。":
            "No permission to replace %@. Move the app into your Applications folder, "
            + "or download the new version manually.",
        "版本 %@": "Version %@",
        "版本号无法识别（包里 %@，期望 %@）":
            "Couldn't read the version number (package has %@, expected %@)",
        "第 %@ 页": "Page %@",
        "质量 %@": "Quality %@",
        "保存失败：%@": "Couldn't save: %@",
        "OCR %@ · %@ 字 · %@s": "OCR %@ · %@ chars · %@s",
        "解压失败：%@": "Couldn't unpack: %@",
        "解出来的包不对：%@": "The unpacked bundle is wrong: %@",
        "无": "none",

        // ---- 应用内阅读器 ----
        "关闭阅读器": "Close reader",
        "在预览中打开": "Open in Preview",
        "放大": "Zoom in",
        "缩小": "Zoom out",
        "当前：实际大小": "Now: actual size",
        "当前：适应宽度": "Now: fit width",
        "用内置阅读器打开": "Open in the built-in reader",
        "本机文件": "Local file",
        "随 App 打包": "Bundled with the app",
        "示例扫描件": "Sample scan",
        "设计文档": "Design document",

        // ---- 菜单 ----
        "打开…": "Open…",
        "设置…": "Settings…",
        "检查更新": "Check for updates",

        // ---- 设置里的杂项 ----
        "默认跟随系统。改完立刻生效，不用重启。":
            "Follows the system by default. Takes effect immediately — no restart.",
        "识别在本机完成，不上传任何内容。":
            "Recognition runs on this Mac; nothing is uploaded.",

    ]
}

// 界面里到处用 `T(...)`（定义在 LumoCore/Localization.swift），
// 命名的取舍见那个文件头：它出现在每一行有文字的代码里，长名字会把信息淹掉。
