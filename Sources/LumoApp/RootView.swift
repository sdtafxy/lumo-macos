// Lumo — 根视图：把窗口外壳、菜单动作、拖放、文件面板、阅读器接在一起
//
// 参考 §3 §4 §5：单窗口、统一标题栏、空态 → 工作态渐进展开、底部状态栏常驻。
// 输入入口极宽容（参考 §2 Downie 的做法）：拖到窗口 / 拖到 Dock / ⌘O /
// ⇧⌘V 粘贴 / 底栏按钮 / 菜单。
//
// ⚠️ 这个文件的结构是**被编译器逼出来的**，别随手合并回去：
//   把十几个 onReceive 直接摊在 body 上时，**macos-14 的编译器**会报
//     error: the compiler is unable to type-check this expression in reasonable time
//   而本机（macOS 26 + Xcode 26）编译得过去、零警告。
//   所以拆成 `windowChrome` + 两个事件 modifier。详见 LumoEventHandlers 的注释。

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LumoCore

struct RootView: View {
    @EnvironmentObject var backend: LumoBackend
    @EnvironmentObject var state: AppState
    @EnvironmentObject var updates: UpdateService
    @EnvironmentObject var theme: LumoTheme
    @EnvironmentObject var prefs: LumoPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showPicker = false
    /// 非 nil 时弹出内置阅读器。用 item-style 的 sheet：
    /// 直接绑 `Bool + URL` 两个状态，在"打开 A → 打开 B"时会有一帧旧内容闪出来。
    @State private var viewerDoc: PDFDocRef?

    var body: some View {
        windowChrome
            .background(WindowConfigurator())
            // 玻璃档位沿视图树传下去。用 Environment（有默认值）而不是 EnvironmentObject
            // —— 后者漏注入就是崩溃，这个坑刚踩过（见 Theme.swift 文件头）。
            .environment(\.lumoGlass, theme.glass)
            // 强调色：分段控件 / 滑块 / 开关一律走品牌青绿，不用系统的蓝。
            .tint(LumoDesign.accent)
            .frame(minWidth: LumoDesign.windowMinWidth, minHeight: LumoDesign.windowMinHeight)
            .animation(LumoMotion.animation(LumoDesign.Motion.appear, reduceMotion: reduceMotion),
                       value: state.stage)
            // 整个窗口都是拖放区（参考 §5 Level 0：全窗口即拖放区）
            .onDrop(of: FileDrop.acceptedTypes, isTargeted: .constant(false)) { providers in
                acceptDrop(providers)
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.pdf]) { res in
                handlePicked(res)
            }
            .sheet(item: $viewerDoc) { doc in
                PDFViewerSheet(doc: doc) { viewerDoc = nil }
                    .environment(\.lumoGlass, theme.glass)
            }
            .task { await bootstrap() }
            .modifier(MenuEventHandlers(sink: eventSink))
            .modifier(DocumentEventHandlers(sink: eventSink))
            .alert("Lumo", isPresented: Binding(get: { state.errorMessage != nil },
                                               set: { if !$0 { state.errorMessage = nil } })) {
                Button("好") { state.errorMessage = nil }
            } message: {
                Text(state.errorMessage ?? "")
            }
    }

    // MARK: 窗口结构

    /// 窗口的可见结构：背景 + 顶栏 / 内容 / 底栏。
    ///
    /// 单独抽出来有两个原因，都不是"好看"：
    ///   ① 让 `body` 短到旧编译器能在合理时间内完成类型检查（见文件头）；
    ///   ② `ignoresSafeArea(.top)` 必须作用在这一层 —— 它要让**顶栏本身**
    ///      贴到窗口顶边，而不是让整个 ZStack 的背景铺出去。
    private var windowChrome: some View {
        ZStack {
            windowBackdrop

            VStack(spacing: 0) {
                TopToolBar()
                stageBody
                BottomStatusBar(showPicker: $showPicker)
            }
            // ★ 让顶栏真的贴到窗口顶边。
            //
            // 不加这一句时，SwiftUI 会给内容留出标题栏那一条的安全区（本机实测约 28pt），
            // 于是顶栏整体被往下推——交通灯落在"顶栏之上的一条空白"里，
            // 顶栏自己的材质也只从 28pt 处才开始，整体看起来像"内容没对齐"。
            // 这正是反馈里"LOGO 处在一个尴尬的位置"的另一半原因：
            // 不只是大小，还有它被推下去了一层。
            .ignoresSafeArea(.container, edges: .top)
        }
    }

    /// 窗口底：先铺一层系统模糊（只在玻璃档位需要时），再盖一层可调的底色。
    /// ★ 底色**不能**是不透明的，否则什么玻璃都看不见——
    ///   三档之间的差别就在这个 opacity 上（见 `LumoGlass.canvasOpacity`）。
    private var windowBackdrop: some View {
        ZStack {
            if theme.glass.wantsBackdrop {
                VisualEffectBackdrop(material: .underWindowBackground,
                                     opacity: theme.glass.backdropOpacity)
                    .ignoresSafeArea()
            }
            LumoDesign.canvas.opacity(theme.glass.canvasOpacity).ignoresSafeArea()
        }
    }

    private var stageBody: some View {
        ZStack {
            switch state.stage {
            case .drop:
                EmptyStateView(showPicker: $showPicker)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .workflow, .result:
                WorkArea()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 事件接点

    /// 把所有"外部事件 → 动作"的落点收成一个值，再交给两个薄薄的 modifier。
    /// 好处是每个 modifier 的表达式都很短——长链是旧编译器超时的原因。
    private var eventSink: LumoEventSink {
        LumoEventSink(
            open: { showPicker = true },
            paste: { pasteFromClipboard() },
            clear: { state.resetToPicker() },
            sample: { loadSample() },
            settings: { SettingsWindow.shared.show() },
            checkUpdates: { Task { @MainActor in await updates.check(manual: true) } },
            bundledDoc: { name in openBundled(name) },
            presentDoc: { ref in viewerDoc = ref },
            presentFailed: { name in
                state.errorMessage = "没找到内置的「\(name)」（安装包可能不完整）"
            },
            openDocuments: { urls in
                guard let first = urls.first else { return }
                Task { @MainActor in await state.load(url: first, backend: backend) }
            }
        )
    }

    // MARK: 动作

    /// 全窗口拖放。抽成方法是因为 `onDrop` 的闭包要求返回 Bool，
    /// 而"漏掉那个 return"会报一句完全不提 onDrop 的错误（见下方注释）。
    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        FileDrop.handle(providers) { url in
            Task { @MainActor in await state.load(url: url, backend: backend) }
        } onFailure: { msg in
            state.errorMessage = msg
        }
        // onDrop 的闭包要求返回 Bool（"我接不接这个拖放"）。
        // 漏掉这个 return 会报 "cannot convert value of type '()' to closure result type 'Bool'"
        // —— 报错信息完全没提 onDrop，第一次见会有点懵。
        return true
    }

    private func handlePicked(_ res: Result<URL, Error>) {
        switch res {
        case .success(let url):
            Task { @MainActor in await state.load(url: url, backend: backend) }
        case .failure(let err):
            state.errorMessage = "没能打开这个文件：\(err.localizedDescription)"
        }
    }

    private func bootstrap() async {
        do {
            try await backend.start()
            state.langs = try await backend.loadLangs()
            if state.langs.isEmpty { state.langs = ["eng"] }
        } catch {
            state.errorMessage = error.localizedDescription
        }
        // 还没载入任何文件时，把全局偏好里的默认值填进来。
        // 载入文件后 `AppState.apply(report)` 会按这一份文件的体检结果覆盖它们——
        // 那是"针对这份文件"的建议，优先级本来就高于全局默认。
        if state.report == nil {
            state.ocrLang = prefs.ocrLang
            state.ocrOutput = prefs.ocrOutput
        }
    }

    /// ⇧⌘V：从剪贴板取一个 PDF。
    ///
    /// 参考 §2 把「⌘V 粘贴」列为 Downie 的输入入口之一，这里做成了它的等价物。
    /// 失败必须**明确提示**（参考 §10：拖放/输入静默失败是不可接受的偏差）——
    /// 用户按了快捷键却什么都没发生，只会以为快捷键坏了。
    private func pasteFromClipboard() {
        guard let url = FileDrop.fromPasteboard() else {
            state.errorMessage = "剪贴板里没有 PDF。可以复制一个 PDF 文件，或复制它的完整路径再试。"
            return
        }
        Task { @MainActor in await state.load(url: url, backend: backend) }
    }

    private func loadSample() {
        guard let u = BundledDoc.url(BundledDoc.sample) else {
            state.errorMessage = "没找到内置示例（安装包可能不完整）"
            return
        }
        Task { @MainActor in await state.load(url: u, backend: backend) }
    }

    /// 用内置阅读器打开一份随 App 打包的文档。
    /// 与 `BundledDoc.present` 走同一个构造入口（`BundledDoc.ref`），
    /// 所以两处的标题与副标题不会长得不一样。
    private func openBundled(_ name: String) {
        guard let u = BundledDoc.url(name), FileManager.default.fileExists(atPath: u.path) else {
            state.errorMessage = "没找到内置的「\(name)」（安装包可能不完整）"
            return
        }
        viewerDoc = BundledDoc.ref(name, url: u)
    }
}

// MARK: - 事件接点

/// 「外部事件 → 动作」的落点集合。
///
/// ⚠️ 为什么要单独抽出来（**别合并回 body**）：
/// 这些 `onReceive` 直接摊在 `body` 上时，**macos-14 的编译器**会报
///   error: the compiler is unable to type-check this expression in reasonable time;
///   try breaking up the expression into distinct sub-expressions
/// 而本机（macOS 26 + Xcode 26）编译得过去、零警告。
///
/// 错误信息本身就给了处方，这里照做。顺带说明：**双 runner 矩阵不只是"兼容性检查"**，
/// 它同时拦住了"只在某一代编译器上才成立的写法"——这一次是本轮第二次被它拦下
/// （上一次是 @MainActor 方法在非隔离上下文里的调用）。
struct LumoEventSink {
    var open: () -> Void
    var paste: () -> Void
    var clear: () -> Void
    var sample: () -> Void
    var settings: () -> Void
    var checkUpdates: () -> Void
    var bundledDoc: (String) -> Void
    var presentDoc: (PDFDocRef) -> Void
    var presentFailed: (String) -> Void
    var openDocuments: ([URL]) -> Void
}

/// 菜单发起的动作。
///
/// 菜单动作怎么送到当前窗口：`Commands` 不是 View，拿不到 environmentObject，
/// 所以走 NotificationCenter 广播，由这里接住。
/// 为什么不用 `@FocusedValue`：那需要每个窗口显式发布 focus value，
/// 而"菜单点了没反应"正是最容易漏的一环——广播的失败方式是"找不到接的人就没人接"，
/// 比静默失效更容易在开发时立刻发现。
private struct MenuEventHandlers: ViewModifier {
    let sink: LumoEventSink

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .lumoRequestOpen)) { _ in
                sink.open()
            }
            .onReceive(NotificationCenter.default.publisher(for: .lumoRequestPaste)) { _ in
                sink.paste()
            }
            .onReceive(NotificationCenter.default.publisher(for: .lumoRequestClear)) { _ in
                sink.clear()
            }
            .onReceive(NotificationCenter.default.publisher(for: .lumoRequestSample)) { _ in
                sink.sample()
            }
            .onReceive(NotificationCenter.default.publisher(for: .lumoRequestSettings)) { _ in
                sink.settings()
            }
            .onReceive(NotificationCenter.default.publisher(for: .lumoRequestCheckUpdates)) { _ in
                sink.checkUpdates()
            }
    }
}

/// 文档相关的事件：内置阅读器、Finder / Dock 交进来的文件。
private struct DocumentEventHandlers: ViewModifier {
    let sink: LumoEventSink

    func body(content: Content) -> some View {
        content
            // 设置窗口里点「查看设计文档」时，阅读器在**主窗口**里弹出来
            // （设置面板自己没有合适的呈现位，弹在那会盖住设置本身）。
            .onReceive(NotificationCenter.default.publisher(for: .lumoPresentDoc)) { note in
                guard let ref = note.object as? PDFDocRef else { return }
                sink.presentDoc(ref)
            }
            // 菜单发起的（菜单不能直接调 @MainActor 的方法，见 LumoCommands 的注释）
            .onReceive(NotificationCenter.default.publisher(for: .lumoRequestBundledDoc)) { note in
                guard let name = note.object as? String else { return }
                sink.bundledDoc(name)
            }
            .onReceive(NotificationCenter.default.publisher(for: .lumoPresentDocFailed)) { note in
                sink.presentFailed((note.object as? String) ?? "内置文档")
            }
            // Finder 双击 / 拖到 Dock 图标走这里
            .onReceive(NotificationCenter.default.publisher(for: .lumoOpenDocuments)) { note in
                guard let urls = note.object as? [URL] else { return }
                sink.openDocuments(urls)
            }
    }
}

// MARK: - 随 App 打包的内置文档

/// 设计文档与示例扫描件随 App 一起打包，用户不用联网、不用另找素材就能试完整流程。
enum BundledDoc {
    static let sample = "示例扫描件"
    static let design = "Lumo-设计文档"

    static func url(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "pdf")
    }

    /// 造一个阅读器用的引用。
    ///
    /// 标题与副标题**只在这里生成一次**：菜单、空态按钮、设置页三处入口
    /// 如果各写一遍文案，迟早有一处忘了改——**同一个东西在两处各写一遍，
    /// 它们迟早会长得不一样**。
    static func ref(_ name: String, url: URL) -> PDFDocRef {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        return PDFDocRef(title: name.replacingOccurrences(of: "Lumo-", with: ""),
                         url: url,
                         caption: size.map { "随 App 打包 · \(lumoBytes($0))" })
    }

    /// 在本 App 的**内置阅读器**里打开。**只能在 `@MainActor` 上下文里调用**
    /// （也就是 View 的闭包里）；菜单要用 `lumoRequestBundledDoc` 广播。
    ///
    /// 为什么不再用 `NSWorkspace.open`（交给预览.app）：
    /// 那样一点 Lumo 就退到后台了，而用户要看的是"Lumo 处理前后的样子"——
    /// 出去的这一步本身就是打断。内置阅读器（PDFKit）够看文档与示例件，
    /// 需要精读时阅读器里还有一个「在预览中打开」的出口。
    @MainActor
    static func present(_ name: String) {
        guard let u = url(name), FileManager.default.fileExists(atPath: u.path) else {
            NotificationCenter.default.post(name: .lumoPresentDocFailed, object: name)
            return
        }
        NotificationCenter.default.post(name: .lumoPresentDoc, object: ref(name, url: u))
    }
}
