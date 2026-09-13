// Lumo — 自更新：原地替换（解压 → 校验 → helper → 回滚）
//
// 只 import Foundation。
//
// ⚠️ 这个文件是整条更新链路上最容易出事的地方。手册 §5 把「不可在 App 内替换自己」
// 和「备份要放同目录、点开头、后缀不能是 .app」这些点单独列了一节，
// 下面每一处都标了它是为了躲开哪个坑。

import Foundation

enum UpdateInstaller {

    // MARK: - 目录约定

    /// 更新工作目录：`~/Library/Caches/<bundle-id>/Updates`
    ///
    /// 手册 §5.3：**日志要写文件**。helper 在 App 死后运行，
    /// 没有任何 UI 能显示它的错误 —— 没有日志就等于没有可诊断性。
    static func workDirectory(bundleID: String = "com.lumo.app") -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(bundleID).appendingPathComponent("Updates")
    }

    static func logURL(in workDir: URL) -> URL {
        workDir.appendingPathComponent("update.log")
    }

    /// 备份位。
    ///
    /// **三个约束缺一不可**（手册 §5.3）：
    /// ① 与目标**同目录** → 同卷 `mv` 是原子的，跨卷会变成慢复制（还可能中途断）；
    /// ② **点开头** → Finder 里看不见，不吓人；
    /// ③ **后缀不能是 `.app`** → 否则 LaunchServices 会把它当成第二个 App 索引进去，
    ///    用户会在「打开方式」里看到两个 Lumo。
    static func backupURL(for target: URL) -> URL {
        let name = target.lastPathComponent          // Lumo.app
        return target.deletingLastPathComponent()
            .appendingPathComponent(".\(name).updating")   // .Lumo.app.updating ✅
    }

    // MARK: - 解压与定位

    /// 用 `ditto -x -k --rsrc` 解压。
    /// 为什么要 `--rsrc`：保留资源分叉与签名结构，解出来的 .app 还能直接跑。
    @discardableResult
    static func unzip(_ archive: URL, into dir: URL) throws -> String {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", "--rsrc", archive.path, dir.path]
        let errPipe = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            throw UpdateError.unpackFailed(msg.isEmpty ? "ditto 退出码 \(p.terminationStatus)" : msg)
        }
        return ""
    }

    /// 在解压结果里找 `.app`。
    ///
    /// 先看**顶层**（这是我们会打出来的形状，见 Scripts/make_zip.sh），
    /// 找不到再递归兜底 —— 手册 §8 提到"zip 里 .app 要在顶层，否则解压出来多套一层"，
    /// 客户端做递归查找可以兜底。但顺序不能反：先顶层能保证"我们的包走的是我们设计的那条路"。
    static func findApp(in dir: URL) throws -> URL {
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        if let a = top.first(where: { $0.pathExtension == "app" }) { return a }

        // 递归兜底（限制深度，别在奇怪的目录树上跑飞）
        if let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil,
                                 options: [.skipsHiddenFiles]) {
            var depthGuard = 0
            for case let u as URL in e {
                depthGuard += 1
                if depthGuard > 5000 { break }
                if u.pathExtension == "app" { return u }
            }
        }
        throw UpdateError.badBundle("解压结果里没有 .app")
    }

    // MARK: - 校验"解出来的确实是我们的包"

    static func plistValue(_ app: URL, _ key: String) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any] else { return nil }
        return dict[key] as? String
    }

    /// 三道检查，缺一不可。
    ///
    /// 为什么要查**版本号对得上**：zip 是 CI 产的，但"下载到的东西"和
    /// "我们以为在下载的东西"之间隔着网络。版本号是唯一能对上号的凭据。
    /// 注意用 `SemanticVersion` 比而不是字符串比：zip 里可能写 `0.3.5`、
    /// 而 tag 是 `v0.3.5`，字符串比会假红。
    static func validateBundle(_ app: URL,
                               expectedBundleID: String,
                               expectedVersion: String) throws {
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path)
        else { throw UpdateError.badBundle("解出来的东西不是 macOS App 包（没有 Info.plist）") }

        if let id = plistValue(app, "CFBundleIdentifier"), id != expectedBundleID {
            throw UpdateError.badBundle("包标识是 \(id)，不是 \(expectedBundleID)")
        }
        guard let v = plistValue(app, "CFBundleShortVersionString") else {
            throw UpdateError.badBundle("包里没有版本号")
        }
        guard let got = SemanticVersion(v), let want = SemanticVersion(expectedVersion) else {
            throw UpdateError.badBundle("版本号无法识别（包里 \(v)，期望 \(expectedVersion)）")
        }
        guard got == want else {
            throw UpdateError.versionMismatch(expected: want.description, found: got.description)
        }
    }

    // MARK: - helper 脚本（纯函数，可单测）

    /// 生成 `sh` helper 的脚本正文。
    ///
    /// 参数：`$1` 旧进程 pid、`$2` 目标 App 路径、`$3` 已校验好的新 App 路径、`$4` 日志路径。
    ///
    /// 时序照手册 §5.2：
    /// ```
    /// 等旧进程消失（30s 超时） → mv 旧包到备份位 → ditto 新包就位
    ///   成功：清 quarantine、删备份、open
    ///   失败：删掉半个新包、备份 mv 回来、open
    /// ```
    /// 注意「等旧进程消失」那一步是**带超时**的：没有超时的话，
    /// 旧进程万一没退干净，helper 会永远挂着，用户看到的是"什么都没发生"。
    static func helperScript(pid: Int32, target: URL, staged: URL, log: URL) -> String {
        // 所有路径都用单引号包住并转义，防止路径里有空格或引号把脚本写坏
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return """
        #!/bin/sh
        # Lumo 自更新 helper —— 由 App 在退出前生成并启动。
        # 它必须在 App 之外运行：正在执行的二进制被替换掉是未定义行为，
        # 而且复制到一半进程被杀，用户手里就是半个 App。
        set -u

        PID=\(q(String(pid)))
        TARGET=\(q(target.path))
        STAGED=\(q(staged.path))
        LOG=\(q(log.path))

        # 先把日志接上。helper 运行的时候 App 已经死了，
        # 这是唯一能留下诊断信息的地方。
        exec >>"$LOG" 2>&1
        log() { echo "[$(date -u +%FT%TZ)] $*"; }

        log "helper 启动 pid=$PID target=$TARGET staged=$STAGED"

        # ① 等旧进程真的消失（最多 30 秒 = 150 × 0.2s）
        i=0
        while [ "$i" -lt 150 ]; do
          if ! kill -0 "$PID" 2>/dev/null; then break; fi
          sleep 0.2
          i=$((i+1))
        done
        if kill -0 "$PID" 2>/dev/null; then
          log "放弃：旧进程 $PID 在 30 秒后仍然活着。未改动任何文件。"
          exit 1
        fi
        log "旧进程已退出"

        PARENT="$(dirname "$TARGET")"
        BACKUP="$PARENT/.$(basename "$TARGET").updating"

        # ② 清掉上一次可能残留的备份（上次异常中断留下的）
        if [ -e "$BACKUP" ]; then
          log "发现残留备份，清掉：$BACKUP"
          rm -rf "$BACKUP" 2>/dev/null || true
        fi

        # ③ 旧包挪到备份位（同目录，mv 是原子的）
        if ! mv "$TARGET" "$BACKUP"; then
          log "放弃：无法把旧版本挪到备份位 $BACKUP（多半是权限问题）。未改动任何文件。"
          exit 1
        fi
        log "旧版本已挪到备份位"

        # ④ 新包就位
        if ditto "$STAGED" "$TARGET"; then
          log "新版本已就位"
          # 解压出来的东西带着隔离标记，不清掉首次启动会被 Gatekeeper 拦
          xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
          rm -rf "$BACKUP" 2>/dev/null || true
          log "更新完成；备份已清理"
          open "$TARGET"
          exit 0
        fi

        # ⑤ 失败：回滚。宁可退回旧版本，也不留半个新包给用户
        log "复制失败，开始回滚"
        rm -rf "$TARGET" 2>/dev/null || true
        if mv "$BACKUP" "$TARGET"; then
          log "已回滚到旧版本"
          open "$TARGET"
          exit 1
        fi
        log "严重：回滚也失败，旧版本仍在 $BACKUP —— 用户需要手动把它搬回 $TARGET"
        exit 2
        """
    }

    // MARK: - 安排一次替换

    /// 把 helper 写到工作目录，返回它的路径。**不启动** —— 便于测试单独验脚本内容。
    @discardableResult
    static func writeHelper(pid: Int32, target: URL, staged: URL, workDir: URL) throws -> URL {
        let log = logURL(in: workDir)
        let script = workDir.appendingPathComponent("lumo-update-helper-\(pid).sh")
        try helperScript(pid: pid, target: target, staged: staged, log: log)
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// 启动 helper。
    ///
    /// **三个标准流都要从父进程身上摘掉**（指向 `nullDevice`）。
    /// 父进程马上就要退出了，子进程继续往已关闭的管道里写会拿到 SIGPIPE，
    /// 而那时已经没人能处理它 —— 表现是"helper 莫名其妙没跑完"。
    static func launchHelper(_ script: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        // 刻意不 waitUntilExit：helper 要等我们退出，等它就是死锁
    }
}
