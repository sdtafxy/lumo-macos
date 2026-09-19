#!/usr/bin/env bash
# 打更新用的 zip —— 更新器**只认 zip，不认 dmg**。
#
# 为什么不是 dmg（手册 §0）：dmg 要挂载、要弹出，中途失败会留半个状态；
# 而 zip 解出来就是一个目录，替换失败也好回滚。
# 发版的 Release 里**两个都要留**：dmg 给首次安装的人，zip 给更新器。
#
# 产出：dist/Lumo-<version>.zip
#       dist/Lumo-<version>.zip.sha256      （shasum 的两列格式）
#       dist/Lumo-<version>.zip.ed25519     （仅当配了签名私钥）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="dist/Lumo.app"
[ -d "$APP" ] || { echo "error: 先跑 Scripts/build.sh —— 没有 $APP" >&2; exit 1; }

VERSION="$(tr -d '[:space:]' < Resources/VERSION)"
[ -n "$VERSION" ] || { echo "error: Resources/VERSION 是空的" >&2; exit 1; }

ZIP="dist/Lumo-${VERSION}.zip"
rm -f "$ZIP" "$ZIP.sha256" "$ZIP.ed25519"

echo "==> 打包 $ZIP"
# ⚠️ ditto 的参数顺序是 **<源…> <目标>**（目标在最后）。
# 写反了会报 "Cannot get the real path for source"，产出为空。
#
# `--keepParent` 让 zip 里第一层就是 `Lumo.app`。
# 手册 §8 那条小坑：zip 里 .app 不在顶层的话，解出来会多套一层目录
# （客户端做了递归查找兜底，但那是保险，不是设计）。
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# 自查：解出来第一层必须就是 Lumo.app，而且版本号对得上。
# 不做这一步的话，"zip 打错了"要等到有人真的点更新失败才发现。
CHECK="$(mktemp -d)"
trap 'rm -rf "$CHECK"' EXIT
/usr/bin/ditto -x -k --rsrc "$ZIP" "$CHECK"
if [ ! -d "$CHECK/Lumo.app" ]; then
  echo "error: zip 里第一层不是 Lumo.app —— 更新器解出来会找不到包" >&2
  ls -la "$CHECK" >&2
  exit 1
fi
INNER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
         "$CHECK/Lumo.app/Contents/Info.plist")"
if [ "$INNER" != "$VERSION" ]; then
  echo "error: zip 里包的版本是 $INNER，与 Resources/VERSION($VERSION) 不符" >&2
  exit 1
fi
echo "==> 自查通过：zip 顶层是 Lumo.app，版本 $INNER"

echo "==> 计算 SHA-256"
( cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256" )
cat "$ZIP.sha256"

# 签名：有私钥就签，没有就明说。
# 手册 §4 纪律二：私钥只放 CI secret，公钥进 Info.plist。
# 这里的判断必须**说清楚"没签"**而不是静默跳过——
# 静默跳过的后果是"以为签了"，而那正是这道防线失效的方式。
PUBKEY="$(/usr/libexec/PlistBuddy -c 'Print :LumoUpdatePublicKey' Resources/Info.plist 2>/dev/null || true)"
if [ -n "${LUMO_UPDATE_SIGNING_KEY:-}" ] || [ -f ".update-key" ]; then
  echo "==> 签名（Ed25519）"
  SIGNER="$(mktemp -d)/sign_update"
  swiftc -O Scripts/sign_update.swift -o "$SIGNER"
  "$SIGNER" sign "$ZIP"
  if [ -n "$PUBKEY" ]; then
    "$SIGNER" verify "$ZIP" "$ZIP.ed25519" "$PUBKEY"
  else
    echo "warn: 签了名，但 Info.plist 的 LumoUpdatePublicKey 是空的 ——" >&2
    echo "      客户端不会验签，只会查 SHA-256。把公钥填上才算真的用上了签名。" >&2
  fi
else
  echo
  echo "==> 未签名（没有 LUMO_UPDATE_SIGNING_KEY，也没有 .update-key）"
  echo "    客户端会如实把校验级别标成「SHA-256 完整性」，不会假装验过来源。"
  echo "    要开启验签：swiftc -O Scripts/sign_update.swift -o /tmp/su && /tmp/su generate"
fi

echo
echo "产出："
ls -lh "$ZIP" "$ZIP.sha256"
# ⚠️ 这里**必须用 if**，不能写 `[ -f x ] && ls x`。
#
# 那个写法在文件不存在时会让**整条 && 表达式返回 1**，而它是脚本的最后一句
# → 脚本以 1 退出。于是"打包成功、sha256 也算好了、输出全都正确"，
# 但 CI 报 "Process completed with exit code 1"。
# 这个 bug 在本机被漏掉了：当时我只看了输出、没看退出码 ——
# 和本文件顶部注释里那条"构建脚本绝不能丢退出码"是同一个坑，我自己又踩了一次。
# （`set -e` 不会救：失败的命令在 `&&` 左边，不算"命令失败"。）
if [ -f "$ZIP.ed25519" ]; then
  ls -lh "$ZIP.ed25519"
fi
true
