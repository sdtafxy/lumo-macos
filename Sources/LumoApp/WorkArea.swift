// Lumo — 工作区：预览（左，主区） + 参数 inspector（右）
//
// 参考 §5「渐进展开模型」：
//   Level 1 有内容 → 文件行 + 主区域接管
//   Level 2 聚焦单对象 → **在同一窗口内展开参数区**，优先行内展开、其次右侧 inspector，
//                        高级选项默认折叠，参数改动即时可见结果（预览）
// 所以这里没有"点一个功能开一个新窗口"，也没有把参数塞进全局工具栏。

import SwiftUI
import AppKit
import LumoCore

// MARK: - 工作区

struct WorkArea: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lumoGlass) private var glass

    var body: some View {
        HStack(spacing: 0) {
            // 主区：预览。它是这个 App 的价值所在，占最大的地方。
            PreviewStage()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

            Rectangle().fill(LumoDesign.hairline).frame(width: 1)

            // 右栏：参数 inspector。参考 §6「侧边栏、inspector 用系统材质」
            ParamInspector()
                // 固定宽度：它是 inspector，不该参与"谁让一步"的弹性分配。
                // 窗口的最小宽度就是照它算出来的（见 LumoDesign.windowMinWidth）。
                .frame(width: LumoDesign.inspectorWidth)
                .background(glass.panelMaterial)
        }
        .animation(LumoMotion.animation(LumoDesign.Motion.state, reduceMotion: reduceMotion),
                   value: state.stage)
    }
}

// MARK: - 预览主区

/// 预览：同一页、同一位置的"处理前 → 处理后"。
/// 参考 §7：状态用图标与语义色，失败可点击查看原因。
///
/// ★ 翻页交互是**反馈驱动**重做的：原来只有「◀ 第 N / M 页 ▶」两个按钮，
/// 用户的原话是「现在一页页点太费力了」。现在加了滑块（可以一把拉到底）
/// 和页码输入框（可以直接跳到第 37 页）。
///
/// 关键取舍：**拖动滑块时只更新页码，松手才真的渲染**。
/// 不这么做的话，一次拖动会触发几十次整页渲染 + 增强，滑块会卡成幻灯片。
struct PreviewStage: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var backend: LumoBackend
    @Environment(\.lumoGlass) private var glass

    @State private var sliderValue: Double = 1
    @State private var pageField: String = "1"
    @FocusState private var pageFieldFocused: Bool

    private var pageCount: Int { max(1, state.report?.analysis.pageCount ?? 1) }

    var body: some View {
        VStack(spacing: 0) {
            header

            // 过程说明与错误：⚠ 用语义警告色，ⓘ 用次要灰。
            // 把"没事"说成"坏了"是另一种误导，所以两者绝不能共用一个颜色。
            VStack(alignment: .leading, spacing: 4) {
                if let n = state.previewNote {
                    Label(n, systemImage: "exclamationmark.triangle.fill")
                        .font(LumoDesign.font(12)).foregroundColor(LumoDesign.warn)
                }
                if let h = state.previewHint {
                    Label(h, systemImage: "info.circle")
                        .font(LumoDesign.font(12)).foregroundColor(LumoDesign.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LumoDesign.padWindow)
            .padding(.bottom, state.previewNote == nil && state.previewHint == nil ? 0 : LumoDesign.gapTight)

            HStack(spacing: LumoDesign.gap) {
                PreviewPane(caption: "原图", image: state.previewBefore, busy: state.previewBusy)
                Image(systemName: "arrow.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(LumoDesign.accent)
                PreviewPane(caption: "处理后", image: state.previewAfter, busy: state.previewBusy)
            }
            .padding(.horizontal, LumoDesign.padWindow)
            .padding(.vertical, LumoDesign.gap)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LumoDesign.canvas.opacity(glass.canvasOpacity))
        // 页码与滑块的双向同步：外部（按钮 / 换文件）改了页码，滑块的 thumb 要跟上。
        .onChange(of: state.previewPage) { p in
            sliderValue = Double(p)
            if !pageFieldFocused { pageField = "\(p)" }
        }
        .onChange(of: pageCount) { n in
            sliderValue = min(sliderValue, Double(max(1, n)))
            if !pageFieldFocused { pageField = "\(state.previewPage)" }
        }
        .onDrop(of: FileDrop.acceptedTypes, isTargeted: .constant(false)) { providers in
            // 工作态里也能直接拖进新文件——参考 §2 Downie「输入入口极宽容」。
            FileDrop.handle(providers) { url in
                Task { @MainActor in await state.load(url: url, backend: backend) }
            } onFailure: { msg in
                state.errorMessage = msg
            }
            return true
        }
    }

    // MARK: 头部（翻页 + 刷新）

    private var header: some View {
        VStack(alignment: .leading, spacing: LumoDesign.gapTight) {
            HStack(spacing: LumoDesign.gapTight) {
                Text("效果预览").font(LumoDesign.font(13, weight: .semibold))
                    .foregroundColor(LumoDesign.text)
                if state.previewBusy {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                LumoButton(title: state.previewAfter == nil ? "生成预览" : "刷新预览",
                           icon: "arrow.clockwise", kind: .secondary,
                           disabled: state.previewBusy || state.fileURL == nil) {
                    render()
                }
            }

            HStack(spacing: 10) {
                LumoCircleButton(icon: "chevron.left", help: "上一页",
                                 disabled: state.previewPage <= 1 || state.previewBusy) {
                    jump(to: state.previewPage - 1)
                }

                // 页码输入框：直接跳到第 N 页
                TextField("", text: $pageField)
                    .textFieldStyle(.plain)
                    .font(LumoDesign.font(12).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .frame(width: 44)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: LumoDesign.radiusField, style: .continuous)
                        .fill(LumoDesign.panelAlt.opacity(glass.panelOpacity)))
                    .overlay(RoundedRectangle(cornerRadius: LumoDesign.radiusField, style: .continuous)
                        .stroke(pageFieldFocused ? LumoDesign.accentEdge : LumoDesign.hairline))
                    .focused($pageFieldFocused)
                    .onSubmit { commitPageField() }
                    .help("输入页码后回车跳转")

                Text("/ \(pageCount) 页")
                    .font(LumoDesign.font(12)).foregroundColor(LumoDesign.muted)
                    .monospacedDigit().fixedSize()

                LumoCircleButton(icon: "chevron.right", help: "下一页",
                                 disabled: state.previewPage >= pageCount || state.previewBusy) {
                    jump(to: state.previewPage + 1)
                }

                // 滑块：从头拉到尾。拖动时只更新页码，松手才渲染（见类型注释）
                Slider(value: $sliderValue,
                       in: 1...Double(max(2, pageCount)),
                       step: 1) { editing in
                    if !editing { jump(to: Int(sliderValue.rounded())) }
                }
                .disabled(pageCount <= 1 || state.previewBusy)
                .frame(minWidth: 120)

                if pageCount > 1 {
                    Text("第 \(state.previewPage) 页")
                        .font(LumoDesign.font(11)).foregroundColor(LumoDesign.faint)
                        .monospacedDigit().frame(minWidth: 52, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, LumoDesign.padWindow)
        .padding(.top, LumoDesign.gap)
        .padding(.bottom, LumoDesign.gapTight)
    }

    // MARK: 动作

    /// 翻到某一页并重渲染。所有入口（上一页 / 下一页 / 滑块 / 页码框）都走这里，
    /// 保证钳位逻辑只有一份 —— 分散写的话迟早有一处忘了 clamp，然后越界崩在别处。
    private func jump(to page: Int) {
        let clamped = max(1, min(pageCount, page))
        guard clamped != state.previewPage else {
            // 页码没变（例如滑块拖回原位）就不重算，省一次几百毫秒的渲染
            sliderValue = Double(clamped)
            pageField = "\(clamped)"
            return
        }
        state.previewPage = clamped
        sliderValue = Double(clamped)
        pageField = "\(clamped)"
        render()
    }

    private func render() {
        Task { @MainActor in await state.refreshPreview(backend: backend) }
    }

    private func commitPageField() {
        pageFieldFocused = false
        guard let n = Int(pageField.trimmingCharacters(in: .whitespaces)) else {
            pageField = "\(state.previewPage)"      // 不是数字：退回当前页，不弹错
            return
        }
        jump(to: n)
    }
}

struct PreviewPane: View {
    let caption: String
    let image: NSImage?
    let busy: Bool
    @Environment(\.lumoGlass) private var glass

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Text(caption).font(LumoDesign.font(11.5, weight: .medium))
                    .foregroundColor(LumoDesign.muted)
                if busy { ProgressView().controlSize(.mini) }
            }
            ZStack {
                RoundedRectangle(cornerRadius: LumoDesign.radiusControl, style: .continuous)
                    .fill(LumoDesign.panelAlt.opacity(glass.panelOpacity))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo").font(.system(size: 22, weight: .light))
                            .foregroundColor(LumoDesign.faint)
                        Text("载入后自动生成预览")
                            .font(LumoDesign.font(11.5)).foregroundColor(LumoDesign.muted)
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: LumoDesign.radiusControl, style: .continuous)
                .stroke(LumoDesign.hairline))
            // 最小尺寸是**窗口最小尺寸的计算依据**（见 LumoDesign.windowMinWidth）：
            // 预览区被压到比这更小时，两张图会缩成两条缝，看起来就是"界面坏了"。
            .frame(minWidth: 180, minHeight: 220)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 参数 inspector

struct ParamInspector: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var backend: LumoBackend
    @State private var showAdvanced = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LumoDesign.gapGroup) {
                FileRow()

                ReportSection()

                // 增强模式：五个成体系的效果（不是一堆滤镜参数）
                InspectorGroup("扫描增强", hint: "选一种效果，左边的预览会按这一页实时算") {
                    VStack(spacing: 6) {
                        ForEach(EnhancePreset.allCases, id: \.rawValue) { p in
                            PresetRow(preset: p, selected: state.preset == p.rawValue) {
                                state.preset = p.rawValue
                                Task { @MainActor in await state.refreshPreview(backend: backend) }
                            }
                        }
                    }
                    // 滑块只对会做"背景归一化"的模式有意义。黑白档走二值化、
                    // 原图档压根不碰画面——这两档摆个滑块出来，用户拉了没反应，
                    // 只会怀疑软件坏了（这就是 L4 的现场）。
                    if EnhancePreset(state.preset).usesBgStrength {
                        BackgroundStrengthSlider()
                    }
                }

                // 微调：只在少数文件上才有用，默认折叠
                InspectorGroup("微调", hint: "只在少数文件上才需要") {
                    VStack(spacing: 6) {
                        FilterRow(icon: "scissors", title: "自动裁边", desc: "裁到纸张边缘，校正透视",
                                  isOn: Binding(get: { state.filters.autoCrop ?? false },
                                                set: { state.filters.autoCrop = $0 }))
                        FilterRow(icon: "angle", title: "纠偏", desc: "自动旋转回正",
                                  isOn: Binding(get: { state.filters.deskew ?? false },
                                                set: { state.filters.deskew = $0 }))
                        FilterRow(icon: "squareshape.split.2x2", title: "去网纹", desc: "消去印刷网点",
                                  isOn: Binding(get: { state.filters.descreen ?? false },
                                                set: { state.filters.descreen = $0 }))
                        FilterRow(icon: "wand.and.sparkles", title: "文本锐化", desc: "非锐化掩膜",
                                  isOn: Binding(get: { (state.filters.sharpen ?? 0) > 0 },
                                                set: { state.filters.sharpen = $0 ? 1.0 : 0.0 }))
                    }
                    .onChange(of: state.filters.autoCrop) { _ in
                        state.schedulePreview(backend: backend)
                    }
                }

                // 作用范围
                InspectorGroup("作用范围") {
                    Picker("", selection: $state.pageScope) {
                        Text("全部页面").tag("all")
                        Text("当前页").tag("current")
                        Text("指定范围").tag("range")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if state.pageScope == "range" {
                        TextField("例如 1-3,5", text: $state.pageRange)
                            .textFieldStyle(.roundedBorder)
                            .font(LumoDesign.font(12.5))
                    }
                }

                // 识别开关：语言与输出方式进设置（参考 §5：高级选项默认折叠）
                InspectorGroup("文本识别") {
                    HStack(spacing: LumoDesign.gap) {
                        LumoToggle(isOn: $state.ocrEnabled)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(state.report?.recommendation.ocr.skip == true
                                 ? "已跳过（文件自带文字层）" : "生成可搜索 PDF")
                                .font(LumoDesign.font(13, weight: .medium))
                                .foregroundColor(LumoDesign.text)
                            Text("语言与输出方式在设置里（⌘,）")
                                .font(LumoDesign.font(11)).foregroundColor(LumoDesign.muted)
                        }
                        Spacer()
                    }
                }

                // 压缩方案：三档卡片，预估体积直接给出来
                InspectorGroup("智能压缩", hint: "体积已预估") {
                    VStack(spacing: 6) {
                        ForEach(state.report?.plans ?? []) { p in
                            PlanRow(plan: p, selected: state.planId == p.id) {
                                state.planId = p.id
                                state.adoptPlan(p)
                            }
                        }
                    }
                }

                // 高级选项：默认折叠（参考 §5「高级选项默认折叠」）。
                // 编码器细节其实更适合放设置窗口，但"这一份文件想怎么压"属于对象级决定，
                // 留在 inspector 里更顺手。设置窗口放的是**全局**偏好。
                DisclosureGroup(isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: LumoDesign.gap) {
                        HStack(spacing: LumoDesign.gap) {
                            LumoToggle(isOn: $state.adaptive)
                            Text("自适应压缩（按页选最省编码）")
                                .font(LumoDesign.font(12.5))
                            Spacer()
                        }
                        labeledPicker("彩色 / 灰度编码", selection: $state.colorEncoder,
                                      options: [("JPEG", "jpeg"), ("JPEG2000", "jp2"), ("ZIP 无损", "zip")])
                        labeledPicker("单色编码", selection: $state.monoEncoder,
                                      options: [("CCITT 组4", "ccitt"), ("ZIP 无损", "zip")])
                        VStack(alignment: .leading, spacing: 4) {
                            Text("质量 \(Int(state.quality))")
                                .font(LumoDesign.font(12)).foregroundColor(LumoDesign.muted)
                            Slider(value: $state.quality, in: 20...95, step: 1)
                        }
                    }
                    .padding(.top, LumoDesign.gapTight)
                } label: {
                    Text("高级选项").font(LumoDesign.font(12.5, weight: .medium))
                        .foregroundColor(LumoDesign.muted)
                }

                // 结果卡：处理完就地显示，不跳页
                if state.stage == .result, let r = state.result {
                    InspectorGroup("处理完成") {
                        VStack(alignment: .leading, spacing: LumoDesign.gapTight) {
                            HStack(spacing: LumoDesign.gap) {
                                metric("原始", lumoBytes(r.inSize))
                                metric("输出", lumoBytes(r.outSize))
                                metric("压缩", String(format: "%.1f×",
                                                      Double(r.inSize) / max(1, Double(r.outSize))))
                            }
                            Text("OCR \(r.ocrEngine ?? "无") · \(r.ocrChars) 字 · \(String(format: "%.1f", r.elapsedSec))s")
                                .font(LumoDesign.font(11.5)).foregroundColor(LumoDesign.muted)
                            ForEach(r.warnings, id: \.self) { w in
                                Label(w, systemImage: "exclamationmark.triangle.fill")
                                    .font(LumoDesign.font(11.5)).foregroundColor(LumoDesign.warn)
                            }
                            FlowChips(items: r.steps)
                        }
                    }
                }
            }
            .padding(LumoDesign.padWindow)
        }
    }

    private func metric(_ k: String, _ v: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(LumoDesign.font(16, weight: .bold))
                .foregroundColor(LumoDesign.accentDeep).monospacedDigit()
            Text(k).font(LumoDesign.font(11)).foregroundColor(LumoDesign.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: LumoDesign.radiusControl).fill(LumoDesign.panelAlt))
    }

    private func labeledPicker(_ title: String, selection: Binding<String>,
                               options: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(LumoDesign.font(12)).foregroundColor(LumoDesign.muted)
            Picker("", selection: selection) {
                ForEach(options, id: \.1) { Text($0.0).tag($0.1) }
            }
            .labelsHidden()
        }
    }
}

/// inspector 里的分组：标题 + 说明 + 内容。
struct InspectorGroup<Content: View>: View {
    let title: String
    let hint: String?
    let content: Content

    init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LumoDesign.gapTight) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(LumoDesign.font(13, weight: .semibold))
                    .foregroundColor(LumoDesign.text)
                if let hint {
                    Text(hint).font(LumoDesign.font(11)).foregroundColor(LumoDesign.muted)
                }
            }
            content
        }
    }
}

// MARK: - 体检报告（行内展开，不弹窗）

struct ReportSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if let r = state.report {
            let a = r.analysis
            InspectorGroup("体检报告", hint: "自动读出来的，不用你填") {
                VStack(alignment: .leading, spacing: LumoDesign.gapTight) {
                    HStack(spacing: 6) {
                        metric("色彩", a.colorModeText)
                        metric("分辨率", "\(a.estimatedDpi)")
                        metric("倾斜", String(format: "%.2f°", a.skewAngle))
                        metric("背景", a.bgText)
                    }
                    ForEach(r.recommendation.notes, id: \.self) { n in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                .foregroundColor(LumoDesign.ok).padding(.top, 2)
                            Text(n).font(LumoDesign.font(11.5))
                                .foregroundColor(LumoDesign.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func metric(_ k: String, _ v: String) -> some View {
        VStack(spacing: 1) {
            Text(v).font(LumoDesign.font(13, weight: .semibold))
                .foregroundColor(LumoDesign.text).lineLimit(1)
            Text(k).font(LumoDesign.font(10)).foregroundColor(LumoDesign.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: LumoDesign.radiusSmall).fill(LumoDesign.panelAlt))
    }
}

// MARK: - 参数行（参考 §6：行高 36 紧凑）

/// 增强模式行。
struct PresetRow: View {
    let preset: EnhancePreset
    let selected: Bool
    let onPick: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 10) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 13))
                    .frame(width: 22, height: 22)
                    .foregroundColor(selected ? LumoDesign.accentDeep : LumoDesign.muted)
                VStack(alignment: .leading, spacing: 0) {
                    Text(preset.title).font(LumoDesign.font(12.5, weight: .medium))
                        .foregroundColor(LumoDesign.text)
                    Text(preset.desc).font(LumoDesign.font(10.5)).foregroundColor(LumoDesign.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                        .foregroundColor(LumoDesign.accentDeep)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: LumoDesign.rowHeightCompact)
            .background(RoundedRectangle(cornerRadius: LumoDesign.radiusControl)
                .fill(selected ? LumoDesign.accentSoft : (hovering ? LumoDesign.hover : .clear)))
            .overlay(RoundedRectangle(cornerRadius: LumoDesign.radiusControl)
                .stroke(selected ? LumoDesign.accentEdge : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(LumoMotion.animation(LumoDesign.Motion.hover, reduceMotion: reduceMotion),
                   value: hovering)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// 微调开关行
struct FilterRow: View {
    let icon: String; let title: String; let desc: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12))
                .frame(width: 18)
                .foregroundColor(isOn ? LumoDesign.accentDeep : LumoDesign.faint)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(LumoDesign.font(12.5)).foregroundColor(LumoDesign.text)
                Text(desc).font(LumoDesign.font(10.5)).foregroundColor(LumoDesign.muted)
            }
            Spacer(minLength: 4)
            LumoToggle(isOn: $isOn)
        }
        .padding(.horizontal, 10)
        .frame(height: LumoDesign.rowHeightCompact)
        .background(RoundedRectangle(cornerRadius: LumoDesign.radiusControl)
            .fill(isOn ? LumoDesign.accentSoft : .clear))
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(desc)")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// 压缩方案行
struct PlanRow: View {
    let plan: Plan
    let selected: Bool
    let onPick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(plan.name).font(LumoDesign.font(12.5, weight: .medium))
                            .foregroundColor(LumoDesign.text)
                        if plan.recommended == true {
                            Text("推荐").font(LumoDesign.font(9.5, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(LumoDesign.accent))
                                .foregroundColor(LumoDesign.onAccent)
                        }
                    }
                    Text(plan.desc).font(LumoDesign.font(10.5)).foregroundColor(LumoDesign.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(lumoBytes(plan.estBytes)).font(LumoDesign.font(12.5, weight: .semibold))
                        .foregroundColor(LumoDesign.accentDeep).monospacedDigit()
                    Text(String(format: "%.1f×", plan.estRatio))
                        .font(LumoDesign.font(10)).foregroundColor(LumoDesign.faint)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: LumoDesign.rowHeightCompact)
            .background(RoundedRectangle(cornerRadius: LumoDesign.radiusControl)
                .fill(selected ? LumoDesign.accentSoft : (hovering ? LumoDesign.hover : .clear)))
            .overlay(RoundedRectangle(cornerRadius: LumoDesign.radiusControl)
                .stroke(selected ? LumoDesign.accentEdge : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// 背景清理强度滑块
struct BackgroundStrengthSlider: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var backend: LumoBackend

    /// 用词刻意避开"对比度/阈值"这类工程词汇——用户判断的是"干不干净"。
    private var label: String {
        switch state.bgStrength {
        case ..<0.2: return "保留纸张质感"
        case ..<0.45: return "轻度清理"
        case ..<0.7: return "干净"
        default: return "很干净（接近纯白）"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label).font(LumoDesign.font(11.5)).foregroundColor(LumoDesign.accentDeep)
                Spacer()
                Text("\(Int(state.bgStrength * 100))%")
                    .font(LumoDesign.font(11)).foregroundColor(LumoDesign.muted).monospacedDigit()
            }
            Slider(value: $state.bgStrength, in: 0...1) { editing in
                if !editing {
                    Task { @MainActor in await state.refreshPreview(backend: backend) }
                }
            }
            // 单参数版 onChange：项目最低支持 macOS 13，
            // 双参数版（of:initial:_:）要 macOS 14 才编译得过。
            .onChange(of: state.bgStrength) { _ in
                state.schedulePreview(backend: backend)
            }
            Text("背景清理").font(LumoDesign.font(10.5)).foregroundColor(LumoDesign.faint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: LumoDesign.radiusControl).fill(LumoDesign.panelAlt))
    }
}

struct FlowChips: View {
    let items: [String]
    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(items, id: \.self) { s in
                Text(s).font(LumoDesign.font(10.5))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(LumoDesign.accentSoft))
                    .foregroundColor(LumoDesign.accentDeep)
            }
        }
    }
}

/// 会折行的横向排布。参数栏很窄，用 HStack 会溢出，用 LazyVGrid 又会在
/// 每个格子里留出难看的空洞——所以自己排。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
