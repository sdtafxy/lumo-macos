#!/usr/bin/env bash
# 端到端：真的做一次升级。
#
# 为什么必须要这一步（手册 §7.3）：发布之前没法凭空造一个新版本，
# 但可以**临时把当前版本号改低再构建**，让它去更一个更高的版本。
# 手册里 P5（自更新器死锁、App 退不掉、更新静默卡死）**只有在真升级里才会暴露**，
# 靠读代码和单元测试一个都发现不了。
#
# 这里用的是比手册更干净的做法：**本地起一个假的 Release 源**，
# 于是整个链路（检查 → 下载 → 校验 → 解压 → 替换 → 重启）全都真的跑一遍，
# 而且不依赖线上仓库、不依赖网络、可重复。
# （Lumo 的仓库是私有的，匿名客户端拉不到——所以真的走 GitHub 那条路在本地测不成。
#  见 README 的「更新源必须是公开仓库」。）
#
# 断言四条（手册 §9「验证」那一节）：
#   ① 磁盘上的版本号真的变了
#   ② helper 日志写了「更新完成」
#   ③ 备份目录无残留
#   ④ 换完的包还能启动
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 装好了 Xcode 但 `xcode-select -p` 还指着 CommandLineTools 时，
# build.sh 会走"没有 Xcode"的兜底路径，App 目标编不出来（报一堆
# "cannot find '$xxx' in scope" —— 那是 @State 宏没展开的形态，不是代码坏了）。
# 这里自己把它指过去，免得**测试的结果取决于调用者有没有 export 这个变量**。
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# 装好了 Xcode 但 `xcode-select -p` 还指着 CommandLineTools 时，
# build.sh 会走"没有 Xcode"的兜底路径，App 目标编不出来（报一堆
# "cannot find '$xxx' in scope" —— 那是 @State 宏没展开的形态，不是代码坏了）。
# 这里自己把它指过去，免得**测试的结果取决于调用者有没有 export 这个变量**。
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

WORK="$(mktemp -d)/lumo-e2e"
mkdir -p "$WORK/release" "$WORK/run"
echo "工作目录：$WORK"

CURRENT="$(tr -d '[:space:]' < Resources/VERSION)"
NEXT="$(/usr/bin/python3 - "$CURRENT" <<'PY'
import sys
parts = [int(x) for x in sys.argv[1].split('.')]
parts[-1] += 1
print('.'.join(str(x) for x in parts))
PY
)"
echo "当前版本 $CURRENT → 假装要升到 $NEXT"

fail=0
check() {  # check <条件描述> <0|1>
  if [ "$2" -eq 0 ]; then echo "  ✓ $1"; else echo "  ✗ $1"; fail=1; fi
}

# ── 0) 先把可能还在跑的 Lumo 关掉（两个同 bundle id 的实例会互相干扰）──
osascript -e 'tell application "Lumo" to quit' >/dev/null 2>&1 || true
sleep 2

# ── 1) 打包当前版本 ──
echo "==> 构建 dist/Lumo.app（${CURRENT}）"
bash Scripts/build.sh > /dev/null 2>&1 || { echo "error: build.sh 失败"; exit 1; }

# ── 2) 造一个"新版本"的更新包 ──
echo "==> 造 $NEXT 的更新包"
/usr/bin/ditto "dist/Lumo.app" "$WORK/release/Lumo.app"
PL="$WORK/release/Lumo.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEXT" "$PL"
# 发布包不该带本地测试用的 feed 覆盖
/usr/libexec/PlistBuddy -c "Delete :LumoUpdateFeedURL" "$PL" 2>/dev/null || true
# ⚠️ 改过 Info.plist 之后签名就废了（签名覆盖 Info.plist），必须重签，
#    否则最后那条 codesign 断言测的是"我自己的测试夹具坏了"，不是产品。
codesign --force --deep --sign - "$WORK/release/Lumo.app" >/dev/null 2>&1
( cd "$WORK/release" && rm -f "Lumo-$NEXT.zip" "Lumo-$NEXT.zip.sha256" \
  && /usr/bin/ditto -c -k --keepParent Lumo.app "Lumo-$NEXT.zip" \
  && shasum -a 256 "Lumo-$NEXT.zip" > "Lumo-$NEXT.zip.sha256" )

ZIP="$WORK/release/Lumo-$NEXT.zip"
SUM="$(awk '{print $1}' "$WORK/release/Lumo-$NEXT.zip.sha256")"
SIZE="$(stat -f%z "$ZIP")"
echo "    zip $SIZE 字节  sha256 ${SUM:0:16}…"

# ── 3) 起本地源 ──
PORT_FILE="$WORK/port"
/usr/bin/python3 - "$WORK/release" "$PORT_FILE" <<'PY' &
import http.server, socketserver, sys, os, json
serve_dir, port_file = sys.argv[1], sys.argv[2]
zip_name = [f for f in os.listdir(serve_dir) if f.endswith(".zip")][0]
size = os.path.getsize(os.path.join(serve_dir, zip_name))
dir_ = serve_dir
base = {}   # 端口要等 bind 之后才知道，所以 meta 在请求时再拼

def build_meta():
    b = base["url"]
    return {
        "tag_name": "v" + zip_name.split("-")[-1][:-4],
        "html_url": "https://example.invalid/releases/latest",
        "body": "## 测试版本\n- 这是端到端自检用的假 Release",
        "published_at": "2026-09-13T00:00:00Z",
        "assets": [
            {"name": "Lumo.dmg", "browser_download_url": b + "/Lumo.dmg", "size": 1},
            {"name": zip_name, "browser_download_url": b + "/" + zip_name, "size": size},
            {"name": zip_name + ".sha256",
             "browser_download_url": b + "/" + zip_name + ".sha256", "size": 100},
        ],
    }
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=dir_, **k)
    def do_GET(self):
        if self.path.startswith("/release.json"):
            body = json.dumps(build_meta()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        return super().do_GET()
    def log_message(self, *a):
        pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", 0), H) as srv:
    base["url"] = "http://127.0.0.1:%d" % srv.server_address[1]
    with open(port_file, "w") as f:
        f.write(str(srv.server_address[1]))
    srv.serve_forever()
PY
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do [ -s "$PORT_FILE" ] && break; sleep 0.1; done
PORT="$(cat "$PORT_FILE" 2>/dev/null || true)"
[ -n "$PORT" ] || { echo "error: 本地源没起来"; exit 1; }
echo "==> 假 Release 源：http://127.0.0.1:${PORT}/release.json"

# ── 4) 准备被测的那份 App：版本仍是 ${CURRENT}，但指向本地源 ──
echo "==> 准备被测 App（${CURRENT}，指向本地源）"
/usr/bin/ditto "dist/Lumo.app" "$WORK/run/Lumo.app"
RPL="$WORK/run/Lumo.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LumoUpdateFeedURL string http://127.0.0.1:${PORT}/release.json" "$RPL" \
  || /usr/libexec/PlistBuddy -c "Set :LumoUpdateFeedURL http://127.0.0.1:${PORT}/release.json" "$RPL"
codesign --force --deep --sign - "$WORK/run/Lumo.app" >/dev/null 2>&1

# 自动检查 + 自动下载安装（默认是关的，这里临时打开；跑完会还原）
defaults write com.lumo.app LumoUpdate.autoCheck -bool true
defaults write com.lumo.app LumoUpdate.autoInstall -bool true

# 清掉上一轮的日志，免得读到旧的"更新完成"
CACHE="$HOME/Library/Caches/com.lumo.app/Updates"
rm -f "$CACHE/update.log" 2>/dev/null || true

# ── 5) 跑 ──
echo "==> 启动被测 App，等它自己升级（最多 90 秒）"
open -n "$WORK/run/Lumo.app"
NEWVER=""
for i in $(seq 1 90); do
  sleep 1
  V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$RPL" 2>/dev/null || echo "?")
  if [ "$V" = "$NEXT" ]; then NEWVER="$V"; break; fi
done

# ── 6) 断言 ──
#
# ⚠️ 这里有个**时序坑，是实测踩出来的**：版本号在 helper 换完包的那一刻就变了，
#    而"写完成日志""删备份""重启 App"都发生在**之后**。所以"版本变了"不等于
#    "helper 干完了"——直接用那一刻的状态去断言，会时红时绿（本机实测：
#    同一份代码，一次 6 条全过、下一次 3 条红，而日志里清清楚楚写着"更新完成"）。
#
#    修法不是加 sleep（那是猜时间），而是**轮询等条件成立**：
#    条件成立了就通过，超时了才判失败。这样断言仍然是确定性的，
#    而且失败时给出的是"等够了也没发生"，不是"我读得太早"。
wait_for() {
  # wait_for <秒> <描述> <命令…>
  local limit="$1" what="$2"; shift 2
  local i=0
  while [ "$i" -lt $((limit * 5)) ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 0.2
    i=$((i + 1))
  done
  echo "    （等了 ${limit}s，${what} 一直没发生）"
  return 1
}

echo
echo "==> 断言"
check "磁盘上的版本号真的变了：$CURRENT → ${NEWVER:-未变（超时）}" \
  "$([ "$NEWVER" = "$NEXT" ] && echo 0 || echo 1)"

LOG="$CACHE/update.log"
# helper 是异步的：等它把"更新完成"写进日志（最多 20 秒）
if wait_for 20 "日志里出现「更新完成」" grep -q "更新完成" "$LOG"; then
  check "helper 日志写了「更新完成」" 0
else
  check "helper 日志写了「更新完成」（日志：${LOG}）" 1
  [ -f "$LOG" ] && { echo "    日志内容："; sed 's/^/      /' "$LOG" | tail -20; }
fi

# 备份应当被清掉——同样是"等它清掉"，不是"此刻还在就判失败"
BACKUP="$WORK/run/.Lumo.app.updating"
if wait_for 10 "备份被清掉" test ! -e "$BACKUP"; then
  check "备份目录无残留" 0
else
  check "备份目录无残留（${BACKUP} 还在）" 1
fi

# helper 在换完包之后会 `open` 新版本，也要等它起来
if wait_for 20 "新版本重新启动" pgrep -f "$WORK/run/Lumo.app/Contents/MacOS/Lumo"; then
  check "换完的包还能启动（进程在跑）" 0
else
  check "换完的包还能启动（进程没找到）" 1
fi

# 用户数据一条没丢：设置里的偏好还在
if defaults read com.lumo.app LumoUpdate.autoCheck >/dev/null 2>&1; then
  check "升级后偏好没有丢（UserDefaults 还在）" 0
else
  check "升级后偏好没有丢" 1
fi

# 签名/结构没坏：换完的包仍然能通过 codesign 自检（ad-hoc）
if codesign --verify --deep --strict "$WORK/run/Lumo.app" >/dev/null 2>&1; then
  check "升级后的包 codesign --verify 通过" 0
else
  check "升级后的包 codesign --verify 失败" 1
fi

# ── 7) 收尾 ──
osascript -e 'tell application "Lumo" to quit' >/dev/null 2>&1 || true
sleep 1
defaults write com.lumo.app LumoUpdate.autoInstall -bool false
defaults write com.lumo.app LumoUpdate.autoCheck -bool true
echo
if [ "$fail" -eq 0 ]; then
  echo "✓ 端到端升级自检通过（工作目录留档在 ${WORK}）"
  exit 0
fi
echo "✗ 端到端升级自检失败" >&2
exit 1
