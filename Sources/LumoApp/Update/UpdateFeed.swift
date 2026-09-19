// Lumo — 自更新：更新源（GitHub Releases）解析与取回
//
// 只 import Foundation（见 SemanticVersion.swift 顶部那段纪律说明）。

import Foundation
import LumoCore

// MARK: - 错误

/// 更新链路上所有能出问题的地方。
///
/// 每一种都带**人话描述**，因为手册 §10.4 那条：自更新器最糟的失败不是"报错"，
/// 是"静默卡住"——用户以为在更新，实际什么都没发生。所以宁可报一个啰嗦的错，
/// 也不要有任何一种"悄悄放弃"的路径。
enum UpdateError: LocalizedError, Equatable, Sendable {
    case badRepository(String)
    case repositoryInaccessible(String)
    case rateLimited
    case httpStatus(Int)
    case malformedResponse
    case noArchiveInRelease(version: String)
    case missingSignature
    case signatureMismatch
    case checksumMismatch(expected: String, actual: String)
    case noVerificationData
    case unpackFailed(String)
    case badBundle(String)
    case versionMismatch(expected: String, found: String)
    case targetNotWritable(String)
    /// 更新助手脚本没能通过 `sh -n`（语法检查）。详见 UpdateInstaller.shellSyntaxProblem。
    case helperScriptInvalid(String)

    var errorDescription: String? {
        switch self {
        case .badRepository(let r):
            return T("更新源地址不合法：%@（应形如 owner/repo）", r)
        case .repositoryInaccessible(let r):
            // ★ 这条是实测踩出来的：Lumo 的仓库是**私有**的，
            //   而 `/releases/latest` 对私有仓库一律返回 404 —— 和"仓库里还没有
            //   任何 Release"是**同一个状态码**。如果不区分，界面会理直气壮地告诉
            //   用户"你已经是最新版本"，而事实是它压根没问到。
            //   所以 404 之后要再探一次仓库本身：存在 = 真的没有 release；
            //   不存在 = 访问不了（私有/写错/被删）。
            return T("更新源 %@ 不可访问（多半是私有仓库，或仓库名写错了）。", r)
                 + T("自动更新需要「公开」的仓库——私有的仓库不允许匿名读取，")
                 + T("客户端拿不到发布信息。")
        case .rateLimited:
            return T("访问 GitHub 太频繁被限流了。过一会儿再试，或到 Releases 页面手动下载。")
        case .httpStatus(let c):
            return T("更新源返回 HTTP %@", c)
        case .malformedResponse:
            return T("更新源的返回看不懂（可能接口变了）")
        case .noArchiveInRelease(let v):
            return T("%@ 这个发布里没有可用的安装包（.zip）", v)
        case .missingSignature:
            return T("这个安装包缺少必要的签名文件，已拒绝安装。")
        case .signatureMismatch:
            return T("签名校验失败——包的内容和签名对不上，已拒绝安装")
        case .checksumMismatch(let e, let a):
            return T("校验和不符（期望 %@…，实际 %@…），包可能在传输中损坏",
                 String(e.prefix(12)), String(a.prefix(12)))
        case .noVerificationData:
            return T("这个发布没有任何校验信息，已拒绝安装")
        case .unpackFailed(let m):
            return T("解压失败：%@", m)
        case .badBundle(let m):
            return T("解出来的包不对：%@", m)
        case .versionMismatch(let e, let f):
            return T("包里的版本是 %@，与预期的 %@ 不符", f, e)
        case .targetNotWritable(let p):
            return T("没有权限替换 %@。把 App 拖到「应用程序」文件夹，或手动下载新版安装。", p)
        case .helperScriptInvalid(let m):
            return T("更新助手脚本没能通过语法检查，这次更新已中止（App 保持原样）：%@", m)
        }
    }

    /// 哪些错误值得把用户引到 Releases 页面手动下载。
    /// 手册 §3：`html_url` 留下来当"打不开更新时手动去看一眼"的兜底。
    var suggestsManualDownload: Bool {
        switch self {
        case .rateLimited, .targetNotWritable, .missingSignature, .signatureMismatch,
             .checksumMismatch, .noArchiveInRelease, .unpackFailed, .badBundle:
            return true
        default:
            return false
        }
    }
}

// MARK: - 发布信息

struct ReleaseAsset: Sendable {
    let name: String
    let url: URL
    let size: Int
    /// GitHub 从 API 2022-11-28 起会给资产带 `digest`（形如 `sha256:abc…`）。
    /// 有就用它当校验和来源，省得再下一个 .sha256 文件。
    let digest: String?
}

struct ReleaseInfo: Sendable {
    let version: SemanticVersion
    let tagName: String
    /// ★ 可选类型，不是偷懒。手册 P3：最新 Release 可能只有 dmg 没有 zip，
    /// 而那时如果当前版本已经不低于它，**根本不该问它有没有 zip**。
    /// 把"这时它可能不存在"表达在类型里，顺序写反了编译器就会拦你。
    let archiveURL: URL?
    let archiveSize: Int
    let checksumURL: URL?
    let signatureURL: URL?
    let digestSHA256: String?
    /// 手动下载兜底 + Release 说明（CHANGELOG）
    let htmlURL: URL?
    let notes: String?
    let publishedAt: String?
}

// MARK: - 网络（★ 绝不能有缓存）

enum UpdateNetwork {
    /// 更新流量专用的 session。
    ///
    /// **这不是性能优化，是安全缺陷的修补。** 手册 P2：原来用 `URLSession.shared`，
    /// 它按 `Last-Modified` 做启发式新鲜度判断，第二次请求直接拿到**上一轮的
    /// `.sha256`** —— 于是"包换了、比对用的是旧哈希"，**放行坏包**。
    /// 注意失败方向：缓存导致的是 fail open（放行），不是拒绝好包。
    /// 校验数据的获取路径上不允许任何缓存。
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 600
        return URLSession(configuration: cfg)
    }()
}

// MARK: - Releases 解析

enum UpdateFeed {

    /// 从 API 的 JSON 解析出发布信息。**纯函数，不碰网络**，所以能被单测直接喂样本。
    ///
    /// - Parameter assetSuffix: 找哪个扩展名的资产，默认 `.zip`。
    ///   手册 §3：**按扩展名筛，不要假设第一个就是**——Release 里通常还有 dmg。
    static func parse(json: Any, assetSuffix: String = ".zip") -> ReleaseInfo? {
        guard let root = json as? [String: Any] else { return nil }
        guard let tag = root["tag_name"] as? String,
              let version = SemanticVersion(tag) else { return nil }

        let assetsRaw = root["assets"] as? [[String: Any]] ?? []
        var assets: [ReleaseAsset] = []
        for a in assetsRaw {
            guard let name = a["name"] as? String,
                  let urlStr = a["browser_download_url"] as? String,
                  let url = URL(string: urlStr) else { continue }
            assets.append(ReleaseAsset(name: name,
                                       url: url,
                                       size: a["size"] as? Int ?? 0,
                                       digest: a["digest"] as? String))
        }

        // 按扩展名筛，大小写不敏感
        let archive = assets.first { $0.name.lowercased().hasSuffix(assetSuffix.lowercased()) }
        let checksum = archive.flatMap { a in
            assets.first { $0.name == a.name + ".sha256" }
        }
        let signature = archive.flatMap { a in
            assets.first { $0.name == a.name + ".ed25519" }
        }

        return ReleaseInfo(
            version: version,
            tagName: tag,
            archiveURL: archive?.url,
            archiveSize: archive?.size ?? 0,
            checksumURL: checksum?.url,
            signatureURL: signature?.url,
            digestSHA256: Self.sha256FromDigest(archive?.digest),
            htmlURL: (root["html_url"] as? String).flatMap(URL.init(string:)),
            notes: root["body"] as? String,
            publishedAt: root["published_at"] as? String)
    }

    /// `"sha256:ab12…"` → `"ab12…"`；不是 sha256 就返回 nil（别把别的算法当校验和用）
    static func sha256FromDigest(_ digest: String?) -> String? {
        guard let d = digest else { return nil }
        let parts = d.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "sha256" else { return nil }
        let hex = String(parts[1]).lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }

    /// 取最新发布。
    ///
    /// 为什么是 `/releases/latest` 而不是 `/releases`：`/latest` 天然排除 draft 与
    /// prerelease，所以 **Beta 不会被推给普通用户**，客户端不必自己判断"这是不是 beta"。
    ///
    /// 为什么不自建一份 `update.json`：发版流程本来就会建 Release，
    /// 多维护一份清单就多一种"清单忘了更新所以推不动"的经典故障。
    ///
    /// - Parameters:
    ///   - repository: 形如 `owner/repo`。
    ///   - feedURLOverride: 直连的 feed 地址。设了它就不走 GitHub、直接请求这个 URL，
    ///     但仍按 GitHub Release 的 JSON 形状解析。两个用途：
    ///     ① 自建/镜像更新源；
    ///     ② **让"真的做一次升级"这条路能在本地被完整跑一遍**——
    ///        否则它必须依赖一个真实的线上 Release，而 Lumo 的仓库是私有的，
    ///        匿名客户端根本拉不到（实测），那条通路就永远测不成。
    /// - Returns: 解析成功返回信息；**仓库里一个 Release 都没有**时返回 nil（不是错误）。
    static func fetchLatest(repository: String,
                            feedURLOverride: String? = nil) async throws -> ReleaseInfo? {
        let override = feedURLOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url: URL
        if !override.isEmpty {
            guard let u = URL(string: override) else { throw UpdateError.badRepository(override) }
            url = u
        } else {
            guard let u = latestURL(repository: repository) else {
                throw UpdateError.badRepository(repository)
            }
            url = u
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // 不加 User-Agent 会被 GitHub 拒绝（403）
        req.setValue("Lumo-Updater", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await UpdateNetwork.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw UpdateError.malformedResponse }
        switch http.statusCode {
        case 200:
            break
        case 404:
            // ⚠️ 404 有两种截然不同的成因，**必须分开**：
            //   ① 仓库存在、但还没有任何 Release → 正常的"已是最新"
            //   ② 仓库不可访问（私有 / 名字写错 / 已删除）→ **不是**"已是最新"
            // 不区分的话，界面会把 ② 说成"你已经是最新版本"——
            // 用户于是永远不会知道自动更新其实从来没工作过。
            // 这是"静默地给出错误结论"，比报错糟糕得多。
            if override.isEmpty, try await repositoryIsAccessible(repository) {
                return nil
            }
            throw UpdateError.repositoryInaccessible(override.isEmpty ? repository : override)
        case 403, 429:
            throw UpdateError.rateLimited
        default:
            throw UpdateError.httpStatus(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw UpdateError.malformedResponse
        }
        // 解析失败可能是接口变了，要当错误报出去，不能悄悄变成"已是最新"
        guard let info = parse(json: json) else { throw UpdateError.malformedResponse }
        return info
    }

    static func latestURL(repository: String) -> URL? {
        let parts = repository.split(separator: "/")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/releases/latest")
    }

    /// 探一次仓库本身能不能匿名访问。
    /// 只在 `/releases/latest` 返回 404 之后才调用——平时不花这一次请求。
    static func repositoryIsAccessible(_ repository: String) async throws -> Bool {
        let parts = repository.split(separator: "/")
        guard parts.count == 2,
              let url = URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])")
        else { throw UpdateError.badRepository(repository) }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Lumo-Updater", forHTTPHeaderField: "User-Agent")
        let (_, resp) = try await UpdateNetwork.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }
}

// MARK: - 决策：到底要不要更新

enum UpdateDecision: Equatable, Sendable {
    case upToDate(current: String, latest: String)
    case available(ReleaseInfoSummary)
    /// 远端比我旧（回滚过 tag、或者我在跑一个未发布的开发版）
    case remoteIsOlder(current: String, latest: String)
    case noReleaseYet

    /// 给 UI 用的轻量快照，免得把 ReleaseInfo 整个搬进 ObservableObject
    struct ReleaseInfoSummary: Equatable, Sendable {
        let version: String
        let tag: String
        let sizeBytes: Int
        let hasChecksum: Bool
        let hasSignature: Bool
        let notes: String?
        let htmlURL: String?
    }
}

extension UpdateFeed {
    /// ★★ 判断顺序：**先比版本号，再要求资产存在。**
    ///
    /// 手册 P3：反过来的话，最新 Release 是 v0.0.2（只有 dmg、没有 zip）、
    /// 当前版本 0.1.0 时，会先抛 `noArchiveInRelease`，用户看到"更新失败"——
    /// 而事实是"你已经是最新的"。
    /// 规矩：**先做便宜的、能得出否定结论的判断。**
    ///
    /// - Parameter signingRequired: Info.plist 里配了公钥就是 true。
    ///   配了公钥而远端没有 `.ed25519` 时，这里就判定为"不可安装"，
    ///   **不降级成只查哈希**（手册 §4 纪律一）。
    static func decide(current: SemanticVersion,
                       remote: ReleaseInfo?,
                       signingRequired: Bool) -> UpdateDecision {
        guard let remote else { return .noReleaseYet }

        switch remote.version.compare(to: current) {
        case .same:
            return .upToDate(current: current.description, latest: remote.version.description)
        case .older:
            // 远端比我旧：可能是回滚过 tag，也可能我在跑未发布的开发版。
            // **绝不能**因此触发"降级更新"。如实报出来即可。
            return .remoteIsOlder(current: current.description, latest: remote.version.description)
        case .newer:
            break
        }

        // 到这里才轮到"有没有包"这个问题
        let hasSig = remote.signatureURL != nil
        let hasSum = remote.checksumURL != nil || remote.digestSHA256 != nil
        return .available(.init(version: remote.version.description,
                                tag: remote.tagName,
                                sizeBytes: remote.archiveSize,
                                // 有签名也算"有校验数据"——Ed25519 比 SHA-256 更强，
                                // 不是"没有校验"。
                                hasChecksum: hasSum || hasSig,
                                hasSignature: hasSig,
                                notes: remote.notes,
                                htmlURL: remote.htmlURL?.absoluteString))
    }
}
