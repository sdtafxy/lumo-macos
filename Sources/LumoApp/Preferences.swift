// Lumo — 全局偏好（全应用一份）
//
// 为什么要有这个文件（而不是继续往 AppState 里塞）：
// `AppState` 是**每个窗口一份**的处理状态（当前文件、预览图、处理结果），
// 而"OCR 默认语言""载入后要不要自动出预览"是**全应用一份**的设置。
// 两者混在一起会造成两个问题：
//   ① 设置面板要读全局偏好，却被迫依赖那个它根本不该有的 per-window 对象
//      —— 这就是 0.4.0 设置面板一打开就崩的直接原因（见 Theme.swift 文件头）；
//   ② 开第二个窗口时，两个窗口各有一份"默认语言"，改了 A 窗口 B 窗口不跟着变。
//
// 逐键读写 UserDefaults。**不要改成一整份 Codable 存在一个 key 里**：
// 那样任何一个字段改名 / 加字段，旧数据整份解不出来，用户的所有偏好会被静默重置。

import SwiftUI
import AppKit
import Combine

@MainActor
final class LumoPreferences: ObservableObject {
    static let shared = LumoPreferences()

    private let d = UserDefaults.standard

    /// OCR 默认语言。默认 eng —— 内置示例件就是英文的，
    /// 而 chi_sim 的识别耗时明显更长，不该替用户先选上。
    @Published var ocrLang: String {
        didSet { d.set(ocrLang, forKey: LumoPreferenceKeys.ocrLang) }
    }

    /// `searchable` = 保留原版式、加一层看不见的文字层；
    /// `editable` = 额外附一份可编辑文本。
    @Published var ocrOutput: String {
        didSet { d.set(ocrOutput, forKey: LumoPreferenceKeys.ocrOutput) }
    }

    /// 载入文件后立刻算第一页预览。
    ///
    /// 默认开：参考文档 §5 Level 2 要求"参数改动即时可见结果，而不是先提交再看"。
    /// 留成开关是因为它是几百毫秒的 CPU 活——批量处理几十份文件的人
    /// 会希望自己控制这个节奏。
    @Published var autoPreviewOnLoad: Bool {
        didSet { d.set(autoPreviewOnLoad, forKey: LumoPreferenceKeys.autoPreview) }
    }

    /// 记住窗口大小与位置。默认开（这是 macOS 的惯例行为）。
    @Published var rememberWindowSize: Bool {
        didSet {
            d.set(rememberWindowSize, forKey: LumoPreferenceKeys.rememberWindowSize)
            // 立刻生效：不用等下次启动。窗口那边会读这个键（见 WindowConfigurator），
            // 但"已经在屏幕上的那个窗口"需要推它一把——改完立刻重排最直观。
            for w in NSApp?.windows ?? [] where w.identifier?.rawValue == WindowConfigurator.mainWindowIdentifier {
                WindowConfigurator.applyFrameAutosave(to: w)
            }
        }
    }

    private init() {
        // 注册默认值而不是在各处写 `?? true`：这样"默认值是什么"只有一个出处
        d.register(defaults: [
            LumoPreferenceKeys.ocrLang: "eng",
            LumoPreferenceKeys.ocrOutput: "searchable",
            LumoPreferenceKeys.autoPreview: true,
            LumoPreferenceKeys.rememberWindowSize: true,
        ])
        ocrLang = d.string(forKey: LumoPreferenceKeys.ocrLang) ?? "eng"
        ocrOutput = d.string(forKey: LumoPreferenceKeys.ocrOutput) ?? "searchable"
        autoPreviewOnLoad = d.bool(forKey: LumoPreferenceKeys.autoPreview)
        rememberWindowSize = d.bool(forKey: LumoPreferenceKeys.rememberWindowSize)
    }

    /// 恢复出厂（"关于"页里给一个出口，比让用户去删 plist 友好）
    func resetAll() {
        for k in [LumoPreferenceKeys.ocrLang, LumoPreferenceKeys.ocrOutput,
                  LumoPreferenceKeys.autoPreview, LumoPreferenceKeys.rememberWindowSize] {
            d.removeObject(forKey: k)
        }
        ocrLang = "eng"
        ocrOutput = "searchable"
        autoPreviewOnLoad = true
        rememberWindowSize = true
    }
}

/// 偏好键名集中在这里。
///
/// 为什么单独抽出来：`WindowConfigurator`（AppKit 侧）也要读"记不记住窗口大小"，
/// 而它**不是** View、拿不到 @MainActor 的单例。把键名共享出来、
/// 两边都直接读 UserDefaults，比为了读一个布尔值去跨 actor 干净。
enum LumoPreferenceKeys {
    static let ocrLang = "LumoPrefs.ocrLang"
    static let ocrOutput = "LumoPrefs.ocrOutput"
    static let autoPreview = "LumoPrefs.autoPreviewOnLoad"
    static let rememberWindowSize = "LumoPrefs.rememberWindowSize"
}
