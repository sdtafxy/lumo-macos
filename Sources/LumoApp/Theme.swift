// Lumo — 主题：外观、玻璃质感、窗口背景模糊
//
// ⚠️ 这个文件是为了修一个**崩溃**才独立出来的，读一遍原因再动：
//
// 0.4.0 的设置面板一打开就 SIGTRAP 崩掉。崩溃栈指向
//   `EnvironmentObject.error() → GeneralSettings.$state.getter`。
// 根因：`GeneralSettings` 用了 `@EnvironmentObject var state: AppState`，
// 而 `Settings` 场景只注入了 backend / updates —— **缺一个就 fatalError**。
// 更本质的问题是设计错了：`AppState` 是**每个窗口一份**的处理状态，
// 而"外观、OCR 默认语言"这类是**全应用一份**的偏好。
// 把它们混在一起，等于让设置窗口去依赖一个它根本不该有的东西。
//
// 所以：全局偏好一律放 `LumoTheme` / `LumoPreferences`（都是单例），
// 视图只依赖它们。设置面板**不接触 AppState**，从结构上就不可能再犯这个错。

import SwiftUI
import AppKit

// MARK: - 外观

enum LumoAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil                       // nil 就是"跟随系统"
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - 玻璃质感

/// 三档玻璃质感，用户可调。
///
/// **三档之间最主要的差别是"我自己的底色留多少"，不是换 material。**
/// 原因：`NSVisualEffectView.Material` 的模糊强度在各系统版本上并不一致，
/// 而"内容底色不透明度"是我们能完全说了算的——所以在每个系统上，
/// 三档的观感差异都是可靠的。
enum LumoGlass: String, CaseIterable, Identifiable {
    case solid, standard, vivid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solid:    return "不透明"
        case .standard: return "玻璃"
        case .vivid:    return "通透"
        }
    }

    var hint: String {
        switch self {
        case .solid:    return "内容完全不透明，可读性最好"
        case .standard: return "控件层有玻璃，内容层留一点底色"
        case .vivid:    return "整窗透出桌面，最接近系统原生观感"
        }
    }

    /// 内容底色（`LumoDesign.canvas`）的不透明度
    var canvasOpacity: Double {
        switch self { case .solid: return 1.0; case .standard: return 0.88; case .vivid: return 0.45 }
    }

    /// 卡片 / 面板的不透明度
    var panelOpacity: Double {
        switch self { case .solid: return 1.0; case .standard: return 0.94; case .vivid: return 0.68 }
    }

    /// 窗口背后那层模糊的不透明度。
    ///
    /// ★ 这个旋钮是**实测之后才加的**，别把它当装饰：
    /// 一开始只靠 `canvasOpacity` 区分三档，结果"通透"和"玻璃"的差别小到看不出来
    /// （实测同一点位：标准 238,243,246 → 通透 225,237,239，而桌面本身是 70,141,217）。
    /// 原因是 `NSVisualEffectView.Material.underWindowBackground` 在**浅色外观下本身就是
    /// 接近不透明的白**——它已经把桌面挡住九成了，上面再盖一层多透的底色都白搭。
    /// 所以真正决定"透不透"的是这一项：把模糊层自己也压到半透明，
    /// 桌面才会真的透上来（而且仍然是模糊过的，不是生硬的透明）。
    var backdropOpacity: Double {
        switch self { case .solid: return 1.0; case .standard: return 1.0; case .vivid: return 0.50 }
    }

    /// 上下栏的材质
    var barMaterial: Material {
        switch self { case .solid, .standard: return .bar; case .vivid: return .ultraThinMaterial }
    }

    /// inspector / 面板的材质
    var panelMaterial: Material {
        switch self { case .solid, .standard: return .regularMaterial; case .vivid: return .thinMaterial }
    }

    /// 窗口背后要不要铺一层模糊。不透明档不需要（省一次合成）
    var wantsBackdrop: Bool { self != .solid }
}

// MARK: - 主题（全应用一份）

/// 外观与玻璃质感。**单例**：这两个是全局偏好，不是"每个窗口一份"的东西。
///
/// 用 `ObservableObject` 而不是纯静态属性，是为了改完立刻生效——
/// 玻璃档位在设置面板里切换时，后面的主窗口要当场变过去，
/// 而不是等下次启动（那用户根本看不出自己改了什么）。
@MainActor
final class LumoTheme: ObservableObject {
    static let shared = LumoTheme()

    private enum Key {
        static let appearance = "LumoAppearance"
        static let glass = "LumoGlass"
    }

    @Published var appearance: LumoAppearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }

    @Published var glass: LumoGlass {
        didSet { UserDefaults.standard.set(glass.rawValue, forKey: Key.glass) }
    }

    private init() {
        let d = UserDefaults.standard
        appearance = LumoAppearance(rawValue: d.string(forKey: Key.appearance) ?? "") ?? .system
        // 默认"玻璃"：参考文档给的就是这个默认值，而且它是"好看"与"稳"之间的分界。
        // "通透"会让预览图的背景透出来，看扫描件时略花——所以不作为默认。
        glass = LumoGlass(rawValue: d.string(forKey: Key.glass) ?? "") ?? .standard
    }

    /// `NSApp.appearance = nil` 就是"跟随系统"
    func applyAppearance() {
        NSApp?.appearance = appearance.nsAppearance
    }
}

// MARK: - 把玻璃档位传下去

/// ★ 用 `Environment`（有默认值）而不是 `EnvironmentObject`（缺了就 fatalError）传玻璃档位。
///
/// 这不是风格问题：**刚刚才被 `EnvironmentObject` 咬过一次**——设置面板缺一个
/// environment object，一打开就 SIGTRAP（见文件头）。组件越底层、被放在越奇怪的
/// 容器里（sheet、独立窗口、预览），漏注入的概率就越高。
/// `Environment` 有 `defaultValue`，最坏情况是"档位没生效"，而不是崩。
private struct LumoGlassKey: EnvironmentKey {
    static let defaultValue: LumoGlass = .standard
}

extension EnvironmentValues {
    var lumoGlass: LumoGlass {
        get { self[LumoGlassKey.self] }
        set { self[LumoGlassKey.self] = newValue }
    }
}

// MARK: - 窗口背后的模糊层


/// 铺在最底层的系统模糊视图（`blendingMode = .behindWindow` 采的是**窗口背后**的内容）。
///
/// 为什么放在 SwiftUI 视图树里，而不是往 `NSWindow.contentView` 的下面插一层：
/// 插进 AppKit 的视图层级要跟 SwiftUI 的宿主视图抢位置，窗口重建 / 全屏切换时
/// 容易失效或错位；而放在视图树最底层由 SwiftUI 自己管尺寸，稳定得多。
///
/// 两个必需条件（缺一个就什么都看不到）：
///   ① 窗口必须 `isOpaque = false` 且背景透明 —— 见 `WindowConfigurator`；
///   ② 它上面的内容必须**真的半透明** —— 见 `LumoGlass.canvasOpacity`。
struct VisualEffectBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    /// 模糊层自身的不透明度。见 `LumoGlass.backdropOpacity` 的说明——
    /// **这才是"透不透"的主旋钮**，材质本身在浅色下太不透明了。
    var opacity: Double = 1.0

    /// 不吃鼠标事件：它铺满整窗，如果不拦住 hitTest，
    /// 上面那些 `.onDrop` / 拖拽区就全都收不到事件了。
    final class PassThroughView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = PassThroughView()
        v.material = material
        v.blendingMode = blending
        v.state = .active          // 窗口失焦时也保持模糊，否则切走再回来会闪一下
        v.alphaValue = opacity
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
        nsView.alphaValue = opacity
    }
}
