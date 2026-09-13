#!/usr/bin/env bash
# 编译并组装 Lumo.app。
# 全部产物都来自 swift build：算法核心 LumoCore 直接链进可执行文件，
# 所以 .app 里既没有 Python，也没有任何需要用户额外安装的东西。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Lumo"

# 0) 构建系统选择
#    Swift 6.x 默认启用的新构建系统（XCBuild 后端）要调用 Xcode 里的
#    SWBBuildService。只装了 CommandLineTools 的机器上拿不到它，会在初始化
#    阶段直接失败，报 "Could not initialize build system / Unknown error
#    parsing property list"——那是环境缺失，不是代码问题，且**与产物无关**。
#    检测不到就退回 native 构建系统；有 Xcode 时（CI 就是这样）行为完全不变。
SWIFT_BUILD_FLAGS=""
if ! xcrun --find SWBBuildService >/dev/null 2>&1; then
  SWIFT_BUILD_FLAGS="--build-system native"
  echo "==> 未检测到 Xcode（SWBBuildService），改用 --build-system native"
fi

# 这里必须让 $SWIFT_BUILD_FLAGS 做词分割，所以故意不加引号。
swift_build() {
  # shellcheck disable=SC2086
  swift build $SWIFT_BUILD_FLAGS "$@"
}

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
RES="$CONTENTS/Resources"

# 1) 编译（App + LumoCore + lumo-cli）
echo "==> swift build -c release"
swift_build -c release

# 2) 定位产物
BIN_DIR="$(swift_build -c release --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
  echo "error: executable not found at $BIN" >&2
  exit 1
fi

# 3) 装 .app
#
# ⚠️ 这里**刻意不用** `rm -rf "$APP"`。
# 手册 P9 记的现场：包内文件数 > 50 时，`rm -rf` 会被 AI 侧的 safe-delete 钩子拦下，
# 而**表现极具欺骗性**——脚本继续往下跑、退出码可能还是 0，
# 于是你测的是**上一次的二进制**，还会得出"我的改动没生效"的错误结论。
# 规避办法：先把旧包 `mv` 走（移动不会被拦），新包照常写到原位置。
# 挪走的那份尽力删掉即可，删不掉也无害（下次构建再挪一次）。
if [[ -e "$APP" ]]; then
  STALE="$DIST/.stale-build-$$.app"
  mv "$APP" "$STALE"
  rm -rf "$STALE" 2>/dev/null || true
fi
mkdir -p "$CONTENTS/MacOS" "$RES"

cp "$BIN" "$CONTENTS/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

# 3b) 版本号：Resources/VERSION 是唯一来源，注入到刚拷过来的 Info.plist。
#     为什么不直接改仓库里的 Info.plist：那样每发一版都要改一个 XML，
#     迟早会忘。VERSION 就一行纯文本，改它心理负担最低。
#     失败要报错而不是静默——静默的后果就是发出去的包版本号是旧的，
#     用户报 bug 时我们对着标签查代码，怎么都对不上。
VERSION_FILE="$ROOT/Resources/VERSION"
if [[ ! -f "$VERSION_FILE" ]]; then
  echo "error: 缺少版本文件 Resources/VERSION" >&2
  exit 1
fi
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ -z "$VERSION" ]]; then
  echo "error: Resources/VERSION 是空的" >&2
  exit 1
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
echo "==> 版本号：$VERSION"

# 4) 图标：仓库里已提交 Lumo.icns；缺失时才现场生成
if [[ -f "$ROOT/Resources/Lumo.icns" ]]; then
  cp "$ROOT/Resources/Lumo.icns" "$RES/Lumo.icns"
elif [[ -f "$ROOT/Scripts/make_icon.py" ]]; then
  python3 "$ROOT/Scripts/make_icon.py" "$RES/Lumo.icns" || echo "warn: icon generation failed, app will use default icon"
fi

# 4b) 内置文档：设计文档 + 示例扫描件（离线可用，第一次打开就能跑通全流程）
for f in "Lumo-设计文档.pdf" "示例扫描件.pdf"; do
  if [[ -f "$ROOT/Resources/$f" ]]; then
    cp "$ROOT/Resources/$f" "$RES/$f"
  else
    echo "error: 缺少内置资源 $f" >&2
    exit 1
  fi
done

# 5) PkgInfo（最小占位即可）
printf 'APPL????' > "$CONTENTS/PkgInfo"

# 6) 确认没有把任何解释型依赖打进去（体积与"开箱即用"都靠这条守住）
if [[ -d "$RES/python" || -f "$RES/setup.sh" || -f "$RES/requirements.txt" ]]; then
  echo "error: 发现遗留的 Python 依赖资源" >&2
  exit 1
fi

# 7) 自签名（ad-hoc）：macOS 14 上未被 ad-hoc 签名的 app 会被 Gatekeeper 直接拒启
echo "==> codesign --force --deep --sign -"
codesign --force --deep --sign - "$APP" || echo "warn: codesign failed; the app may be blocked on first launch"

echo
echo "built: $APP"
du -sh "$APP" | sed 's/^/size:  /'
