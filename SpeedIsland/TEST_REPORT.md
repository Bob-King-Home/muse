# SpeedIsland v2.2 测试报告（2026-11-09 20:38）

测试人：Muse（本机 Linux，没有 Mac / iPhone / Xcode）
测试对象：~/workspace/SpeedIsland/ v2.2，SpeedIsland-v2.2.zip（30K）

## 先说结论（实话）

我能测的部分都测了，31 项逻辑模拟全部通过，静态检查也通过。
但我**没法**在这台机器上真编译、真机跑，所以不能跟你说“测试好了，你直接用吧”。

没测的部分，必须在 Mac + 你的 18 Pro Max 上测：
- Xcode 能不能打开 `project.pbxproj`、能不能编译通过
- 灵动岛真能显示吗、画中画小窗真能弹出来吗、字清不清晰
- 切后台 10 分钟、过夜、来电话打断后，保活是不是真的还在
- 整夜真实耗电多少

如果你只有手机、没有 Mac，这版还是装不上，需要先有人在 Mac 上打出 `.ipa`。

## 测了什么，通过了什么

### 1. 静态测试 — 通过

- 文件齐了：16 个文件，含 `project.pbxproj`、`project.yml`、2 个 Info.plist、10 个 .swift、README、VERIFICATION。
- 括号平衡：10 个 .swift 文件左右括号都为 0 差值。
- Info.plist 能解析：`UIRequiredDeviceCapabilities = ['arm64']`，`armv7` 和 `LaunchScreen` 已删掉，`UIBackgroundModes = ['audio']` 在。
- `project.pbxproj`：49 个引用都有定义，无缺失，括号平衡。
- 关键修复 grep 确认都在代码里：
  - `startTimerOnly()` 存在，`restartTimerForPowerMode()` 只调它，不走 `start()` 的 guard
  - `powerObserver` token 保存，`stop()` 按 token 删
  - PiP `frameIndex` 从 0 递增，`timeIntervalSince1970` 已清零
  - `memset` 清零 + `volume = 0` 都在
  - 32 位绕回 `(UInt64(1) << 32)` 在，`AF_LINK` 判断在
  - `startTask` / `updateTask` 分开了
  - PiP 分两行画字，不再是带 `\n` 的一次 `draw(at:)`

### 2. 逻辑模拟测试 — 31 通过，0 失败

把 Swift 里的纯逻辑原样搬到 Python 里跑（`/tmp/test_speedisland.py`），不依赖 Apple 框架：

- `format()`：0、9 B/s、500、1.5 KB/s、2.5 MB/s、150 MB/s 都对；9 B/s 不再被抹成 0。
- 32 位绕回：`delta(100, 2^32-96) = 196`，旧逻辑会算 0，确认旧 bug 存在过，新逻辑修了。
- 平滑：10 MB/s 的流，首秒 6.50 MB/s，3 秒后 9.57 MB/s，不直接跳变；零流量 2 秒归零。
- 低电量重启：v2.1 模拟会失败（timer 建不起来），v2.2 模拟能重建。
- 通知泄漏：旧逻辑启停 2 次积 2 个观察者，v2.2 只注册一次、stop 能删掉。
- 心跳：文字变了推，文字不变 1 秒不推（省电），4 秒 / 10 秒推心跳。
- PiP 时间戳：1,2,3,4,5 递增，都在 0-8 小时内；旧墙钟时间戳超出 8 小时，确认旧 bug。
- 短数字：`12.4 MB/s → 12.4M`、`850 KB/s → 850K`、`0 B/s → 0`。
- 自适应刷新：正常 1 秒，低电量 5 秒。
- 8 小时自动续期：到期后下一个 tick 重建，没到期不重建。
- 中间有 1 项一开始失败，是测试本身写错了（在同一个 tick 里既失效又重建），不是 App 的 bug，改了测试后通过。

### 3. Swift 编译检查 — 没法做，已确认

- `which swift swiftc xcodebuild` 无返回，`/usr/bin/*swift*`、`/opt/*swift*` 都没有。
- 没去下载 600MB 的 Linux Swift 工具链：就算装上，也编不了 UIKit / ActivityKit / AVFoundation 这些苹果专属框架，测不出真结果，还浪费时间。
- 所以：**本机没有做过一次真正的 Xcode 编译**，`project.pbxproj` 是程序生成的，括号和引用都对，但 Xcode 认不认，只有在 Mac 上打开才知道。

## 没测的部分（必须你那边或 Mac 上测）

1. Xcode 打开工程、编译、签名、装到 18 Pro Max
2. 灵动岛 / 锁屏 / 画中画真机显示
3. 切后台 10 分钟、过夜 8 小时、来电话打断、低电量切换
4. 整夜真实耗电（README 里不再写具体百分比，就是因为没测过）
5. 免费自签 7 天到期、重启手机后的自动续开

## 建议你拿到 Mac 后的真机测试清单

1. 打开 `SpeedIsland.xcodeproj`，选你的手机点 Run，能不能一次编译过
2. 点开始，切到微信放 10 分钟，灵动岛数字还在跳吗
3. 开低电量再退出，还刷吗
4. 开悬浮小窗切到抖音，小窗在吗、字清吗、能拖吗
5. 来个电话挂断，保活自己恢复了吗
6. 放一夜，看掉电多少、早上还在吗

有一项不过就告诉我，我按那一项再改，不要自己硬扛。
