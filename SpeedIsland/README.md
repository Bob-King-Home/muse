# SpeedIsland · 极简网速（自用版）v2.6

> 按验证报告修的 P0 / P1，目标：耗电一定要低，不关就一直都在。

给 iPhone 18 Pro Max 做的极简网速显示：灵动岛 + 锁屏实时活动 + 画中画小窗，无广告、无定位、无联网测速。

## v2.6 修了什么（2026-11-10 全面复查发现的）

1. **8 小时到期自动续真的修了（之前是假话）**：原来 tick() 只看 `manager.isActive`，但系统 8 小时后结束 Activity 时不会通知 App，`isActive` 一直是 true，tick() 就一直调 `update()`（对已结束的 Activity 无效），Activity 死透了也永远不重建。现在加了 `ensureActive()`，每次 tick 都查一次系统里还活着的 Activity：有就 update，没有就重建。注意：灵动岛被手动划掉也会重建（App 还在跑就认为还要显示），要彻底关掉点 App 里的“停止”。
2. **状态文字低电量也对了**：之前写死“约1秒刷新”，低电量模式实际是 5 秒一刷，文字是错的。现在用 `intervalText`，低电量显示“5 秒（低电量）刷新”。
3. **“只有 2 个按钮，没有设置页”改过来了**：v2.5 加了外观设置区，这句就错了。现在是“2 个按钮 + 一个外观设置区”。
4. **小窗第一行字符数数错了**：README、PiPManager、SpeedAppearance 三处都写“约 13 字符”，实际 "↓ 12.4M  ↑ 850K" 是 15 字符（22pt 约 198pt，大号 26pt 约 234pt）。结论不变，320 宽照样放得下，只是数字错了。
5. **低耗电一节三处不准**：“采样只读活跃网卡，找到就停”——蜂窝要汇总所有 pdp_ip*，得全扫一遍，不是找到就停；“String(format:) 只有文字变了才调”——其实每秒都调两次（要先算出来才知道变没变），开销很小但说法是错的；“数据只有两个短文本”——v2.5 起 ContentState 多了三个外观小字段。
6. **“整夜待机应该是个位数百分比”删了**：这是没测过的数字，前面刚说“不再写没测过的数字”，转头又写一个，自相矛盾。改成只说“具体多少要真机跑一夜才知道”。

## v2.5 新功能：外观自定义（不用重装，App 里直接改）

App 主界面多了“外观”设置区，改完立即生效，灵动岛 / 锁屏 / 小窗一起变：

1. **字体颜色**：白 / 黄 / 绿 / 青 / 橙 / 红，6 个色点选。应用到主界面数字、小窗文字、灵动岛文字、锁屏文字。
2. **字号**：小 / 中 / 大三档。主界面数字 18 / 22 / 28pt；小窗第一行 18 / 22 / 26pt；灵动岛紧凑 11 / 12 / 13pt；展开模式 = 紧凑 + 2pt（13 / 14 / 15pt）；锁屏 15 / 16 / 20pt。大字号在灵动岛约 47pt 宽，仍在单侧宽度内；100 MB/s 以上极少见，万一超长由系统截断。
3. **背景底色**：黑 / 深灰 / 藏青 / 深绿 / 深紫，5 个色点选。应用到主界面底色、小窗底色、锁屏底色。灵动岛本身的底是系统黑，改不了。

实现说明：设置存在主 App 的 UserDefaults（不用 App Group）；灵动岛 / 锁屏拿不到 App 的 UserDefaults，所以颜色、字号、底色放进 Live Activity 的 ContentState，每次 start / update 一起推过去；画中画在主 App 进程里，直接读 UserDefaults。改设置时立即重推一次，不用等下一秒 tick。

## v2.5 还改了：灵动岛实时刷新（纠正之前 5-15 秒的说法）

之前 README 和界面写的是“灵动岛约 5-15 秒一跳”，这个说法是错的。实际情况：

- App 的 Info.plist 里一直有 `NSSupportsLiveActivitiesFrequentUpdates`（频繁刷新开关），从 v2.2 就有了。
- App 本来就是网速一变就每 1 秒推一次，代码里没有任何 5-15 秒的限制。
- 开了频繁刷新，正常情况下灵动岛约 1 秒一跳，和前台 App 一样实时。只有系统繁忙、低电量时才可能放慢到 5-15 秒，那是系统控制的，App 改不了。
- 这次把界面状态文字从“前台约1秒，灵动岛约5-15秒”改成“约1秒刷新”，README 的“做不到”一节也改过来了。v2.2 那条历史记录留着不动（当时就是这么理解的），以这次纠正为准。
- 注意：到底是不是严格 1 秒，还得真机上看才知道——系统在什么情况下节流，模拟和文档都说不准，装上之后你自己看一眼就清楚了。

## v2.4 改了什么（18 Pro Max 灵动岛适配）

1. **灵动岛字号加大**：紧凑模式（左右两侧）和最小模式（只显示下载）的数字，字号从 caption2（11pt）加大到 caption（12pt），读起来更大。短格式不变（↓12.4M / ↑850K，6 字符），12pt 等宽字约 43pt 宽，仍在灵动岛单侧宽度内，不会被截。100 MB/s 以上（7 字符）在手机上极少见，万一超长由系统截断。
2. 展开模式和锁屏不动：展开模式本来就是 caption，锁屏也不在灵动岛里，不受影响。

## v2.3 修了什么（相对 v2.2，第二遍复查发现的 4 个问题）

1. **双卡真的修了**：v2.2 README 写“双卡 `pdp_ip1` 不再漏”是假话，代码只认 `pdp_ip0`。现在蜂窝汇总所有 `pdp_ip*` 接口的计数，流量走副卡也不再显示 0，没流量的卡增量为 0，不会双计。
2. **小窗点 X 关掉，按钮马上同步**：原来收到关闭通知后什么都没做，按钮还显示“关闭小窗”，点一下是空操作，再点一下才能重开。现在 `SpeedEngine.syncPiPStopped()` 收到通知就把状态置 false，下一按直接重开。
3. **计数器复位不再跳天价**：开关飞行模式、切网、重启后计数器是归零不是绕回，旧代码按 +2^32 补差会跳出约 1330 MB/s。现在速率超过 500 MB/s 当次按 0 算并重新记基线，下一秒恢复正常；真 4GB 绕回增量很小，不受影响。
4. **画中画第一行真的不再被裁**：v2.2 的“320 宽不再被裁”也说过了头，双向都上 MB/s 时约 24–25 字符超宽。现在第一行改用和灵动岛紧凑模式同一个短格式（12.4 MB/s → 12.4M），约 15 字符（22pt 约 198pt），22 号字也放得下。

顺手修的 2 个小问题：`togglePiP()` 先赋值 `onPiPFailed` 再启动，不支持 PiP 的设备上同步失败也能接到回调；`setupIfNeeded()` 第一次没找到 keyWindow 时不再锁死，下次再进来重试。

## v2.2 修了什么（相对 v2.1）

**P0，必须修的：**
1. 低电量死锁修了：`SpeedEngine` 拆出 `startTimerOnly()`，低电量切换只重建 timer，不走 `start()` 的 guard，不会再永久停刷。
2. 通知泄漏修了：`NotificationCenter` 用 token 保存，`stop()` 按 token 删，不再越积越多。
3. 画中画时间戳修了：从墙钟 17 亿秒改成从 0 递增，每帧 +1 秒；timeRange 改无限时长；建了不可见承载 View 挂进 keyWindow，启动前判 `isPictureInPictureSupported()`，失败会回显提示。
4. 画中画画字修了：分两行画，字号 28→22，像素格式改 `byteOrder32Little`，320 宽不再被裁（v2.3 修正：双向 MB/s 时还是会裁，改成短格式后才真正不裁）。
5. 工程文件补了：`SpeedIsland.xcodeproj/project.pbxproj` 已生成，双击能打开；另附 `project.yml`（XcodeGen），如果 pbxproj 打不开就跑 `xcodegen` 重新生成。

**P1，严重但不致命的：**
6. 静音保活修了：显式 `volume=0` + `memset` 清零，不再赌 buffer 默认是 0；加了打断监听，来电 / Siri 结束自动重开；`start` 失败会把 `isRunning` 复位；`stop` 不打断用户音乐。
7. 采样修了：32 位计数器 4GB 绕回按 +2^32 补差，不再掉零；只统计 `AF_LINK`；VPN 时回退到 `utun*` 汇总；双卡 `pdp_ip1` 不再漏（v2.3 修正：v2.2 这句是假话，代码只认 `pdp_ip0`，v2.3 改成汇总所有 `pdp_ip*` 后才真正不漏）；`timebase` 只算一次缓存；`<10 B/s` 不再显示成 0。
8. Live Activity 修了：`startTask` 和 `updateTask` 分开，不再互相取消；`start` 用 await 串行化；失败会显示一句话，不再只 print；数据精简到只剩两个文本 + Wi-Fi。
9. 灵动岛宣传改实话了：前台 App 内约 1 秒，灵动岛系统节流到 5-15 秒，闲时每 4 秒推一次心跳保鲜，不再说“1 秒刷新”。
10. tick 断更修了：文字不变也每 4 秒推一次，灵动岛 / PiP 闲时也不冻住。

## 低耗电是怎么做的（你要的“耗电一定要低”）

- 有流量 1 秒，闲时只推 4 秒心跳，低电量自动 5 秒一刷，退出低电量自动恢复。
- 定时器 leeway 放到 200ms，让系统合并唤醒；队列是 utility，不是高优先级。
- 采样只读活跃网卡（Wi-Fi 读 en0，蜂窝汇总所有 pdp_ip*）；每秒只调两次 `String(format:)`，开销很小；PiP 每秒只画 1 帧 320x120，format 只建一次复用。
- 静音音频从 44100Hz 降到 8000Hz 单声道，0.5 秒循环，音量 0。
- Live Activity 只推变了的文字 + 心跳，数据只有两个短文本 + 三个外观小字段。

预期（未实测，别当保证）：比 v2.1 更省，具体多少要真机跑一夜才知道。README 里不再写没测过的耗电数字。

## “不关就一直都在”是怎么做的，和做不到的部分

能做到的：
- 点开始后，静音音频 + 画中画双保活让进程后台不被挂起。
- Live Activity 8 小时到期，App 活着时会自动重建，不用你手动点。
- 上次是开着的状态，再打开 App 会自动续开（UserDefaults 记状态）。

做不到的（苹果的限制，任何 App 都一样）：
- 免费自签 7 天到期要连电脑重签一次；99 美元账号 1 年。
- 重启手机、被系统杀掉后，iOS 不会自己启动 App，必须手动点开一次 App 才会续开。
- 内存实在不够时系统还是可能杀 App，杀掉后要重开。
- 灵动岛本身 8 小时上限还在，只是现在自动续了，你不用管。

## 能做到 / 做不到（实话）

能做到：
- 前台 App 内约 1 秒刷新，显示 ↓下载 / ↑上传，区分 Wi-Fi / 蜂窝 / VPN
- 灵动岛常驻：紧凑模式只放短数字，不会被截；长按展开看大字
- 锁屏也能看，系统托管，比普通 App 在后台活得久
- 极简：2 个按钮 + 一个外观设置区，没有广告、没有第三方库

做不到：
- 没有真正的安卓式跨 App 悬浮窗，iOS 不允许，画中画是取巧用法，上架会被拒，自用没问题。
- 灵动岛已开频繁刷新（Info.plist 有 NSSupportsLiveActivitiesFrequentUpdates），正常情况下约 1 秒一跳；系统繁忙、低电量时可能放慢到 5-15 秒，这个是系统控制的，App 改不了。

## 文件说明

```
SpeedIsland.xcodeproj/project.pbxproj  双击打开的工程（已生成，需 Mac 上验证）
project.yml                           XcodeGen 配置，pbxproj 打不开时用它重新生成
SpeedIsland/
  SpeedIslandApp.swift            入口
  ContentView.swift               主界面：2 个按钮 + 外观设置 + 错误提示
  SpeedAppearance.swift           v2.5 外观设置：字体颜色 / 字号 / 背景底色（UserDefaults + ContentState 透传）
  SpeedEngine.swift               引擎：后台定时器 + 低电量降频 + 保活 + 自动续开
  NetworkSpeedSampler.swift       采样：只读活跃网卡 + 32 位绕回 + VPN 回退
  LiveActivityManager.swift       Live Activity：拆分 Task + 心跳 + 自动续期
  BackgroundKeepAlive.swift       静音音频保活：8000Hz + volume=0 + 中断恢复
  SpeedActivityAttributes.swift   精简后的共享数据（两个 target 都要勾选）
  PiPManager.swift                画中画：递增时间戳 + 承载 View + 分行画字
SpeedIslandWidget/
  SpeedIslandWidgetBundle.swift
  SpeedIslandLiveActivity.swift   灵动岛紧凑只放短数字
```

## 安装方法：需要一台 Mac + Xcode（免费自签就行）

**没有 Mac？看 `BUILD_IPA.md`：把源码推到 GitHub，用免费的云端 macOS 编译出未签名的 .ipa，再用 AltStore / SideStore / ESign 签名安装。不用 Mac、不用装 Xcode。**

1. Mac 上装 Xcode（App Store 免费），iOS 17 以上，Xcode 15 以上。18 Pro Max 出厂系统较新，建议用最新 Xcode。
2. 用你的 Apple ID 登录 Xcode。免费账号限制：最多 10 个 App ID、同时最多 3 个自签 App、7 天过期要重签；99 美元账号 1 年。
3. 打开本包的 `SpeedIsland.xcodeproj`，不要新建工程再拖文件。
   - 如果打不开，删掉 `SpeedIsland.xcodeproj`，装 `brew install xcodegen`，在包根目录跑 `xcodegen` 重新生成。
   - 如果坚持手动新建：先删新建工程自带的 `SpeedIslandApp.swift`、`ContentView.swift`、`Assets.xcassets`、`Info.plist`，再把本包文件拖进去，不然会出现两个 `@main` 冲突。
4. 在 Xcode 的 Signing & Capabilities 里确认：主 App 勾 Background Modes > Audio，Widget 勾 Live Activity。单改 Info.plist 不够。
5. 手机先开开发者模式：设置 > 隐私与安全 > 开发者模式，打开后重启。没有这一步自签 App 打不开。
6. 手机连 Mac，Xcode 顶部选你的 iPhone 18 Pro Max，点 Run。
7. 手机上 设置 > 通用 > VPN 与设备管理，信任你的 Apple ID 证书。
8. 打开 App，点“开始”，再回桌面 / 锁屏看灵动岛；要点小窗再点“悬浮小窗”。

没有 Mac 的替代路：
- 找朋友借 Mac 装一次，之后 7 天内有效，到期再连 Mac 重签一次。
- 或者用 Apple Developer 账号（99 美元/年）走 TestFlight 分发，但同样需要 Mac 打包。
- 只有手机、没有电脑时装不上，需要先有人在 Mac 上打出 `.ipa` 再用 SideStore / ESign 在手机上签。

## 使用

- 点开始，灵动岛就出现；点停止，就结束。
- 不要上滑杀掉 App，留在后台切换器里。
- 8 小时到期会自动续，不用你管；重启手机后打开 App 一次会自动续开。
- 灵动岛手动划掉也会重建（App 还在跑就认为还要显示），要彻底关掉点 App 里的停止。
- 低电量模式下会自动降到 5 秒一刷，退出低电量自动恢复。
