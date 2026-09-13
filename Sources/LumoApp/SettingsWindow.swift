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
        w.title = "Lumo 设置"
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

// MARK: - 面板

struct SettingsPanel: View {
    @ObservedObject private var prefs = LumoPreferences.shared
    @ObservedObject private var theme = LumoTheme.shared
    @ObservedObject private var updates = UpdateService.shared

    @State private var tab: Tab = .appearance

    enum Tab: String, CaseIterable, Identifiable {
        case appearance, recognize, storage, update, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .appearance: return "外观"
            case .recognize:  return "识别"
            case .storage:    return "存储"
            case .update:     return "更新"
            case .about:      return "关于"
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
                    case .appearance: AppearanceSection(theme: theme)
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

    var body: some View {
        SettingGroup("外观模式", hint: "深浅两套是独立设计的，不是把颜色反过来") {
            Picker("", selection: $theme.appearance) {
                ForEach(LumoAppearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        SettingGroup("玻璃质感", hint: "控件层用系统材质、内容层留出底色。点一下立刻生效") {
            HStack(spacing: LumoDesign.gap) {
                ForEach(LumoGlass.allCases) { g in
                    GlassSwatch(glass: g, selected: theme.glass == g) { theme.glass = g }
                }
            }
            Text(theme.glass.hint)
                .font(LumoDesign.font(11.5)).foregroundColor(LumoDesign.muted)
        }

        SettingGroup("动效", hint: nil) {
            SettingRow("遵循「减弱动态效果」", detail: "在系统设置里开启后，本应用的转场会变成瞬时切换。") {
                Text("自动").font(LumoDesign.font(12)).foregroundColor(LumoDesign.muted)
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
        SettingGroup("文本识别默认值", hint: "这些是「新文件」的默认值；单个文件的语言可以在主界面里改") {
            SettingRow("文档语言") {
                Picker("", selection: $prefs.ocrLang) {
                    ForEach(OCR.languages, id: \.id) { l in
                        Text(l.name).tag(l.id)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            SettingRow("输出方式") {
                Picker("", selection: $prefs.ocrOutput) {
                    Text("可搜索图像").tag("searchable")
                    Text("可编辑文本").tag("editable")
                }
                .labelsHidden()
                .frame(width: 200)
            }
            Text("识别在本机完成，不上传任何内容。")
                .font(LumoDesign.font(11)).foregroundColor(LumoDesign.muted)
        }

        SettingGroup("主界面", hint: nil) {
            SettingRow("载入文件后自动生成预览",
                       detail: "关掉后需要手动点「刷新预览」。批量处理很多文件时关掉它更省事。") {
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
        SettingGroup("预览缓存", hint: "只清预览图；处理产物不会被清掉") {
            SettingRow("当前占用") {
                HStack(spacing: LumoDesign.gap) {
                    Text(lumoBytes(cacheBytes))
                        .font(LumoDesign.font(12.5).monospacedDigit())
                        .foregroundColor(LumoDesign.muted)
                    LumoButton(title: "清理", kind: .secondary, disabled: cacheBytes == 0) {
                        LumoBackend.clearPreviewCache()
                        cacheBytes = LumoBackend.previewCacheSize()
                    }
                }
            }
            Text("处理产物所在的目录由系统管理，退出 App 后会被回收。"
                 + "「没保存的产物」不会被当成可清理的东西删掉——那是你还没拿走的东西，"
                 + "把它算进「缓存」里就成了陷阱。")
                .font(LumoDesign.font(11)).foregroundColor(LumoDesign.muted)
                .fixedSize(horizontal: false, vertical: true)
        }

        SettingGroup("窗口", hint: nil) {
            SettingRow("记住窗口大小与位置") {
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
        SettingGroup("更新方式", hint: "Lumo 唯一的联网功能就是这里") {
            SettingRow("自动检查更新",
                       detail: "启动约 10 秒后检查一次，之后每天一次。") {
                Toggle("", isOn: $prefs.autoCheck).toggleStyle(.switch)
                    .tint(LumoDesign.accent).labelsHidden()
            }
            SettingRow("自动下载并安装",
                       detail: "会退出并重启 App，所以默认关闭——那是要你点头的事。") {
                Toggle("", isOn: $prefs.autoInstall).toggleStyle(.switch)
                    .tint(LumoDesign.accent).labelsHidden()
            }
            Text("关掉「自动检查更新」后，Lumo 一行网络请求都不会发。")
                .font(LumoDesign.font(11)).foregroundColor(LumoDesign.muted)
        }

        SettingGroup("状态", hint: nil) {
            statusRow

            HStack(spacing: LumoDesign.gap) {
                LumoButton(title: "立即检查", icon: "arrow.clockwise", kind: .secondary,
                           disabled: service.state == .checking) {
                    Task { @MainActor in await service.check(manual: true) }
                }
                if case .available = service.state {
                    LumoButton(title: "跳过这个版本", kind: .secondary) {
                        service.skipCurrentVersion()
                    }
                }
                if case .ready = service.state {
                    LumoButton(title: "重启并更新", icon: "arrow.triangle.2.circlepath") {
                        confirmingRestart = true
                    }
                }
                if case .failed(_, _, let url) = service.state, url != nil {
                    LumoButton(title: "手动下载", kind: .secondary) {
                        service.openManualDownload(url)
                    }
                }
            }

            HStack(spacing: 6) {
                Text("上次检查：\(prefs.lastCheckedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "尚未检查过")")
                    .font(LumoDesign.font(11)).foregroundColor(LumoDesign.muted)
                Spacer()
                Button("查看更新日志") {
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

        SettingGroup("安全强度", hint: nil) {
            if service.config.signingRequired {
                Label("已配置公钥：安装前强制验证 Ed25519 签名，缺少签名文件直接拒绝，不会降级成只查校验和。",
                      systemImage: "checkmark.seal.fill")
                    .font(LumoDesign.font(11.5)).foregroundColor(LumoDesign.ok)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("未配置公钥：当前只校验 SHA-256。", systemImage: "exclamationmark.shield")
                    .font(LumoDesign.font(11.5)).foregroundColor(LumoDesign.warn)
                Text("SHA-256 是「完整性」检查，不是「来源」检查——校验和与安装包放在同一个 Release 里，"
                     + "能替换安装包的人也能替换校验和。它能挡住传输损坏，挡不住「有人换了个包」。")
                    .font(LumoDesign.font(11)).foregroundColor(LumoDesign.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(LumoDesign.hairline).padding(.vertical, 2)
            SettingRow("更新源") {
                Text(service.config.repository)
                    .font(LumoDesign.font(11.5).monospaced())
                    .foregroundColor(LumoDesign.muted)
                    .textSelection(.enabled)
            }
            SettingRow("当前版本") {
                Text(service.config.currentVersion.description)
                    .font(LumoDesign.font(11.5).monospacedDigit())
                    .foregroundColor(LumoDesign.muted)
            }
        }
        .alert("现在重启并更新？", isPresented: $confirmingRestart) {
            Button("取消", role: .cancel) {}
            Button("重启并更新") { Task { @MainActor in await service.installAndRelaunch() } }
        } message: {
            Text("Lumo 会退出，由后台助手替换应用包，然后自动重新打开。你已经打开的文件不受影响。")
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch service.state {
        case .idle:
            Label("待检查", systemImage: "clock")
                .font(LumoDesign.font(12)).foregroundColor(LumoDesign.muted)
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在检查…").font(LumoDesign.font(12))
            }
        case .upToDate(let latest):
            Label("已是最新版本（\(latest)）", systemImage: "checkmark.circle.fill")
                .font(LumoDesign.font(12)).foregroundColor(LumoDesign.ok)
        case .available(let s):
            VStack(alignment: .leading, spacing: 6) {
                Label("发现新版本 \(s.version)", systemImage: "arrow.down.circle.fill")
                    .font(LumoDesign.font(12, weight: .medium)).foregroundColor(LumoDesign.accentDeep)
                if s.sizeBytes > 0 {
                    Text("安装包 \(lumoBytes(s.sizeBytes)) · "
                         + (s.hasSignature ? "带签名" : (s.hasChecksum ? "带校验和" : "无校验信息")))
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
                Text("正在下载… \(Int(p * 100))%").font(LumoDesign.font(12)).monospacedDigit()
                ProgressView(value: p)
            }
        case .ready(let v, let level, let note):
            VStack(alignment: .leading, spacing: 6) {
                Label("\(v) 已下载并校验通过", systemImage: "checkmark.seal.fill")
                    .font(LumoDesign.font(12, weight: .medium)).foregroundColor(LumoDesign.ok)
                Text("校验级别：\(level.label)").font(LumoDesign.font(11))
                    .foregroundColor(LumoDesign.muted)
                Text(note).font(LumoDesign.font(11)).foregroundColor(LumoDesign.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在替换应用包…").font(LumoDesign.font(12))
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
                    Text("可以点上面的「立即检查」重试"
                         + (manualURL != nil ? "，或到 Releases 手动下载。" : "。"))
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
            LumoDesign.Emblem(size: 76)
                .shadow(color: LumoDesign.accent.opacity(0.35), radius: 12, y: 3)
            VStack(spacing: 3) {
                Text("Lumo · 流明").font(LumoDesign.font(19, weight: .semibold))
                Text("版本 \(version)").font(LumoDesign.font(11.5))
                    .foregroundColor(LumoDesign.muted).monospacedDigit()
            }
            Text("扫描件焕新：感知 → 增强 → 识别 → 压缩，全程在本机完成。")
                .font(LumoDesign.font(12)).foregroundColor(LumoDesign.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)

        SettingGroup("内置文档", hint: "随 App 一起打包，不用联网、不用另找素材") {
            HStack(spacing: LumoDesign.gap) {
                LumoButton(title: "查看设计文档", icon: "doc.richtext", kind: .secondary) {
                    BundledDoc.present(BundledDoc.design)
                }
                LumoButton(title: "查看示例扫描件", icon: "doc.text.magnifyingglass", kind: .secondary) {
                    BundledDoc.present(BundledDoc.sample)
                }
            }
        }

        SettingGroup("偏好", hint: nil) {
            SettingRow("恢复默认设置",
                       detail: "只重置识别默认值与载入行为，不会动你的文件。") {
                LumoButton(title: "恢复默认", kind: .secondary) { confirmingReset = true }
            }
        }
        .alert("恢复默认设置？", isPresented: $confirmingReset) {
            Button("取消", role: .cancel) {}
            Button("恢复默认") { prefs.resetAll() }
        }

        Text("零第三方依赖：仅使用 CoreGraphics / Core Image / Vision / ImageIO / PDFKit / zlib。\n"
             + "更新是唯一的联网功能，且只访问更新源。")
            .font(LumoDesign.font(11)).foregroundColor(LumoDesign.faint)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }
}
