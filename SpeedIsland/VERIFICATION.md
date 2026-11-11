# SpeedIsland v2.1 验证报告（静态审查，2026-11-09）

> 纠正（2026-11-10）：这份报告是 v2.1 时期的历史记录，下面第 E 条“iOS 18 起系统会把 Live Activity 刷新节流到 5-15 秒”是错的。App 的 Info.plist 里一直有 `NSSupportsLiveActivitiesFrequentUpdates`，开了频繁刷新正常情况下灵动岛约 1 秒一跳，只有系统繁忙、低电量时才可能放慢。报告其他条目以当时代码为准，修没修看 README 的版本记录。

验证方式：逐文件读源码 + 文件结构检查。注意：这台机器是 Linux，没有 Swift / Xcode，没法真编译、没法真机跑。以下结论是静态审查，不是真机实测。“一晚上 1-2% 耗电”这类数字是估算，没有实测。

## 结论一句话

思路是对的，代码大体能看，但直接拿去 Xcode 编译，大概率要先修 3-5 处才能跑起来；后台保活和画中画这两个最关键的功能，恰好是风险最大的两处，需要真机验证，不能保证一次就成。

## P0 — 装不上 / 跑不起来，必须先修

1. **没有 Xcode 工程文件**
   - `SpeedIsland.xcodeproj/` 是空目录，zip 里甚至把它排除了。
   - 后果：双击打不开，只能按 README 手动新建工程、拖文件、配 target，新手很容易配错。
   - 修：补一个能打开的 `project.pbxproj`，或把 README 的新建步骤写到每一步点什么。

2. **缺 Assets / LaunchScreen / AppIcon / entitlements**
   - 包里只有 .swift + Info.plist，没有 `Assets.xcassets`、启动屏、图标和权限文件。
   - 后果：新建工程会报缺失，图标空白，Background Modes / Live Activity 要在 Capabilities 里手动再勾一次。

3. **SpeedActivityAttributes 容易配错**
   - 这个文件必须同时勾主 App 和 Widget 两个 target，README 写了，但漏勾一次 Widget 就编译失败，报错还不好定位。
   - 修：最好改成共享 Framework 或 Swift Package，避免靠手动勾选。

4. **PiP 时间戳对不上，小窗可能黑屏**
   - `PiPManager.swift` 里 `presentationTimeStamp = CMTime(value: Int64(Date().timeIntervalSince1970))`，是 17 亿秒量级。
   - 但 `pictureInPictureControllerTimeRangeForPlayback` 返回的是 0 到 8 小时，timebase 也是从 0 开始。
   - 后果：时间戳超出播放范围，系统可能直接不显示帧，小窗黑屏。
   - 修：改成从 0 开始递增的计数器，每推一帧 +1 秒。

5. **PiP 第二行文字会被切掉**
   - `makePixelBuffer` 用 `NSString.draw(at:)` 画 `"↓ ... ↑ ...\nWi-Fi · SpeedIsland"`，这个 API 不处理换行，第二行大概率不显示或重叠。
   - 28 号字一行放下载+上传，320 宽的小窗也可能超宽被切。
   - 修：分两行画，或用 `draw(in:)` + 自动换行，字号降到 22-24。

6. **静音保活 buffer 没清零 + 没处理打断**
   - `BackgroundKeepAlive.swift` 新建的 `AVAudioPCMBuffer` 没显式清零，新内存不保证全 0，启动瞬间可能有杂音/爆音。
   - 没有监听电话、Siri、其他 App 抢音频的打断通知，打断一次引擎停了就不会自动恢复，保活悄悄死了，用户还以为在跑。
   - 修：建 buffer 后 `memset` 清零；加 `AVAudioSession.interruptionNotification`，打断结束自动重开。

7. **SpeedEngine 会重复注册通知**
   - `restartTimerForPowerMode()` 里 `stopTimerOnly() + start()`，`start()` 每次都 `addObserver`，旧的没移除。
   - 低电量来回切换几次，同一个通知会触发多次重启。
   - 修：`start()` 前先 `removeObserver`，或只注册一次。

## P1 — 后台还是可能停 / 数字不准

8. **LiveActivity 更新可能丢**
   - `LiveActivityManager.update()` 每次都 `updateTask?.cancel()` 再新建 Task，取消正在 `await activity.update` 的任务可能把这次更新丢掉。
   - `staleDate` 只给 5 秒，系统一节流就显示“过期”样式。

9. **采样有三处小问题**
   - 双卡只读 `pdp_ip0`，第二张卡的流量漏了。
   - `format()` 里 `<10 B/s` 直接显示 `0 B/s`，小流量会被抹掉。
   - 平滑逻辑自相矛盾：一边说 0.65 跟进，一边 `if downSmooth < downRaw*0.4 { downSmooth = downRaw }`，大跳变时平滑就失效了。
   - `tick()` 在后台队列读 `@Published var isWiFi`，有数据竞争；`mach_timebase_info` 每秒调一次，没必要，应缓存。

10. **ContentView 易用性**
    - “悬浮小窗”按钮必须先点开始才能点，置灰状态没解释，用户会以为坏了。
    - 没有保活状态、没有 8 小时倒计时、Live Activity 权限被拒时只显示“已停止”，不知道去设置里开。

11. **README 有估算没标注**
    - “一晚上 1-2%”是估算，不是实测，README 里只在个别地方写了“真机实测为准”，容易让人当成保证。

## P2 — 包装 / 安装

12. **还是源码，不是 .ipa**
    - 手机上直接装不了，必须 Mac + Xcode 编译签名。README 的安装步骤缺了关键步：iOS 16+ 要开开发者模式、Capabilities 里勾 Audio + Live Activity、Widget 的 Bundle ID 必须是主 App ID + 后缀。

13. **小毛病**
    - `BackgroundKeepAlive` 里 `AVAudioFormat(...)!` 强制解包，理论上会崩，虽然概率很低。
    - `NetworkSpeedSampler` 用 `getifaddrs / if_data` 但没显式 `import Darwin`，多数情况能编过，但换个 Xcode 版本有风险。
    - PiP 的 `displayLayer` 没加到任何 view 上；`isReadyForMoreMediaData == false` 时直接丢帧，没重试。

## 做得对的地方

- 只读活跃网卡、不双计、后台队列定时器、平滑、去重更新、低电量降频、零广告、零第三方库，方向是对的。
- 代码括号基本平衡，没发现 `TODO / FIXME`，没发现明显的强制崩溃点（除上面那一处 `!`）。
- README 把做不到的三条 iOS 限制写清楚了，没有夸大成“保证不被杀”。

## 建议下一步

先修 P0 的 4、5、6、7，再补一个能打开的工程文件，最后在真机上测三件事再下结论：
1. 切后台放 10 分钟，灵动岛数字还在不在跳
2. 开 PiP 小窗切到微信/抖音，小窗在不在、字清不清晰
3. 来个电话打断一次，挂断后保活自己能不能恢复

---

## 补充：独立审计发现的新问题（2026-11-09 20:06，第二遍检查）

下面这几条是第一遍没抓到的，比上面更严重，修 v2.2 时要优先修。

### 新增 P0

A. **低电量一切换，定时器永久停刷**
   - `SpeedEngine.swift`：`restartTimerForPowerMode()` 先 `stopTimerOnly()`（只取消 timer，不改 `isRunning`），再调 `start()`，但 `start()` 开头是 `guard !isRunning else { return }`，`isRunning` 还是 true，直接返回，timer 永远不重建。
   - 后果：开一次低电量模式（或退出低电量），网速就再也不刷了，只能杀掉重开。
   - 修：抽一个内部 `startTimerOnly()`，重启时不走 `start()` 的 guard。

B. **按 README 拖文件会重复符号，照做就编译失败**
   - Xcode 新建 SwiftUI App 自带 `SpeedIslandApp.swift`（`@main`）、`ContentView.swift`、`Assets.xcassets`、`Info.plist`，再把本包同名文件拖进去，会出现两个 `@main`、两个 `ContentView`、两个 `Info.plist` 冲突。
   - 修：README 必须写“先删新建工程自带的同名文件再拖入”，或直接给完整工程。

C. **通知观察者删不掉，越积越多**
   - `SpeedEngine` 用闭包版 `addObserver(forName:...)`，返回值 token 没保存；`stop()` 里的 `removeObserver(self)` 对闭包版无效。
   - 后果：每点一次开始就多一个观察者，点停止也删不掉。
   - 修：保存 token，`stop()` 时 `removeObserver(token)`。

D. **PiP 图层是孤儿，没挂到任何 View 上**
   - `PiPManager` 只 `AVSampleBufferDisplayLayer()` 新建，没 `addSublayer` 到任何 View / Window，也没检查 `isPictureInPictureSupported()`，`init(contentSource:)` 失败时没有任何处理。
   - 修：建一个不可见承载 View 挂进窗口层级再建 ContentSource，启动前先判是否支持。

### 新增 P1

E. **“灵动岛 1 秒刷新”是夸大**
   - iOS 18 起系统会把 Live Activity 刷新节流到 5-15 秒，`NSSupportsLiveActivitiesFrequentUpdates` 只能提高预算，不能取消预算。`tick()` 文字不变就直接 return，闲时超过 5 秒不推，灵动岛还会变 stale。
   - 修：宣传改成“前台 App 内 1 秒，灵动岛 5-15 秒”；闲时至少每 4 秒推一次心跳。

F. **计数器 32 位，4GB 就绕回**
   - `getifaddrs` 只暴露 32 位 `ifi_ibytes / ifi_obytes`，流量累计到 4GB 就绕回 0，代码 `cur >= last ? cur-last : 0` 会让那一秒速度直接掉零。
   - 开 VPN 时流量走 `utun`，会显示 0；双卡可能走 `pdp_ip1`，也会漏。
   - 修：绕回时按 +2^32 补差；只统计 `AF_LINK` 的条目；VPN 时提示不准。

G. **Info.plist 还有错**
   - 主 plist 写 `UILaunchStoryboardName = LaunchScreen` 但包里没有这个文件；`UIRequiredDeviceCapabilities` 只写 `armv7`，18 Pro Max 是 arm64，应为 `arm64`。

H. **README 缺关键安装信息**
   - 没提 iOS 16+ 要开开发者模式，没提免费账号最多 10 个 App ID、同时最多 3 个自签 App、7 天过期，没提 Background Modes 要在 Capabilities 里勾，单改 Info.plist 不够。
