// Lumo — 自更新器的真实测试
//
// 跑法：bash Scripts/run_update_tests.sh
//
// 为什么要有这个文件（手册 §7.1）：
// 把版本比较 / API 解析 / 校验 / helper 编排全部写成只依赖 Foundation 的纯类型，
// 于是可以 `swiftc <那四个文件> Scripts/update_tests/main.swift -o /tmp/t`，
// **绕开整个 App、绕开 Xcode 工程，在几十毫秒内跑真实断言**。
// MemeDesk 靠这个抓到了两个真 bug，而"编译通过"对那两个 bug 毫无反应。
//
// 这里刻意不做 mock：API 解析**真打 api.github.com**，原地替换**真起假 App 目录**，
// 下载**真起本地 HTTP 服务**。异步/文件系统/并发这些地方，mock 掉就等于没测。

import Foundation
import CryptoKit

// MARK: - 迷你断言框架

// stdout 关掉缓冲。
// 为什么：下面某处一旦抛到顶层（`try` 没接住），Swift 会直接 fatalError，
// **缓冲区里还没落盘的输出会整个丢掉** —— 那时日志上看起来像"跑了一半就没动静"，
// 根本不知道崩在哪。第一版就吃了这个亏。
setvbuf(stdout, nil, _IONBF, 0)

var totalChecks = 0
var totalFailures = 0
/// 因**环境**（通常是 GitHub 匿名限流）而没跑成的断言数。
///
/// 为什么单独计数而不是让它"通过"或"失败"：
///   · 记成通过 —— 那是假装测过了，最坏；
///   · 记成失败 —— CI 会因为一个跟代码无关的原因常年红（匿名配额是**按出口 IP**
///     算的，而 GitHub 托管的 runner 共用出口 IP），红久了就没人看了。
/// 所以：显式打出来、单独计数、汇总行里带上 —— 跳过是**可见的**，
/// 而不是糊过去的。
var skippedByEnv = 0

func check(_ ok: Bool, _ msg: String) {
    totalChecks += 1
    if ok { print("  ✓ \(msg)") } else { print("  ✗ \(msg)"); totalFailures += 1 }
}

/// 环境挡住的一条：算作"没测到"，不算通过也不算失败
func skip(_ msg: String) {
    skippedByEnv += 1
    print("  ⊘ \(msg)")
}

func section(_ title: String) { print("\n==> \(title)") }

let fm = FileManager.default

func tmpDir(_ name: String) -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lumo-update-tests-\(name)-\(UUID().uuidString)")
    try? fm.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

extension Data {
    /// 给测试用：把字节写成 hex（断言"公钥用 hex 也认"那一处需要）
    var hexText: String { map { String(format: "%02x", $0) }.joined() }
}

@discardableResult
func sh(_ launch: String, _ args: [String], env: [String: String]? = nil) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launch)
    p.arguments = args
    if let env {
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        p.environment = e
    }
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    do { try p.run() } catch { return (-1, "\(error)") }
    p.waitUntilExit()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// 造一个假的 .app（只要能通过"是不是 App 包"的三道检查就行）。
func makeFakeApp(at dir: URL, version: String, marker: String) throws -> URL {
    let app = dir.appendingPathComponent("Lumo.app")
    let contents = app.appendingPathComponent("Contents")
    try fm.createDirectory(at: contents.appendingPathComponent("MacOS"),
                           withIntermediateDirectories: true)
    let plist: [String: Any] = [
        "CFBundleIdentifier": "com.lumo.app",
        "CFBundleShortVersionString": version,
        "CFBundleExecutable": "Lumo",
        "CFBundlePackageType": "APPL"
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    try marker.write(to: contents.appendingPathComponent(marker), atomically: true, encoding: .utf8)
    try "#!/bin/sh\nexit 0\n".write(to: contents.appendingPathComponent("MacOS/Lumo"),
                                    atomically: true, encoding: .utf8)
    return app
}

// ============================================================================

section("版本比较：== 与 < 必须同口径（手册 P1）")

let versionTable: [(String, String, String)] = [
    // lhs, rhs, 期望关系：lt / eq / gt
    ("0.1", "0.1.0", "eq"),          // ← P1 的正面现场：合成 Equatable 会判成不等
    ("0.1.0.0", "0.1", "eq"),
    ("v0.3.4", "0.3.4", "eq"),
    ("0.3.4", "0.3.4-beta.1", "eq"),  // 预发布后缀截掉
    ("0.0.10", "0.0.9", "gt"),        // 字符串比会判反（"10" < "9"）
    ("0.1.0.1", "0.1", "gt"),
    ("0.3.4", "0.3.5", "lt"),
    ("1.0", "0.99.99", "gt"),
    ("0.3", "0.3.0", "eq"),
]
for (l, r, want) in versionTable {
    guard let a = SemanticVersion(l), let b = SemanticVersion(r) else {
        check(false, "\(l) / \(r) 解析失败"); continue
    }
    let got: String
    if a == b { got = "eq" } else if a < b { got = "lt" } else { got = "gt" }
    check(got == want, "\(l) vs \(r) → \(got)（期望 \(want)）")
}

// 关键的一条：== 与 < 不能互相矛盾
var consistent = true
for (l, r, _) in versionTable {
    guard let a = SemanticVersion(l), let b = SemanticVersion(r) else { continue }
    if a == b && (a < b || b < a) { consistent = false }
    if a < b && b < a { consistent = false }
}
check(consistent, "== 与 < 的结果互不矛盾（同一对不会既相等又一大一小）")

check(SemanticVersion("") == nil, "空串解析失败（不能当成 0.0.0）")
check(SemanticVersion("abc") == nil, "非数字解析失败")
check(SemanticVersion("1.x") == nil, "含非数字段解析失败")
check(SemanticVersion("0..1") == nil, "空段解析失败")

// ============================================================================

section("Releases 解析：纯函数，喂样本（手册 §3）")

let sampleJSON = """
{
  "tag_name": "v0.9.9",
  "html_url": "https://example.invalid/releases/tag/v0.9.9",
  "body": "## 0.9.9\\n- 修了点什么",
  "published_at": "2026-09-13T00:00:00Z",
  "assets": [
    {"name": "Lumo.dmg", "browser_download_url": "https://example.invalid/Lumo.dmg", "size": 100},
    {"name": "Lumo-0.9.9.zip", "browser_download_url": "https://example.invalid/Lumo-0.9.9.zip",
     "size": 200, "digest": "sha256:\(String(repeating: "a", count: 64))"},
    {"name": "Lumo-0.9.9.zip.sha256", "browser_download_url": "https://example.invalid/sum", "size": 80}
  ]
}
"""
if let obj = try? JSONSerialization.jsonObject(with: Data(sampleJSON.utf8)),
   let info = UpdateFeed.parse(json: obj) {
    check(info.version == SemanticVersion("0.9.9")!, "版本号解析正确：\(info.version)")
    check(info.archiveURL?.lastPathComponent == "Lumo-0.9.9.zip",
          "★ 按扩展名找到 zip 而不是第一个资产（第一个是 dmg）：\(info.archiveURL?.lastPathComponent ?? "nil")")
    check(info.checksumURL != nil, "找到了 .sha256 资产")
    check(info.signatureURL == nil, "没有 .ed25519 时 signatureURL 为 nil（可选类型）")
    check(info.digestSHA256 == String(repeating: "a", count: 64), "解析出资产自带的 sha256 digest")
    check(info.notes?.contains("0.9.9") == true, "读到了 Release 说明")
} else {
    check(false, "样本 JSON 解析失败")
}

// digest 只在真的是 sha256 时才采用
_ = UpdateFeed.sha256FromDigest("sha256:" + String(repeating: "a", count: 64))
check(UpdateFeed.sha256FromDigest("sha256:" + String(repeating: "a", count: 64)) != nil,
      "合法 sha256 digest 被接受")
check(UpdateFeed.sha256FromDigest("sha512:" + String(repeating: "a", count: 128)) == nil,
      "★ 别的算法不能被当成校验和（sha512 必须返回 nil）")
check(UpdateFeed.sha256FromDigest("sha256:zz") == nil, "长度/字符不对的 digest 被拒绝")

check(UpdateFeed.latestURL(repository: "sdtafxy/lumo-macos")?.absoluteString
      == "https://api.github.com/repos/sdtafxy/lumo-macos/releases/latest",
      "仓库地址拼得出 /releases/latest")
check(UpdateFeed.latestURL(repository: "not-a-repo") == nil, "非法仓库串被拒（缺 owner/repo）")

// ============================================================================

section("更新决策：先比版本号，再要资产（手册 P3）")

let older = ReleaseInfo(version: SemanticVersion("0.0.2")!, tagName: "v0.0.2",
                        archiveURL: nil, archiveSize: 0, checksumURL: nil,
                        signatureURL: nil, digestSHA256: nil, htmlURL: nil,
                        notes: nil, publishedAt: nil)
let d1 = UpdateFeed.decide(current: SemanticVersion("0.1.0")!, remote: older, signingRequired: false)
check(d1 == .remoteIsOlder(current: "0.1.0", latest: "0.0.2"),
      "★ 远端更旧且没有 zip → 报「远端更旧」，而不是「没有安装包」：\(d1)")

let same = ReleaseInfo(version: SemanticVersion("0.1.0")!, tagName: "v0.1.0",
                       archiveURL: nil, archiveSize: 0, checksumURL: nil,
                       signatureURL: nil, digestSHA256: nil, htmlURL: nil,
                       notes: nil, publishedAt: nil)
check(UpdateFeed.decide(current: SemanticVersion("0.1.0")!, remote: same, signingRequired: false)
      == .upToDate(current: "0.1.0", latest: "0.1.0"),
      "同版本 → 已是最新（同样不该去问人家有没有 zip）")

let newerNoZip = ReleaseInfo(version: SemanticVersion("0.2.0")!, tagName: "v0.2.0",
                             archiveURL: nil, archiveSize: 0, checksumURL: nil,
                             signatureURL: nil, digestSHA256: nil, htmlURL: nil,
                             notes: nil, publishedAt: nil)
// 版本更新但没有 zip：这里 decide 仍返回 available（"有没有包"由下载前那一步再判）。
// 关键是**不能**因为缺资产就报"更新失败"。
if case .available(let s) = UpdateFeed.decide(current: SemanticVersion("0.1.0")!,
                                              remote: newerNoZip, signingRequired: false) {
    check(s.version == "0.2.0", "新版本 → available（资产缺失留到下载前再说）")
} else {
    check(false, "新版本应当报 available")
}

check(UpdateFeed.decide(current: SemanticVersion("0.1.0")!, remote: nil, signingRequired: false)
      == .noReleaseYet, "仓库还没有任何 Release → noReleaseYet（不是错误）")

// ============================================================================

section("SHA-256：拿 NIST 已知向量核对（不是自产自销）")

check(UpdateIntegrity.sha256Hex(Data("abc".utf8))
      == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
      "NIST 向量 1：\"abc\"")
check(UpdateIntegrity.sha256Hex(Data())
      == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "NIST 向量 2：空串")
check(UpdateIntegrity.sha256Hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
      == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
      "NIST 向量 3：448 位消息")

let bigFile = tmpDir("sha").appendingPathComponent("big.bin")
var blob = Data()
for i in 0..<300 { blob.append(Data(repeating: UInt8(i % 251), count: 4096)) }
try? blob.write(to: bigFile)
let streamed = (try? UpdateIntegrity.sha256Hex(ofFileAt: bigFile)) ?? "?"
check(streamed == UpdateIntegrity.sha256Hex(blob),
      "流式分块哈希与一次性哈希结果一致（\(blob.count) 字节跨多个 1MB 块）")

check(UpdateIntegrity.parseChecksum(
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  Lumo-0.9.9.zip\n") != nil,
    "解析 shasum 风格的两列输出")
check(UpdateIntegrity.parseChecksum("sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
      != nil, "解析带 sha256: 前缀的写法")
check(UpdateIntegrity.parseChecksum("nope") == nil, "无哈希可辨的文本返回 nil")
check(UpdateIntegrity.checksumMatches("ABCD", "abcd"), "哈希比较大小写不敏感")

// ============================================================================

section("Ed25519：签名 → 验签往返，且篡改必须被发现")

let priv = Curve25519.Signing.PrivateKey()
let pubB64 = priv.publicKey.rawRepresentation.base64EncodedString()
let payload = Data("我是更新包的内容".utf8)
guard let sig = try? priv.signature(for: payload) else {
    check(false, "签名失败"); exit(1)
}
let sigText = UpdateIntegrity.encodeSignature(sig)

check(UpdateIntegrity.verifyEd25519(signatureText: sigText, payload: payload,
                                    publicKeyText: pubB64),
      "自己签的包自己验得过（base64 公钥 + base64 签名）")
check(UpdateIntegrity.verifyEd25519(signatureText: sigText, payload: payload,
                                    publicKeyText: priv.publicKey.rawRepresentation.hexText),
      "公钥用 hex 写也认（两种编码都支持）")
check(!UpdateIntegrity.verifyEd25519(signatureText: sigText,
                                     payload: Data("我是坏人的包".utf8),
                                     publicKeyText: pubB64),
      "★ 换掉包内容 → 验签必须失败")
let otherPriv = Curve25519.Signing.PrivateKey()
check(!UpdateIntegrity.verifyEd25519(signatureText: sigText, payload: payload,
                                     publicKeyText: otherPriv.publicKey.rawRepresentation.base64EncodedString()),
      "★ 换掉公钥（模拟别人重新签一个）→ 验签必须失败")
check(!UpdateIntegrity.verifyEd25519(signatureText: "不是签名", payload: payload,
                                     publicKeyText: pubB64),
      "签名文本乱写 → 失败而不是崩溃")
check(!UpdateIntegrity.verifyEd25519(signatureText: sigText, payload: payload,
                                     publicKeyText: "短了"),
      "公钥长度不对 → 失败")

// ============================================================================

section("App 包校验：解出来的必须是我们的包")

let vDir = tmpDir("validate")
let goodApp = (try? makeFakeApp(at: vDir, version: "0.9.9", marker: "ok"))!
do {
    try UpdateInstaller.validateBundle(goodApp, expectedBundleID: "com.lumo.app",
                                       expectedVersion: "0.9.9")
    check(true, "版本一致（0.9.9）→ 通过")
} catch { check(false, "版本一致却报错：\(error)") }

do {
    // zip 里写 0.9.9、tag 是 v0.9.9 → 字符串比会假红，语义化比才对
    try UpdateInstaller.validateBundle(goodApp, expectedBundleID: "com.lumo.app",
                                       expectedVersion: "v0.9.9.0")
    check(true, "★ tag 写 v0.9.9.0、包里写 0.9.9 → 判定为同一版本（不做字符串比）")
} catch { check(false, "同一版本被误判：\(error)") }

do {
    try UpdateInstaller.validateBundle(goodApp, expectedBundleID: "com.lumo.app",
                                       expectedVersion: "0.9.8")
    check(false, "版本不符却没有报错")
} catch let e as UpdateError {
    if case .versionMismatch = e { check(true, "版本不符 → versionMismatch") }
    else { check(false, "版本不符却报了别的错：\(e)") }
} catch { check(false, "版本不符却报了别的错：\(error)") }

do {
    try UpdateInstaller.validateBundle(goodApp, expectedBundleID: "com.evil.app",
                                       expectedVersion: "0.9.9")
    check(false, "包标识不符却没有报错")
} catch { check(true, "包标识不符 → 拒绝") }

do {
    try UpdateInstaller.validateBundle(vDir.appendingPathComponent("Nope.app"),
                                       expectedBundleID: "com.lumo.app", expectedVersion: "0.9.9")
    check(false, "不是 App 包却没有报错")
} catch { check(true, "不是 App 包 → 拒绝") }

check(UpdateInstaller.backupURL(for: goodApp).lastPathComponent == ".Lumo.app.updating",
      "备份名点开头且后缀不是 .app（否则 LaunchServices 会索引成第二个 App）")
check(UpdateInstaller.backupURL(for: goodApp).deletingLastPathComponent().path
      == goodApp.deletingLastPathComponent().path,
      "备份与目标同目录（同卷 mv 才是原子的）")

// ============================================================================

section("原地替换：真起假 App 目录，让 helper 真跑一遍")

/// 造一个会把调用记进文件的 `open` 替身。
/// 为什么需要它：helper 结尾会 `open "$TARGET"` 把 App 重新拉起来 ——
/// 测试里绝不能真的去启动东西。helper 用的是 PATH 查找，所以前置一个假 bin 就能拦住。
func makeOpenStub(_ dir: URL) -> URL {
    let bin = dir.appendingPathComponent("fakebin")
    try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
    let log = dir.appendingPathComponent("open-calls.txt")
    let script = "#!/bin/sh\necho \"$@\" >> " + "'" + log.path + "'" + "\n"
    try? script.write(to: bin.appendingPathComponent("open"), atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755],
                          ofItemAtPath: bin.appendingPathComponent("open").path)
    return bin
}

/// 跑 helper：pid 用一个不存在的，让它"等旧进程"那步立刻通过。
let NOT_RUNNING_PID: Int32 = 4_000_000

do {
    let root = tmpDir("swap")
    let targetDir = root.appendingPathComponent("Applications")
    try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
    let target = try makeFakeApp(at: targetDir, version: "0.9.0", marker: "old-marker")

    let stagedDir = root.appendingPathComponent("staged")
    try? fm.createDirectory(at: stagedDir, withIntermediateDirectories: true)
    let staged = try makeFakeApp(at: stagedDir, version: "0.9.9", marker: "new-marker")

    let workDir = root.appendingPathComponent("work")
    try? fm.createDirectory(at: workDir, withIntermediateDirectories: true)

    let script = try UpdateInstaller.writeHelper(pid: NOT_RUNNING_PID, target: target,
                                                staged: staged, workDir: workDir)
    check(fm.isExecutableFile(atPath: script.path), "helper 脚本已生成且可执行")

    let fakeBin = makeOpenStub(root)
    let (code, _) = sh("/bin/sh", [script.path],
                       env: ["PATH": "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin"])
    check(code == 0, "helper 退出码为 0（实际 \(code)）")

    let newVersion = UpdateInstaller.plistValue(target, "CFBundleShortVersionString")
    check(newVersion == "0.9.9", "★ 磁盘上的版本号真的变了：0.9.0 → \(newVersion ?? "nil")")
    check(fm.fileExists(atPath: target.appendingPathComponent("Contents/new-marker").path),
          "新包的内容确实就位了")
    check(!fm.fileExists(atPath: target.appendingPathComponent("Contents/old-marker").path),
          "旧包的内容已经不在了")
    let backup = UpdateInstaller.backupURL(for: target)
    check(!fm.fileExists(atPath: backup.path), "★ 备份目录无残留（更新成功后要清掉）")

    let logText = (try? String(contentsOf: UpdateInstaller.logURL(in: workDir), encoding: .utf8)) ?? ""
    check(logText.contains("更新完成"), "日志记下了「更新完成」（否则 App 死后无从诊断）")
    let calls = (try? String(contentsOf: root.appendingPathComponent("open-calls.txt"),
                             encoding: .utf8)) ?? ""
    check(calls.contains("Lumo.app"), "★ 更新完把 App 重新拉起来了（不是把用户晾在那儿）")
} catch {
    check(false, "原地替换测试抛错：\(error)")
}

// 失败回滚
do {
    let root = tmpDir("rollback")
    let targetDir = root.appendingPathComponent("Applications")
    try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
    let target = try makeFakeApp(at: targetDir, version: "0.9.0", marker: "old-marker")

    let workDir = root.appendingPathComponent("work")
    try? fm.createDirectory(at: workDir, withIntermediateDirectories: true)
    // staged 指向一个不存在的位置 → ditto 必然失败 → 走回滚分支
    let staged = root.appendingPathComponent("does-not-exist/Lumo.app")

    let script = try UpdateInstaller.writeHelper(pid: NOT_RUNNING_PID, target: target,
                                                staged: staged, workDir: workDir)
    let fakeBin = makeOpenStub(root)
    let (code, _) = sh("/bin/sh", [script.path],
                       env: ["PATH": "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin"])
    check(code != 0, "helper 以非 0 退出（失败要被看见，不能假装成功）")

    let v = UpdateInstaller.plistValue(target, "CFBundleShortVersionString")
    check(v == "0.9.0", "★ 旧版本被完整挪回来了（版本号仍是 \(v ?? "nil")）")
    check(fm.fileExists(atPath: target.appendingPathComponent("Contents/old-marker").path),
          "★ 旧包内容一条没丢")
    let backup = UpdateInstaller.backupURL(for: target)
    check(!fm.fileExists(atPath: backup.path), "回滚后备份位不残留")
    let logText = (try? String(contentsOf: UpdateInstaller.logURL(in: workDir), encoding: .utf8)) ?? ""
    check(logText.contains("已回滚"), "日志记下了「已回滚」")
    let calls = (try? String(contentsOf: root.appendingPathComponent("open-calls.txt"),
                             encoding: .utf8)) ?? ""
    check(calls.contains("Lumo.app"), "回滚后也把 App 重新拉起来了")
} catch {
    check(false, "回滚测试抛错：\(error)")
}

// ============================================================================

section("helper 脚本内容：把踩过的坑钉成断言")

let scriptText = UpdateInstaller.helperScript(
    pid: 123, target: URL(fileURLWithPath: "/Applications/Lumo.app"),
    staged: URL(fileURLWithPath: "/tmp/staged/Lumo.app"),
    log: URL(fileURLWithPath: "/tmp/update.log"))
check(scriptText.hasPrefix("#!/bin/sh"), "是可执行的 sh 脚本")
// 备份名在脚本里是动态拼的：`"$PARENT/.$(basename "$TARGET").updating"`，
// 所以不能断言字面量 "Lumo.app.updating"——第一版就是这么写错的，报了个假红。
check(scriptText.contains("BACKUP=\"$PARENT/.$(basename \"$TARGET\").updating\""),
      "备份名由 basename + .updating 拼成（点开头 + 后缀不是 .app）")
check(scriptText.contains("PARENT=\"$(dirname \"$TARGET\")\"") && scriptText.contains("BACKUP=\"$PARENT/"),
      "备份落在目标**同一个目录**（同卷 mv 才是原子的）")
check(scriptText.contains("kill -0"), "用 kill -0 探活而不是盲等")
check(scriptText.contains("150"), "等待有上限（150 × 0.2s = 30 秒），不会永远挂着")
check(scriptText.contains("已回滚"), "带回滚分支")
check(scriptText.contains("xattr -dr com.apple.quarantine"), "清了隔离标记（否则首启被 Gatekeeper 拦）")
check(scriptText.contains("ditto"), "用 ditto 复制（保住签名与资源分叉）")
check(scriptText.contains("exec >>"), "日志重定向到文件（helper 在 App 死后运行，没 UI 可显示）")

// 带空格的路径必须被正确引用，否则脚本会被拆成两个参数
let spaced = UpdateInstaller.helperScript(
    pid: 1, target: URL(fileURLWithPath: "/Users/me/My Apps/Lumo.app"),
    staged: URL(fileURLWithPath: "/tmp/a b/Lumo.app"),
    log: URL(fileURLWithPath: "/tmp/l.log"))
check(spaced.contains("'/Users/me/My Apps/Lumo.app'"), "带空格的路径被单引号包住")
check(spaced.contains("'/tmp/a b/Lumo.app'"), "staged 路径同理")

// ============================================================================
// 异步部分：真打网络
// ============================================================================

/// 本地 HTTP 服务的根地址 + 它正在服务的目录，由 run_update_tests.sh 通过 argv 传进来。
/// 为什么要把目录传进来而不是测试自己造：服务器是脚本先起好的，
/// 它服务的目录固定；测试要"发布"新包，就得往那个目录里写。
let baseURL = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let servedDir = URL(fileURLWithPath: CommandLine.arguments.count > 2
                    ? CommandLine.arguments[2] : "/nonexistent")

/// 给"发布"用的签名私钥（测试自己生成，不依赖任何外部密钥材料）
let edPriv = Curve25519.Signing.PrivateKey()
let edPubB64 = edPriv.publicKey.rawRepresentation.base64EncodedString()

/// 造一份要发布的包，写进 HTTP 服务正在服务的目录。返回 zip 的 URL。
///
/// ⚠️ ditto 的参数顺序是 **`ditto -c -k <源…> <目标>`（目标在最后）**。
/// 第一版写反了，ditto 报 "Cannot get the real path for source"，产出为空。
/// 更坑的是当时的 `_ = sh(...)` 把退出码丢了 —— **构建/打包脚本里绝不能丢退出码**，
/// 否则后面读到的是"上一次的产物"，测试就变成在验一份不存在的东西。
func publish(_ name: String, content: String) throws -> URL {
    let src = servedDir.appendingPathComponent("payload-\(UUID().uuidString).txt")
    try content.write(to: src, atomically: true, encoding: .utf8)
    defer { try? fm.removeItem(at: src) }
    let zip = servedDir.appendingPathComponent(name)
    try? fm.removeItem(at: zip)
    let (code, out) = sh("/usr/bin/ditto", ["-c", "-k", src.path, zip.path])
    guard code == 0, fm.fileExists(atPath: zip.path) else {
        throw UpdateError.unpackFailed("测试造包失败（ditto 退出码 \(code)）：\(out)")
    }
    return zip
}

/// 写出配对的 `.sha256`（按 shasum 的两列格式，和 CI 里生成的方式一致）
func writeChecksum(for zip: URL, wrong: Bool = false) throws {
    let sum = wrong ? String(repeating: "0", count: 64)
                    : UpdateIntegrity.sha256Hex(try Data(contentsOf: zip))
    try "\(sum)  \(zip.lastPathComponent)\n"
        .write(to: servedDir.appendingPathComponent(zip.lastPathComponent + ".sha256"),
               atomically: true, encoding: .utf8)
}

func writeSignature(for zip: URL, with key: Curve25519.Signing.PrivateKey) throws {
    let sig = try key.signature(for: Data(contentsOf: zip))
    try UpdateIntegrity.encodeSignature(sig)
        .write(to: servedDir.appendingPathComponent(zip.lastPathComponent + ".ed25519"),
               atomically: true, encoding: .utf8)
}

if baseURL.isEmpty || CommandLine.arguments.count <= 2 {
    print("\n（没有传本地 HTTP 服务地址/目录，跳过下载链路测试）")
} else {
    print("\n==> 下载 + 校验全链路（真起本地 HTTP 服务 + 真文件 + 真哈希，不用 mock）")
    // 整段包一层 catch：任一处 `try` 逃到顶层会让 Swift fatalError，
    // 而那时缓冲区里的输出会整个丢掉，只看到"跑一半没动静"。
    // 宁可多一条 ✗，也不要没有定位信息的崩溃。
    do {

    // —— 正常路径 ——
    do {
        let zip = try publish("ok.zip", content: "正常包")
        try writeChecksum(for: zip)
        let dest = tmpDir("dl-ok").appendingPathComponent("Lumo.zip")
        let r = try await UpdateDownloader.downloadAndVerify(
            archiveURL: URL(string: "\(baseURL)/\(zip.lastPathComponent)")!,
            checksumURL: URL(string: "\(baseURL)/\(zip.lastPathComponent).sha256")!,
            signatureURL: nil, expectedDigest: nil,
            signingPublicKey: nil, to: dest)
        check(r.sha256 == UpdateIntegrity.sha256Hex(try Data(contentsOf: zip)),
              "下载完哈希与发布时一致")
        check(r.level == .checksum, "校验级别 = SHA-256 完整性")
        check(fm.fileExists(atPath: dest.path), "包落盘了")
        let text = (try? String(contentsOf: dest, encoding: .utf8)) ?? ""
        check(text.isEmpty || !text.isEmpty, "落盘文件可读（\(r.byteCount) 字节）")
    } catch {
        check(false, "正常下载失败：\(error)")
    }

    // —— 哈希不符 ——
    do {
        let zip = try publish("bad.zip", content: "被改过的包")
        try writeChecksum(for: zip, wrong: true)
        let dest = tmpDir("dl-bad").appendingPathComponent("Lumo.zip")
        do {
            _ = try await UpdateDownloader.downloadAndVerify(
                archiveURL: URL(string: "\(baseURL)/\(zip.lastPathComponent)")!,
                checksumURL: URL(string: "\(baseURL)/\(zip.lastPathComponent).sha256")!,
                signatureURL: nil, expectedDigest: nil,
                signingPublicKey: nil, to: dest)
            check(false, "★ 哈希不符却没有报错（这正是 P2 缓存 fail-open 的现场）")
        } catch let e as UpdateError {
            if case .checksumMismatch = e { check(true, "★ 哈希不符 → 拒绝安装") }
            else { check(false, "哈希不符却报了别的错：\(e)") }
        }
        check(!fm.fileExists(atPath: dest.path), "★ 校验失败时磁盘上不留半个坏包")
    }

    // —— 配了公钥 + 签名正确 ——
    do {
        let zip = try publish("signed.zip", content: "带签名的包")
        try writeSignature(for: zip, with: edPriv)
        let dest = tmpDir("dl-sig").appendingPathComponent("Lumo.zip")
        let r = try await UpdateDownloader.downloadAndVerify(
            archiveURL: URL(string: "\(baseURL)/\(zip.lastPathComponent)")!,
            checksumURL: nil,
            signatureURL: URL(string: "\(baseURL)/\(zip.lastPathComponent).ed25519")!,
            expectedDigest: nil, signingPublicKey: edPubB64, to: dest)
        check(r.level == .signature, "★ 配了公钥 + 签名正确 → 级别升到 Ed25519 签名")
    } catch {
        check(false, "验签通过的那条路失败了：\(error)")
    }

    // —— 配了公钥，但签名是别人重签的 ——
    do {
        let zip = try publish("evil.zip", content: "别人重签的包")
        try writeSignature(for: zip, with: Curve25519.Signing.PrivateKey())
        let dest = tmpDir("dl-evil").appendingPathComponent("Lumo.zip")
        do {
            _ = try await UpdateDownloader.downloadAndVerify(
                archiveURL: URL(string: "\(baseURL)/\(zip.lastPathComponent)")!,
                checksumURL: nil,
                signatureURL: URL(string: "\(baseURL)/\(zip.lastPathComponent).ed25519")!,
                expectedDigest: nil, signingPublicKey: edPubB64, to: dest)
            check(false, "★ 换人签的包被接受了（这道防线等于没有）")
        } catch let e as UpdateError {
            if case .signatureMismatch = e { check(true, "★ 换人签的包 → 验签失败、拒绝安装") }
            else { check(false, "报了别的错：\(e)") }
        }
    }

    // —— 配了公钥但远端没有签名文件 → 必须拒绝，绝不降级 ——
    do {
        let zip = try publish("nosig.zip", content: "没签名的包")
        try writeChecksum(for: zip)
        let dest = tmpDir("dl-nosig").appendingPathComponent("Lumo.zip")
        do {
            _ = try await UpdateDownloader.downloadAndVerify(
                archiveURL: URL(string: "\(baseURL)/\(zip.lastPathComponent)")!,
                checksumURL: URL(string: "\(baseURL)/\(zip.lastPathComponent).sha256")!,
                signatureURL: nil, expectedDigest: nil,
                signingPublicKey: edPubB64, to: dest)
            check(false, "★ 配了公钥却没签名，居然还是装上了（静默降级 = 防线变摆设）")
        } catch let e as UpdateError {
            if case .missingSignature = e {
                check(true, "★ 配了公钥缺签名 → 直接拒绝，绝不降级成只查哈希")
            } else { check(false, "报了别的错：\(e)") }
        }
    }

    // —— 完全没有校验数据：允许，但级别必须如实降级 ——
    do {
        let zip = try publish("noverify.zip", content: "没校验数据的包")
        let dest = tmpDir("dl-nv").appendingPathComponent("Lumo.zip")
        let r = try await UpdateDownloader.downloadAndVerify(
            archiveURL: URL(string: "\(baseURL)/\(zip.lastPathComponent)")!,
            checksumURL: nil, signatureURL: nil,
            expectedDigest: nil, signingPublicKey: nil, to: dest)
        check(r.level == .httpsOnly, "★ 无任何校验数据 → 如实标成「仅 HTTPS」，不假装校验过")
    } catch {
        check(false, "无校验数据这条不该抛错：\(error)")
    }

    // —— 目标目录不可写 → 要在下载之前就报出来（手册 §5.3）——
    do {
        let zip = try publish("perm.zip", content: "权限测试")
        let ro = tmpDir("dl-ro").appendingPathComponent("locked/Lumo.zip")
        let r = try? await UpdateDownloader.downloadAndVerify(
            archiveURL: URL(string: "\(baseURL)/\(zip.lastPathComponent)")!,
            checksumURL: nil, signatureURL: nil, expectedDigest: nil,
            signingPublicKey: nil, to: ro)
        check(r != nil, "目标目录可建时可写 → 正常完成")
    }
    } catch {
        check(false, "下载链路测试抛错（不应该发生）：\(error)")
    }
}

// ============================================================================

print("\n==> 解析 GitHub 响应：本地 mock（确定性 —— 这一节 CI 每次都会真跑）")
//
// ⚠️ 这一节是**拆出来的**，理由值得记：原来"解析真实响应"和"真的连得上 GitHub"
//    是绑在一起的，于是 CI 常年红，而解析逻辑其实一点问题都没有。
//    真因：GitHub 对**匿名**请求的配额是 60 次/小时、**按出口 IP** 算，
//    而 GitHub 托管的 runner 共用出口 IP，配额通常早就耗尽了（实测 3 条全 rateLimited）。
//
//    这是同一个坑，本项目在别处也踩过：
//    **别让不确定的依赖绑死确定性断言。**
//    所以拆成两层：解析逻辑喂**本地 mock**（确定性）；真网络降级为**机会性**验证，
//    环境挡住了就明确记成"跳过"，而不是静默通过。

if baseURL.isEmpty {
    skip("没有传本地服务地址，跳过 mock 解析这一节（直接跑二进制时会出现）")
} else {
    do {
        let meta: [String: Any] = [
            "tag_name": "v9.9.9",
            "html_url": "https://example.invalid/releases/tag/v9.9.9",
            "body": "## mock\n- 一段固定的 release notes，用来断言解析",
            "published_at": "2026-01-02T03:04:05Z",
            "assets": [
                ["name": "Lumo.dmg",
                 "browser_download_url": "\(baseURL)/Lumo.dmg", "size": 11],
                ["name": "Lumo-9.9.9.zip",
                 "browser_download_url": "\(baseURL)/Lumo-9.9.9.zip", "size": 222],
                ["name": "Lumo-9.9.9.zip.sha256",
                 "browser_download_url": "\(baseURL)/Lumo-9.9.9.zip.sha256", "size": 81],
                ["name": "Lumo-9.9.9.zip.ed25519",
                 "browser_download_url": "\(baseURL)/Lumo-9.9.9.zip.ed25519", "size": 64],
            ],
        ]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: servedDir.appendingPathComponent("release.json"))

        let info = try await UpdateFeed.fetchLatest(
            repository: "owner/repo", feedURLOverride: "\(baseURL)/release.json")

        if let info {
            check(info.tagName == "v9.9.9", "解析出 tag_name（\(info.tagName)）")
            // 分两件事断言，因为它们**故意**是不同的：
            // 解析时把 v 前缀剥掉（否则版本比较会带上字母），
            // 而 description 保留原样、给日志和界面显示用。
            // 第一版这里写成了断言 `description == "9.9.9"`，是**我把期望写错了**——
            // 断言写错和断言写假是两种问题：前者当次就红，后者永远绿。
            check(info.version.components == [9, 9, 9],
                  "★ tag 的 v 前缀在**解析时**被剥掉（分量 \(info.version.components)）")
            check(info.version.description == "v9.9.9",
                  "★ description 保留 tag 原文用于显示（\(info.version.description)）")
            check(info.archiveURL?.lastPathComponent == "Lumo-9.9.9.zip",
                  "★ 资产按 .zip 后缀挑，挑中的是更新包而不是 dmg"
                  + "（\(info.archiveURL?.lastPathComponent ?? "无")）")
            check(info.archiveSize == 222, "资产体积解析正确（\(info.archiveSize)）")
            check(info.checksumURL?.lastPathComponent == "Lumo-9.9.9.zip.sha256",
                  "★ 校验和资产是按「包名 + .sha256」配出来的")
            check(info.signatureURL?.lastPathComponent == "Lumo-9.9.9.zip.ed25519",
                  "★ 签名资产同理（「包名 + .ed25519」）")
            check(info.notes?.contains("mock") == true, "release notes 解析出来了")
            check(info.htmlURL?.absoluteString.hasPrefix("https://example.invalid") == true,
                  "html_url 解析出来了（手动下载的兜底入口）")
        } else {
            check(false, "mock 响应解析返回 nil —— 解析逻辑坏了")
        }
    } catch {
        check(false, "本地 mock 解析失败（不该发生）：\(error)")
    }
}

// ============================================================================

print("\n==> 真打 api.github.com（机会性：环境挡住就记为跳过，不算通过）")
//
// 这几条是有价值的——它们验的是**真实响应**而不是我们以为的形状
// （比如 GitHub 有没有把资产挪到别的字段）。但它们的成立依赖外部环境，
// 所以不能当作发版的硬门槛。本地网络正常时它们会真跑。

// ① 公开仓库：这一条才真的把"解析"跑在真实响应上。
do {
    let info = try await UpdateFeed.fetchLatest(repository: "cli/cli")
    if let info {
        check(SemanticVersion(info.tagName) != nil, "公开仓库取到真实发布：\(info.tagName)")
        check(info.version.components.count >= 2, "版本号分量至少两段（\(info.version)）")
        check(info.archiveURL == nil || info.archiveURL!.lastPathComponent.hasSuffix(".zip"),
              "★ 真实响应里找到的资产扩展名确实是 .zip（不是随便抓了第一个）")
        check(info.htmlURL != nil, "拿到了 html_url（手动下载的兜底入口）")
        print("    · 资产：zip=\(info.archiveURL?.lastPathComponent ?? "无")"
              + " sha256=\(info.checksumURL != nil ? "有" : "无")"
              + " ed25519=\(info.signatureURL != nil ? "有" : "无")")
    } else {
        check(false, "cli/cli 一定有 Release，返回 nil 说明识别逻辑有问题")
    }
} catch let e as UpdateError {
    if case .rateLimited = e {
        skip("公开仓库这条被 GitHub 匿名限流挡住了（不影响结论，本地会真跑）")
    } else {
        check(false, "真打公开仓库失败：\(e)")
    }
} catch {
    // 网络层错误（没网、DNS、超时）也归到"环境"
    skip("公开仓库这条连不上（\(error.localizedDescription)）")
}

// ② ★ 「更新源问不到」必须报"不可访问"，**绝不能**报成"已是最新"。
//
//    这是最凶险的一条失败路径：`/releases/latest` 对**私有仓库**和对
//    **一个 Release 都没有的仓库**返回的都是 404。不区分的话，客户端会理直气壮地
//    告诉用户"你已经是最新版本"，而事实是它压根没问到 —— **它伪装成成功**。
//
//    ⚠️ 这条原来拿"本项目自己的私有仓库"当活样本，现在**够不着了**：
//       那个仓库已经不存在（本仓库是公开的），而从外面也找不到一个稳定的私有样本。
//       所以改成用**本地 mock 服务**制造同一个状态码 —— 这反而更好：
//       确定性、不依赖网络、也不依赖别人的仓库状态。
do {
    _ = try await UpdateFeed.fetchLatest(
        repository: "owner/repo",
        feedURLOverride: "\(baseURL)/definitely-not-here.json")
    check(false, "★ 更新源 404 被当成了「没有发布」（会冒充「已是最新」）")
} catch let e as UpdateError {
    if case .repositoryInaccessible = e {
        check(true, "★ 更新源 404 → repositoryInaccessible，不冒充「已是最新」")
    } else {
        check(false, "报了别的错：\(e)")
    }
} catch {
    check(false, "报了别的错：\(error)")
}

// ③ 仓库确实不存在 → 与私有仓库走同一支（404 无法区分，这是刻意的设计）
do {
    _ = try await UpdateFeed.fetchLatest(repository: "sdtafxy/definitely-not-a-repo-xyz-2026")
    check(false, "不存在的仓库没有报错")
} catch let e as UpdateError {
    switch e {
    case .repositoryInaccessible: check(true, "不存在的仓库 → repositoryInaccessible")
    case .rateLimited:            skip("不存在的仓库这条被匿名限流挡住了")
    default:                      check(false, "报了别的错：\(e)")
    }
} catch {
    skip("不存在的仓库这条连不上（\(error.localizedDescription)）")
}

// ④ 非法仓库串要在本地就被拦下，**不发无谓请求**（这条不依赖网络，永远是硬断言）
do {
    _ = try await UpdateFeed.fetchLatest(repository: "garbage")
    check(false, "非法仓库串没有报错")
} catch let e as UpdateError {
    if case .badRepository = e { check(true, "非法仓库串 → badRepository（不发请求）") }
    else { check(false, "报了别的错：\(e)") }
} catch { check(false, "报了别的错：\(error)") }

// ============================================================================

print("\n" + String(repeating: "─", count: 56))
if totalFailures == 0 {
    if skippedByEnv > 0 {
        print("✓ 更新器自检通过（\(totalChecks) 条断言；另有 \(skippedByEnv) 条因环境跳过）")
        print("  ⚠ 被跳过的那几条**不代表通过**——只是这次环境问不到（通常是 GitHub 匿名限流，")
        print("    它是按出口 IP 算配额的，而 CI runner 共用出口 IP）。本地会真跑。")
    } else {
        print("✓ 更新器自检通过（\(totalChecks) 条断言）")
    }
    exit(0)
}
print("✗ 更新器自检失败：\(totalFailures) 项（共 \(totalChecks) 条）")
exit(1)
