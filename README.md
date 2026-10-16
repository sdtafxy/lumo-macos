<p align="center">
  <img src="docs/logo.png" width="88" alt="Lumo">
</p>

<h1 align="center">Lumo · 流明</h1>

<p align="center"><em>扫描件，一键焕新。</em></p>

<p align="center">
  <a href="https://github.com/sdtafxy/lumo-macos/releases/latest"><img src="https://img.shields.io/github/v/release/sdtafxy/lumo-macos?style=for-the-badge&color=14B8A6&label=%E6%9C%80%E6%96%B0%E7%89%88%E6%9C%AC" alt="最新版本"></a>
  <a href="https://github.com/sdtafxy/lumo-macos/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/sdtafxy/lumo-macos/ci.yml?style=for-the-badge&label=CI" alt="CI"></a>
  <a href="https://github.com/sdtafxy/lumo-macos/releases"><img src="https://img.shields.io/github/downloads/sdtafxy/lumo-macos/total?style=for-the-badge&color=14B8A6" alt="下载量"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-3DA639?style=for-the-badge" alt="License: MIT"></a>
  <br>
  <img src="https://img.shields.io/badge/macOS-13%2B-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-5.9%2B-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift 5.9+">
  <img src="https://img.shields.io/badge/SwiftUI-%E5%8E%9F%E7%94%9F-1D9E75?style=for-the-badge" alt="SwiftUI">
  <img src="https://img.shields.io/badge/%E7%AC%AC%E4%B8%89%E6%96%B9%E4%BE%9D%E8%B5%96-0-14B8A6?style=for-the-badge" alt="零第三方依赖">
  <br>
  <img src="https://img.shields.io/badge/PDF-%E5%A2%9E%E5%BC%BA%20%7C%20%E5%8E%8B%E7%BC%A9-B45309?style=for-the-badge" alt="PDF 增强与压缩">
  <img src="https://img.shields.io/badge/OCR-Vision-0F6E56?style=for-the-badge" alt="Vision OCR">
  <img src="https://img.shields.io/badge/%E4%B8%AD%20%2F%20%E8%8B%B1-%E5%8F%8C%E8%AF%AD-1D9E75?style=for-the-badge" alt="中英双语">
  <img src="https://img.shields.io/badge/%E5%85%A8%E7%A8%8B%E6%9C%AC%E6%9C%BA-%E4%B8%8D%E4%B8%8A%E4%BC%A0-14B8A6?style=for-the-badge" alt="全程本机">
</p>

把一个扫描 PDF 拖进来，得到一份**干净、可搜索、体积更小**的 PDF。全程在本机完成。

原生 macOS 应用（Swift + SwiftUI），只链接系统框架——没有 Python、没有 Homebrew、没有 Tesseract。安装包约 2.7 MB，打开即用。

## 功能

**增强**：五种模式，按文件的实际情况选一种就行。

| 模式 | 适合 |
| --- | --- |
| 自动增强 | 不确定，或灰阶文档。逐页判断：文字页转黑白，含图页保留色彩 |
| 增强 | 带图表、印章、照片的页面。清背景、校正光照，不二值化 |
| 黑白 | 合同、票据、纯文字页 |
| 对比度 | 线稿、表格 |
| 原图 | 只做识别与压缩，画面不动 |

背景清理强度是连续可调的滑块，旁边给一个起点建议，**0% 就是关**。另有纠偏、去网纹、文本锐化；自动裁边与透视校正默认关闭。

**识别**：Vision OCR，可选「可搜索图像」（保留原版式，加一层文字层）或「可编辑文本」。已经带文字层的文件会自动跳过。

**压缩**：逐页选合适的编码——单色页走 CCITT G4，彩色与灰阶页走 JPEG，照片式页面用分层压缩；需要保留原始像素时选无损档。示例扫描件实测 759 KB → 209 KB。

**命令行**：`lumo-cli` 与 App 共用同一份处理逻辑。

```bash
BIN=$(swift build -c release --show-bin-path)/lumo-cli
BIN report in.pdf                                    # 体检：页数、色彩、分辨率、倾斜、背景
BIN process in.pdf out.pdf --preset auto --quality 70
BIN encbench in.pdf --page 3                         # 比较各编码器的体积与保真度
```

## 界面

单窗口：左边是预览，右边是参数，底部是状态与操作。

- 处理前 / 处理后的同页对照，可切「并排」或「窗帘」（拖动竖线比较同一处）；改动参数预览会重算。
- 打开文件的方式：拖到窗口、拖到 Dock 图标、`⌘O`、`⇧⌘V` 粘贴、菜单。
- 载入之后可以用内置阅读器打开原文件，不必回 Finder。
- 界面语言可选中 / 英，默认跟随系统。

## 安装

[最新版本](https://github.com/sdtafxy/lumo-macos/releases/latest) → 下载 `Lumo-<版本号>.dmg`，拖进「应用程序」。

首次打开需要**右键 → 打开**一次（App 使用 ad-hoc 签名）。之后新版本由内置更新接管。

## 从源码构建

需要 macOS 13+ 与 Xcode 15+。

```bash
git clone https://github.com/sdtafxy/lumo-macos
cd lumo-macos
./Scripts/build.sh
open dist/Lumo.app
```

不需要装任何依赖。

## 自动更新

App 会去 GitHub Releases 检查新版本，也可以选择自动下载并原地替换（默认关闭）。这是唯一联网的功能；关掉之后一行请求都不发。用户数据都在 App 包外，替换包体不会碰到它们，失败会自动回滚。

## 隐私

- 处理全部在本机完成：不上传文件、文件名或任何统计。
- 不含分析 SDK，也不含崩溃上报。

## 已知限制

| 限制 | 说明 |
| --- | --- |
| 首次打开要右键 → 打开 | ad-hoc 签名，Gatekeeper 会拦一次 |
| 系统菜单仍是系统语言 | 「文件 / 编辑 / 窗口」由 macOS 自己本地化，应用内的语言设置管不到 |

## 文档

- **内置设计文档**：App 里 `帮助 → 查看设计文档`。功能取舍、参数含义、实测数据都在里面。源文件是 [`Scripts/design_doc.html`](Scripts/design_doc.html)。
- [`CHANGELOG.md`](CHANGELOG.md) · [`CONTRIBUTING.md`](CONTRIBUTING.md) · [`SECURITY.md`](SECURITY.md)

## 许可

[MIT](LICENSE)。

---

<sub>Lumo（流明）是光通量的单位。</sub>
