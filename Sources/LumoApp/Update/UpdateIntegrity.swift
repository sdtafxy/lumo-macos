// Lumo — 自更新：完整性校验（SHA-256 + Ed25519）
//
// 只 import Foundation + CryptoKit。CryptoKit 是系统框架，不是第三方依赖，
// 所以"零第三方依赖"这条项目底线没有被破坏，同时这些函数仍可被 swiftc 单编。

import Foundation
import CryptoKit
import LumoCore

/// 这次安装**实际**验到了什么级别。
///
/// ⚠️ **它只用于内部判断与日志，不出现在界面上。**
/// 曾经这里还带着 `label` / `explanation`，把「只校验了 SHA-256、它证明不了来源」
/// 这类话直接摊给用户看。那是实现细节：用户需要判断的只有"这个更新能不能装"，
/// 而这件事 App 已经替他判完了（验不过就拒绝安装，见 UpdateIntegrity）。
/// 把加密方案的解释挂在设置页上，帮不上忙，还像是在替自己辩解。
enum UpdateSecurityLevel: String, Equatable, Sendable {
    /// 只走了 HTTPS。链路上改不了包，但仓库/账号被攻破就防不住。
    case httpsOnly
    /// HTTPS + SHA-256。能防传输损坏与截断。
    case checksum
    /// HTTPS + SHA-256 + Ed25519。**这才是能回答"是不是我发的"的那一级。**
    case signature

}

enum UpdateIntegrity {

    // MARK: - SHA-256

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 按块读，避免把几十 MB 的包整个读进内存。
    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk = try h.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 从 `.sha256` 文件里取出哈希。
    ///
    /// 格式按 `shasum -a 256` 的输出来（那是我们在 CI 里生成它的方式）：
    /// `<64位hex>  <文件名>`。也容忍只有哈希、或者有 `sha256:` 前缀的写法。
    static func parseChecksum(_ text: String) -> String? {
        let lower = text.lowercased()
        // 先按空白切开找那一段 64 位 hex
        for token in lower.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }) {
            let t = token.contains(":") ? String(token.split(separator: ":").last ?? "") : String(token)
            if t.count == 64, t.allSatisfy({ $0.isHexDigit }) { return t }
        }
        return nil
    }

    /// 比较两个哈希，**大小写不敏感**（发布脚本可能输出大写）。
    /// 用常量时间比较没必要在这里做，但大小写这条踩过一次：CI 用 `shasum`（小写），
    /// 而手工核对时有人从别处拷了大写的值。
    static func checksumMatches(_ a: String, _ b: String) -> Bool {
        a.lowercased() == b.lowercased()
    }

    // MARK: - Ed25519

    /// 校验签名。
    ///
    /// - Parameters:
    ///   - signatureText: `.ed25519` 文件的**内容**（base64 或 hex 都接受）
    ///   - payload: 被签名的数据（这里就是整个 zip 的字节）
    ///   - publicKeyText: Info.plist 里的公钥（base64 或 hex，32 字节）
    static func verifyEd25519(signatureText: String,
                              payload: Data,
                              publicKeyText: String) -> Bool {
        guard let sigBytes = decodeFlexible(signatureText),
              let keyBytes = decodeFlexible(publicKeyText),
              keyBytes.count == 32,
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
        else { return false }
        return pub.isValidSignature(sigBytes, for: payload)
    }

    /// 既接受 base64 也接受 hex。
    ///
    /// 为什么要猜：公钥是人手填进 Info.plist 的、签名文件是脚本产的，
    /// 两边格式不一致是迟早的事。**但猜要有纪律**——先按"长度+字符集"判，
    /// 不能两个都试成功就当过（那样等于把校验标准降到"随便哪种编码都算对"）。
    static func decodeFlexible(_ text: String) -> Data? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // hex：全是 hex 字符、长度偶数
        if t.count % 2 == 0, t.allSatisfy({ $0.isHexDigit }) {
            return Data(hexString: t)
        }
        return Data(base64Encoded: t, options: [.ignoreUnknownCharacters])
    }

    /// 我们自己发布时用的签名文本格式：base64。
    /// 生成端与校验端共用这一个函数，免得两边各写一份格式约定。
    static func encodeSignature(_ sig: Data) -> String {
        sig.base64EncodedString()
    }
}

extension Data {
    /// 从 hex 字符串构造。`nil` 表示有非法字符或长度为奇数。
    init?(hexString: String) {
        let s = hexString.lowercased()
        guard s.count % 2 == 0 else { return nil }
        var out = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        self = out
    }
}
