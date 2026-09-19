// Lumo — 自更新：下载 + 校验一条龙
//
// 只 import Foundation + CryptoKit。

import Foundation
import CryptoKit
import LumoCore

/// 下载并校验之后的产物。
struct VerifiedArchive: Sendable {
    let fileURL: URL
    let sha256: String
    let level: UpdateSecurityLevel
    let byteCount: Int
}

enum UpdateDownloader {

    /// 下载 → 校验 → 落盘。
    ///
    /// ## 为什么是"一次性读进内存"而不是流式到磁盘
    ///
    /// 手册 §2 写的是"流式下载"，照抄之前先想过：**Ed25519 验签本来就需要
    /// 整份数据在内存里**（`Curve25519.Signing` 没有分段验签接口），
    /// 所以"流式写到磁盘、再读回来验签"是白跑一趟，还多引出一个
    /// `URLSessionDownloadDelegate` 的经典陷阱——`didFinishDownloadingTo`
    /// 给的那个临时文件**在回调返回后就被删掉**，必须同步搬走。
    ///
    /// 于是这里选了简单的那条路：读进内存 → 算哈希 → 验签 → **校验全过才落盘**。
    /// 顺带还有一个好处：**校验失败时磁盘上不会留下半个坏包**。
    ///
    /// 代价写在明处：**内存峰值 ≈ 包大小**。Lumo 的更新包是 2~3 MB，无所谓；
    /// 哪天包涨到几十 MB，就该改成流式分段哈希 + 文件级验签。
    /// （`UpdateIntegrity.sha256Hex(ofFileAt:)` 已经留好了流式版本，改起来不难。）
    ///
    /// - Parameters:
    ///   - signingPublicKey: Info.plist 里的公钥。**非空就强制验签**——
    ///     远端缺 `.ed25519` 直接拒绝，绝不降级成只查哈希（手册 §4 纪律一）。
    ///   - progress: 只在几个**确定的里程碑**上报（下载完 / 校验完 / 落盘完）。
    ///     不做字节级进度：那需要 delegate 化的下载，而收益只是让进度条动得更细，
    ///     换来的是一堆并发与临时文件生命周期的坑。UI 侧因此显示不确定进度。
    static func downloadAndVerify(archiveURL: URL,
                                  checksumURL: URL?,
                                  signatureURL: URL?,
                                  expectedDigest: String?,
                                  signingPublicKey: String?,
                                  to destination: URL,
                                  progress: @escaping @Sendable (Double) -> Void = { _ in })
    async throws -> VerifiedArchive {
        // 先问"目标目录能不能写"。手册 §5.3：**必须在退出之前问**，
        // 否则用户会看到"App 退出了，然后什么也没发生"。
        // 这一步放在下载之前，省得白下几 MB。
        let parent = destination.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.targetNotWritable(parent.path)
        }

        progress(0.05)
        let payload = try await fetch(archiveURL)
        let bytes = payload.count
        progress(0.55)
        guard bytes > 0 else { throw UpdateError.unpackFailed(T("下载到 0 字节")) }

        // ── 第一级：SHA-256 ──────────────────────────────────────────────
        let actual = UpdateIntegrity.sha256Hex(payload)
        progress(0.7)

        // 校验和来源优先级：Release 资产自带的 digest（GitHub 2022-11-28 起提供）
        // → 单独的 .sha256 文件。两者都没有就是"只剩 HTTPS"这一级，如实标出来。
        var expected = expectedDigest
        if expected == nil, let cu = checksumURL {
            if let data = try? await fetch(cu), let text = String(data: data, encoding: .utf8) {
                expected = UpdateIntegrity.parseChecksum(text)
            }
        }
        if let e = expected, !UpdateIntegrity.checksumMatches(e, actual) {
            throw UpdateError.checksumMismatch(expected: e, actual: actual)
        }

        // ── 第二级：Ed25519 ─────────────────────────────────────────────
        var level: UpdateSecurityLevel = expected == nil ? .httpsOnly : .checksum
        let key = signingPublicKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !key.isEmpty {
            // 配了公钥就必须验签：缺签名文件直接拒绝，绝不降级
            guard let su = signatureURL else { throw UpdateError.missingSignature }
            guard let data = try? await fetch(su),
                  let sigText = String(data: data, encoding: .utf8) else {
                throw UpdateError.missingSignature
            }
            guard UpdateIntegrity.verifyEd25519(signatureText: sigText,
                                                payload: payload,
                                                publicKeyText: key) else {
                throw UpdateError.signatureMismatch
            }
            level = .signature
        }
        progress(0.85)

        // ── 校验全过，才落盘 ────────────────────────────────────────────
        // 写临时名再原子 mv：中途失败不会留下"看起来像完整包"的半截文件。
        let tmp = parent.appendingPathComponent(".\(destination.lastPathComponent).partial")
        try? FileManager.default.removeItem(at: tmp)
        try payload.write(to: tmp, options: .atomic)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmp, to: destination)
        progress(1.0)

        return VerifiedArchive(fileURL: destination, sha256: actual,
                               level: level, byteCount: bytes)
    }

    /// 取一个 URL 的全部字节。更新流量走**无缓存**的 session（见 UpdateNetwork.session）。
    static func fetch(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("Lumo-Updater", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await UpdateNetwork.session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode)
        }
        return data
    }
}
