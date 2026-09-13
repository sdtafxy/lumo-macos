#!/usr/bin/env bash
# 更新器自检 —— 把纯逻辑文件用 swiftc 单独编出来跑真实断言。
#
# 为什么不用 `swift test` / XCTest：那需要一套 SwiftPM 测试 target，
# 而我们的更新器活在 App target 里（要 import SwiftUI 的那些文件编译代价大）。
# 手册 §7.1 的招数更划算：**纯逻辑文件只依赖 Foundation，于是能绕开整个 App、
# 绕开 Xcode 工程，几十毫秒跑完**。实测编译约 10 秒、跑完 2 秒。
#
# 覆盖：版本比较（P1）、Releases 解析、更新决策顺序（P3）、SHA-256（NIST 向量）、
# Ed25519 往返与篡改、App 包校验、helper 脚本内容、**真的原地替换**、
# **真的失败回滚**、本地 HTTP 下载全链路（正常/哈希不符/签名不符/缺签名/无校验数据）、
# 以及真打 api.github.com。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> 编译更新器纯逻辑层 + 测试入口"

# ① 先做一遍严格并发检查（手册 P7）。
#    为什么单独列一步：Swift 的并发诊断依赖 SDK 里的 @Sendable 标注，
#    **同一个提交可能本地过、CI 挂**。本地先看一眼，能提前抓到那一类。
#    只当提示，不当失败——这个 flag 会带出改动前就存在的历史警告。
echo "--- 严格并发自查（只看 Update/ 下有没有新警告）---"
if swiftc -typecheck -swift-version 5 -strict-concurrency=complete \
      Sources/LumoApp/Update/SemanticVersion.swift \
      Sources/LumoApp/Update/UpdateFeed.swift \
      Sources/LumoApp/Update/UpdateIntegrity.swift \
      Sources/LumoApp/Update/UpdateDownloader.swift \
      Sources/LumoApp/Update/UpdateInstaller.swift 2>/tmp/lumo-update-strict.log; then
  if [ -s /tmp/lumo-update-strict.log ]; then
    echo "（有警告，逐条看过再决定要不要改）"
    cat /tmp/lumo-update-strict.log
  else
    echo "干净：Update/ 下没有并发警告"
  fi
else
  echo "严格并发检查有 **错误**（不是警告），需要处理："
  cat /tmp/lumo-update-strict.log
fi

BIN="$(mktemp -d)/lumo-update-tests"
swiftc -O -swift-version 5 \
  Sources/LumoApp/Update/SemanticVersion.swift \
  Sources/LumoApp/Update/UpdateFeed.swift \
  Sources/LumoApp/Update/UpdateIntegrity.swift \
  Sources/LumoApp/Update/UpdateDownloader.swift \
  Sources/LumoApp/Update/UpdateInstaller.swift \
  Scripts/update_tests/main.swift \
  -o "$BIN"

# ② 起一个本地 HTTP 服务，端口让它自己挑（避免撞上被占用的端口）。
#
# 注意：手册 §7.2 那条——**请求本地服务必须先绕开代理**，否则会被系统代理吞掉，
# `Connection refused` 会被误判成"服务没起来"。
# 这里做两件事：给测试进程设 no_proxy，并且把 http_proxy/https_proxy 清掉。
SERVE_DIR="$(mktemp -d)"
PORT_FILE="$(mktemp)"
trap 'kill "${SERVER_PID:-}" 2>/dev/null || true' EXIT

/usr/bin/python3 - "$SERVE_DIR" "$PORT_FILE" <<'PY' &
import http.server, socketserver, sys
serve_dir, port_file = sys.argv[1], sys.argv[2]
class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=serve_dir, **k)
    def log_message(self, *a):   # 静音，免得刷屏
        pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", 0), Handler) as srv:
    with open(port_file, "w") as f:
        f.write(str(srv.server_address[1]))
    srv.serve_forever()
PY
SERVER_PID=$!

# 等服务把端口写出来（最多 10 秒）
for _ in $(seq 1 100); do
  [ -s "$PORT_FILE" ] && break
  sleep 0.1
done
PORT="$(cat "$PORT_FILE" 2>/dev/null || true)"
if [ -z "$PORT" ]; then
  echo "error: 本地 HTTP 服务没起来" >&2
  exit 1
fi
echo
echo "==> 本地 HTTP 服务：http://127.0.0.1:${PORT} （服务目录 ${SERVE_DIR}）"

# ③ 跑测试
set +e
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    no_proxy="127.0.0.1,localhost" NO_PROXY="127.0.0.1,localhost" \
    "$BIN" "http://127.0.0.1:$PORT" "$SERVE_DIR"
CODE=$?
set -e

echo
if [ "$CODE" -eq 0 ]; then
  echo "更新器自检：通过"
else
  echo "更新器自检：失败（退出码 ${CODE}）" >&2
fi
exit "$CODE"
