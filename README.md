<p align="center">
  <img src="docs/logo.png" width="88" alt="Lumo">
</p>

<h1 align="center">Lumo · 流明</h1>

<p align="center"><em>扫描件，一键焕新。</em></p>

<p align="center">
  <a href="https://github.com/sdtafxy/lumo-macos/actions/workflows/ci.yml"><img src="https://github.com/sdtafxy/lumo-macos/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/sdtafxy/lumo-macos/releases/latest"><img src="https://img.shields.io/github/v/release/sdtafxy/lumo-macos" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS 13+">
</p>

把一个又大又灰的扫描 PDF 拖进来，得到一份**看着干净、文字可搜、体积小得多**的 PDF。全程在本机完成。

**零第三方依赖**——算法核心是本仓库的 `LumoCore`，只链接系统框架（CoreGraphics / Core Image / Vision / ImageIO / PDFKit / zlib）。没有 Python、没有 Homebrew、没有 Tesseract。下载 DMG、拖进「应用程序」、打开即用。

## 它解决什么问题

用通用 PDF 工具处理扫描件，要在「扫描增强 → 文本识别 → 压缩」三个面板之间来回切换、逐项调参，调完不满意再重来一遍。**而这个过程里用户做的决定，大部分机器本来就能做对。**

Lumo 把它收敛成一句话：**拖进来，按一下。**

| 扫描件常见的毛病 | Lumo 的做法 |
| --- | --- |
| 又大（几十上百 MB） | 逐页自适应编码 + 分层压缩，实测省 **97.3%** |
| 又灰、又歪、有阴影和噪点 | 先体检再动手：纠偏、背景清理、去网纹、文本锐化，逐页按需启用 |
| 不可搜、不可选、不可复制 | Vision OCR 补文字层；**已经带文字层的文件自动跳过** |
| 拍照件四周带着桌面 | 自动裁边 + 透视校正（默认关，理由见下） |

## 能力

### 五种增强模式，而不是八个开关

用户想选的是**效果**，不是滤镜。所以四个开关被收敛成五个模式：

| 模式 | 适用 | 做法 |
| --- | --- | --- |
| **自动增强** | 不确定 / 灰阶文档 | 逐页判断：文字页走黑白，含图页保色彩 |
| **增强** | 带图表、印章、照片 | 清背景、校正光照、略提饱和，**绝不二值化** |
| **黑白** | 合同、票据、纯文字 | 只留纯黑与纯白，底灰、阴影、污渍全部清掉 |
| **对比度** | 线稿、表格 | 温和的对比拉伸，不改变颜色关系 |
| **原图** | 只做识别与压缩 | 一个像素都不动 |

背景清理强度是**连续可调**的滑块，因为它没有统一标准：正版书扫描只是纸色偏黄，手机拍照件却可能带一整片阴影，同一份文件里不同页都能差很多。滑块旁边会给一个起点建议，**0% 是真的关**。

每个滤镜过完都会过一次「内容守卫」：把画面的对比度洗掉太多就放弃该滤镜。增强滤镜的失败方式是「画面变干净了、内容也没了」，这个方向不可逆——**宁可留着脏，也不能把内容洗掉**。

### 识别与压缩

- **识别**：Vision OCR，可输出「**可搜索图像**」（保留原版式 + 一层看不见的文字层）或「**可编辑文本**」。
- **压缩**：先逐页路由（单色页走 CCITT G4、灰阶与彩色页走 JPEG），再对照片式扫描件做**分层压缩**——背景低分辨率彩色 + 文字全分辨率 1 bit 蒙版 + 实测墨色。带**体积闸门**：只有真的更小时才采用，所以它不可能让结果变差。
- **体积预估**：用真实抽样页外推出来的数字，不是公式拍出来的。

### 命令行

处理逻辑与 App 是同一份代码：

```bash
BIN=$(swift build -c release --show-bin-path)/lumo-cli
BIN report in.pdf                          # 体检：页数、色彩、分辨率、倾斜、噪声、背景
BIN process in.pdf out.pdf --preset auto --quality 70
BIN process in.pdf out.pdf --pages 1-3 --auto-crop on --bg-strength 0.7
```

---

## 界面

**单窗口承载全流程**：没有独立标题条，内容一直铺到窗口顶边；界面上不放 logo 之类的装饰，把地方全留给文件本身。

- **玻璃只铺在控件层**（参数栏、底栏），内容区保持不透明。
- **处理前 / 处理后的同页对照**，参数一改预览就重算；旁边就是体检结论与它给出的建议。
- **六个输入入口**：拖到窗口任意处、拖到 Dock 图标、`⌘O`、`⇧⌘V` 粘贴、底栏按钮、菜单。
- **载入之后可以直接用内置阅读器打开原文件**（文件行上的那个图标），不用去 Finder 里找。
- **界面语言可选**：默认跟随系统，也可以在设置里指定简体中文或 English。

最低支持 **macOS 13**。所以在更新一代系统上走的是材质兼容路径，**不试图在旧系统上模拟新材质**。

### 自动裁边默认是关的

它是整条流水线里**唯一会主动丢像素**的一步。判定边界用的不是「检出覆盖率」——那个指标两头都会骗人（同一张纸几乎铺满的图，真实占比 84.6% 而模型只报 59.7%，照它裁会切掉正文），而是「**边界外侧必须暗下去**」，这一个判据与模型无关。即便如此，是否丢像素的决定仍然留给你。

---

## 自动更新

App 会自己去 GitHub Releases 看有没有新版本，**点一下就原地换掉并自动重启**。这是全项目**唯一联网的地方**：算法、识别、压缩全部在本机完成，没有任何上传；在设置里关掉「自动检查更新」就一行请求都不发。

「**自动下载并安装**」是独立的开关，**默认关闭**——它会重启 App，那是要你点头的事。替换的只是 App 包体本身，你的文件与偏好都在包外，所以换包天然不碰它们；换失败了会自动回滚。

## 下载

[最新版本](https://github.com/sdtafxy/lumo-macos/releases/latest) → 下载 `Lumo.dmg`，拖进「应用程序」。

App 是 **ad-hoc 签名**（没有 Developer ID），所以首次打开需要**右键 → 打开**一次。之后内置的自动更新会接管，不用再回来手动下载。

## 从源码构建

环境：macOS 13+，Xcode 15+（自带 Swift 5.9+）。

```bash
git clone https://github.com/sdtafxy/lumo-macos
cd lumo-macos
./Scripts/build.sh
open dist/Lumo.app
```

不需要任何 `pip install` / `brew install`。`build.sh` 会编译、组装 `.app`、做 ad-hoc 签名，并在最后**断言包里没有 Python / venv / brew 残留**——这是「零依赖」的机器化定义。

> **只装了 CommandLineTools 的机器**：`lumo-cli` 照样能编能跑，但 App 目标需要完整 Xcode
> （更新一代 SDK 把 SwiftUI 的 `@State` 做成了宏，宏插件只随 Xcode 提供）。
> 装了 Xcode 但 `xcode-select -p` 还指着 CommandLineTools 时，不必改全局：
> `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 就够了。

## 隐私

- 处理**全部在本机完成**：不上传文件，不上传文件名，不上传任何统计。
- 唯一的网络行为是**自动更新检查**。关掉它之后 App 一行请求都不发。
- 不含任何分析 SDK，也不含崩溃上报。

## 已知限制

| 限制 | 说明 |
| --- | --- |
| 首次打开要**右键 → 打开** | ad-hoc 签名、没有 Developer ID，Gatekeeper 会拦一次 |
| 系统菜单仍是系统语言 | 「文件 / 编辑 / 窗口」这些由 macOS 自己本地化，应用内的语言设置管不到它们 |

## 文档

- **内置设计文档**：App 里 `帮助 → 查看设计文档`。它讲的是「为什么是这样」——配色与材质的规范、流水线的每一段在做什么、以及那些被实测否掉过的选项。源文件是 [`Scripts/design_doc.html`](Scripts/design_doc.html)。
- [`CHANGELOG.md`](CHANGELOG.md) · [`CONTRIBUTING.md`](CONTRIBUTING.md) · [`SECURITY.md`](SECURITY.md)

## 许可

[MIT](LICENSE)。

---

<sub>Lumo（流明）是光通量的单位。这个名字选定的气质是：**把纸面清理干净，但不改变纸上的内容**。</sub>
