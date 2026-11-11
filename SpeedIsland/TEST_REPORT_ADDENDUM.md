# SpeedIsland v2.2 — 独立复查补充（2026-11-09 20:38，复查人：Muse 研究阶段）

背景：用户 2026-11-09 20:38 说“你自己测试下，测试好我再用”。
主助手已在 20:39–20:40 回复：31 项逻辑模拟全过、静态检查通过，
并写了 `TEST_REPORT.md`（已进 `SpeedIsland-v2.2.zip`，33K）。
本文件是第二遍独立复查，只写第一遍报告**没提到**的东西，
不重复它已经通过的结论。

## 先确认：第一遍报告的结论，我复核后基本属实

- 10 个 .swift 文件括号/圆括号/方括号平衡（去字符串和注释后复算）。
- 两个 Info.plist 能解析；`UIRequiredDeviceCapabilities = ['arm64']`，
  `armv7` / `LaunchScreen` 已删；`UIBackgroundModes = ['audio']` 在。
- `project.pbxproj` 里 10 个 .swift + 2 个 Info.plist 都有引用且文件都在；
  `@main` 只有 2 个（App 和 Widget Bundle），没有重复符号。
- 关键修复在代码里确实存在：`startTimerOnly()`、低电量重启不走 `start()` 的
  guard、通知 token 保存/删除、PiP `frameIndex` 从 0 递增、
  `timeIntervalSince1970` 已清零、静音 `memset` + `volume = 0`、
  32 位绕回 `+2^32`、`AF_LINK` 判断、`startTask` / `updateTask` 分开。
- `format()` 逻辑模拟通过：0、5、9 B/s 不再抹成 0，1.5 KB/s、12.0 MB/s 正确。
- zip 与磁盘源码一致（写本文件之前校验过）；`TEST_REPORT.md` 已在 zip 里。
- 仍无法真编译、真机测试：本机无 Swift / Xcode / iPhone，
  这一点第一遍报告已如实说了，复查同意。

## 复查新发现：4 个值得先修的问题（按严重程度）

### 1. 双卡第二张卡还是漏的 —— README 的说法与代码不符（中）
- 位置：`SpeedIsland/NetworkSpeedSampler.swift:69`
  ```swift
  } else if !isWiFi && name == "pdp_ip0" {
  ```
  全仓库搜不到 `pdp_ip1`。README v2.2 第 7 条写“双卡 `pdp_ip1` 不再漏”，
  代码并没有实现。
- 影响：数据卡是副卡、或运营商走 `pdp_ip1` 时，蜂窝网速显示 0。
  这正是 v2.1 验证报告 P1-9 指出的问题，v2.2 声称修了但没修。
- 建议修法：蜂窝时不 `break` 在 `pdp_ip0` 上，改为汇总所有
  `pdp_ip*` 接口的计数（另一张卡没流量时增量为 0，不会双计）；
  注意切卡瞬间可能有一秒跳变，修完要在双卡真机上验证。

### 2. 用户在小窗上点关闭，按钮状态不同步，要点两次才能重开（中）
- 位置：`SpeedIsland/PiPManager.swift:199` 发通知
  `SpeedIslandPiPDidStop`；`SpeedIsland/ContentView.swift:55-58` 收到后
  **什么都没做**，只有注释说“下一次 tick 时自然回落”。
- 实际上 `SpeedEngine.isPiPOn` 只在 `togglePiP()` 失败回调和 `stop()`
  里置 false，tick 里从不改它（`SpeedEngine.swift:100` 只读它来推帧）。
  所以小窗被关掉后按钮还显示“关闭小窗”，点一下是空操作（只是把
  状态翻成 false），再点一下才能重开。
- 建议修法：给 `SpeedEngine` 加一个 `syncPiPStopped()` 方法
  （把 `isPiPOn` 置 false），`ContentView` 的 `onReceive` 里调用它；
  `isPiPOn` 是 `private(set)`，不能直接在 View 里改。

### 3. 计数器“掉回”时可能出现一秒天价网速（低–中）
- 位置：`SpeedIsland/NetworkSpeedSampler.swift` 的 `delta()`，
  `cur < last` 时一律按 `+2^32` 补差。
- 真 4GB 绕回时这是对的；但开关飞行模式、切 Wi-Fi/蜂窝、重启后
  计数器是**归零**不是绕回。模拟：上次 3,000,000,000、本次
  100,000,000，代码算出 1,394,967,296 字节/秒 ≈ 1330 MB/s，
  平滑后首秒仍显示约 865 MB/s，是一次肉眼可见的跳变，不是崩溃。
  同理切网瞬间（en0 切 pdp_ip0）`sample()` 也不重置基线。
- 建议修法：`delta` 补差后若超过合理上限（如 1 秒内 >500MB）
  视为复位，当次返回 0 并重新记基线；或在接口名变化时 `reset()`。

### 4. 画中画第一行高速时仍可能被裁（低）
- 位置：`SpeedIsland/PiPManager.swift:165-177`，宽 320，22 号等宽字。
- 第一行是 `"↓ {下载}  ↑ {上传}"`。例：`"↓ 12.4 MB/s  ↑ 850.0 KB/s"`
  约 24–25 个字符，按等宽 22pt ≈ 每字 13.2pt 算约 317–330pt，
  超过 320 时居中计算的 x 为负，两边被裁。低速时没问题，
  双向都上 MB/s 时会裁。README“320 宽不再被裁”说过了头。
- 建议修法：PiP 第一行改用 Widget 里已有的短格式
  （`12.4 MB/s → 12.4M`），或字号再降一档。

## 小问题（不阻塞，但值得顺手修）

- `SpeedEngine.togglePiP()` 里先调 `startPiP()`、后才赋值
  `onPiPFailed`：不支持 PiP 的设备上，同步失败那次回调是 nil，
  `isPiPOn` 会一直为 true。18 Pro Max 支持 PiP，对用户本人影响小。
- `PiPManager.setupIfNeeded()` 先把 `isSetup` 置 true 再找 keyWindow：
  第一次调用时若 keyWindow 还不存在，承载 View 永远挂不上，且不再重试。
  正常启动时窗口已在，风险低。
- `LiveActivityManager.update()` 仍每次 `updateTask?.cancel()` 再建新任务，
  v2.1 报告 P1-8 的“取消可能丢更新”只修了一半（start/update 分开了，
  update 内部仍取消）。引擎已限流到“变了或 4 秒心跳”才推，实际丢的概率低。
- 仍无 `Assets.xcassets`：`project.pbxproj` 引用了 `AppIcon` /
  `AccentColor`，但包里没有图标资源，Xcode 一般只警告、图标为空，
  不是编译不过的原因。

## 结论

v2.2 不是“测好了能直接用”：第一遍的 31 项通过属实，但上面 4 个问题
（尤其第 1、2 条）是第一遍没发现的、用户在真机上会直接撞上的问题。
建议先按上面修一版 v2.3（都是小改动），再重跑逻辑模拟、重打 zip，
然后再上 Mac 做那 5 项真机测试（编译、切后台 10 分钟、低电量切换、
来电打断、放一夜耗电）。在 v2.3 之前，不要让用户以为双卡和 PiP
关闭这两处已经没问题了。

复查方法：逐文件读源码 + `rg` / Python 校验（括号平衡、plist 解析、
pbxproj 引用、zip 与磁盘一致性、format/delta/平滑/短格式的数值模拟）。
未做：Swift 编译、Xcode 打开工程、任何真机测试——本机没有这些工具。
