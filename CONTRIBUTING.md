# 参与开发

感谢你有兴趣改这个项目。先说三条会直接影响你写法的前提。

## 这个项目的性格（决定了它不接受什么）

1. **零第三方依赖。** 算法只用 CoreGraphics / Core Image / Vision / ImageIO / PDFKit / zlib。
   `Scripts/build.sh` 最后一步会**主动断言** `.app` 里没有 Python / venv / brew 残留。
   所以「引个库就好了」这个念头要先过这一关。
2. **不联网，除了更新。** 处理全程在本机完成，没有上传。
   唯一的网络行为是访问更新源（GitHub Releases），关掉自动检查即完全静默。
   任何新的联网点都必须先在这里说明清楚，并在 README 的隐私一节如实更新。
3. **能断言的就别靠人眼。** 尤其是那些「编译通过、单元测试全过、真跑一次才发现」的问题。

## 本地开发

```bash
git clone https://github.com/sdtafxy/lumo-macos
cd lumo-macos
./Scripts/build.sh          # 编译 + 组装 dist/Lumo.app + ad-hoc 签名
open dist/Lumo.app
```

需要 macOS 13+ 与 Xcode（自带 Swift 5.9+）。**不需要** `pip install` / `brew install`。

如果你装了 Xcode 但 `xcode-select -p` 还指着 CommandLineTools，
**不必改全局设置**，给单条命令指定就行：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## 提交之前必须跑的

```bash
# 1) 核心自检（在真机上跑完整流水线并断言结果）
BIN=$(swift build -c release --product lumo-cli --show-bin-path)
"$BIN/lumo-cli" selftest

# 2) 更新器自检（纯逻辑层用 swiftc 单编，跑真实断言）
bash Scripts/run_update_tests.sh

# 3) 端到端真升级（起本地假 Release 源，真的升一次）
bash Scripts/e2e_update_test.sh

# 4) 设计文档与内置 PDF 必须一致（改了 HTML 却没重排 PDF 会在这里红）
python3 Scripts/check_design_doc.py
```

CI 会跑 1 / 2 / 4；第 3 条跑不了（GitHub 的 runner 没有窗口环境去 `open` 一个 App），
所以它是**发版前手工跑一次**的纪律。

## 改动设计文档

`Resources/Lumo-设计文档.pdf` 是从 `Scripts/design_doc.html` 生成的**同一份内容的另一份拷贝**，
所以改了 HTML 就必须重排，否则第 4 条断言会红。重排需要 WeasyPrint 与中文字体：

```bash
pip install weasyprint==68.0
brew install --cask font-noto-sans-cjk-sc   # HTML 里写的就是 Noto Sans CJK SC
python3 Scripts/make_design_doc.py
python3 Scripts/check_design_doc.py
```

> 字体不是可选项：换一套字体，PDF 里提取出来的文本会对不上，一致性断言会红。

## 代码约定

- **Swift 语言模式锁在 Swift 5**（见 `Package.swift` 文件头），
  最低支持 **macOS 13**。也就是说 `@Environment(\.openSettings)`、
  `MainActor.assumeIsolated`、双参数版 `onChange` 这些 **14+ 的 API 不能用**。
- 设计 token 全部在 `Sources/LumoApp/Design.swift` 与 `Theme.swift` 里，
  **不要在视图里硬编码颜色和圆角**。
- 应用内字符串是中文。**拼接出来的字符串不会渲染 Markdown**——
  `"a" + "**b**"` 会把星号原样显示出来，要用「」。
- 图标有两处基准：`Sources/LumoApp/Design.swift` 的 `LumoDesign.Emblem`
  与 `Scripts/make_icon.py` 的常量，**改一处必须同时改另一处**，
  否则桌面图标和打开后的第一眼就是两个 logo。
- 界面上的数字（分辨率、体积、比例）**要能说出出处**。自检的条数由程序自己打在汇总行里，
  不要去数屏幕输出——那里的 `✓` 混着进度信息行，数出来的数字必然虚高。

## commit message

中文 + 类型前缀（`feat` / `fix` / `docs` / `chore` / `refactor` / `test` / `build`）。

**正文写「为什么」，不是「改了什么」。** 「改了什么」看 diff 就知道；
「为什么非得这么改」diff 里看不出来，而它正是三个月后最需要的信息。

```
fix(core): 裁边前先修边 —— 残留 1% 桌面会被二值化染成一条黑线

检出四角难免差一两个像素，页面又是歪的，这点误差在结果里就是边缘残留一条桌面。
它只占 1% 宽，所以用「边缘均值」判不出来（关掉修边时均值几乎不变），
必须数暗像素占比才看得见。判据因此改成后者，并带上 2% 的上限。
```

## 测试怎么写

- **断言必须能失败。** 写完一条断言，除了问「它过不过」，还要问「**它能不过吗**」。
  数出来的错误是 0 的断言，必须同时断言「确实数了足够多的东西」。
  项目里抓到过一条永远不会红的断言：它的判据用了**全局均值**，而异常只占画面 1% 宽，
  被稀释到看不出来。规则：**当异常只影响画面的一小部分时，别用全局均值当判据。**
- **别让不确定的依赖绑死确定性断言。** 如果一段测试里同时有确定性逻辑和
  ML / 网络 / 外部服务，**先把它们切开**；否则一次模型升级就能让你怀疑自己写错了代码。
- **验证工具本身要先被验证。** 复刻版、反证脚本都可能是错的。

## 发版

1. 改 `Resources/VERSION`；
2. **同时**改 `Sources/LumoCore/PDFWriter.swift` 的 `fallbackVersion`
   （CLI 拿不到 bundle 的 `Info.plist`，`lumo-cli version` 永远走这条兜底分支）；
3. `Resources/Info.plist` 里的版本号是占位符，由 `build.sh` 注入，不用手改；
4. 设计文档封面上的版本号也要跟着改（见上面「改动设计文档」）；
5. 更新 `CHANGELOG.md`；
6. 提交、打 tag、推送。release workflow 会产出 dmg + zip + sha256。

CI 有断言钉住版本号的一致性，所以漏改会红，不会静默出错。

## 报告问题

用 [Issue 模板](https://github.com/sdtafxy/lumo-macos/issues/new/choose)。
如果涉及自动更新，**请附上 `~/Library/Caches/com.lumo.app/Updates/update.log`**——
更新器是那种「用户说不好用、维护者什么都看不到」的功能，那个文件是唯一的诊断通道。
