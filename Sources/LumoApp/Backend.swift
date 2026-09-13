// Lumo —— 原生核心桥接层
// 核心就是同仓库里的 LumoCore（CoreGraphics / Core Image / Vision / ImageIO），
// 随 App 一起编译进去，因此没有 Python、没有 Homebrew、没有 Tesseract，启动即可用。
import Foundation
import SwiftUI
import LumoCore

@MainActor
final class LumoBackend: ObservableObject {
    /// 全应用共用的那一份。
    ///
    /// 为什么敢做成单例：这个类只包了一层**无状态的**处理入口
    /// （`Pipeline` / `PagePreview` 都是纯函数式的），
    /// 反复构造的代价只是重复建目录。窗口级的**状态**在 `AppState` 里，那个是每窗一份。
    /// 单例的用处是让"文件行上那个重新体检按钮"这种深层子视图能直接拿到它，
    /// 不必一路把 environmentObject 传下去。
    static let shared = LumoBackend()

    /// 原生核心随进程一起加载，不存在"启动服务"这一步；保留该字段是为了让 UI 逻辑不变
    @Published var isReady = true
    @Published var statusText = "引擎就绪"
    @Published var startError: String?

    private let workDir: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
                  ?? URL(fileURLWithPath: NSTemporaryDirectory())
        workDir = base.appendingPathComponent("Lumo", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    // MARK: - 生命周期（保留接口，去掉了进程与 HTTP）

    func start() async throws {
        isReady = true
        startError = nil
        statusText = "引擎就绪"
    }

    func stop() {}

    func loadLangs() async throws -> [String] { OCR.languages.map { $0.id } }

    func langName(_ id: String) -> String { OCR.name(of: id) }

    // MARK: - 核心调用

    func analyze(fileURL: URL) async throws -> ReportResponse {
        try await offMain { try Pipeline.report(fileURL: fileURL) }
    }

    /// progress 在主线程回调：流水线本身是同步 CPU 密集任务，放到后台跑，
    /// 再把进度扔回主线程更新 UI。
    func process(fileURL: URL, spec: ProcessSpec,
                 progress: @escaping @MainActor (Double, String) -> Void) async throws -> ProcessResponse {
        let outURL = workDir.appendingPathComponent(outputName(for: fileURL))
        let previewDir = workDir.appendingPathComponent("preview-" + UUID().uuidString, isDirectory: true)
        return try await offMain {
            try Pipeline.process(fileURL: fileURL, spec: spec, outURL: outURL,
                                 previewDir: previewDir) { p, t in
                Task { @MainActor in progress(p, t) }
            }
        }
    }

    /// 单页效果预览：只渲染一页 + 跑增强，不 OCR 不压缩，所以能在几百毫秒内出结果
    func preview(fileURL: URL, page: Int, spec: EnhanceSpec) async throws -> PreviewPair? {
        try await offMain {
            PagePreview.beforeAfter(fileURL: fileURL, page: page, spec: spec)
        }
    }

    func previewURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - 临时目录

    /// 预览缓存目录（`preview-<uuid>/`）占了多少字节。
    ///
    /// **只统计预览目录，不统计处理产物**：产物是用户还没保存的东西，
    /// 把它们算进"可清理"里，用户点一下就会丢掉刚跑出来的结果——
    /// 那种"清理"是个陷阱（手册 §10.5：别让清理动作破坏用户数据）。
    static func previewCacheSize() -> Int {
        let dir = shared.workDir
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.filter { $0.lastPathComponent.hasPrefix("preview-") }
            .reduce(0) { acc, u in acc + directorySize(u) }
    }

    static func clearPreviewCache() {
        let dir = shared.workDir
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                     includingPropertiesForKeys: nil)
        else { return }
        for u in items where u.lastPathComponent.hasPrefix("preview-") {
            try? FileManager.default.removeItem(at: u)
        }
    }

    private static func directorySize(_ url: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: url,
                                                     includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total = 0
        for case let f as URL in e {
            total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    // MARK: - 辅助

    private func outputName(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        return "\(stem)-lumo.pdf"
    }

    private func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try body() }.value
    }
}
