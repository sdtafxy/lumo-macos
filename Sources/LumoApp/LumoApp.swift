// Lumo — macOS App 入口
//
// 单窗口架构（参考 §4）：主窗口承载全流程，设置走我们自建的窗口（⌘,）。
//
// ⚠️ 这个文件里有**三处是踩过坑才写对的**，改动前先读注释：
//   ① AppDelegate.applicationShouldTerminate —— 自更新器最致命的死锁就在这（手册 P5）
//   ② 保留 Cmd+N —— 删掉它会让"关窗后点 Dock 图标"失效
//   ③ applicationShouldHandleReopen **不许**再用 NSDocumentController.newDocument
//      —— 就是它弹的「未能创建文稿」

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LumoCore

// MARK: - 应用状态

@MainActor
final class AppState: ObservableObject {
    enum Stage: Int { case drop = 0, workflow = 1, result = 2 }

    @Published var stage: Stage = .drop
    @Published var fileURL: URL?
    @Published var report: ReportResponse?
    @Published var langs: [String] = []
    @Published var filters = EnhanceSpec()
    /// 增强模式：与 filters.preset 同步，单独存一份是为了让 UI 绑定不必碰 Optional
    @Published var preset: String = EnhancePreset.auto.rawValue
    /// 背景清理强度（滑块，0~1）。拖动时不会每帧重算，见 schedulePreview 的防抖说明。
    @Published var bgStrength: Double = 0.5
    @Published var previewPage = 1
    @Published var previewBefore: NSImage?
    @Published var previewAfter: NSImage?
    @Published var previewBusy = false
    @Published var previewNote: String?
    /// 预览的过程说明（裁边结论、"这一页已经够干净"）。与 previewNote 分开：
    /// 那个是错误（渲染失败），这个是解释，不该用警告色去吓人。
    @Published var previewHint: String?
    /// 滑块防抖任务：每次新改动取消上一个，只有停手一小会儿才真的去渲染
    private var previewDebounce: Task<Void, Never>?
    @Published var ocrEnabled = true
    @Published var ocrLang = "eng"
    @Published var ocrOutput = "searchable"
    @Published var pageScope = "all"          // all | current | range
    @Published var pageRange = ""
    @Published var planId = "balanced"
    @Published var adaptive = true
    @Published var colorEncoder = "jpeg"
    @Published var monoEncoder = "ccitt"
    @Published var quality: Double = 72
    @Published var result: ProcessResponse?
    @Published var busy = false
    @Published var busyText = ""
    @Published var progress: Double = 0
    @Published var errorMessage: String?

    var activeFilters: [String] {
        var s: [String] = [EnhancePreset(preset).title]
        // 顺序照流水线里的实际执行顺序写：裁边在最前（它改变几何），
        // 后面几步都建立在"画面上只有纸"这个前提上。
        if filters.autoCrop == true { s.append(T("自动裁边")) }
        if filters.deskew == true { s.append(T("纠偏")) }
        if filters.descreen == true { s.append(T("去网纹")) }
        if (filters.sharpen ?? 0) > 0 { s.append(T("文本锐化")) }
        return s
    }

    func apply(_ r: ReportResponse) {
        report = r
        filters = r.recommendation.enhance
        // 推荐里带了模式就直接用；没有（例如旧版缓存）就按体检出的色彩模式反推一个
        preset = r.recommendation.enhance.preset ?? fallbackPreset(r.analysis.colorMode)
        // 体检给出的强度起点直接填进滑块：用户一进来就是接近合适的值，不用自己试。
        bgStrength = r.recommendation.enhance.bgStrength ?? Enhance.defaultStrength
        previewPage = 1
        previewBefore = nil
        previewAfter = nil
        ocrEnabled = r.recommendation.ocr.enabled && !r.recommendation.ocr.skip
        ocrLang = r.recommendation.ocr.lang
        if let rec = r.plans.first(where: { $0.recommended == true }) ?? r.plans.first {
            planId = rec.id
            adoptPlan(rec)
        }
        stage = .workflow
    }

    /// 体检没给模式时的兜底：单色 → 黑白，彩色 → 增强，其余自动
    private func fallbackPreset(_ colorMode: String) -> String {
        switch colorMode {
        case "mono": return EnhancePreset.bw.rawValue
        case "color": return EnhancePreset.color.rawValue
        default: return EnhancePreset.auto.rawValue
        }
    }

    /// 生成当前页的处理前/后预览。
    /// 刻意不做成 onChange 自动触发：300dpi 的整页渲染是实打实的 CPU 活，
    /// 让用户点一下「刷新」或换模式时再算，界面才不会在拖动滑块时卡住。
    func refreshPreview(backend: LumoBackend) async {
        guard let url = fileURL else { return }
        previewBusy = true
        defer { previewBusy = false }
        filters.preset = preset
        filters.bgStrength = bgStrength
        do {
            guard let pair = try await backend.preview(fileURL: url, page: previewPage,
                                                       spec: filters) else {
                previewNote = T("这一页渲染不出来（文件可能已损坏）")
                previewHint = nil
                return
            }
            previewBefore = NSImage(data: pair.before)
            previewAfter = NSImage(data: pair.after)
            previewNote = nil
            // 过程说明单独占一行：裁边动了什么手、这一页是不是本来就够干净。
            // 后者是 L4 的收尾——滑块在干净页上确实看不出变化，
            // 但用户必须知道原因，否则他只会得出"这个控件坏了"的结论。
            previewHint = pair.notes.isEmpty ? nil : pair.notes.joined(separator: "；")
        } catch {
            previewNote = error.localizedDescription
            previewHint = nil
        }
    }

    /// 滑块专用：停手 400ms 再渲染。
    ///
    /// 为什么不直接在 onChange 里调 refreshPreview：整页渲染 + 增强是几百毫秒级的
    /// CPU 活，跟着拖动每帧算一次会让滑块本身卡成幻灯片——而这恰恰是最需要顺滑的地方。
    /// 400ms 是试出来的：比手抖的间隔长，比"觉得它没反应"的忍耐度短。
    func schedulePreview(backend: LumoBackend) {
        previewDebounce?.cancel()
        previewDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await refreshPreview(backend: backend)
        }
    }

    func adoptPlan(_ p: Plan) {
        adaptive = p.settings.adaptive
        colorEncoder = p.settings.colorEncoder
        monoEncoder = p.settings.monoEncoder
        quality = Double(p.settings.quality)
    }

    /// 丢掉当前文件，回到「选择文件」这一步。
    ///
    /// 为什么必须有一个显式的重置动作：载入文件后 stage 会切到 .workflow，
    /// 而选择文件的那个界面只在 .drop 阶段存在——
    /// 也就是说**一旦选了文件，界面上就再没有任何入口能换一个**，
    /// 只能退出 App 重开。
    ///
    /// 重置要连同报告、预览图、处理结果、错误提示一起清干净：
    /// 只把 stage 改回 .drop 的话，再选一个文件时旧报告会短暂闪一下，
    /// 预览图也可能残留上一个文件的内容——那比"退不回去"更让人困惑。
    func resetToPicker() {
        previewDebounce?.cancel()
        previewDebounce = nil
        stage = .drop
        fileURL = nil
        report = nil
        result = nil
        previewBefore = nil
        previewAfter = nil
        previewNote = nil
        previewHint = nil
        previewPage = 1
        previewBusy = false
        busy = false
        busyText = ""
        progress = 0
        errorMessage = nil
        pageScope = "all"
        pageRange = ""
        langs = []
    }

    var selectedPlan: Plan? { report?.plans.first { $0.id == planId } }

    /// 载入文件并触发体检（感知入口）
    func load(url: URL, backend: LumoBackend) async {
        // 文件选择器给的是安全作用域 URL；这里开启访问，处理阶段还要再读一次
        _ = url.startAccessingSecurityScopedResource()
        fileURL = url
        busy = true
        progress = 0
        busyText = T("正在分析文件体质…")
        defer { busy = false }
        do {
            let r = try await backend.analyze(fileURL: url)
            apply(r)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        // ★ 载入完**立刻**把第一页预览算出来。
        //
        // 参考文档 §5 Level 2 那一条：「参数改动即时可见结果（预览/试跑），
        // 而不是先提交再看」。以前这里要用户自己点一下「生成预览」——
        // 那就是"先提交再看"，而且空着两块大灰框会让人以为功能坏了。
        //
        // 现在这一步可以由用户在设置里关掉：批量处理几十份文件的人
        // 会希望自己控制节奏（`LumoPreferences.autoPreviewOnLoad`）。
        if LumoPreferences.shared.autoPreviewOnLoad {
            await refreshPreview(backend: backend)
        }
    }

    func buildSpec() -> ProcessSpec {
        var pages = pageScope
        if pageScope == "range" { pages = pageRange.isEmpty ? "all" : pageRange }
        if pageScope == "current" { pages = "1" }
        var enh = filters
        enh.preset = preset
        return ProcessSpec(
            pages: pages,
            enhance: enh,
            ocr: OCRSpec(enabled: ocrEnabled, lang: ocrLang, output: ocrOutput,
                         skip: report?.recommendation.ocr.skip ?? false),
            compress: CompressSpec(adaptive: adaptive,
                                   colorMode: selectedPlan?.settings.colorMode ?? "auto",
                                   colorEncoder: colorEncoder,
                                   monoEncoder: monoEncoder,
                                   quality: Int(quality)),
            procDpi: report?.procDpi
        )
    }
}

// MARK: - 动作

extension AppState {

    /// 底栏那个主按钮走这里。
    /// 做成"请求"而不是直接 await，是为了让按钮的 action 保持同步签名
    /// （SwiftUI 的 Button action 不是 async），同时把"谁在跑"这件事
    /// 统一记在 state 上，避免两处都能发起处理。
    func requestRun(backend: LumoBackend) {
        guard !busy else { return }
        Task { @MainActor in await run(backend: backend) }
    }

    private func run(backend: LumoBackend) async {
        guard let url = fileURL else { return }
        busy = true
        progress = 0
        busyText = T("正在处理…")
        defer { busy = false }
        do {
            let res = try await backend.process(fileURL: url, spec: buildSpec()) { p, t in
                self.progress = p
                self.busyText = t
            }
            result = res
            stage = .result
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestSave(_ r: ProcessResponse) {
        Task { @MainActor in await save(r) }
    }

    /// 产物本来就在本机磁盘上，直接复制即可——不需要再走一次网络下载
    private func save(_ r: ProcessResponse) async {
        let src = URL(fileURLWithPath: r.outPath)
        guard FileManager.default.fileExists(atPath: src.path) else {
            errorMessage = T("产物文件已经不在临时目录里了，请重新处理一次。")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = src.lastPathComponent
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: src, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            errorMessage = T("保存失败：%@", error.localizedDescription)
        }
    }
}

// MARK: - App

@main
struct LumoMacApp: App {
    // 三个全局对象都是单例：引擎无状态、更新服务**必须只有一份**
    // （两份会有两个定时器同时打 GitHub），主题与偏好同理。
    private let backend = LumoBackend.shared
    private let updates = UpdateService.shared
    private let theme = LumoTheme.shared
    private let prefs = LumoPreferences.shared

    /// 供 AppDelegate 在「点 Dock 图标」时把窗口叫回来
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // ★★ `Window` 而**不是** `WindowGroup` —— 这是"点 Dock 图标会多出一个窗口"的根因修法。
        //
        // 差别不是风格问题：`WindowGroup` 表示"**可以有很多个**同类型的窗口"，
        // 于是它的场景机制在某些时刻会主动补一个窗口出来。诊断日志（关窗 → 点 Dock 图标）：
        //
        //     DIAG windowShouldClose 被调用 → 改成隐藏
        //     DIAG reopen flag=false registry=有 windows=1 ids=["lumo.main"]   ← 我们已经把窗口恢复了
        //     DIAG install: 首次，原 delegate=AppKitWindowController          ← 系统又建了一个
        //
        // 也就是说：**我们的 reopen 逻辑根本没有创建窗口**（它走了"端回已有的那个"），
        // 第二个窗口是**框架自己**建的。之前一直在用自己的代码找原因，方向就是错的。
        //
        // `Window` 是"**恰好一个**"的语义（macOS 13+），正好对上单窗口工具类 App。
        // 换成它之后，"再开一个"这件事在场景层面就不再可能发生。
        Window("Lumo", id: "main") {
            // backend / updates / theme / prefs 全应用共享；
            // state（当前文件 / 预览 / 结果）每个窗口一份，见 WindowState。
            WindowState()
                .environmentObject(backend)
                .environmentObject(updates)
                .environmentObject(theme)
                .environmentObject(prefs)
                .onAppear {
                    theme.applyAppearance()
                    updates.start()
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification)) { _ in
                    backend.stop()
                    updates.stop()
                }
        }
        // 统一标题栏：内容延伸到窗口顶部，交通灯浮在内容之上（参考 §3）
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: LumoDesign.windowDefaultWidth,
                     height: LumoDesign.windowDefaultHeight)
        // ★ 窗口缩放下限。`.contentMinSize` 会尊重内容里的 `.frame(minWidth:minHeight:)`
        // （见 RootView），两者一起用：这一层管"系统层面不许再缩"，
        // 那一层管"布局本身要多大"。只写一处都可能在某个路径上被绕开。
        .windowResizability(.contentMinSize)
        .commands { LumoCommands() }

        // ⚠️ 这里**没有** `Settings { }` 场景 —— 它在本项目上是坏的：
        //   ① 打开它走 `SettingsLink` / 私有 selector，前者要 macOS 14，
        //      后者在 macOS 26 上没有 responder 接（齿轮按钮因此毫无反应）；
        //   ② 它的内容缺一个 environment object 就直接 fatalError（实测崩过）。
        // 现在设置是我们自建的 NSWindow，见 SettingsWindow.swift。
    }
}

/// 菜单结构（参考 §9：标准结构、主要动作都配快捷键、不覆盖系统快捷键语义）
struct LumoCommands: Commands {
    var body: some Commands {
        // 这里原本写的是 CommandGroup(replacing: .newItem) {}——把「新建窗口」
        // 菜单项整个删掉。当时想的是「这 App 一次只开一个窗口，别让用户点出第二个」，
        // 但这个想法有个致命副作用：**Cmd+N 一旦不存在，关窗之后就没有任何
        // 常规途径把窗口叫回来**。
        // 现在 AppDelegate 也补了 reopen 处理，两道保险都在。参考文档 §9 说
        // 「移除不适用的标准菜单命令（新建、保存、打印等）」——但对我们来说
        // Cmd+N 恰恰是**必要**的那一个，所以留着，并在上面这段话里写清楚为什么。

        // 设置：替换掉系统那一项，指向我们自建的窗口。
        // 系统那项会去打开 SwiftUI 的 Settings 场景（那把一打开就崩，见 LumoMacApp 的注释）。
        CommandGroup(replacing: .appSettings) {
            Button(T("设置…")) {
                NotificationCenter.default.post(name: .lumoRequestSettings, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(after: .newItem) {
            Button(T("打开…")) {
                NotificationCenter.default.post(name: .lumoRequestOpen, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)

            Button(T("从剪贴板打开")) {
                NotificationCenter.default.post(name: .lumoRequestPaste, object: nil)
            }
            // 刻意**不用** ⌘V：那个键要留给文本框粘贴。
            // 全局劫持 ⌘V 会让"给页码范围输入框粘一串数字"直接变成"打开文件"，
            // 这是那种看起来聪明、用起来想砸键盘的设计。
            .keyboardShortcut("v", modifiers: [.command, .shift])

            Divider()

            Button(T("清空当前文件")) {
                NotificationCenter.default.post(name: .lumoRequestClear, object: nil)
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])

            Divider()

            Button(T("载入示例扫描件")) {
                NotificationCenter.default.post(name: .lumoRequestSample, object: nil)
            }
        }

        // Edit / Window 保持系统默认——文本框的剪切复制粘贴全依赖它们。

        CommandGroup(replacing: .help) {
            // ⚠️ 这里**不能**直接调 `BundledDoc.present(...)`。
            //
            // 它是 @MainActor 的，而 `Commands` 不是 View —— 在较老的工具链上，
            // 这个闭包被判定为"同步非隔离上下文"，编译直接报：
            //   call to main actor-isolated static method 'present'
            //   in a synchronous nonisolated context
            //
            // **这个错在本机完全不出现**（macOS 26 + Xcode 26 全绿，零警告），
            // 是 CI 的 macos-14 job 抓出来的 —— 并发诊断依赖 SDK 里的标注，
            // 所以换一套工具链结论就变了。这正是双 runner 矩阵存在的理由。
            // 菜单一律走广播，和本文件里其它菜单项保持一致。
            Button(T("查看设计文档")) {
                NotificationCenter.default.post(name: .lumoRequestBundledDoc,
                                                object: BundledDoc.design)
            }
            Button(T("查看示例扫描件")) {
                NotificationCenter.default.post(name: .lumoRequestBundledDoc,
                                                object: BundledDoc.sample)
            }
            Divider()
            Button(T("检查更新")) {
                NotificationCenter.default.post(name: .lumoRequestCheckUpdates, object: nil)
            }
        }
    }
}

// 菜单动作怎么送到当前窗口：Commands 不是 View，拿不到 environmentObject，
// 所以走 NotificationCenter 广播，由当前窗口的 RootView 接住。
// 为什么不用 @FocusedValue：那需要每个窗口显式发布 focus value，
// 而"菜单点了没反应"正是最容易漏的一环——广播的失败方式是"找不到接的人就没人接"，
// 比静默失效更容易在开发时立刻发现。

extension Notification.Name {
    static let lumoRequestOpen = Notification.Name("lumo.request.open")
    static let lumoRequestPaste = Notification.Name("lumo.request.paste")
    static let lumoRequestClear = Notification.Name("lumo.request.clear")
    static let lumoRequestSample = Notification.Name("lumo.request.sample")
    static let lumoRequestSettings = Notification.Name("lumo.request.settings")
    static let lumoRequestCheckUpdates = Notification.Name("lumo.request.checkUpdates")
    /// 请求在主窗口里用内置阅读器打开一份 PDF
    static let lumoPresentDoc = Notification.Name("lumo.present.doc")
    static let lumoPresentDocFailed = Notification.Name("lumo.present.doc.failed")
    /// 菜单发起的"打开某份内置文档"（带文档名）。菜单不能直接调 @MainActor 的方法，
    /// 见 LumoCommands 里那段注释。
    static let lumoRequestBundledDoc = Notification.Name("lumo.request.bundledDoc")
    /// Finder / Dock 把文件交给 App 时用这条
    static let lumoOpenDocuments = Notification.Name("lumo.open.documents")
}

// MARK: - 主窗口的引用

/// 让 AppDelegate 能"新开一个主窗口"。
///
/// 为什么要有这个东西：AppDelegate 拿不到 SwiftUI 的 `openWindow` 环境动作，
/// 而**关掉最后一个窗口之后**，系统问应用"要不要重开窗口"时只能由 AppDelegate 回答。
/// 所以由窗口内容在出现时把这个动作存下来，AppDelegate 需要时直接调。
@MainActor
final class MainWindowOpener {
    static let shared = MainWindowOpener()
    private init() {}
    var open: (() -> Void)?
}

// MARK: - 主窗口登记处

/// 记着当前那个主窗口。
///
/// 为什么需要一个登记处，而不是在 AppDelegate 里翻 `NSApp.windows`：
/// 实测「关掉主窗口再打开 App」时的窗口数组里，剩下那个窗口的 identifier 是 nil
/// ——按标识符认不出来，按"能当主窗口"筛又会把别的窗口一起筛进来。
/// 窗口自己在配置时登记一下，就没有猜的成分了。
/// 用 `weak`：窗口被关掉并释放时它自动变 nil，AppDelegate 据此知道该新开一个。
enum MainWindowRegistry {
    static weak var window: NSWindow?
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: 启动兜底：一定要有一个窗口

    /// 关掉"退出时记住窗口"这条系统机制。
    ///
    /// ⚠️ 实测过它的后果：`~/Library/Saved Application State/com.lumo.app.savedState`
    /// 里一旦记着"上次没有窗口"，**SwiftUI 的 `Window` 场景一个新窗口都不开**——
    /// App 启动了、菜单栏在、Dock 图标在，屏幕上什么都没有，用户只能强退。
    /// 对一个"打开就是为了放文件进去"的工具来说，这是最坏的一种失败。
    ///
    /// 我们本来就关了窗口状态恢复（窗口的 `isRestorable = false` 加本类的两处
    /// shouldSave/Restore），但那条路仍然会留下状态。这里把系统的"退出时保留窗口"
    /// 也一并关掉——必须在 `applicationWillFinishLaunching` 里设，晚了 AppKit 已经读过了。
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    /// 再确认一次结果：起来之后如果**一个窗口都没有**，主动开一个。
    ///
    /// 为什么不只靠上面那条开关：那是"别留下坏状态"，这是"就算留下了也别让用户卡住"。
    /// 两者都要——这一条是最后一道保险，它的失败方式是"多开一个窗口"，
    /// 而上面那条的失败方式是"应用打不开"，两者不对称，所以宁可都留着。
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 用 Task + sleep 而不是 DispatchQueue.asyncAfter：下面那件事是 @MainActor
        // 隔离的（要碰 NSWindow），从非隔离的 delegate 方法里直接调是编不过的。
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self?.ensureWindow()
        }
    }

    @MainActor
    private func ensureWindow() {
        // ① 窗口在、但被藏起来了（"关闭即隐藏"就是这个状态）→ 直接端出来。
        //    这一步不能省：实测那次故障里窗口对象是**存在**的（内容 onAppear 过、
        //    更新服务都启动了），只是不在屏幕上。只看"有没有窗口对象"会漏掉它。
        if let w = MainWindowRegistry.window {
            if !w.isVisible {
                UpdateLog.write("启动兜底：窗口被藏着，端到前台")
                w.makeKeyAndOrderFront(nil)
            }
            return
        }

        // ② 真没有窗口对象 → 开一个。
        guard let open = MainWindowOpener.shared.open else { return }
        UpdateLog.write("启动兜底：没有窗口，主动开一个")
        open()
        // 开完再收尾一次：万一 SwiftUI 同时补了一个，只留一个。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            let mains = NSApp.windows.filter {
                $0.identifier?.rawValue == WindowConfigurator.mainWindowIdentifier
            }
            guard mains.count > 1 else { return }
            let keep = mains.first(where: { $0.isKeyWindow }) ?? mains[mains.count - 1]
            for w in mains where w !== keep { w.close() }
        }
    }

    /// ★★ 这是自更新器最致命的那个坑（手册 P5），改动前务必读完。
    ///
    /// **绝对不要**在这里用 `.terminateLater` + 异步 reply：
    ///
    /// ```swift
    /// // ❌ 更新器调用时会死锁，App 退不掉 → helper 在门外等 → 更新静默卡死
    /// Task { @MainActor in
    ///     saveNow()
    ///     NSApp.reply(toApplicationShouldTerminate: true)
    /// }
    /// return .terminateLater
    /// ```
    ///
    /// 根因：`.terminateLater` 让 `NSApp.terminate` 跑一个嵌套 runloop 等 reply，
    /// 而那个 reply 是**主 actor 的任务**；调用方（自更新器）正占着主 actor，
    /// reply 永远排不上 → 互相等 → 死锁。
    ///
    /// **为什么它特别隐蔽**：⌘Q 完全正常，因为那时主 actor 是空闲的。
    /// 只有"从主 actor 的闭包里调 NSApp.terminate"才会触发——
    /// 而那恰好是自更新器唯一会做的事。
    ///
    /// Lumo 这里需要落盘的东西是零（设置走 UserDefaults，会自动落），
    /// 所以直接放行即可。将来若真有需要同步保存的状态，也请**同步**存完再返回。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }

    /// Finder / Dock 拖进来的文件（也覆盖「用 Lumo 打开」）
    func application(_ application: NSApplication, open urls: [URL]) {
        let pdfs = urls.filter { $0.isFileURL }
        guard !pdfs.isEmpty else { return }
        NotificationCenter.default.post(name: .lumoOpenDocuments, object: pdfs)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 上一次"因为点 Dock 图标而新开窗口"的时刻。**只给兜底分支用**
    /// （正常路径根本走不到那里，理由见下面 ① 的注释）。
    private var lastReopenAt = Date.distantPast

    /// ★ 关窗后点 Dock 图标把窗口带回来。
    ///
    /// **这里以前有一行是错的，会弹「未能创建文稿」，别再写回去：**
    ///
    /// ```swift
    /// // ❌ 一个窗口都不剩时，用 NSDocumentController 的"新建文档"来开窗口
    /// _ = NSApp.sendAction(#selector(NSDocumentController.newDocument(_:)), to: nil, from: nil)
    /// ```
    ///
    /// Lumo **不是文档型应用**（没有 NSDocument、没有 NSDocumentController 子类），
    /// 所以 `newDocument(_:)` 找不到能创建的文档类型，直接弹
    /// 「未能创建文稿」。而它看起来还挺"合理"——毕竟 App 声明了
    /// `CFBundleDocumentTypes`（那是为了能被"用 Lumo 打开 PDF"唤起），
    /// 声明了就会被当成文档型应用，这个误会很难从代码上看出来。
    ///
    /// —— 上面那条修完之后，还有第二层问题：**点一次 Dock 图标会闪出两个窗口**。
    /// 上一版的做法是"开完窗再把多出来的那个关掉"，所以用户仍然能看到它闪一下
    /// （反馈原文：「肉眼可以看到还是打开了两个窗口，然后其中一个很快消失了，
    /// 其实并没有很好解决」）。**那是在打扫，不是修复。**
    ///
    /// 真正的修法在窗口那边：`MainWindowDelegate` 把"关闭主窗口"改成了
    /// "隐藏主窗口"，于是 `MainWindowRegistry.window` **永远不会变成 nil**，
    /// 下面 ① 永远命中，② 那条"必须新开"的路根本走不到。
    /// 一并关掉了系统的窗口状态恢复（`isRestorable` + 本类里两处 shouldSave/Restore）。
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if flag {
            sender.activate(ignoringOtherApps: true)
            return true
        }

        // ① 主窗口一直都在（只是被"隐藏"了）→ 直接端回来。
        //
        //    实测过：关掉主窗口后 `sender.windows` 里只剩一个
        //    **identifier 为 nil** 的窗口，按标识符认不出来。
        //    所以让窗口自己在配置时登记（见 MainWindowRegistry）——
        //    "谁是主窗口"这件事，只有那个窗口自己最清楚。
        if let main = MainWindowRegistry.window {
            main.makeKeyAndOrderFront(nil)
            sender.activate(ignoringOtherApps: true)
            return true
        }

        // ② 兜底：窗口真的不存在了（理论不可达，见上面的说明）。
        //
        //    ⚠️ 这里**必须自己做**——实测只 `return false` 的话 SwiftUI 不会开窗，
        //       点 Dock 图标依然什么都没有。
        //    ⚠️ 一旦走到这里，`openWindow` 会一次开出两个窗口，
        //       所以要配一次防抖 + 一次收尾。这段是网，不是主路径。
        let now = Date()
        guard now.timeIntervalSince(lastReopenAt) > 1.5 else {
            sender.activate(ignoringOtherApps: true)
            return true
        }
        lastReopenAt = now

        if let open = MainWindowOpener.shared.open {
            open()
            sender.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let mains = NSApp.windows.filter {
                    $0.identifier?.rawValue == WindowConfigurator.mainWindowIdentifier
                }
                guard mains.count > 1 else { return }
                let keep = mains.first(where: { $0.isKeyWindow }) ?? mains[mains.count - 1]
                for w in mains where w !== keep { w.close() }
                UpdateLog.write("reopen 兜底：清理重复主窗口 \(mains.count) → 1")
            }
            return true
        }

        return false
    }

    /// 关掉那条"App 没有窗口时，要不要顺手开一个空文稿"的老路径。
    /// 返回 false 就不会再走到 NSDocumentController 上（也就是上面那个对话框的来源）。
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    /// ★ 声明支持"安全的状态恢复"。
    ///
    /// macOS 14 起如果不实现这个方法，每次启动都会记一条
    /// `Secure coding is not enabled for restorable state` —— 是噪音，不是错误，
    /// 但既然窗口状态恢复本身就是多出窗口的嫌疑来源之一，这里如实声明。
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// ★ 不保存、也不恢复窗口状态。
    ///
    /// 单窗口工具类 App 不需要"上次关在哪儿、开着哪些窗口"这套机制；
    /// 而它恰恰是"点了 Dock 图标凭空多出一个窗口"这类现象的常见来源。
    /// 窗口自己的位置大小由 `WindowConfigurator.applyFrameAutosave` 单独记，
    /// 与系统那套恢复无关（那条路是用户在设置里能关掉的）。
    func application(_ app: NSApplication,
                     shouldSaveSecureApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ app: NSApplication,
                     shouldRestoreSecureApplicationState coder: NSCoder) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 关掉最后一个窗口**不退出**：工具类 App 的惯例，也让「关窗后再点 Dock」
        // 有窗口可回。退出的唯一途径是显式退出。
        // （参考 §4：单窗口工具类应用，关闭主窗口默认隐藏而非退出。）
        false
    }
}

/// 每个窗口一份独立的处理状态。
///
/// 为什么不能把 AppState 直接挂在 App 层共享：多窗口时两个窗口会共用同一份
/// fileURL / 预览图 / 处理结果，在 A 窗口选文件会打断 B 窗口的处理。
/// 把状态挂在 WindowGroup 的每个窗口内部，各窗口天然隔离。
struct WindowState: View {
    @StateObject private var state = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RootView()
            .environmentObject(state)
            .onAppear {
                // 把"新开一个主窗口"的能力交给 AppDelegate（见 MainWindowOpener）。
                // 只在还没有的时候记一次即可——这个动作与具体窗口无关。
                if MainWindowOpener.shared.open == nil {
                    MainWindowOpener.shared.open = { openWindow(id: "main") }
                }
            }
    }
}
