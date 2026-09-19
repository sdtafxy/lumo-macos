// Lumo — 内置 PDF 阅读器
//
// 为什么要有它：内置的设计文档与示例扫描件原来只能交给「预览.app」打开，
// 而那是**离开 App** 了——用户点了一下，Lumo 就退到后台，回来还得重新找。
// 更重要的是：**这是唯一能让人在 App 里看到"处理前长什么样"的地方**。
//
// 用的是系统 PDFKit。这不是"引入依赖"——PDFKit 是 macOS 自带框架，
// 与 CoreGraphics / Vision 同级，`.app` 里不会多出任何东西。

import SwiftUI
import AppKit
import PDFKit
import LumoCore

/// 要在阅读器里打开的一份 PDF。
struct PDFDocRef: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let url: URL
    /// 头部右侧的小字（文件大小、页数之类）。懒算，避免为了显示一行字去解析整份文件。
    var caption: String?

    static func == (a: PDFDocRef, b: PDFDocRef) -> Bool { a.id == b.id }

    /// 用**任意一个本机 PDF** 造引用。
    ///
    /// 内置文档之外的文件（用户自己拖进来的扫描件、处理后的产物）都走这里，
    /// 于是"能预览的 PDF"和"能在阅读器里打开的 PDF"是同一个集合——
    /// 不会出现"预览里能看、点开却打不开"这种分裂。
    static func file(_ url: URL, captionPrefix: String? = nil) -> PDFDocRef {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        let head = captionPrefix ?? T("本机文件")
        return PDFDocRef(title: url.lastPathComponent,
                         url: url,
                         caption: size.map { "\(head) · \(lumoBytes($0))" })
    }

    /// 在**当前窗口**的内置阅读器里打开一个文件。
    ///
    /// 为什么走通知而不是直接调：阅读器是 `RootView` 上的一个 sheet，
    /// 而调用方（文件行、设置页、菜单）都在别的视图树里。通知是这里已经存在的、
    /// 唯一能跨视图树送达的通道（见 LumoEventSink 的文件头注释）。
    @MainActor
    static func present(_ url: URL, captionPrefix: String? = nil) {
        NotificationCenter.default.post(name: .lumoPresentDoc,
                                        object: PDFDocRef.file(url, captionPrefix: captionPrefix))
    }
}

// MARK: - 阅读器控制器

/// 把 `PDFView` 的"当前页 / 总页数 / 缩放"暴露给 SwiftUI。
///
/// 为什么不让 SwiftUI 直接持有 `PDFView`：`PDFView` 是引用类型的 AppKit 视图，
/// 它的状态变化（翻页、缩放）**不会**触发 SwiftUI 重绘。所以用一个轻量的
/// ObservableObject 当桥梁——AppKit 那边变 → 写进这里 → SwiftUI 重绘。
@MainActor
final class PDFHandle: ObservableObject {
    @Published var pageIndex: Int = 0
    @Published var pageCount: Int = 0
    @Published var isFitWidth: Bool = true

    weak var view: PDFView?

    func go(to index: Int) {
        guard let v = view, let d = v.document, d.pageCount > 0 else { return }
        let clamped = max(0, min(d.pageCount - 1, index))
        if let page = d.page(at: clamped) { v.go(to: page) }
    }

    func step(_ delta: Int) { go(to: pageIndex + delta) }

    func setFitWidth(_ on: Bool) {
        guard let v = view else { return }
        isFitWidth = on
        v.autoScales = on
        if !on { v.scaleFactor = 1.0 }
    }

    func zoom(_ factor: CGFloat) {
        guard let v = view else { return }
        isFitWidth = false
        v.autoScales = false
        // 钳在 PDFKit 自己的上下限里：越界赋值在部分系统版本上会被忽略，
        // 表现是"按了没反应"，很难查。
        let next = v.scaleFactor * factor
        v.scaleFactor = max(v.minScaleFactor, min(v.maxScaleFactor, next))
    }
}

// MARK: - PDFKit 桥

struct PDFKitView: NSViewRepresentable {
    let url: URL
    @ObservedObject var handle: PDFHandle

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.displaysPageBreaks = true
        v.pageShadowsEnabled = true
        // 背景透明：让 App 的玻璃背景透上来，页面本身仍是白的，
        // 形成"纸上叠纸"的层次，比一整片灰底好看。
        v.backgroundColor = .clear
        v.document = PDFDocument(url: url)

        handle.view = v
        handle.pageCount = v.document?.pageCount ?? 0
        handle.pageIndex = 0

        // 用户在 PDF 里滚轮翻页时，页码要跟着动 —— 否则滑块会跟画面脱节。
        //
        // ⚠️ 用 `Task { @MainActor in … }` 而不是 `MainActor.assumeIsolated`：
        // 后者要 macOS 14，而本项目最低支持 13（这条是刻意的）。
        context.coordinator.token = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: v, queue: .main) { note in
                guard let pv = note.object as? PDFView,
                      let p = pv.currentPage, let d = pv.document else { return }
                let idx = d.index(for: p)
                Task { @MainActor in handle.pageIndex = idx }
            }
        return v
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        // 文件换了就重载。用 URL 比对而不是每次重建视图——
        // 重建会让滚动位置和缩放都丢掉。
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            nsView.document = PDFDocument(url: url)
            handle.pageCount = nsView.document?.pageCount ?? 0
            handle.pageIndex = 0
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator {
        var loadedURL: URL
        var token: NSObjectProtocol?
        init(url: URL) { loadedURL = url }
        deinit {
            if let t = token { NotificationCenter.default.removeObserver(t) }
        }
    }
}

// MARK: - 阅读器面板

struct PDFViewerSheet: View {
    let doc: PDFDocRef
    let onClose: () -> Void

    @StateObject private var handle = PDFHandle()
    @State private var pageField = "1"
    @FocusState private var pageFieldFocused: Bool
    @Environment(\.lumoGlass) private var glass
    /// 阅读器是 sheet，独立于主窗口的视图树，所以自己订阅语言。
    @ObservedObject private var lang = LumoLanguageStore.shared

    private var pageCount: Int { max(1, handle.pageCount) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(LumoDesign.hairline)
            PDFKitView(url: doc.url, handle: handle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(LumoDesign.hairline)
            footer
        }
        // 尺寸刻意**小于主窗口**（默认 1000×680）：sheet 比父窗口还高的话，
        // 它会探出窗口边界，看起来像"飘在外面的一块"，而不是"这张纸上盖了一层"。
        .frame(minWidth: 640, idealWidth: 840, minHeight: 380, idealHeight: 540)
        // ★ sheet 打开时不要把焦点给第一个按钮。
        //   不给的话，「在预览中打开」会顶着一圈蓝色焦点环——看起来像它被选中了，
        //   实际只是 AppKit 把第一响应者给了它。macOS 原生 App 里按钮默认不带环。
        //   和主窗口用的是同一招（见 WindowConfigurator）：延后一拍清掉第一响应者。
        .onAppear {
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .background(LumoDesign.canvas.opacity(glass.canvasOpacity))
        // 页码输入实时跟住滚动
        .onChange(of: handle.pageIndex) { i in
            if !pageFieldFocused { pageField = "\(i + 1)" }
        }
        .onAppear { pageField = "1" }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: LumoDesign.gap) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(LumoDesign.accentDeep)

            VStack(alignment: .leading, spacing: 0) {
                Text(doc.title)
                    .font(LumoDesign.font(13.5, weight: .semibold))
                    .foregroundColor(LumoDesign.text)
                    .lineLimit(1)
                Text(doc.caption ?? doc.url.lastPathComponent)
                    .font(LumoDesign.font(11))
                    .foregroundColor(LumoDesign.muted)
                    .lineLimit(1).truncationMode(.middle)
            }

            Spacer(minLength: LumoDesign.gap)

            LumoButton(title: T("在预览中打开"), icon: "arrow.up.forward.app", kind: .secondary) {
                // 逃生出口：内置阅读器是"够用就好"，真要认真读还是系统预览更顺手。
                NSWorkspace.shared.open(doc.url)
            }
            LumoCircleButton(icon: "xmark", help: T("关闭阅读器")) { onClose() }
        }
        .padding(.horizontal, LumoDesign.padWindow)
        .frame(height: 56)
        .background(glass.barMaterial)
        // 头部也要能拖着走（它是个 sheet，拖动改变不了窗口大小，
        // 但保持一致的手感没坏处，而且 sheet 靠它移动不了——所以这里不加拖拽区）
    }

    // MARK: 页码 / 缩放

    private var footer: some View {
        HStack(spacing: LumoDesign.gap) {
            LumoCircleButton(icon: "chevron.left", help: T("上一页"),
                             disabled: handle.pageIndex <= 0) { handle.step(-1) }

            TextField("", text: $pageField)
                .textFieldStyle(.plain)
                .font(LumoDesign.font(12.5).monospacedDigit())
                .multilineTextAlignment(.center)
                .frame(width: 46)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: LumoDesign.radiusField, style: .continuous)
                    .fill(LumoDesign.panelAlt))
                .overlay(RoundedRectangle(cornerRadius: LumoDesign.radiusField, style: .continuous)
                    .stroke(pageFieldFocused ? LumoDesign.accentEdge : LumoDesign.hairline))
                .focused($pageFieldFocused)
                .onSubmit { commitPageField() }

            Text(T("/ %@ 页", pageCount))
                .font(LumoDesign.font(12)).foregroundColor(LumoDesign.muted)
                .monospacedDigit()

            LumoCircleButton(icon: "chevron.right", help: T("下一页"),
                             disabled: handle.pageIndex >= pageCount - 1) { handle.step(1) }

            // ★ 滑块：从头拉到尾。一页页点在这个位置是最累的交互。
            //
            // ⚠️ 区间上界必须是 `max(2, pageCount)`，不能是 `pageCount`：
            // 第一次求值时文档还没解析完，`pageCount` 是 0（或 1），
            // 这时 `1...1` 是个**退化的区间**，SwiftUI 内部
            // `Normalizing.init(min:max:stride:)` 会直接 precondition 失败 → SIGTRAP。
            // 也就是说：**一个"看起来只是初始值不对"的写法，代价是整个 App 崩掉。**
            Slider(value: Binding(
                get: { Double(handle.pageIndex + 1) },
                set: { handle.go(to: Int($0.rounded()) - 1) }
            ), in: 1...Double(max(2, pageCount)), step: 1)
            .frame(minWidth: 160)
            .disabled(pageCount <= 1)

            Divider().frame(height: 18)

            LumoCircleButton(icon: "minus.magnifyingglass", help: T("缩小")) { handle.zoom(1 / 1.25) }
            LumoCircleButton(icon: handle.isFitWidth ? "arrow.up.left.and.arrow.down.right" : "1.magnifyingglass",
                             help: handle.isFitWidth ? T("当前：适应宽度") : T("当前：实际大小")) {
                handle.setFitWidth(!handle.isFitWidth)
            }
            LumoCircleButton(icon: "plus.magnifyingglass", help: T("放大")) { handle.zoom(1.25) }
        }
        .padding(.horizontal, LumoDesign.padWindow)
        .frame(height: 48)
        .background(glass.barMaterial)
    }

    private func commitPageField() {
        pageFieldFocused = false
        guard let n = Int(pageField.trimmingCharacters(in: .whitespaces)) else {
            pageField = "\(handle.pageIndex + 1)"   // 输入不是数字：退回当前页，不报错
            return
        }
        let clamped = max(1, min(pageCount, n))
        pageField = "\(clamped)"
        handle.go(to: clamped - 1)
    }
}
