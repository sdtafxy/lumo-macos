# 这个 PR 改了什么

<!-- 一两句话。如果是修 bug，说清"什么情况下会出问题"。 -->

## 为什么

<!--
这一节是重点。「改了什么」看 diff 就知道；「为什么非得这么改」diff 里看不出来，
而它正是三个月后最需要的信息。

如果这个改动否掉了某个看起来更显然的做法，请说明为什么——
否则下一个人会把它改回去。
-->

## 怎么验证的

- [ ] `lumo-cli selftest` 全过（条数：____，应是 95 条）
- [ ] `bash Scripts/run_update_tests.sh` 全过
- [ ] `bash Scripts/e2e_update_test.sh` 全过（改了更新器时**必须**跑）
- [ ] `python3 Scripts/check_design_doc.py` 通过（改了 `Scripts/design_doc.html` 时**必须**跑）
- [ ] `./Scripts/build.sh` 通过，`dist/Lumo.app` 能打开
- [ ] 界面改动：**在自己的机器上真的跑起来看过**（不是只看代码）

## 断言

<!--
本项目有一条硬规矩：**断言必须能失败**。

如果你新增/修改了断言，请说明你做了什么反证（故意改坏 → 必须变红）。
写"我加了一条断言"是不完整的；写"我把 X 改成 Y，这条就红了"才算。
-->

## 影响面

- [ ] 改动了 `Resources/VERSION`（若是，`PDFWriter.fallbackVersion` 也改了吗？）
- [ ] 改了图标相关（`Design.swift` 的 `Emblem` 与 `Scripts/make_icon.py` 是否同步？）
- [ ] 引入了新的联网行为（若是，README 的隐私描述更新了吗？）
- [ ] 引入了第三方依赖（**这个项目不接受**，请先开 issue 讨论）
- [ ] 更新了 `CHANGELOG.md`

## 截图 / 录屏

<!-- 界面改动请附。没附的话我会自己跑一遍再看。 -->
