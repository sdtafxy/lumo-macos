<p align="center">
  <img src="docs/logo.png" width="88" alt="Lumo">
</p>

<h1 align="center">Lumo · 流明</h1>

<p align="center"><em>把扫描件收拾干净：看得清、搜得到、体积小。</em></p>

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

Lumo 是一个处理扫描 PDF 的 macOS 应用：把灰的、歪的、不能搜索的文件，变成干净、可搜索、体积更小的文件。

它是原生的——Swift 和 SwiftUI 写的，只用系统自带的框架，没有 Python、没有 Homebrew、没有 Tesseract。安装包 2.7 MB，拖进「应用程序」就能用。处理和识别都在本机完成。

## 它能做什么

**增强**

- 五种模式：自动增强、增强、黑白、对比度、原图。
- 背景清理强度是一个 0–100% 的滑块，旁边给个起点建议；拉到 0 就是完全关闭。
- 纠偏、去网纹、文本锐化按页启用，用不上的页不动。
- 自动裁边和透视校正默认关闭——它会裁掉像素，需要时再打开。

**识别**

- Vision OCR 补文字层，输出「可搜索图像」（保留原版式）或「可编辑文本」两种。
- 已经带文字层的文件会自动跳过，不会重复识别。

**压缩**

- 逐页选编码：单色页走 CCITT G4，彩色和灰阶页走 JPEG。
- 照片式的页面用分层压缩；想原样保留像素就选无损。
- 动手之前先给体积预估，数字来自真实抽样页，不是公式估的。

**预览**

- 同一页的处理前 / 处理后对照。可以并排看，也可以切「窗帘」——一张图上拖一根竖线，左边原样、右边处理过。
- 改一个参数，预览立刻重算。
- 载入之后可以直接用内置阅读器打开原文件。

## 用起来是这样的

把 PDF 拖进窗口（也可以 `⌘O`，或者从菜单打开）。右边一栏会给出体检结论：多少页、彩色还是灰阶、多少 dpi、有没有倾斜、背景脏不脏，以及它建议怎么处理。

模式先选一个。不确定就留在「自动增强」，它逐页判断：文字页转黑白，带插图的页保留色彩。

左边是预览。想看得更细就切到「窗帘」，把竖线拖到文字边缘上，两边的差别一眼就看出来。

满意了按右下角的「开始处理」。完成后可以直接打开结果，或者在 Finder 里找到它。

## 命令行

App 里的处理和 `lumo-cli` 是同一份代码，批处理用得上。

```bash
BIN=$(swift build -c release --show-bin-path)/lumo-cli

BIN report in.pdf                                  # 体检：页数、色彩、分辨率、倾斜、背景
BIN process in.pdf out.pdf --preset auto --quality 70
BIN encbench in.pdf --page 3                       # 比较几种编码的体积与画质
```

## 安装

到 [Releases](https://github.com/sdtafxy/lumo-macos/releases/latest) 下载 `Lumo-<版本号>.dmg`，把里面的 App 拖进「应用程序」。

第一次打开要**右键 → 打开**：App 用的是 ad-hoc 签名，没有开发者证书，Gatekeeper 会拦一次。之后的版本交给内置更新。

## 从源码构建

需要 macOS 13 或更新，以及 Xcode 15 以上。

```bash
git clone https://github.com/sdtafxy/lumo-macos
cd lumo-macos
./Scripts/build.sh
open dist/Lumo.app
```

不用另外装依赖。

## 更新

App 会到 Releases 看看有没有新版本。也可以让它自动下载并原地替换——这个开关默认关着，打开之后会重启 App。更新只替换 App 本身，你的文件和偏好在包外，碰不到；替换失败会回滚。

## 隐私

- 文件不出本机：不上传文件、文件名，也不上报使用数据。
- 没有分析 SDK，没有崩溃上报。
- 联网只发生在检查更新这一件事上，关掉之后一行请求都不发。

## 一些说明

### 第一次打开为什么要右键？

App 没有付费的开发者证书，签名是 ad-hoc 的，所以 Gatekeeper 第一次会拒绝。右键选「打开」，之后就不再问了。

### 为什么系统菜单还是英文？

「文件」「编辑」「窗口」这些菜单归 macOS 管，应用内的语言设置改不动它们。界面本身可以选简体中文或 English，默认跟随系统。

### 能一次处理多份吗？

App 一次一份。多份的话用命令行走一圈循环就够了。

## 文档

功能取舍、参数含义、编码与压缩的实测数据，都写在**内置设计文档**里：App 里 `帮助 → 查看设计文档`。源文件是 [`Scripts/design_doc.html`](Scripts/design_doc.html)。

其他：[`CHANGELOG.md`](CHANGELOG.md) · [`CONTRIBUTING.md`](CONTRIBUTING.md) · [`SECURITY.md`](SECURITY.md)

## 许可

[MIT](LICENSE)。

---

<sub>Lumo（流明）是光通量的单位。</sub>
