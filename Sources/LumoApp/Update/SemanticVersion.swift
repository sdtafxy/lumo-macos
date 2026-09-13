// Lumo — 自更新：版本号解析与比较
//
// ⚠️ 这个文件**只 import Foundation**，是刻意的。
// 手册《给 macOS 应用做无损自动更新》§7.1 把这条列为"最值得照抄的一条"：
// 纯逻辑文件只依赖 Foundation，就能绕开 App、绕开 Xcode 工程，
// 用 `swiftc 这几个文件 + 一个测试 main.swift` 在几十毫秒内跑真实断言。
// MemeDesk 靠这个抓到了两个真 bug（版本号口径、缓存 fail-open），
// **那两个都不是读代码读出来的**。所以本目录下前四个文件都守这条纪律。
//
// 别在这里 import SwiftUI / AppKit —— 一 import 就再也单编不了了。

import Foundation

/// 语义化版本。
///
/// 只处理我们真正用得到的那部分：点分数字，可有 `v` 前缀，`-` 之后的后缀忽略。
/// 不追求完整实现 semver（预发布版本的排序规则很绕，而我们用不上——
/// 更新源走 `/releases/latest`，它天然排除 prerelease 与 draft）。
struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {

    /// 原始分量，例如 "0.3.4" → [0, 3, 4]
    let components: [Int]
    /// 原始字符串（保留下来只为了打日志时能显示原样）
    let raw: String

    // MARK: - 规范化（★ 整个文件最要紧的五行的）

    /// 把分量规范化成**比较用**的唯一形式。
    ///
    /// 为什么必须只有一个函数：手册 P1 就是踩在这上面——
    /// 合成 Equatable 按数组逐元素比，`[0,1] != [0,1,0]`，而手写的 `<` 又会补零，
    /// 于是 `0.1 == 0.1.0` 为 false，"最新版 0.1.0 / 当前 0.1" 被判定成有更新。
    /// 症状是**永远提示有新版本**，点更新又装成一样的版本，用户只会觉得这软件有病。
    ///
    /// 所以规矩是：`==` 和 `<` **必须**走同一个函数。谁手写了一个比较运算符，
    /// 另一个也得手写，否则默认实现会偷偷用另一套逻辑。
    static func canonical(_ c: [Int]) -> [Int] {
        var x = c
        while x.count < 3 { x.append(0) }          // 补到三段：0.1 → 0.1.0
        while x.count > 3, x.last == 0 { x.removeLast() }  // 去掉第四段起的尾零
        return x
    }

    // MARK: - 解析

    /// 从字符串解析。解析不出来返回 nil（调用方据此报"版本号无法识别"，
    /// 而不是当成 0.0.0——那会让"解析失败"变成"有更新"，方向反了）。
    init?(_ s: String) {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = trimmed
        // tag 常写成 v0.3.4
        if body.hasPrefix("v") || body.hasPrefix("V") { body.removeFirst() }
        // 预发布/构建元数据直接截掉：0.3.4-beta.1 → 0.3.4
        if let cut = body.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            body = String(body[body.startIndex..<cut])
        }
        guard !body.isEmpty else { return nil }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 6 else { return nil }
        var nums: [Int] = []
        for p in parts {
            // 只接受纯数字。出现 "x" / 空段都是不可识别的写法。
            guard !p.isEmpty, let n = Int(p), n >= 0 else { return nil }
            nums.append(n)
        }
        self.components = nums
        self.raw = trimmed
    }

    init(components: [Int], raw: String? = nil) {
        self.components = components
        self.raw = raw ?? components.map(String.init).joined(separator: ".")
    }

    // MARK: - 比较

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let a = canonical(lhs.components)
        let b = canonical(rhs.components)
        let n = max(a.count, b.count)
        for i in 0..<n {
            // 短的那边补 0：0.1.0 与 0.1.0.1 比，前者视作 0.1.0.0
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    // 刻意手写，不用合成实现（见 canonical 的注释）
    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        canonical(lhs.components) == canonical(rhs.components)
    }

    var description: String { raw }
}

// MARK: - 给日志与 UI 用的人话

extension SemanticVersion {
    /// 判断"值不值得更新"。把三态说清楚，别让调用方自己写 `>`：
    /// Swift 的 Comparable 只给了 `<`，`a > b` 是 `b < a`，很容易写反。
    enum Comparison { case newer, same, older }

    func compare(to current: SemanticVersion) -> Comparison {
        if self == current { return .same }
        return self < current ? .older : .newer
    }

    var isStableRelease: Bool { components.count >= 2 }
}
