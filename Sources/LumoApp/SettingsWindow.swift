// Lumo — 设置窗口（⌘,）
//
// ★ 为什么不用 SwiftUI 的 `Settings` 场景 —— 这是踩过的坑，别改回去：
//
//   ① 它**一打开就崩**。`Settings` 场景只注入我们给它的 environment object，
//      而设置面板当时用了 `@EnvironmentObject var state: AppState`（那是每个窗口
//      一份的处理状态，设置面板本来就不该有）。缺一个 → SwiftUI 直接 fatalError：
//      `EnvironmentObject.error() → GeneralSettings.$state.getter`（SIGTRAP）。
//   ② 打开它的正规途径是 `SettingsLink`（macOS 14+）或私有 selector
//      `showSettingsWindow:`。后者在 macOS 26 上**没有任何 responder 接**，
//      于是齿轮按钮点了毫无反应；而菜单里的「设置…」走 `SettingsLink` → 崩溃。
//      也就是说：这条路在旧系统和新系统上是**两种不同的坏法**。
//
//   自建 NSWindow 之后，这两件事都不存在了：打开是普通的 `makeKeyAndOrderFront`，
//   内容是普通视图，缺什么一眼就能看出来。
//
// 这个文件里的 `SettingsPanel` **不认识 AppState**，只依赖三个全局对象
// （prefs / theme / updates）—— 从结构上就不可能再犯 ①。

import SwiftUI
import AppKit
import LumoCore

// MARK: - 窗口宿主

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private init() {}

    private var window: NSWindow?

    func show() {
        if window == nil { window = makeWindow() }
        guard let w = window else { return }
        // 玻璃档位可能改过：窗口底色跟着走，否则"不透明 ↔ 通透"切完要重启才生效
        w.isOpaque = false
        w.backgroundColor = .clear
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = T("Lumo 设置")
        // 与主窗口同一套形态：内容延伸到顶、标题透明、去分隔线
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.titlebarSeparatorStyle = .none
        w.isMovableByWindowBackground = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.contentMinSize = NSSize(width: 700, height: 520)
        // ★ 关掉窗口**不能**释放它（默认是 true）。默认值下第二次点齿轮会崩：
        //   被释放的 NSWindow 再 makeKeyAndOrderFront 就是野指针。
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsPanel())
        w.center()
        return w
    }
}

/// 让设置窗口的标题跟着界面语言走。
///
/// 标题在界面上是隐藏的（`titleVisibility = .hidden`），但**窗口菜单和读屏仍会读它**，
/// 所以它也得跟着变——不然中文界面下从「窗口」菜单看会是一个英文标题。
private struct WindowTitleSync: NSViewRepresentable {
    let title: String
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        // 延后一拍：updateNSView 时视图可能还没挂到窗口上
        DispatchQueue.main.async { nsView.window?.title = title }
    }
}

// MARK: - 面板

struct SettingsPanel: View {
    @ObservedObject private var prefs = LumoPreferences.shared
    @ObservedObject private var theme = LumoTheme.shared
    @ObservedObject private var updates = UpdateService.shared
    /// 订阅语言：设置窗口是**另一个窗口**（不是主窗口的子树），
    /// 所以它必须自己订阅一次，否则在主窗口切语言后这里还是旧语言。
    @ObservedObject private var lang = LumoLanguageStore.shared

    @State private var tab: Tab = .appearance

    enum Tab: String, CaseIterable, Identifiable {
        case appearance, recognize, storage, update, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .appearance: return T("外观")
            case .recognize:  return T("识别")
            case .storage:    return T("存储")
            case .update:     return T("更新")
            case .about:      return T("关于")
            }
        }
        var icon: String {
            switch self {
            case .appearance: return "paintpalette"
            case .recognize:  return "text.viewfinder"
            case .storage:    return "internaldrive"
            case .update:     return "arrow.triangle.2.circlepath"
            case .about:      return "info.circle"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(LumoDesign.hairline).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: LumoDesign.gapGroup) {
                    switch tab {
                    case .appearance: AppearanceSection(theme: theme, lang: lang)
                    case .recognize:  RecognizeSection(prefs: prefs)
                    case .storage:    StorageSection(prefs: prefs)
                    case .update:     UpdateSection(service: updates, prefs: updates.prefs)
                    case .about:      AboutSection(prefs: prefs)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(LumoDesign.canvas.opacity(theme.glass.canvasOpacity))
        }
        .padding(.top, 34)
        // 同上：不忽略顶部安全区的话，SwiftUI 会再叠一层标题栏的内缩，
        // 侧栏第一项会被推到 70pt 处（实测），而不是设计上的 46pt。
        .ignoresSafeArea(.container, edges: .top)
        // 顶部可拖拽带。顺序要紧：**先 padding 再 overlay**，
        // 否则 overlay 会被算进被 padding 的区域里，跑到 y=30 而不是 y=0，
        // 表现是"顶部那条缝拖不动窗口"。
        .overlay(alignment: .top) {
            WindowDragStrip().frame(height: 34)
        }
        .background(
            ZStack {
                if theme.glass.wantsBackdrop {
                    VisualEffectBackdrop(material: .underWindowBackground,
                                         opacity: theme.glass.backdropOpacity).ignoresSafeArea()
                }
                LumoDesign.canvas.opacity(theme.glass.canvasOpacity).ignoresSafeArea()
            }
        )
        // 把玻璃档位沿视图树传下去（Environment 有默认值，漏传不会崩）
        .environment(\.lumoGlass, theme.glass)
        // 标题（窗口菜单 / 读屏会读它）也跟着语言走
        .background(WindowTitleSync(title: T("Lumo 设置")))
        // ★ 强调色。不设的话，分段控件 / 开关 / 滑块全走系统默认的蓝色，
        // 与界面上到处都在用的青绿完全不是一套——观感上像"这个控件是别人家的"。
        // `tint` 会沿视图树传下去，一处设好整窗统一。
        .tint(LumoDesign.accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Tab.allCases) { t in
                SidebarItem(tab: t, selected: tab == t) { tab = t }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .frame(width: 172)
        .background(theme.glass.panelMaterial)
    }
}

private struct SidebarItem: View {
    let tab: SettingsPanel.Tab
    let selected: Bool
    let onPick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 9) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: 18)
                Text(tab.title).font(LumoDesign.font(13))
                Spacer(minLength: 0)
            }
            .foregroundColor(selected ? LumoDesign.onAccent : LumoDesign.text)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: LumoDesign.radiusControl, style: .continuous)
                .fill(selected ? AnyShapeStyle(LumoDesign.accentGradient)
                               : AnyShapeStyle(hovering ? LumoDesign.hover : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: LumoDesign.Motion.hover), value: hovering)
        // 去掉 Tab 焦点环：设置窗口里第一个可聚焦控件会顶着一圈系统焦点环，
        // 而它未必是"当前选中的那一项"（实测：选中「更新」时，环留在「外观」上），
        // 看起来就像状态错了。VoiceOver 不受影响（辅助功能与 focusable 无关）。
        .focusable(false)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - 通用行

/// 设置里的一行：标题 + 说明 + 右侧控件。
struct SettingRow<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, detail: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LumoDesign.gap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(LumoDesign.font(13)).foregroundColor(LumoDesign.text)
                if let detail {
                    Text(detail).font(LumoDesign.font(11)).foregroundColor(LumoDesign.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: LumoDesign.gap)
            trailing()
        }
        .padding(.vertical, 4)
    }
}

/// 分组：小标题 + 一段说明 + 一个卡片容器。
struct SettingGroup<Content: View>: View {
    let title: String
    let hint: String?
    @ViewBuilder var content: () -> Content
    @Environment(\.lumoGlass) private var glass

    init(_ title: String, hint: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(LumoDesign.font(14, weight: .semibold))
                    .foregroundColor(LumoDesign.text)
                if let hint {
                    Text(hint).font(LumoDesign.font(11.5)).foregroundColor(LumoDesign.muted)
                }
            }
            VStack(alignment: .leading, spacing: 6) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: LumoDesign.radiusCard, style: .continuous)
                    .fill(LumoDesign.panel.opacity(glass.panelOpacity)))
                .overlay(RoundedRectangle(cornerRadius: LumoDesign.radiusCard, style: .continuous)
                    .stroke(LumoDesign.hairline))
        }
    }
}

// MARK: - 外观

private struct AppearanceSection: View {
    @ObservedObject var theme: LumoTheme
    /// 与 `theme` / `prefs` / `updates` 一样**由外面传进来**。
    ///
    /// 这里原本是内联初始化（`= LumoLanguageStore.shared`），一度以为那是 bug：
    /// 点分段控件毫无反应，而同一个视图里的 `theme.appearance` 点一下就好。
    /// **后来查明是误判**——当时屏幕上有个上一轮崩溃留下的系统弹窗，正好盖住了
    /// 这个控件，而 `appearance` 那一行在弹窗右边，所以只有它响应。
    /// 内联初始化本身没问题；改成传进来只是为了和本文件其余部分保持一致
    /// （这也是 SwiftUI 推荐的写法：`@ObservedObject` 由外部注入，而不是视图自造）。
    ///
    /// 留这段记录是因为**教训比结论值钱**：那次"两个控件行为不一致"看起来
    /// 完全像是绑定写错了，实际是屏幕上有东西挡着。诊断这类问题时，
    /// 先确认"点击到底落到了哪个窗口"（`CGWindowListCopyWindowInfo` 按坐标列一遍），
    /// 比读绑定代码快得多。
    @ObservedObject var lang: LumoLanguageStore

    var body: some View {
        // 语言放在"外观"页**最前面**，两个理由：
        //   · 它是打开设置后最先该定下来的事；
        //   · 改了它整页文字都会变——放在中间，用户会以为只有下半页跟着变了。
        SettingGroup(T("界面语言"), hint: T("默认跟随系统。改完立刻生效，不用重启。")) {
            Picker("", selection: $lang.choice) {
                ForEach(LumoLanguage.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        SettingGroup(T("外观模式"), hint: T("深浅两套是独立设计的，不是把颜色反过来")) {
            Picker("", selection: $theme.appearance) {
                ForEach(LumoAppearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        SettingGroup(T("玻璃质感"), hint: T("控件层用系统材质、内容层留出底色。点一下立刻生效")) {
            HStack(spacing: LumoDesign.gap) {
                ForEach(LumoGlass.allCases) { g in
                    GlassSwatch(glass: g, selected: theme.glass == g) { theme.glass = g }
                }
            }
            Text(theme.glass.hint)
                .font(LumoDesign.font(11.5)).foregroundColor(LumoDesign.muted)
        }

        SettingGroup(T("动效"), hint: nil) {
            SettingRow(T("遵循「减弱动态效果」"), detail: T("在系统设置里开启后，本应用的转场会变成瞬时切换。")) {
                Text(T("自动")).font(LumoDesign.font(12)).foregroundColor(LumoDesign.muted)
            }
        }
    }
}

/// 一档玻璃质感的可视化预览：一张迷你窗口，用真实的层叠关系画出来。
private struct GlassSwatch: View {
    let glass: LumoGlass
    let selected: Bool
    let onPick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onPick) {
            VStack(spacing: 8) {
                ZStack {
                    // 桌面（彩色渐变，用来体现"透出多少"）
                    LinearGradient(colors: [Color(hex: 0x34D399), Color(hex: 0x0EA5E9)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    // 窗口内容
                    VStack(spacing: 4) {
                        Capsule().fill(LumoDesign.text.opacity(0.35)).frame(height: 4)
                        Capsule().fill(LumoDesign.text.opacity(0.22)).frame(height: 4)
                        Spacer()
                    }
                    .padding(7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LumoDesign.canvas.opacity(glass.canvasOpacity))
                }
                .frame(height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(LumoDesign.hairline))

                Text(glass.title).font(LumoDesign.font(12, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? LumoDesign.accentDeep : LumoDesign.text)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: LumoDesign.radiusControl, style: .continuous)
                .fill(selected ? LumoDesign.accentSoft
                               : (hovering ? LumoDesign.hover : Color.clear)))
            .overlay(RoundedRectangle(cornerRadius: LumoDesign.radiusControl, style: .continuous)
                .stroke(selected ? LumoDesign.accentEdge : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - 识别

private struct RecognizeSection: View {
    @ObservedObject var prefs: LumoPreferences

    var body: some View {
        SettingGroup(T("文本识别默认值"), hint: T("这些是「新文件」的默认值；单个文件的语言可以在主界面里改")) {
            SettingRow(T("文档语言")) {
                Picker("", selection: $prefs.ocrLang) {
                    ForEach(OCR.languages, id: \.id) { l in
                        Text(l.name).tag(l.id)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            SettingRow(T("输出方式")) {
                Picker("", selection: $prefs.ocrOutput) {
                    Text(T("可搜索图像")).tag("searchable")
                    Text(T("可编辑文本")).tag("editable")
                }
                .labelsHidden()
                .frame(width: 200)
            }
            Text(T("识别在本机完成，不上传任何内容。"))
                .font(LumoDesign.font(11)).foregroundColor(LumoDesign.muted)
        }

        SettingGroup(T("主界面"), hint: nil) {
            SettingRow(T("载入文件后自动生成预览"),
                       detail: T("关掉后需要手动点「刷新预览」。批量处理很多文件时关掉它更省事。")) {
                Toggle("", isOn: $prefs.autoPreviewOnLoad).toggleStyle(.switch)
                    .tint(LumoDesign.accent).labelsHidden()
            }
        }
    }
}

// MARK: - 存储

private struct StorageSection: View {
    @ObservedObject var prefs: LumoPreferences
    @State private var cacheBytes: Int = 0

    var body: some View {
        SettingGroup(T("预览缓存"), hint: T("只清预览图；处理产物不会被清掉")) {
            SettingRow(T("当前占用")) {
                HStack(spacing: LumoDesign.gap) {
                    Text(lumoBytes(cacheBytes))
                        .font(LumoDesign.font(12.5).monospacedDigit())
                        .foregroundColor(LumoDesign.muted)
                    LumoButton(title: T("清理"), kind: .secondary, disabled: cacheBytes == 0) {
                        LumoBackend.clearPreviewCache()
                        cacheBytes = LumoBackend.previewCacheSize()
                    }
                }
            }
            Text(T("处理产物所在的目录由系统管理，退出 App 后会被回收。")
                 + T("「没保存的产物」不会被当成可清理的东西删掉——那是你还没拿走的东西，")
                 + T("把它算进「缓存」里就成了陷阱。"))
                .font(LumoDesign.font(11)).foregroundColor(LumoDesign.muted)
                .fixedSize(horizontal: false, vertical: true)
        }

        SettingGroup(T("窗口"), hint: nil) {
            SettingRow(T("记住窗口大小与位置")) {
                Toggle("", isOn: $prefs.rememberWindowSize).toggleStyle(.switch)
                    .tint(LumoDesign.accent).labelsHidden()
            }
        }
        .onAppear { cacheBytes = LumoBackend.previewCacheSize() }
    }
}

// MARK: - 更新

private struct UpdateSection: View {
    @ObservedObject var service: UpdateService
    @ObservedObject var prefs: UpdatePreferences
    @State private var confirmingRestart = false

    var body: some View {
        SettingGroup(T("更新方式"), hint: T("Lumo 唯一的联网功能就是这里")) {
            SettingRow(T("自动检查更新"),
                       detail: T("启动约 10 秒后检查一次，之后每天一次。")) {
                Toggle("", isOn: $prefs.autoCheck).toggleStyle(.switch)
                    .tint(LumoDesign.accent).labelsHidden()
            }
            SettingRow(T("自动下载并安装"),
                       detail: T("会退出并重启 App，所以默认关闭——那是要你点头的事。")) {
                Toggle("", isOn: $prefs.autoInstall).toggleStyle(.switch)
                    .tint(LumoDesign.accent).labelsHidden()
            }
            Text(T("关掉「自动检查更新」后，Lumo 一行网络请求都不会发。"))
                .font(LumoDesign.font(11)).foregroundColor(LumoDesign.muted)
        }

        SettingGroup(T("状态"), hint: nil) {
            statusRow

            HStack(spacing: LumoDesign.gap) {
                LumoButton(title: T("立即检查"), icon: "arrow.clockwise", kind: .secondary,
                           disabled: service.state == .checking) {
                    Task { @MainActor in await service.check(manual: true) }
                }
                if case .available = service.state {
                    LumoButton(title: T("跳过这个版本"), kind: .secondary) {
                        service.skipCurrentVersion()
                    }
                }
                if case .ready = service.state {
                    LumoButton(title: T("重启并更新"), icon: "arrow.triangle.2.circlepath") {
                        confirmingRestart = true
                    }
                }
                if case .failed(_, _, let url) = service.state, url != nil {
                    LumoButton(title: T("手动下载"), kind: .secondary) {
                        service.openManualDownload(url)
                    }
                }
            }

            HStack(spacing: 6) {
                Text(T("上次检查：%@", prefs.lastCheckedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? T("尚未检查过")))
                    .font(LumoDesign.font(11)).foregroundColor(LumoDesign.muted)
                Spacer()
                Button(T("查看更新日志")) {
                    let u = UpdateLog.url
                    if FileManager.default.fileExists(atPath: u.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([u])
                    } else {
                        NSWorkspace.shared.open(u.deletingLastPathComponent())
                    }
                }
                .buttonStyle(.link)
                .font(LumoDesign.font(11))
                .help(UpdateLog.url.path)
            }
        }

        // ★ 这里曾经是一整组叫「安全强度」的东西：写着"当前只校验 SHA-256、
        //   它是完整性检查不是来源检查、能换包的人也能换校验和"。
        //
        //   那是**实现细节**，不是用户需要知道的事。用户要判断的只有
        //   "这个更新能不能装"，而这件事 App 已经替他判完了——验不过就拒绝安装。
        //   把内部的强度选择摊在设置页上，既帮不上忙，又像是在替自己辩解。
        //   **产品不该对着用户解释自己的加密方案。** 校验逻辑一个字没动，
        //   只是不再往外讲；开关在哪、怎么开启见仓库的 SECURITY.md。
        SettingGroup(T("关于更新"), hint: nil) {
            SettingRow(T("更新源")) {
                Text(service.config.repository)
                    .font(LumoDesign.font(11.5).monospaced())
                    .foregroundColor(LumoDesign.muted)
                    .textSelection(.enabled)
            }
            SettingRow(T("当前版本")) {
                Text(service.config.currentVersion.description)
                    .font(LumoDesign.font(11.5).monospacedDigit())
                    .foregroundColor(LumoDesign.muted)
            }
        }
        .alert(T("现在重启并更新？"), isPresented: $confirmingRestart) {
            Button(T("取消"), role: .cancel) {}
            Button(T("重启并更新")) { Task { @MainActor in await service.installAndRelaunch() } }
        } message: {
            Text(T("Lumo 会退出，由后台助手替换应用包，然后自动重新打开。你已经打开的文件不受影响。"))
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch service.state {
        case .idle:
            Label(T("待检查"), systemImage: "clock")
                .font(LumoDesign.font(12)).foregroundColor(LumoDesign.muted)
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(T("正在检查…")).font(LumoDesign.font(12))
            }
        case .upToDate(let latest):
            Label(T("已是最新版本（%@）", latest), systemImage: "checkmark.circle.fill")
                .font(LumoDesign.font(12)).foregroundColor(LumoDesign.ok)
        case .available(let s):
            VStack(alignment: .leading, spacing: 6) {
                Label(T("发现新版本 %@", s.version), systemImage: "arrow.down.circle.fill")
                    .font(LumoDesign.font(12, weight: .medium)).foregroundColor(LumoDesign.accentDeep)
                if s.sizeBytes > 0 {
                    Text(T("安装包 %@", lumoBytes(s.sizeBytes)))
                        .font(LumoDesign.font(11)).foregroundColor(LumoDesign.muted)
                }
                if let notes = s.notes, !notes.isEmpty {
                    ScrollView {
                        Text(notes).font(LumoDesign.font(11)).foregroundColor(LumoDesign.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 76)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: LumoDesign.radiusSmall, style: .continuous)
                        .fill(LumoDesign.panelAlt))
                }
            }
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 6) {
                Text(T("正在下载… %@%%", Int(p * 100))).font(LumoDesign.font(12)).monospacedDigit()
                ProgressView(value: p)
            }
        case .ready(let v, _):
            Label(T("%@ 已就绪，重启即可完成更新", v), systemImage: "checkmark.seal.fill")
                .font(LumoDesign.font(12, weight: .medium)).foregroundColor(LumoDesign.ok)
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(T("正在替换应用包…")).font(LumoDesign.font(12))
            }
        case .blocked(let reason):
            Label(reason, systemImage: "hand.raised.fill")
                .font(LumoDesign.font(12)).foregroundColor(LumoDesign.warn)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message, let canRetry, let manualURL):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(LumoDesign.font(12)).foregroundColor(LumoDesign.warn)
                    .fixedSize(horizontal: false, vertical: true)
                if canRetry || manualURL != nil {
                    Text(T("可以点上面的「立即检查」重试")
                         + (manualURL != nil ? T("，或到 Releases 手动下载。") : "。"))
                        .font(LumoDesign.font(11)).foregroundColor(LumoDesign.muted)
                }
            }
        }
    }
}

// MARK: - 关于

private struct AboutSection: View {
    @ObservedObject var prefs: LumoPreferences
    @State private var confirmingReset = false

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    var body: some View {
        VStack(spacing: LumoDesign.gap) {
            LumoDesign.LumoMark(width: 62)
                .shadow(color: LumoDesign.accent.opacity(0.35), radius: 14, y: 4)
            VStack(spacing: 3) {
                Text(T("流明")).font(LumoDesign.font(20, weight: .semibold)).tracking(2)
                Text(T("扫描件焕新")).font(LumoDesign.font(12)).foregroundColor(LumoDesign.muted)
                    .tracking(1)
                Text(T("版本 %@", version)).font(LumoDesign.font(11.5))
                    .foregroundColor(LumoDesign.faint).monospacedDigit()
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)

        SettingGroup(T("内置文档"), hint: T("随 App 一起打包，不用联网、不用另找素材")) {
            HStack(spacing: LumoDesign.gap) {
                LumoButton(title: T("查看设计文档"), icon: "doc.richtext", kind: .secondary) {
                    BundledDoc.present(BundledDoc.design)
                }
                LumoButton(title: T("查看示例扫描件"), icon: "doc.text.magnifyingglass", kind: .secondary) {
                    BundledDoc.present(BundledDoc.sample)
                }
            }
        }

        SettingGroup(T("偏好"), hint: nil) {
            SettingRow(T("恢复默认设置"),
                       detail: T("只重置识别默认值与载入行为，不会动你的文件。")) {
                LumoButton(title: T("恢复默认"), kind: .secondary) { confirmingReset = true }
            }
        }
        .alert(T("恢复默认设置？"), isPresented: $confirmingReset) {
            Button(T("取消"), role: .cancel) {}
            Button(T("恢复默认")) { prefs.resetAll() }
        }

        Text(T("零第三方依赖：仅使用 CoreGraphics / Core Image / Vision / ImageIO / PDFKit / zlib。\n")
             + T("更新是唯一的联网功能，且只访问更新源。"))
            .font(LumoDesign.font(11)).foregroundColor(LumoDesign.faint)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }
}
