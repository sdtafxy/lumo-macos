// Lumo — 窗口外壳：统一标题栏 / 空态 / 底部状态栏 / 拖放
//
// 依据《macOS 单窗口玻璃质感设计参考》§3 §4 §5 §7。
// 三件事在这里落地：
//   · 统一标题栏：无独立标题条，内容延伸到顶，交通灯浮在内容上，只做避让；
//   · 渐进展开：Level 0 空态 = 一句话 + 一个全窗口拖放区，放入文件后列表接管；
//   · 底部状态栏常驻：左添加、中统计、右主按钮（对象级动作不走全局工具栏）。

import SwiftUI
import AppKit
import ObjectiveC
import UniformTypeIdentifiers
import LumoCore

// MARK: - 窗口配置

/// 把窗口调成"统一标题栏"形态，并落实几条只有 AppKit 才能设的东西。
///
/// 参考 §3 列了两条路：SwiftUI 的 window style / toolbar style，
/// 或 AppKit 的 `titlebarAppearsTransparent` / `fullSizeContentView` / `titleVisibility`。
/// 这里两条都用：`.windowStyle(.hiddenTitleBar)` 管大头，
/// 这个配置器补上 SwiftUI 没暴露的几项（分隔线、缩放下限、窗口标识、背景透明）。
struct WindowConfigurator: NSViewRepresentable {
    /// 主窗口的标识。AppDelegate 靠它把"主窗口"从设置窗口里认出来
    /// —— 关窗后点 Dock 图标时，不能把设置窗口当成主窗口提到前台。
    static let mainWindowIdentifier = "lumo.main"
    /// 帧自动保存用的名字。`rememberWindowSize` 关掉时会清空它。
    private static let frameAutosaveName = "LumoMainWindow"

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { configure(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ w: NSWindow?) {
        guard let w else { return }
        w.identifier = NSUserInterfaceItemIdentifier(Self.mainWindowIdentifier)
        // 登记一下，供 AppDelegate 在「点 Dock 图标」时把窗口端回来
        MainWindowRegistry.window = w

        // ★★ 把"关闭主窗口"变成"隐藏主窗口"。
        //
        // 这是「关窗后点 Dock 图标会闪出两个窗口」的**最终解法**，
        // 也是唯一一个不依赖"猜 SwiftUI 内部为什么"的解法。因果链见
        // `MainWindowDelegate` 的注释：只要窗口不被真正关掉，
        // 那条"必须新开一个"的路径就永远走不到，第二个窗口也就无从产生。
        installCloseInterceptor(on: w)

        // 显式关掉系统的窗口状态恢复。
        // 我们不希望 App 被激活时系统自己"把上次的窗口恢复回来"——
        // 那属于同一个"会凭空多出一个窗口"的家族。
        // （AppDelegate 里另有两处 shouldSave/Restore 的声明，双保险。）
        w.isRestorable = false

        w.titleVisibility = .hidden               // 隐藏标题，靠交通灯 + 内容识别
        w.titlebarAppearsTransparent = true       // 标题栏透明，与内容视觉连续
        w.styleMask.insert(.fullSizeContentView)  // 内容铺到窗口顶部边缘
        w.titlebarSeparatorStyle = .none          // 去掉那条分割线

        // ★ 窗口必须**非不透明 + 背景透明**，否则铺在视图树底层的
        //   `VisualEffectBackdrop`（blendingMode = .behindWindow）什么都采不到，
        //   表现是"玻璃档位切了没变化"。
        w.isOpaque = false
        w.backgroundColor = .clear

        // ★ 缩放下限。SwiftUI 那层的 `.frame(minWidth:minHeight:)` 管布局，
        //   这里再钉一次系统级的 `contentMinSize`——内容高度会随预览图变化，
        //   只靠 SwiftUI 时窗口仍有机会被拖到比布局需要的最小值更小。
        w.contentMinSize = NSSize(width: LumoDesign.windowMinWidth,
                                  height: LumoDesign.windowMinHeight)

        // ★ 刻意**不开** isMovableByWindowBackground。
        // 开了之后整窗任意空白处都能拖动，滑块和文本选区的操作手感会变得很怪。
        // 参考 §3 要的是"顶部约 50pt 区域保持可拖拽"，那就只留那 50pt（见 WindowDragStrip）。
        w.isMovableByWindowBackground = false

        Self.applyFrameAutosave(to: w)
    }

    /// 按用户偏好决定要不要记住窗口大小与位置。
    ///
    /// 直接读 UserDefaults 而不是问 `LumoPreferences.shared`：这个函数在 AppKit 侧、
    /// 不是 MainActor 上下文，为一个布尔值去跨 actor 不值得（键名见 LumoPreferenceKeys）。
    static func applyFrameAutosave(to w: NSWindow) {
        let remember = UserDefaults.standard.object(forKey: LumoPreferenceKeys.rememberWindowSize)
            as? Bool ?? true
        _ = w.setFrameAutosaveName(remember ? frameAutosaveName : "")
    }

    /// 给窗口装上"关闭即隐藏"的拦截器。**只装一次**（`updateNSView` 会被反复调用）。
    private func installCloseInterceptor(on w: NSWindow) {
        if objc_getAssociatedObject(w, &Self.proxyKey) is MainWindowDelegate { return }
        let proxy = MainWindowDelegate()
        proxy.forwarded = w.delegate
        // ⚠️ `NSWindow.delegate` 是 **weak** 的。不在别处强引用住代理，
        //    它会被立刻释放、delegate 变回 nil —— 拦截器静默失效。
        //    挂在窗口自己的关联对象上，生命周期就与窗口一致。
        objc_setAssociatedObject(w, &Self.proxyKey,
                                 proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        w.delegate = proxy

        // ★ 窗口打开时**不要自动把焦点给第一个按钮**。
        //
        // 不给的话，底栏最左边那个按钮会顶着一圈蓝色焦点环——看起来像"它被选中了"，
        // 实际上只是 AppKit 把第一响应者给了它。macOS 原生 App 里按钮默认是不带环的，
        // 那个环应该只在用户真的用 Tab 走键盘导航时出现。
        // 放在这里是因为这个分支**只会跑一次**（窗口刚建好那一下），
        // 不会在以后的每次 updateNSView 里反复把焦点抢走——那会打断用户正在输入的文本。
        DispatchQueue.main.async { w.makeFirstResponder(nil) }
    }

    private static var proxyKey: UInt8 = 0
}

/// 主窗口的关闭行为：**把"关"变成"藏"**。
///
/// 这是「关窗后点 Dock 图标会闪出两个窗口」的最终解法。因果链（诊断日志实测）：
///
///   ① 关掉主窗口 → AppKit 把它释放 → `MainWindowRegistry.window`（弱引用）变 nil；
///   ② 再点 Dock 图标 → 只能走"必须新开一个"那条路 → 调 `openWindow(id:)`；
///   ③ 而**一次** `openWindow` 会开出**两个**窗口（框架把"开一个窗口"和
///      "把这个组恢复回来"各做了一遍，两个窗口的坐标是 macOS 经典的层叠偏移）。
///      用户肉眼看到的就是「闪出两个、其中一个随即消失」。
///
/// 上一版的做法是在 ③ 之后打扫（留 key window、关掉其余）——那是**掩盖**，
/// 不是修复：窗口照样被创建、照样在屏幕上出现一帧。所以反馈才会说
/// 「其实并没有很好解决」。
///
/// 现在改成让 ① 永远不发生：拦下 `windowShouldClose`，返回 false（拒绝真的关闭）
/// 并改成 `orderOut`。窗口对象一直活着，弱引用一直有效，那条"必须新开"的路
/// 根本走不到，第二个窗口无从产生。
///
/// 代价：⌘W / 红灯从"关闭"变成"隐藏"。对单窗口工具类 App 这本来就是惯例
/// （参考 §4：关闭主窗口默认隐藏而非退出），而且**再打开时文件还在**——
/// 比"关掉再开、一切重来"更符合直觉。
///
/// 为什么用代理而不是直接 `w.delegate = self`：SwiftUI 自己会在窗口上挂 delegate，
/// 直接覆盖等于把它摘掉。所以这一个只截 `windowShouldClose`，其余选择子
/// 通过 `responds(to:)` + `forwardingTarget(for:)` 转发给原来的 delegate。
/// 转发对象用**弱引用**：万一它先被释放，最坏情况也只是"这几个方法没人实现"，
/// 与完全没有代理时一致 —— 不会比原来更坏。
final class MainWindowDelegate: NSObject, NSWindowDelegate {
    weak var forwarded: NSWindowDelegate?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return forwarded?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if super.responds(to: aSelector) { return nil }
        return forwarded
    }
}

/// 顶部可拖拽条。
///
/// `mouseDownCanMoveWindow = true` 是 AppKit 给的正路：不用手工调
/// `performDrag(with:)`，也不会把拖拽权扩散到整窗。
struct WindowDragStrip: NSViewRepresentable {
    final class DraggingView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { self }
    }
    func makeNSView(context: Context) -> NSView { DraggingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - 顶部工具区

/// 顶部工具区：交通灯避让 + 品牌 + （可拖拽的空白）+ 更新状态 + 设置。
///
/// 材质说明：用 `glass.barMaterial` 浮在内容之上——参考 §6 的"浮动控件用半透明材质"。
///
/// ⚠️ 布局上有一处是**反馈驱动的**：0.4.0 第一版的品牌是"20pt 图标 + 13pt 文字"，
/// 观感上又小又浮（反馈原文：「处在一个尴尬的位置，有点偏右、有点太小、没有设计感」）。
/// 改成两行后反馈仍是「位置还是有点不美观，要么就放大」，所以现在**只留一行、
/// 整体放大**（标识 36pt、主名 20pt，见 `BrandLockup`）。
///
/// 内边距收到 14：交通灯避让区 78 是硬需求（macOS 26 的交通灯确实占这么宽），
/// 能调的只有那层额外内边距。**别再往左压了**——再压品牌就贴到交通灯上了，
/// "偏右"的观感其实来自品牌块太小、周围太空，不是它真的靠右。
struct TopToolBar: View {
    @EnvironmentObject var updates: UpdateService
    @Environment(\.lumoGlass) private var glass

    private var hasUpdate: Bool {
        if case .available = updates.state { return true }
        if case .ready = updates.state { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 14) {
            // ★ 交通灯避让。
            //
            // ⚠️ 宽度要**减掉 HStack 的 spacing**：那 14pt 也会加在这段空白的右边，
            //    不减的话品牌会被多推 14pt。这是"偏右"的**另一半**来源——
            //    实测过：交通灯只占到 x=68pt（三个 14pt 圆，间距 23pt），
            //    而品牌左边缘当时在 106pt，中间空出 38pt 一条。
            //    改完之后品牌落在 92pt，与交通灯之间留 24pt——那是刻意的呼吸，
            //    不是"忘了对齐"。
            Spacer().frame(width: LumoDesign.trafficLightAvoid - 14)

            BrandLockup()
                // 品牌区也让它可拖：标题区是用户最自然会去拖的地方
                .overlay(WindowDragStrip())

            Spacer(minLength: LumoDesign.gap)

            // 空白处铺满拖拽条，顶部这一整条都能拖（参考 §3）
            WindowDragStrip().frame(height: LumoDesign.titleBarHeight)

            UpdateStatusChip(service: updates)

            LumoCircleButton(icon: "gearshape", help: "设置（⌘,）", badge: hasUpdate) {
                SettingsWindow.shared.show()
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 18)
        .frame(height: LumoDesign.titleBarHeight)
        .background(glass.barMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LumoDesign.hairline).frame(height: 1)
        }
    }
}

/// 右上角的更新状态。平时是一个不起眼的图标，有事才变成文字。
struct UpdateStatusChip: View {
    @ObservedObject var service: UpdateService

    var body: some View {
        switch service.state {
        case .available(let s):
            Button {
                SettingsWindow.shared.show()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 12))
                    Text("有新版 \(s.version)").font(LumoDesign.font(12, weight: .medium))
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(LumoDesign.accentSoft))
                .foregroundColor(LumoDesign.accentDeep)
            }
            .buttonStyle(.plain)
            .help("发现新版本 \(s.version)，去设置里查看")

        case .downloading(let p):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("下载中 \(Int(p * 100))%").font(LumoDesign.font(12))
                    .foregroundColor(LumoDesign.muted).monospacedDigit()
            }

        case .ready(let v, _, _):
            Button { SettingsWindow.shared.show() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                    Text("\(v) 已就绪").font(LumoDesign.font(12, weight: .medium))
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(LumoDesign.accentSoft))
                .foregroundColor(LumoDesign.accentDeep)
            }
            .buttonStyle(.plain)
            .help("新版本已下载并校验完成，去设置里重启更新")

        default:
            EmptyView()
        }
    }
}

// MARK: - 底部状态栏

/// 底部状态栏。参考 §7：左侧添加、中间统计、右侧主按钮；**空态时只保留添加入口**。
/// 参考 §6：轻材质 + 1px 极细分隔线。
struct BottomStatusBar: View {
    @EnvironmentObject var backend: LumoBackend
    @EnvironmentObject var state: AppState
    @Environment(\.lumoGlass) private var glass
    @Binding var showPicker: Bool

    private var isEmpty: Bool { state.stage == .drop }

    var body: some View {
        HStack(spacing: 14) {
            // 左：添加 / 换一个
            Button {
                showPicker = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(.system(size: 11.5, weight: .bold))
                    Text(isEmpty ? "添加 PDF" : "换一个文件")
                        .font(LumoDesign.font(13.5, weight: .medium))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: LumoDesign.radiusControl, style: .continuous)
                    .fill(LumoDesign.panelAlt.opacity(glass.panelOpacity)))
                .overlay(RoundedRectangle(cornerRadius: LumoDesign.radiusControl, style: .continuous)
                    .stroke(LumoDesign.hairline))
                .foregroundColor(LumoDesign.text)
            }
            .buttonStyle(.plain)
            .help(isEmpty ? "选择要处理的 PDF（也可以拖进来，或按 ⌘O）" : "换一个文件")

            if !isEmpty {
                Button {
                    state.resetToPicker()
                } label: {
                    Text("清空").font(LumoDesign.font(12.5))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .foregroundColor(LumoDesign.muted)
                }
                .buttonStyle(.plain)
                .help("回到空态，当前文件与结果都会清掉")
            }

            Divider().frame(height: 20)

            // 中：统计。
            //
            // `layoutPriority(-1)` 是刻意的：窗口变窄时**先压缩它**。
            // 右侧那一排是操作入口，左侧只是一行信息——宁可让信息打省略号，
            // 也不能让按钮被挤扁。（这是"底栏太挤"那半条反馈的结构性解法，
            // 另一半是把栏高和水平内边距加上去。）
            Text(statsText)
                .font(LumoDesign.font(12.5))
                .foregroundColor(LumoDesign.muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .monospacedDigit()
                .layoutPriority(-1)

            Spacer(minLength: 16)

            // 右：进度 + 操作。**整组 fixedSize**：它们是操作入口，宽度不能被让出去。
            HStack(spacing: 10) {
                if state.busy {
                    HStack(spacing: 8) {
                        Text(state.busyText).font(LumoDesign.font(12))
                            .foregroundColor(LumoDesign.muted).lineLimit(1)
                        if state.progress > 0.001 && state.progress < 0.999 {
                            ProgressView(value: state.progress).frame(width: 110)
                            Text("\(Int(state.progress * 100))%")
                                .font(LumoDesign.font(11)).foregroundColor(LumoDesign.muted)
                                .monospacedDigit()
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }

                if state.stage == .result, let r = state.result {
                    LumoButton(title: "在访达中显示", kind: .secondary) { reveal(r) }
                    LumoButton(title: "保存到…", kind: .secondary) { state.requestSave(r) }
                }

                LumoButton(title: runTitle,
                           disabled: state.busy || !backend.isReady || isEmpty) {
                    state.requestRun(backend: backend)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 24)
        .frame(height: LumoDesign.statusBarHeight)
        .background(glass.panelMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(LumoDesign.hairline).frame(height: 1)
        }
    }

    private var runTitle: String {
        if state.busy { return "处理中…" }
        return state.stage == .result ? "再处理一次" : "开始处理"
    }

    private var statsText: String {
        guard state.stage != .drop else {
            // ⚠️ 这里原本写的是「不联网，全部在本机完成」。加了自动更新之后
            // **那句话就不成立了**——App 现在确实会联网（只访问更新源）。
            // 一个不再成立的卖点比没有卖点更伤，所以改成只说能站住的那一半。
            return backend.isReady ? "引擎就绪 · 处理全部在本机完成" : backend.statusText
        }
        var bits: [String] = []
        if let r = state.report {
            bits.append("\(r.analysis.pageCount) 页")
            bits.append(lumoBytes(r.analysis.fileSize))
            bits.append(r.analysis.colorModeText)
            if let p = state.selectedPlan {
                bits.append("预计输出 \(lumoBytes(p.estBytes))")
            }
        }
        bits.append("增强 \(state.activeFilters.count) 项")
        bits.append(state.ocrEnabled ? "OCR" : "跳过 OCR")
        return bits.joined(separator: " · ")
    }

    private func reveal(_ r: ProcessResponse) {
        let src = URL(fileURLWithPath: r.outPath)
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([src])
    }
}

// MARK: - 空态

/// Level 0：全窗口即拖放区，中间是一块"品牌区 + 三个入口"。
///
/// 参考 §5「不做多步引导、不铺满功能入口、不弹 onboarding」——
/// 一句主提示 + 一句次要提示 + 少量低视觉权重的边角按钮。
///
/// ★ 与 0.4.0 第一版的区别（反馈驱动）：原来这里只有一行图标 + 一句话，
/// 而「载入示例扫描件」「打开设计文档」藏在菜单栏里——用户的原话是
/// 「设计文档你藏到了菜单栏里的帮助，但我也希望默认页面能看到直接打开它的按钮」。
/// 现在这两个入口就在主界面上，和「添加 PDF」并列。
struct EmptyStateView: View {
    @EnvironmentObject var backend: LumoBackend
    @EnvironmentObject var state: AppState
    @Environment(\.lumoGlass) private var glass
    @Binding var showPicker: Bool
    @State private var targeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: LumoDesign.gap)

            // 品牌区：这是在"还没有文件"时唯一占据视线的东西，
            // 所以它得撑得住场面——大图标 + 名称 + 一句话。
            LumoDesign.Emblem(size: 82)
                .shadow(color: LumoDesign.accent.opacity(0.38), radius: 18, y: 5)

            VStack(spacing: 4) {
                Text("把 PDF 拖到这里")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundColor(LumoDesign.text)
                    .padding(.top, 18)
                Text("感知 → 增强 → 识别 → 压缩，全程在本机完成，不上传任何内容。")
                    .font(LumoDesign.font(13))
                    .foregroundColor(LumoDesign.muted)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: LumoDesign.gapTight + 2) {
                LumoButton(title: "添加 PDF", icon: "plus") { showPicker = true }
                LumoButton(title: "载入示例扫描件", icon: "doc.text.magnifyingglass",
                           kind: .secondary) { loadSample() }
                LumoButton(title: "查看设计文档", icon: "doc.richtext",
                           kind: .secondary) { BundledDoc.present(BundledDoc.design) }
            }
            .padding(.top, 22)

            Text("也可以按 ⌘O 选择文件、⇧⌘V 粘贴文件路径，或把文件拖到 Dock 图标上。")
                .font(LumoDesign.font(11.5))
                .foregroundColor(LumoDesign.faint)
                .padding(.top, 14)

            Spacer(minLength: LumoDesign.gap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: LumoDesign.radiusCard, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: targeted ? 2 : 1,
                                                 dash: targeted ? [] : [6, 5]))
                .foregroundColor(targeted ? LumoDesign.accent : LumoDesign.hairline)
                .padding(LumoDesign.padWindow)
        )
        .animation(LumoMotion.animation(LumoDesign.Motion.appear, reduceMotion: reduceMotion),
                   value: targeted)
        .onDrop(of: FileDrop.acceptedTypes, isTargeted: $targeted) { providers in
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
        // 空态本身也接受快捷键，避免用户以为必须先点按钮
        .accessibilityElement(children: .contain)
        .accessibilityLabel("拖入 PDF 文件开始处理")
    }

    private func loadSample() {
        guard let u = BundledDoc.url(BundledDoc.sample) else {
            state.errorMessage = "没找到内置示例（安装包可能不完整）"
            return
        }
        Task { @MainActor in await state.load(url: u, backend: backend) }
    }
}

// MARK: - 文件行

/// 参考 §7「文件行」：图标 + 主标题（中截断保留扩展名）+ 次要元信息 + 状态；
/// 操作按钮默认低调，hover / 选中时才明显起来。
struct FileRow: View {
    @EnvironmentObject var state: AppState
    @State private var hovering = false

    var body: some View {
        if state.stage != .drop, let url = state.fileURL {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 15))
                    .foregroundColor(LumoDesign.accent)

                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(LumoDesign.font(13.5, weight: .medium))
                        .foregroundColor(LumoDesign.text)
                        .lineLimit(1)
                        .truncationMode(.middle)   // 中截断，保住扩展名
                    if let r = state.report {
                        Text("\(r.analysis.pageCount) 页 · \(lumoBytes(r.analysis.fileSize)) · \(r.analysis.colorModeText) · \(r.analysis.estimatedDpi) DPI")
                            .font(LumoDesign.font(11.5))
                            .foregroundColor(LumoDesign.muted)
                            .lineLimit(1)
                    } else {
                        Text("正在体检…").font(LumoDesign.font(11.5))
                            .foregroundColor(LumoDesign.muted)
                    }
                }

                Spacer(minLength: LumoDesign.gap)

                // 对象级动作就地展开（参考 §5 Level 1）：hover 时才浮出来
                HStack(spacing: 4) {
                    LumoIconButton(icon: "arrow.clockwise", help: "重新体检这个文件") {
                        Task { @MainActor in
                            if let u = state.fileURL { await state.load(url: u, backend: LumoBackend.shared) }
                        }
                    }
                    LumoIconButton(icon: "arrow.left.arrow.right", help: "换一个文件") {
                        state.resetToPicker()
                    }
                }
                .opacity(hovering ? 1 : 0.25)
                .animation(LumoMotion.animation(LumoDesign.Motion.hover, reduceMotion: false),
                           value: hovering)
            }
            .padding(.horizontal, 12)
            .frame(height: LumoDesign.rowHeight)
            .background(RoundedRectangle(cornerRadius: LumoDesign.radiusCard)
                .fill(LumoDesign.panel))
            .overlay(RoundedRectangle(cornerRadius: LumoDesign.radiusCard)
                .stroke(LumoDesign.hairline))
            .onHover { hovering = $0 }
        }
    }
}

// MARK: - 拖放

/// 拖放支持：同时接受**文件 URL 与文本**（参考 §7「拖放区」）。
/// 文本这一路很重要——从浏览器地址栏或访达里拖出来的常常是 URL 字符串。
enum FileDrop {
    static let acceptedTypes: [UTType] = [.fileURL, .url, .pdf, .plainText]

    /// 从一个拖放进来的 provider 里尽力挖出一个本地文件 URL。
    /// 参考 §10：**不支持的类型要明确提示，不能静默失败**——
    /// 所以挖不出来时回调 `onFailure`，由调用方弹一条人话。
    static func handle(_ providers: [NSItemProvider],
                       onFile: @escaping (URL) -> Void,
                       onFailure: @escaping (String) -> Void = { _ in }) {
        guard let p = providers.first else { return }

        func finish(_ url: URL?) {
            guard let url, url.isFileURL, url.pathExtension.lowercased() == "pdf" else {
                onFailure("只认 PDF。拖进来的是别的类型，或者不是本机文件。")
                return
            }
            onFile(url)
        }

        if p.canLoadObject(ofClass: URL.self) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async { finish(url) }
            }
            return
        }
        // 退一步：有些来源只给 file-url 的 Data，或者给的是纯文本路径 / 文本 URL
        p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let u = item as? URL { url = u }
            else if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
            if url != nil { DispatchQueue.main.async { finish(url) }; return }

            p.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                var text: String?
                if let s = item as? String { text = s }
                else if let d = item as? Data { text = String(data: d, encoding: .utf8) }
                DispatchQueue.main.async {
                    finish(FileDrop.fromText(text))
                }
            }
        }
    }

    /// 文本 → 文件 URL。支持 `file:///…`、`/绝对/路径.pdf`、以及裸路径。
    static func fromText(_ text: String?) -> URL? {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if raw.hasPrefix("file://"), let u = URL(string: raw), u.isFileURL { return u }
        let path = raw.hasPrefix("/") ? raw : nil
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// 从剪贴板取一个 PDF。⌘V 走这条路。
    static func fromPasteboard(_ pb: NSPasteboard = .general) -> URL? {
        // ① 文件 URL（在访达里复制文件）
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for u in urls where u.isFileURL && u.pathExtension.lowercased() == "pdf" { return u }
        }
        // ② 纯文本里的路径
        if let s = pb.string(forType: .string), let u = fromText(s) { return u }
        return nil
    }
}
