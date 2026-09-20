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
import LumoCore

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
    /// 星芒的填充色。**纯白**，不是深墨绿。
    ///
    /// 早先这里是 #04201C（深墨绿，当年叫 emblemInk）。深色小块压在底座偏上的位置，
    /// 整枚标识会读成"一张脸 + 一只眼睛/一道疤"——这不是审美挑剔，是形状心理学：
    /// 深色小斑块 + 圆角方底 + 偏上偏左，就是脸的构型。
    /// 换成白之后它从"暗块"变成"高光"，也才对得上名字——流明是光通量的单位。
    static let emblemStar  = Color.white
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

    // MARK: - 品牌标识

    /// 品牌标识：**一方底座 + 一颗偏左的白色星芒**。
    ///
    /// 构图（所有数字都按标识的边长取比例，换任何尺寸都不走样）：
    ///
    ///     ┌────────────────┐
    ///     │                │   星芒 0.28 × 边长（**正四角，不拉长**）
    ///     │  ✦             │   左留白 0.13 × 边长
    ///     │                │   纵向居中
    ///     └────────────────┘   圆角 0.26 × 边长
    ///
    /// 每一条都是被否掉一版之后才定下来的，所以都写清楚：
    ///
    ///   · **为什么星芒是白的**：早先是深墨绿，压在偏上的位置时整块会读成
    ///     "一张脸 + 一只眼睛/一道疤"。改白之后它从"暗块"变成"高光"，
    ///     也才和名字对得上——流明是光通量的单位。
    ///   · **为什么不再纵向拉长**：拉长到过 2.00 倍，细得像一根针；1.65 / 1.45 也试过。
    ///     最后回到 **1 : 1**：正四角星的比例本身是被设计过的，硬拉两头不讨好。
    ///   · **为什么偏左、但纵向必须居中**：偏左让右侧的留白成为画面的一部分
    ///     （像"标记 + 预留文字位"的排版），比正中最稳的摆法多一点方向感。
    ///     但横向偏移一定要配纵向居中——早先是偏在左上角，重心就歪了。
    ///   · **为什么底座是正方形**：macOS 的图标槽位就是正方形。底座做成竖版的话，
    ///     同一个标识在桌面和窗口里就是两种形状，又回到"这个 App 有两个 logo"。
    ///     方形底座让**图标、欢迎页、关于页、README 里的 logo 是同一份几何**。
    ///
    /// ★ 这里是视觉的唯一基准。`Resources/Lumo.icns` 与 `docs/logo.png` 都由
    ///   `Scripts/make_icon.py` 生成，那边的常量照着本结构写，两边文件头互相注明。
    struct LumoMark: View {
        /// 边长。
        var width: CGFloat = 26

        /// 圆角 / 边长。0.30 往上开始像胶囊，0.26 才是"一方底座"。
        static let cornerRatio: CGFloat = 0.26
        /// 星芒边长 / 标识边长。**高宽同值**——这里没有"拉长"这个旋钮，
        /// 想拉长就得先改回一个由两段代码共同维护的比例，那是刻意不做的。
        static let starSizeRatio: CGFloat = 0.28
        /// 星芒左留白 / 标识边长。比右侧小得多：偏移是构图的一部分。
        static let starInsetLeft: CGFloat = 0.13
        /// 内顶点 / 外顶点。0.30 比默认的 1/√2 凹得更深，四个角才显得利。
        static let starInnerRatio: CGFloat = 0.30

        private var starSize: CGFloat { width * Self.starSizeRatio }

        var body: some View {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: width * Self.cornerRatio, style: .continuous)
                    // 注意：LumoMark 是嵌在 LumoDesign 里的类型，而嵌套类型内部看不到
                    // 外层 enum 的静态成员——accent / emblemStar 必须写全名。
                    // 漏掉限定词就是 "cannot find 'accent' in scope"，
                    // 而这个错**只在编 App 目标时才暴露**（编 CLI 看不出来）。
                    .fill(LinearGradient(colors: [LumoDesign.accent, Color(hex: 0x34D399)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: width, height: width)

                LumoStar(innerRatio: Self.starInnerRatio)
                    .fill(LumoDesign.emblemStar)
                    .frame(width: starSize, height: starSize)   // ← 两边同值 = 不拉长
                    // 纵向居中由几何推出来，不写死数字：以后换尺寸时重心不会歪。
                    .offset(x: width * Self.starInsetLeft, y: (width - starSize) / 2)
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

// MARK: - 星芒（标识的图形部分）

/// 四角星芒。
///
/// 横竖两个半径**分别取 frame 的宽和高**：传一个正方形 frame 就是正四角星
/// （现在用的就是这个），传一个竖长 frame 就是拉长版。
/// 之所以是手绘路径而不是字体里的 ✦ 字符：字符只能整体缩放，
/// 一旦两个方向要给不同的值，笔画会跟着变粗、四个尖也一起钝掉。
///
/// 构造与 `Scripts/make_icon.py` 的 `star_pts()` 完全同构：四个外顶点指向
/// 正上 / 右 / 下 / 左，四个内凹点落在对角线上（所以乘 1/√2 投影）。
struct LumoStar: Shape {
    /// 内顶点 / 外顶点。
    var innerRatio: CGFloat = 0.30

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        let rx = rect.width / 2, ry = rect.height / 2
        let k: CGFloat = 0.70710678
        let ix = rx * innerRatio * k
        let iy = ry * innerRatio * k
        var p = Path()
        p.move(to:    CGPoint(x: cx,      y: cy - ry))
        p.addLine(to: CGPoint(x: cx + ix, y: cy - iy))
        p.addLine(to: CGPoint(x: cx + rx, y: cy))
        p.addLine(to: CGPoint(x: cx + ix, y: cy + iy))
        p.addLine(to: CGPoint(x: cx,      y: cy + ry))
        p.addLine(to: CGPoint(x: cx - ix, y: cy + iy))
        p.addLine(to: CGPoint(x: cx - rx, y: cy))
        p.addLine(to: CGPoint(x: cx - ix, y: cy - iy))
        p.closeSubpath()
        return p
    }
}

// MARK: - 欢迎页的品牌区

/// 欢迎页中央：标识 + 「流明」+「扫描件焕新」，**竖排居中**。
///
/// 为什么中文名放在这里、而不是界面顶部：欢迎页是唯一"什么都没有、
/// 可以只讲自己是谁"的画面，品牌在这里才立得住。
/// 界面顶部那一条已经**整个去掉了**（反馈：「界面最顶端的 logo + Lumo 字样都不要了」），
/// 所以现在 App 里只有这一处大标识，不再有"两处都写全名、互相抢"的问题。
struct BrandHero: View {
    var body: some View {
        VStack(spacing: 0) {
            LumoDesign.LumoMark(width: 72)
                .shadow(color: LumoDesign.accent.opacity(0.34), radius: 20, y: 8)

            Text(T("流明"))
                .font(.system(size: 30, weight: .semibold))
                .tracking(4)
                .foregroundColor(LumoDesign.text)
                .padding(.top, 22)

            Text(T("扫描件焕新"))
                .font(.system(size: 14, weight: .medium))
                .tracking(2.4)
                .foregroundColor(LumoDesign.muted)
                .padding(.top, 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(T("流明 · 扫描件焕新"))
    }
}
