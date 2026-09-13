// Lumo — 设计系统
//
// 依据《macOS 单窗口玻璃质感设计参考》重建。三条硬规矩：
//
//  ① **用语义色 + 自适应明暗**，不硬编码"浅色版"的颜色。
//     参考 §6「颜色与文字」：用语义色，避免硬编码色值，把值沉淀为 token；
//     参考 §10「常见偏差」：只做浅色或只做深色是不合格的。旧版是硬编码的浅色，
//     深色系统下就是一张白纸糊在暗界面上。
//
//  ② **玻璃只铺在控件层**。窗口底 / 内容层不透明，顶栏、底栏、inspector 用系统材质。
//     参考 §10 明确列了"玻璃叠玻璃"和"给列表文本区加玻璃"两种偏差。
//
//  ③ **不在旧系统上模拟 Liquid Glass**。最低支持 macOS 13（这是本项目刻意保留的，
//     CI 的 macos-14 矩阵靠它才有意义），所以走材质兼容路径：`.regularMaterial`
//     / `.thinMaterial` 一类。参考 §3 末那条教训说得很清楚——
//     Permute 4 中途遇上 macOS 26 新设计语言，大量设计稿一夜作废。
//     **先定最低版本再动手**，这里定的是 13+。

import SwiftUI
import AppKit

enum LumoDesign {

    // MARK: - 品牌（固定值，不随明暗变）
    //
    // 这几个色是"品牌标识"，与 Resources/Lumo.icns 是同一套参数，**不能随明暗漂**：
    // 图标在浅色和深色下是同一个图标。

    static let accent      = Color(hex: 0x14B8A6)
    static let accentDeep  = Color(hex: 0x0D9488)
    /// ★ 清新绿。主按钮走"清新绿 → 青绿"的纵向渐变（见 `accentGradient`）。
    ///
    /// 为什么按钮不用纯 `accent`：纯色按钮在玻璃背景上看着像一块贴纸，
    /// 而且和"推荐"角标、选中态用同一个色号，视觉上分不出主次。
    /// 渐变让主按钮有了"能被按下去"的体积感，同时仍然是同一套品牌色
    /// —— 它就来自应用图标渐变里已有的那个亮端。
    static let accentFresh = Color(hex: 0x34D399)
    /// 星芒墨色。固定在青绿渐变方块上使用，换色就跟应用图标不是同一个东西了。
    static let emblemInk   = Color(hex: 0x04201C)
    static let emblemGlyph = "✦"
    /// 强调色上的文字（青绿底 + 深墨字，对比度达 WCAG AA）
    static let onAccent    = Color(hex: 0x04201C)

    static var accentSoft: Color { .adaptive(light: 0xE4F6F2, dark: 0x12352F) }
    static var accentEdge: Color { .adaptive(light: 0x9FDCD2, dark: 0x2C6C63) }

    /// 主按钮 / 品牌方块的渐变。与 `LumoDesign.Emblem` 用的是同一对颜色，
    /// 所以"按钮的绿"和"图标的绿"是同一个绿。
    static let accentGradient = LinearGradient(
        colors: [accentFresh, accent],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// 更收敛的一档，给次要的强调元素（角标、小圆点）
    static let accentGradientSoft = LinearGradient(
        colors: [accent, accentDeep],
        startPoint: .top, endPoint: .bottom)

    // MARK: - 语义 token（随明暗自适应）

    /// 窗口底（内容层，**不透明**，不给玻璃）
    static var canvas: Color   { .adaptive(light: 0xF5F7F9, dark: 0x15171A) }
    /// 卡片 / 面板
    static var panel: Color    { .adaptive(light: 0xFFFFFF, dark: 0x1E2126) }
    /// 次级面（卡片里的内嵌块）
    static var panelAlt: Color { .adaptive(light: 0xF1F4F7, dark: 0x262A30) }
    /// 1px 极细分隔线（参考 §6：底栏用轻材质 + 1px 极细分隔线）
    static var hairline: Color { .adaptive(light: 0xE1E7EE, dark: 0x333941) }
    /// 选中/悬停底色
    static var hover: Color    { .adaptive(light: 0xEDF1F5, dark: 0x2A2F36) }

    // 文字：直接用系统的语义色，系统会自己处理明暗与对比度
    static let text   = Color.primary
    static let muted  = Color.secondary
    static let faint  = Color(nsColor: .tertiaryLabelColor)

    /// 状态色（语义，不是"橙色好看"）
    static var ok: Color     { .adaptive(light: 0x0E7C6B, dark: 0x4ADEBD) }
    static var warn: Color   { .adaptive(light: 0xB45309, dark: 0xF5B563) }
    static var danger: Color { .adaptive(light: 0xB42318, dark: 0xF08C80) }

    // MARK: - 圆角
    //
    // 参考 §6 给的是"卡片 14 / 按钮 8 / 输入框 6"。这里整体上调了两档
    // （16 / 10 / 8），是**有意的偏离**：玻璃材质下圆角偏小会显得"硬"，
    // 而偏大的圆角与模糊边缘过渡更自然。改大圆角是安全的——
    // 改小才会让控件看起来像老式工具条。
    static let radiusCard: CGFloat    = 16
    static let radiusControl: CGFloat = 10
    static let radiusField: CGFloat   = 8
    static let radiusSmall: CGFloat   = 8
    /// 胶囊（角标、状态芯片）
    static let radiusPill: CGFloat    = 999

    // MARK: - 间距与尺寸（参考 §6）
    static let padWindow: CGFloat      = 20
    static let padWindowNarrow: CGFloat = 16
    static let gap: CGFloat            = 12
    static let gapTight: CGFloat       = 8
    static let gapGroup: CGFloat       = 24
    static let rowHeight: CGFloat      = 44
    static let rowHeightCompact: CGFloat = 36
    /// 底栏高度。
    ///
    /// ⚠️ 这个数被**反馈**顶上来过：0.4.0 是 40，反馈原文是
    /// 「底部那一栏有按钮和说明，太挤了，拉宽一点，给按钮和字留点空间」。
    /// 40 装不下"两个次级按钮 + 一段统计文字 + 一个主按钮"——它们的垂直内边距
    /// 各占 6~8pt，40 只剩不到 12pt 的余量，看着就是挤在一起。
    /// 54 之后：按钮上下各有 12pt 呼吸，统计文字不用贴着按钮。
    static let statusBarHeight: CGFloat = 54
    /// 顶部工具区高度。⚠️ 与 `WindowDragStrip` 的命中区、交通灯避让一起改，
    /// 三者不匹配会出现"顶部某一段拖不动"。
    static let titleBarHeight: CGFloat = 56
    /// ★ 交通灯避让区。参考 §3：macOS 26 交通灯变大，约 78×34pt。
    /// 一律按 78 留，老系统上多留一点无害，新系统上正好。
    static let trafficLightAvoid: CGFloat = 78
    /// 顶部可拖拽区高度。参考 §3：顶部约 50pt 保持可拖拽，且**不要被密集控件占满**。
    static let dragStripHeight: CGFloat = 50
    /// inspector（参数栏）宽度
    static let inspectorWidth: CGFloat  = 340
    static let inspectorMinWidth: CGFloat = 300

    // MARK: - 窗口尺寸下限
    //
    // ★ 这两个数是**算出来的，不是拍的**：inspector 340 + 分隔线 1 + 内容边距 20×2
    //   + 预览主区最小可用宽（两张预览并排、每张至少 180）= 340+1+40+360 ≈ 740，
    //   再给两侧留余量 → 860。
    //   高度：顶栏 56 + 底栏 40 + 预览头约 76 + 两张预览最小高 220 + 边距 ≈ 560 → 600。
    //
    //   为什么必须真的限制住：窗口能缩到 520 时两栏会被挤到重叠、预览图被压成一条缝，
    //   看起来就是"界面坏了"。**宁可不让缩，也不要让界面崩。**
    static let windowMinWidth: CGFloat  = 860
    static let windowMinHeight: CGFloat = 600
    static let windowDefaultWidth: CGFloat  = 1000
    static let windowDefaultHeight: CGFloat = 680

    // MARK: - 动效（参考 §8）
    //
    // 时长都压在 0.3s 以内。**并且必须尊重 Reduce Motion**——
    // 由 `LumoMotion.duration` 统一取用，别在各处写死 `.easeOut(duration:)`。
    enum Motion {
        static let appear = 0.2      // 出现 / 消失
        static let state  = 0.2      // 状态切换 0.15–0.25
        static let hover  = 0.12     // hover 只改颜色/透明度，不做位移跳变
    }

    // MARK: - 字体
    //
    // 参考 §6：字体用系统字体，标题 headline、正文 body、次要 footnote。
    // 这里保留一个 size 入口是为了兼容既有调用点（它们都写的是点数），
    // 但语义上请优先用 headline/body/footnote 三个。
    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static let headline = Font.headline
    static let body     = Font.body
    static let footnote = Font.footnote
    static let mono     = Font.system(.footnote, design: .monospaced)

    // MARK: - 品牌标识方块

    /// 应用标识方块：青绿对角渐变圆角方块 + 居中星芒。
    ///
    /// **这里是图标视觉的唯一基准。** 打包用的 Resources/Lumo.icns 由
    /// Scripts/make_icon.py 生成，那个脚本里的 GRAD_START / GRAD_END /
    /// STAR_INK / CORNER_RATIO / STAR_RATIO 五项就是照着本结构写的。
    /// 改这里的观感，就要同步改那边并重新生成 icns——
    /// 否则桌面图标和打开后的第一眼就又是两个 logo 了（踩过这个坑）。
    struct Emblem: View {
        var size: CGFloat = 40
        /// 圆角比 = 12/40 = 0.30，与 make_icon.py 的 CORNER_RATIO 一致
        private var corner: CGFloat { size * 0.30 }
        /// 星芒字号 = 边长的一半，与 make_icon.py 的 STAR_RATIO=0.28 对应
        /// （字号是"字面框"，实际墨迹略小，所以字号取 0.50 而半径取 0.28）
        private var glyph: CGFloat { size * 0.50 }

        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: corner)
                    // 注意：Emblem 是嵌在 LumoDesign 里的类型，而嵌套类型内部
                    // 看不到外层 enum 的静态成员——accent / emblemInk 必须写全名。
                    // 漏掉限定词就是 "cannot find 'accent' in scope"，
                    // 这个错只在编 App 目标时才暴露。
                    .fill(LinearGradient(colors: [LumoDesign.accent, Color(hex: 0x34D399)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: size, height: size)
                Text(LumoDesign.emblemGlyph)
                    .font(.system(size: glyph, weight: .bold))
                    .foregroundColor(LumoDesign.emblemInk)
            }
            .accessibilityHidden(true)   // 装饰性图形，读屏不需要念它
        }
    }
}

// MARK: - 自适应色

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8)  & 0xff) / 255,
                  blue:  Double(hex         & 0xff) / 255,
                  opacity: alpha)
    }

    /// 一套亮/暗两值，交给系统按当前外观解析。
    ///
    /// 为什么用 `NSColor` 的动态构造而不是 `@Environment(\.colorScheme)` 手工分支：
    /// 手工分支要求每个用色的地方都能拿到环境，而我们的 token 是**静态属性**
    /// （`LumoDesign.panel` 这样直接取）。动态 NSColor 让"明暗"这件事在 token
    /// 内部就解决掉，调用点一行都不用改——也就不会有人漏掉某处。
    static func adaptive(light: UInt, dark: UInt) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(srgbHex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    /// 不做颜色空间转换，避免半透明叠加时出现意料之外的色偏
    convenience init(srgbHex hex: UInt) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green:   CGFloat((hex >> 8)  & 0xff) / 255,
                  blue:    CGFloat(hex         & 0xff) / 255,
                  alpha:   1)
    }
}

// MARK: - 尊重 Reduce Motion

/// 动效统一入口。
///
/// 参考 §8「无障碍：动画尊重 Reduce Motion」。做成一取即用的函数，
/// 而不是让每个转场各写一遍 `if reduceMotion` —— 那种写法必然有人忘。
struct LumoMotion {
    /// 开了 Reduce Motion 就返回 0，调用点不用写分支
    static func duration(_ base: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : base
    }
    static func animation(_ base: Double, reduceMotion: Bool) -> Animation {
        .easeOut(duration: duration(base, reduceMotion: reduceMotion))
    }
}

// MARK: - 通用容器

/// 内容层卡片。玻璃档位决定它有多"透"（不透明档 = 完全实心）。
/// 读的是 `\.lumoGlass`（有默认值的 Environment），不是 EnvironmentObject —— 见 Theme.swift。
struct LumoCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content
    @Environment(\.lumoGlass) private var glass

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LumoDesign.gap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(LumoDesign.font(14, weight: .semibold))
                    .foregroundColor(LumoDesign.text)
                if let s = subtitle {
                    Text(s).font(LumoDesign.font(11.5)).foregroundColor(LumoDesign.muted)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LumoDesign.radiusCard, style: .continuous)
            .fill(LumoDesign.panel.opacity(glass.panelOpacity)))
        .overlay(RoundedRectangle(cornerRadius: LumoDesign.radiusCard, style: .continuous)
            .stroke(LumoDesign.hairline))
    }
}

/// 主按钮。走品牌渐变（清新绿 → 青绿），形状按参考 §6（macOS 26 上系统会自己给胶囊）。
struct LumoButton: View {
    let title: String
    var icon: String?
    var kind: Kind = .primary
    var disabled: Bool = false
    let action: () -> Void

    enum Kind { case primary, secondary, quiet }

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                }
                Text(title).font(LumoDesign.font(13, weight: kind == .primary ? .semibold : .regular))
            }
            .padding(.horizontal, kind == .primary ? 18 : 12)
            .padding(.vertical, kind == .primary ? 8 : 6)
            .background(background)
            .foregroundColor(foreground)
            .clipShape(RoundedRectangle(cornerRadius: LumoDesign.radiusControl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: LumoDesign.radiusControl, style: .continuous)
                    .stroke(kind == .secondary ? LumoDesign.hairline : .clear)
            )
            // 主按钮给一点投影，让它从玻璃背景上"浮"起来；
            // hover 时轻微提亮。有反馈的按钮才像按钮——"点了没反应"的观感
            // 有一半来自按钮本身看不出可点。
            .shadow(color: kind == .primary ? LumoDesign.accent.opacity(hovering ? 0.45 : 0.30) : .clear,
                    radius: hovering ? 10 : 7, y: 2)
            .brightness(kind == .primary && hovering ? 0.04 : 0)
            .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: LumoDesign.Motion.hover), value: hovering)
    }

    @ViewBuilder private var background: some View {
        switch kind {
        case .primary:   LumoDesign.accentGradient
        case .secondary: LumoDesign.panelAlt
        case .quiet:     Color.clear
        }
    }
    private var foreground: Color {
        switch kind {
        case .primary:   LumoDesign.onAccent
        case .secondary: LumoDesign.text
        case .quiet:     LumoDesign.muted
        }
    }
}

// MARK: - 品牌锁排

/// 品牌标识锁排：**标识 → 流明 → 扫描件焕新**，横排一行。
///
/// 这里是**两轮反馈改出来的**，顺序别动：
///   · 第一轮（0.4.0）：20pt 图标 + 13pt 单行文字 —— 反馈是"有点偏右、有点太小、没有设计感"；
///   · 第二轮：改成两行（Lumo / 流明 · 扫描件焕新），反馈仍是"位置还是有点不美观，要么就放大"。
///
/// 于是改成现在这样——**一行、从左到右三段、整体放大**：
///   ① 标识 36pt（比第一版大 80%）。它和 56pt 高的栏、34pt 的交通灯成比例，
///      再小就会被交通灯"压住"；
///   ② 主名「流明」20pt、加字距。**用中文名而不是 "Lumo"**：这是产品名，
///      中文写出来只占两个字，同样宽度下可以给到更大的字号，一眼能读；
///   ③ 「扫描件焕新」13.5pt + 一条 1pt 竖线分隔。竖线是这个锁排的关键——
///      没有它，两段文字会糊成一个长句；有它，才读得出"名字｜定位"的层级。
struct BrandLockup: View {
    /// 标识方块边长。顶栏 36；空态、关于页要更大时直接传。
    var size: CGFloat = 36
    /// 是否显示第二段（定位语「扫描件焕新」）
    var showsSubtitle: Bool = true

    var body: some View {
        HStack(spacing: 13) {
            LumoDesign.Emblem(size: size)
                // 极轻的投影：让方块从玻璃上脱离出来。
                // 不用描边——描边在有底色时会显脏。
                .shadow(color: LumoDesign.accent.opacity(0.35), radius: 8, y: 2)

            HStack(spacing: 12) {
                Text("流明")
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(2.0)
                    .foregroundColor(LumoDesign.text)

                if showsSubtitle {
                    Rectangle()
                        .fill(LumoDesign.hairline)
                        .frame(width: 1, height: 17)

                    Text("扫描件焕新")
                        .font(.system(size: 13.5, weight: .medium))
                        .tracking(1.0)
                        .foregroundColor(LumoDesign.muted)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("流明 · 扫描件焕新")
    }
}

// MARK: - 玻璃图标按钮

/// 圆形玻璃图标按钮（顶栏用）。
///
/// 与 `LumoIconButton` 的区别：那个是"融入背景"的次级图标（列表行内动作），
/// 这个是顶栏上的常驻控件，**必须一眼看出可以点**——所以有底色、有描边、
/// 有 hover 高亮。用户反馈"点它没反应、毫无作用"里，有一半是观感问题：
/// 一个没有边界的灰色图标，看起来就像个装饰。
struct LumoCircleButton: View {
    let icon: String
    let help: String
    var badge: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(hovering ? LumoDesign.hover : LumoDesign.panelAlt.opacity(0.85))
                    .overlay(Circle().stroke(hovering ? LumoDesign.accentEdge : LumoDesign.hairline))
                Image(systemName: icon)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(hovering ? LumoDesign.accentDeep : LumoDesign.text)
                    .rotationEffect(.degrees(hovering ? 18 : 0))
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
            // 就绪状态的小圆点：有新版本时给一个不抢眼的提示
            .overlay(alignment: .topTrailing) {
                if badge {
                    Circle().fill(LumoDesign.accentFresh)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(LumoDesign.panel, lineWidth: 1.5))
                        .offset(x: 1, y: -1)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: LumoDesign.Motion.hover), value: hovering)
        // 关掉 Tab 焦点：顶栏这个按钮是窗口里第一个可聚焦控件，于是 App 一启动
        // 它就顶着一圈系统焦点环，和旁边没有环的控件不一致，看起来像"被选中了"。
        // 键盘通路没有断——同一个动作在菜单里有 ⌘,。
        .focusable(false)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 纯图标按钮（工具栏用）。参考 §7：图标按钮补 help 与 VoiceOver 标签。
struct LumoIconButton: View {
    let icon: String
    let help: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 24)
                .foregroundColor(LumoDesign.muted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct LumoToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .tint(LumoDesign.accent)
            .labelsHidden()
    }
}

func lumoBytes(_ b: Int) -> String {
    let kb = Double(b) / 1024
    return kb < 1024 ? String(format: "%.0f KB", kb) : String(format: "%.2f MB", kb / 1024)
}
