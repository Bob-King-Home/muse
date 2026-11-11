# 不用 Mac，云端免费编译出 .ipa 再装到手机上

Muse 的电脑是 Linux，没有 Xcode，编不出 iOS 的 .ipa。这个办法是：把源码推到 GitHub，用 GitHub 免费的 macOS 机器编译，下载未签名的 .ipa，再用你自己的工具签名安装。

## 准备

- 一个 GitHub 账号（没有就去 github.com 注册一个，免费）
- 手机上装好 AltStore、SideStore、ESign 或 Scarlet 其中一个（用来签名安装，你说你会装，应该已经有了）

## 步骤

### 1. 在 GitHub 上建一个仓库

- 打开 github.com，点右上角 + → New repository
- 名字随便起，比如 `SpeedIsland`
- 选 Public（公开仓库的 macOS 编译时间免费不限量；Private 每月 200 分钟 macOS 时间，一次编译约 5–10 分钟，也够用）
- 点 Create repository

### 2. 把源码传上去

把本文件夹（`SpeedIsland/`）里的**全部内容**传到仓库根目录，根目录下应该直接有这些：

```
SpeedIsland.xcodeproj/
SpeedIsland/
SpeedIslandWidget/
project.yml
.github/workflows/build-ipa.yml
```

最简单的是用网页上传：进仓库页面 → Add file → Upload files → 把本文件夹里的所有文件和文件夹拖进去 → Commit。

也可以用 git（电脑上有 git 的话）：

```bash
git clone https://github.com/你的用户名/SpeedIsland.git
cd SpeedIsland
# 把本文件夹的全部内容拷进来
git add .
git commit -m "SpeedIsland v2.6"
git push
```

### 3. 跑编译

- 进仓库页面 → 点顶部 Actions
- 左边找到 "Build unsigned IPA" → 点 Run workflow → Run workflow
- 等 5–10 分钟，变成绿色对勾就是编好了（红色就是失败，点进去看日志）

### 4. 下载 .ipa

- 点那次成功的运行记录 → 往下翻到 Artifacts → 下载 `SpeedIsland-unsigned-ipa`
- 解压得到 `SpeedIsland-unsigned.ipa`

### 5. 签名安装到手机

这个 .ipa 是**未签名**的，不能直接装，必须用你的工具签名：

- **AltStore / SideStore**：把 .ipa 传给它，用你的 Apple ID 签名安装（免费账号 7 天过期，到期在 AltStore 里点 Refresh 重签，不用重新编译）
- **ESign / Scarlet**：导入 .ipa，签名后安装
- 有付费开发者账号（99 美元/年）的，签名后 1 年有效

装好后：设置 → 通用 → VPN 与设备管理 → 信任你的 Apple ID 证书 → 打开 App → 点“开始”。

## 注意

- **图标是空白的**：源码里没有做 App 图标，装好后主屏幕上是个白图标，不影响使用。以后有空再补图标。
- **每次更新都要重新编**：改了源码就再跑一次 workflow，下载新的 .ipa 重装（重装前不用删旧的，直接覆盖）。
- **7 天过期**：免费 Apple ID 签的 App 7 天后打不开，在 AltStore / SideStore 里点一下 Refresh 就续上，不用重新编译、不用重新下载。
- **不要把仓库设成公开又放敏感信息**：这个源码里没有任何账号密码，放心公开。但别把你的 Apple ID 密码写进仓库。
