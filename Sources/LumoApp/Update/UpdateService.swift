// Lumo — 自更新：状态机 + 定时检查 + 偏好
//
// 这是 Update/ 下**唯一**允许 import SwiftUI 的文件。
// 前面那几个（SemanticVersion / UpdateFeed / UpdateIntegrity / UpdateDownloader /
// UpdateInstaller）刻意只依赖 Foundation，才能被 swiftc 单编出来跑真实测试
// （见 Scripts/run_update_tests.sh）。往它们里面加 UI 依赖会毁掉那条通路。

import Foundation
import SwiftUI
import AppKit
import os

// MARK: - 配置

/// 更新配置。**从 Info.plist 读，不硬编码**（手册 §2）：
/// 这样 fork 的人能改成自己的仓库地址与公钥，不用改代码。
struct UpdateConfig: Sendable {
    let repository: String
    /// 自定义 feed 地址（Info.plist 的 `LumoUpdateFeedURL`）。留空 = 走 GitHub Releases。
    let feedURLOverride: String
    let publicKey: String
    let assetSuffix: String
    let bundleID: String
    let currentVersion: SemanticVersion

    static func fromBundle(_ bundle: Bundle = .main) -> UpdateConfig {
        let dict = bundle.infoDictionary ?? [:]
        // 兜底值指向本项目自己的仓库，方便第一次跑起来能看到真实响应
        let repo = (dict["LumoUpdateRepository"] as? String) ?? "sdtafxy/lumo-macos"
        let key = (dict["LumoUpdatePublicKey"] as? String) ?? ""
        let suffix = (dict["LumoUpdateAssetSuffix"] as? String) ?? ".zip"
        let rawVersion = (dict["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        return UpdateConfig(
            repository: repo,
            feedURLOverride: (dict["LumoUpdateFeedURL"] as? String) ?? "",
            publicKey: key.trimmingCharacters(in: .whitespacesAndNewlines),
            assetSuffix: suffix,
            bundleID: (dict["CFBundleIdentifier"] as? String) ?? "com.lumo.app",
            currentVersion: SemanticVersion(rawVersion) ?? SemanticVersion("0.0.0")!)
    }

    /// 配了公钥就强制验签（手册 §4 纪律一）
    var signingRequired: Bool { !publicKey.isEmpty }
}

// MARK: - 偏好持久化

/// 更新相关的偏好。
///
/// **为什么用 UserDefaults 逐键读写，而不是一个 Codable 结构体存 JSON**：
/// 手册 P8 是个很脏的坑——用合成 `Codable` 的结构体加字段后，
/// **旧版本写下的文件会整份解码失败**；如果加载路径写的是 `try?`，
/// 结果就是「升级后用户的整个配置被清空，而且日志里什么都没有」。
/// 逐键读写天然免疫这一类：**加字段不影响已有字段的解码**，
/// 所以这里不是"偷懒用 UserDefaults"，是**从构造上让那个 bug 不可能发生**。
@MainActor
final class UpdatePreferences: ObservableObject {
    private let d = UserDefaults.standard
    private enum Key {
        static let autoCheck = "LumoUpdate.autoCheck"
        static let autoInstall = "LumoUpdate.autoInstall"
        static let skippedVersion = "LumoUpdate.skippedVersion"
        static let lastCheckedAt = "LumoUpdate.lastCheckedAt"
    }

    /// 自动检查：默认**开**。用户预期一个 App 会自己看有没有新版。
    @Published var autoCheck: Bool {
        didSet { d.set(autoCheck, forKey: Key.autoCheck) }
    }

    /// 自动下载并安装：默认**关**。
    /// 手册 §2 明确说这条要慎重——它会重启 App，那是**用户没同意的事**。
    @Published var autoInstall: Bool {
        didSet { d.set(autoInstall, forKey: Key.autoInstall) }
    }

    /// 用户点过"跳过这个版本"的版本号
    @Published var skippedVersion: String? {
        didSet { d.set(skippedVersion, forKey: Key.skippedVersion) }
    }

    /// 上次**尝试**检查的时间（注意是尝试，不是成功——见 P4）
    @Published var lastCheckedAt: Date? {
        didSet { d.set(lastCheckedAt, forKey: Key.lastCheckedAt) }
    }

    init() {
        // 注册默认值而不是手写 `?? true`：这样"默认开"这件事只有一个出处
        d.register(defaults: [Key.autoCheck: true, Key.autoInstall: false])
        autoCheck = d.bool(forKey: Key.autoCheck)
        autoInstall = d.bool(forKey: Key.autoInstall)
        skippedVersion = d.string(forKey: Key.skippedVersion)
        lastCheckedAt = d.object(forKey: Key.lastCheckedAt) as? Date
    }
}

// MARK: - 日志
//
/// 同时写 os_log 和**文件**。
///
/// 为什么要写文件（手册 §5.3 的原话：「没有日志就等于没有可诊断性」）：
/// 更新器是那种"用户说不好用，你什么都看不到"的功能。os_log 在
/// `log show` 里要过滤 subsystem 才能看到，而且**在受限环境里经常读不出来**
/// （实测：本地端到端自检跑完，log show 要么报参数错、要么返回空）。
/// 文件日志没有这个门槛——用户把文件发过来就能看。
/// helper 在 App 死后运行，它写的就是同一个文件，两段日志拼在一起读才是完整的故事。
enum UpdateLog {
    static var url: URL {
        UpdateInstaller.workDirectory().appendingPathComponent("update.log")
    }

    private static let queue = DispatchQueue(label: "com.lumo.update.log")

    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        queue.async {
            let fm = FileManager.default
            let u = url
            try? fm.createDirectory(at: u.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: u) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(line.utf8))
            } else {
                try? line.write(to: u, atomically: true, encoding: .utf8)
            }
        }
    }
}

// MARK: - 状态机

@MainActor
final class UpdateService: ObservableObject {

    /// ★ 全应用**只能有一份**。
    ///
    /// 为什么必须是单例：它内部有定时器（启动后 10 秒首查、之后每 24 小时一次）。
    /// 两份实例 = 两个定时器同时打 GitHub，而且主窗口与设置窗口看到的状态各说各话
    /// ——"检查更新点了没反应""明明说已就绪却点不动"这类怪现象都是这么来的。
    static let shared = UpdateService()

    /// **一个** @Published 状态，不要摊成一堆布尔量（手册 §2）。
    /// 多个布尔量的后果是出现"正在下载 且 正在安装"这种不可能组合，
    /// 然后每个 UI 点都得自己拼逻辑，迟早拼错。
    enum State: Equatable {
        case idle
        case checking
        case upToDate(latest: String)
        case available(UpdateDecision.ReleaseInfoSummary)
        case downloading(progress: Double)
        case ready(version: String, level: UpdateSecurityLevel, note: String)
        case installing
        case blocked(reason: String)
        case failed(message: String, canRetry: Bool, manualURL: String?)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var config: UpdateConfig
    let prefs = UpdatePreferences()

    private let log = Logger(subsystem: "com.lumo.app", category: "update")
    private var timer: Timer?
    private var busy = false
    /// 已经下载并校验好的包（点"立即重启并更新"时用）
    private var staged: VerifiedArchive?
    /// 这个包**应该**是什么版本（来自 Release 元数据）。
    ///
    /// 为什么要单独记：安装前要校验"解出来的包版本对不对"，
    /// 而**对标的必须是"我们要装的那个版本"，不是"当前正在跑的版本"**。
    /// 第一版写成了 `config.currentVersion`，于是每一次真实更新都会在这里被拦下：
    /// 包里写着 0.3.5、当前是 0.3.4 → "版本不符" → 更新永远装不上，
    /// 而日志看起来还挺像回事（"install failed: 版本不符"）。
    /// 这是端到端自检抓出来的第二个真 bug。
    private var stagedVersion: String?

    // MARK: 起停

    init(config: UpdateConfig = .fromBundle()) {
        self.config = config
        let startup = """
            update service started; repository=\(config.repository) \
            current=\(config.currentVersion.description) \
            feed=\(config.feedURLOverride.isEmpty ? "GitHub Releases" : config.feedURLOverride) \
            signingRequired=\(config.signingRequired)
            """
        log.info("\(startup, privacy: .public)")
        UpdateLog.write(startup)
        if config.signingRequired {
            state = .idle
        }
    }

    /// 启动后的第一次检查安排在 10 秒后：**别和 App 首屏抢资源**。
    /// 之后每 24 小时一次。
    func start() {
        guard prefs.autoCheck else {
            log.info("自动检查已关闭，不排定时器")
            return
        }
        schedule(after: 10)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func schedule(after delay: TimeInterval) {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            // ⚠️ P7：**在外层闭包里就解成强引用**，再跨到 Task 里去。
            // Timer 的 block 是 @Sendable 的，`weak` 捕获是可变绑定，
            // 在并发上下文里引用它（包括解包出来的 self）是不允许的。
            // 这个错**本地编译器可能完全不报，只有 CI 报**——因为并发诊断
            // 依赖 SDK 里的 @Sendable 标注。所以这里按规矩写，不赌。
            guard let service = self else { return }
            Task { @MainActor in
                await service.check(manual: false)
                // 排下一次
                service.schedule(after: 24 * 3600)
            }
        }
        // ★ P6：tolerance 要按延迟比例给，不能写死 60 秒。
        // 写死的话，用在"启动后 10 秒首查"上，系统可以把触发时刻往后推最多 60 秒，
        // 表现是「检查好像没跑」，其实只是被推迟了。
        t.tolerance = min(delay * 0.1, 60)
        timer = t
        log.info("下次检查安排在 \(Int(delay), privacy: .public) 秒后（tolerance \(Int(t.tolerance), privacy: .public) 秒）")
    }

    // MARK: 检查

    func check(manual: Bool) async {
        guard !busy else {
            log.info("已有检查在进行，忽略这次（manual=\(manual, privacy: .public)）")
            return
        }
        busy = true
        // ★ P4：记录的是**尝试**时间，不是成功时间。
        // 写在 do 的成功分支里的话，只要失败过一次，
        // 设置页就永远显示「尚未检查过」——那是在骗用户。
        defer {
            busy = false
            prefs.lastCheckedAt = Date()
        }

        state = .checking
        log.info("checking … — current \(self.config.currentVersion.description, privacy: .public), manual=\(manual, privacy: .public)")
        UpdateLog.write("checking … — current \(config.currentVersion.description), manual=\(manual)")

        do {
            let info = try await UpdateFeed.fetchLatest(repository: config.repository,
                                                        feedURLOverride: config.feedURLOverride)
            let decision = UpdateFeed.decide(current: config.currentVersion,
                                             remote: info,
                                             signingRequired: config.signingRequired)
            switch decision {
            case .noReleaseYet:
                log.info("更新源还没有任何发布")
                UpdateLog.write("no release yet")
                state = .upToDate(latest: config.currentVersion.description)

            case .upToDate(let cur, let latest):
                log.info("up to date (current=\(cur, privacy: .public) latest=\(latest, privacy: .public))")
                UpdateLog.write("up to date (current=\(cur) latest=\(latest))")
                state = .upToDate(latest: latest)

            case .remoteIsOlder(let cur, let latest):
                // 远端比我旧：不提示、不降级。但要写日志——否则将来
                // "为什么一直不提示更新"会变成一个查不出来的问题。
                log.notice("远端版本 \(latest, privacy: .public) 比当前 \(cur, privacy: .public) 旧，视为已是最新")
                state = .upToDate(latest: cur)

            case .available(let summary):
                if !manual, prefs.skippedVersion == summary.version {
                    log.info("新版本 \(summary.version, privacy: .public) 已被用户跳过")
                    state = .upToDate(latest: config.currentVersion.description)
                    return
                }
                let avail = """
                    update available: \(summary.version) tag=\(summary.tag) \
                    bytes=\(summary.sizeBytes) \
                    checksum=\(summary.hasChecksum) signature=\(summary.hasSignature)
                    """
                log.info("\(avail, privacy: .public)")
                UpdateLog.write(avail)
                state = .available(summary)
                if manual || prefs.autoInstall {
                    await download()
                    // ★ 开了"自动下载并安装"就必须**真的装**，不能只下完就停在那儿。
                    //
                    // 这个洞是端到端自检抓出来的：日志里四行写得清清楚楚——
                    // 检查到 0.3.5 → 下载校验通过 → **然后什么都没有**。
                    // 界面上停在"已就绪"，用户以为在升，其实永远不会升。
                    // 单元测试和"编译通过"都发现不了它，因为每一步单独看都是对的。
                    // 这也正是手册 §10 那条「'编译通过'不是验证」的现场。
                    if prefs.autoInstall, case .ready = state {
                        await installAndRelaunch()
                    }
                }
            }
        } catch {
            log.error("check failed: \(String(describing: error), privacy: .public)")
            UpdateLog.write("check failed: \(error.localizedDescription)")
            let manualURL = "https://github.com/\(config.repository)/releases"
            if let ue = error as? UpdateError, ue.suggestsManualDownload {
                state = .failed(message: ue.errorDescription ?? "\(error)",
                                canRetry: true, manualURL: manualURL)
            } else {
                state = .failed(message: (error as? UpdateError)?.errorDescription
                                ?? error.localizedDescription,
                                canRetry: true, manualURL: manualURL)
            }
        }
    }

    // MARK: 下载

    func download() async {
        guard case .available(let summary) = state else { return }
        // 远端只在 available 里留了摘要，真正下载要重新取一次完整信息
        do {
            guard let info = try await UpdateFeed.fetchLatest(
                    repository: config.repository, feedURLOverride: config.feedURLOverride),
                  let archive = info.archiveURL else {
                throw UpdateError.noArchiveInRelease(version: summary.version)
            }
            let work = UpdateInstaller.workDirectory(bundleID: config.bundleID)
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let dest = work.appendingPathComponent("Lumo-\(summary.version).zip")

            state = .downloading(progress: 0)
            let verified = try await UpdateDownloader.downloadAndVerify(
                archiveURL: archive,
                checksumURL: info.checksumURL,
                signatureURL: info.signatureURL,
                expectedDigest: info.digestSHA256,
                signingPublicKey: config.publicKey.isEmpty ? nil : config.publicKey,
                to: dest,
                progress: { p in
                    // 回调在别的线程上，回到主 actor 再改状态
                    Task { @MainActor [weak self] in
                        guard let s = self, case .downloading = s.state else { return }
                        s.state = .downloading(progress: p)
                    }
                })
            staged = verified
            stagedVersion = summary.version
            log.info("downloaded & verified (\(verified.byteCount, privacy: .public) bytes, level=\(verified.level.rawValue, privacy: .public))")
            UpdateLog.write("downloaded & verified \(verified.byteCount) bytes, level=\(verified.level.rawValue)")
            state = .ready(version: summary.version, level: verified.level,
                           note: verified.level.explanation)
        } catch {
            log.error("download failed: \(String(describing: error), privacy: .public)")
            UpdateLog.write("download failed: \(error.localizedDescription)")
            let manualURL = "https://github.com/\(config.repository)/releases"
            state = .failed(message: (error as? UpdateError)?.errorDescription
                            ?? error.localizedDescription,
                            canRetry: true, manualURL: manualURL)
        }
    }

    // MARK: 安装

    /// 解压 → 校验 → 生成 helper → 启动 helper → **自己退出**。
    ///
    /// 时序照手册 §5.2。注意最后一步是"自己退出"，不是"替换自己"——
    /// 正在执行的二进制被替换掉是未定义行为。
    func installAndRelaunch() async {
        guard let verified = staged, let wantVersion = stagedVersion else {
            state = .failed(message: "还没有下载好的更新包", canRetry: false, manualURL: nil)
            return
        }
        state = .installing
        let work = UpdateInstaller.workDirectory(bundleID: config.bundleID)
        let target = Bundle.main.bundleURL
        let cfg = config

        do {
            // 解压与校验都是阻塞活儿（ditto + 文件系统），挪到主线程外
            let stagedApp = try await UpdateService.runOffMain {
                let unpack = work.appendingPathComponent("unpacked")
                try? FileManager.default.removeItem(at: unpack)
                try UpdateInstaller.unzip(verified.fileURL, into: unpack)
                let app = try UpdateInstaller.findApp(in: unpack)
                // 用"要装的版本"校验，不是"当前版本"（见 stagedVersion 的注释）
                try UpdateInstaller.validateBundle(app, expectedBundleID: cfg.bundleID,
                                                   expectedVersion: wantVersion)
                return app
            }

            // 可写性预检要在**退出之前**做（手册 §5.3）。
            // 不做的话，用户看到的是"App 退出了，然后什么也没发生"。
            let parent = target.deletingLastPathComponent()
            guard FileManager.default.isWritableFile(atPath: parent.path) else {
                throw UpdateError.targetNotWritable(target.path)
            }

            let script = try UpdateInstaller.writeHelper(pid: ProcessInfo.processInfo.processIdentifier,
                                                        target: target, staged: stagedApp,
                                                        workDir: work)
            log.notice("installer scheduled; quitting so the helper can swap the bundle")
            UpdateLog.write("installer scheduled pid=\(ProcessInfo.processInfo.processIdentifier) "
                            + "target=\(target.path) staged=\(stagedApp.path)")
            try UpdateInstaller.launchHelper(script)

            // ★★ P5：强退兜底。
            // 自更新器最糟的失败不是"报错"，是"静默卡住"——用户以为在更新，
            // 实际什么都没发生。所以宁可硬退，也不要卡住。
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
            NSApp.terminate(nil)
        } catch {
            log.error("install failed: \(String(describing: error), privacy: .public)")
            UpdateLog.write("install failed: \(error.localizedDescription)")
            state = .failed(message: (error as? UpdateError)?.errorDescription
                            ?? error.localizedDescription,
                            canRetry: true, manualURL: nil)
        }
    }

    /// 跳过这个版本
    func skipCurrentVersion() {
        if case .available(let s) = state {
            prefs.skippedVersion = s.version
            log.info("用户跳过版本 \(s.version, privacy: .public)")
        }
        state = .upToDate(latest: config.currentVersion.description)
    }

    /// 打开手动下载页（任何失败都该有这条路，手册 §3）
    func openManualDownload(_ urlString: String?) {
        let s = urlString ?? "https://github.com/\(config.repository)/releases"
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    /// 把阻塞活儿挪出主 actor。
    /// 直接在主 actor 上调 `Process.waitUntilExit()` 会把整界面冻住，
    /// 而"更新时界面卡死几秒"正是用户最容易当成"这软件坏了"的时刻。
    nonisolated static func runOffMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try work()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }
}
