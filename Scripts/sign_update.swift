// Lumo — 更新包签名工具（Ed25519）
//
// 用法：
//   生成密钥对： swiftc -O Scripts/sign_update.swift -o /tmp/sign_update && /tmp/sign_update generate
//   签名：       /tmp/sign_update sign dist/Lumo-0.3.5.zip          → 产出同名 .ed25519
//   验签：       /tmp/sign_update verify <zip> <sig文件> <base64公钥>
//
// 为什么用 Swift 写而不是 Python：
//   手册提的是 `Scripts/sign_update.py`，但 macOS 自带的 Python 没有 cryptography，
//   而系统自带的 /usr/bin/openssl 是 LibreSSL——**它不支持 Ed25519**（要 Homebrew 的 openssl）。
//   而我们的项目本来就要求有 Swift 工具链（CI 的 runner 自带 Xcode），
//   CryptoKit 的 Ed25519 是系统框架、零依赖。**用已有的能力，别为了一个脚本
//   去给发布链路引入新的系统依赖**——那正是 build.sh 第 6 步那条断言要防的事。
//
// 私钥的安全约定（手册 §4 纪律二）：
//   · 私钥**只放 CI secret**，绝不进仓库（.gitignore 已覆盖 *.update-key）
//   · 公钥进 Info.plist 的 LumoUpdatePublicKey
//   · 客户端**配了公钥就强制验签**，缺签名文件直接拒绝，绝不降级成只查哈希

import Foundation
import CryptoKit

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + msg + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    print("""
    usage:
      sign_update generate                     生成密钥对（打印公钥，私钥写到 .update-key）
      sign_update sign <file> [keyfile]        给文件签名 → <file>.ed25519
      sign_update verify <file> <sig> <pubkey> 验签
    """)
    exit(0)
}

switch cmd {

case "generate":
    let priv = Curve25519.Signing.PrivateKey()
    let privB64 = priv.rawRepresentation.base64EncodedString()
    let pubB64 = priv.publicKey.rawRepresentation.base64EncodedString()
    // 私钥落到 .update-key（.gitignore 已覆盖）。**故意不往 stdout 打私钥**——
    // 打出来就会进 CI 日志，而 CI 日志的可见性通常比 secret 宽得多。
    let keyURL = URL(fileURLWithPath: ".update-key")
    try privB64.write(to: keyURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                          ofItemAtPath: keyURL.path)
    print("私钥已写入 \(keyURL.path)（权限 600，已在 .gitignore 里）")
    print("")
    print("把下面这行填进 Resources/Info.plist 的 LumoUpdatePublicKey：")
    print(pubB64)
    print("")
    print("再把私钥内容加进 GitHub 仓库 secret：LUMO_UPDATE_SIGNING_KEY")
    print("（值就是 \(keyURL.path) 的内容，一整行 base64）")

case "sign":
    guard args.count >= 2 else { fail("sign 需要文件名") }
    let file = URL(fileURLWithPath: args[1])
    let keyPath = args.count >= 3 ? args[2] : ".update-key"
    // CI 里私钥来自 secret，用环境变量传；本地则读文件。
    // 两条路都支持，因为"只在 CI 能签、本地签不了"会让发版前的自查做不到。
    let keyText: String
    if let env = ProcessInfo.processInfo.environment["LUMO_UPDATE_SIGNING_KEY"],
       !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        keyText = env
    } else if let s = try? String(contentsOfFile: keyPath, encoding: .utf8) {
        keyText = s
    } else {
        fail("找不到私钥（既没有 LUMO_UPDATE_SIGNING_KEY 环境变量，也没有 \(keyPath)）")
    }
    guard let keyData = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let priv = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
        fail("私钥解析失败（应当是 32 字节的 base64）")
    }
    guard let payload = try? Data(contentsOf: file) else { fail("读不到 \(file.path)") }
    guard let sig = try? priv.signature(for: payload) else { fail("签名失败") }
    let out = file.appendingPathExtension("ed25519")
    try sig.base64EncodedString().write(to: out, atomically: true, encoding: .utf8)
    print("已签名 \(file.lastPathComponent) → \(out.lastPathComponent)")
    print("包 \(payload.count) 字节，签名 \(sig.count) 字节")
    // 顺手自验一次：签完自己都验不过的签名，等于没签
    guard priv.publicKey.isValidSignature(sig, for: payload) else { fail("自验失败，这不该发生") }
    print("自验通过（公钥 \(priv.publicKey.rawRepresentation.base64EncodedString().prefix(16))…）")

case "verify":
    guard args.count >= 4 else { fail("verify 需要 <file> <sig> <pubkey>") }
    guard let payload = try? Data(contentsOf: URL(fileURLWithPath: args[1])) else {
        fail("读不到 \(args[1])")
    }
    guard let sigText = try? String(contentsOfFile: args[2], encoding: .utf8),
          let sigData = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines))
    else { fail("签名文件读不出来（应当是 base64）") }
    guard let keyData = Data(base64Encoded: args[3].trimmingCharacters(in: .whitespacesAndNewlines)),
          let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
        fail("公钥解析失败")
    }
    if pub.isValidSignature(sigData, for: payload) {
        print("验签通过")
        exit(0)
    }
    print("验签失败")
    exit(1)

default:
    fail("不认识的子命令：\(cmd)")
}
