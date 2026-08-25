# hyperdisplay

把 Android 平板变成 Mac 的一块**虚拟扩展屏**：Mac 上用 `CGVirtualDisplay` 凭空创建一块显示器，
ScreenCaptureKit 采集 → VideoToolbox HEVC 编码 → 局域网 UDP 推流到平板。产品收敛为纯显示：
不申请辅助功能，也不把平板触摸、鼠标或键盘注入 Mac。

```
┌─────────────── macOS host（纯 Swift 单进程）───────────────┐
│ CGVirtualDisplay → SCStream → VTCompressionSession(HEVC)   │
│                                             │ UDP 视频分片   │
│                                             ▼ (不可靠)      │
└──────────────────────────┬─────────────────────────────────┘
                           │ 局域网
              ┌────────────┴───────────────┐
              │ Android 平板（Kotlin）      │
              │ MediaCodec HEVC 低延迟解码  │
              │ SurfaceView 全屏显示         │
              └────────────────────────────┘
```

## 当前功能（M1–M4）

- 局域网 Wi-Fi 与 **USB 连线（仅限系统提供 USB/RNDIS 网卡的设备）** 双通道——实时负载
  始终为 UDP，不使用 TCP/adb 隧道。Android 同时发现同一 Mac 的多网络端点，USB 网卡
  可用时优先，拔线自动回退已保存的 Wi-Fi。MTP/PTP/HiSuite 只传文件或设备管理数据，
  不会被误认为网络；实测华为 DBY2-W00（Wi-Fi 版）没有 USB 网络共享入口，因此该机型
  当前走 Wi-Fi。
- **零点击恢复**：Android 保存主机、设备身份、布局和画中画参数；同一设备以固定 EDID
  `(vendor, product, serial)` 恢复相同屏幕槽位。后台/退出即视为拔线，Host 立即移除该设备
  的虚拟屏；USB/Wi-Fi 换路由则静默重连并复用屏幕身份。无客户端时没有虚拟屏、采集或编码。
- **多块虚拟显示器 + 平板分屏**：平板「布局」一次保存单屏、左右/上下分屏、侧栏或画中画，
  下次 HELLO 由 Host 统一恢复完整屏幕组；Android 不再直接逐块 CREATE/DESTROY，避免拓扑 churn。
- **局域网发现 + 扫码连接**：Mac 菜单栏「显示连接二维码…」出二维码（hyperdisplay://ip:port）；
  平板「局域网发现」经 mDNS 自动找到 Mac 点一下即连，无需手输 IP。
- **关键帧分片 NACK 重传**：host 缓存近期关键帧分片，客户端上报缺失分片号定向重传
  （增量帧可丢、关键帧必须完整）——弱网（如 2.4GHz）下画面恢复的兜底机制。
- 静态桌面不填充码率（静态 0fps 为诚实值）；运动时优先实时性，静止后恢复全质量关键帧。
- 启动参数：`--display WxH`（可重复）、`--fps 30|60|90|144`、`--port`、`--bitrate`（缺省
  按分辨率自动）、`--codec h264`（诊断/兼容）。

## 构建与运行

```sh
# macOS host
cd macos
swift build -c release
./Scripts/make-app.sh          # 组装 Hyperdisplay.app（含 ad-hoc 签名）
open build/Hyperdisplay.app    # 首次按引导仅开启屏幕录制，然后按提示重启 Host

# Android 客户端
cd android
./gradlew assembleDebug
adb install app/build/outputs/apk/debug/app-debug.apk
# 也可 adb 直连（自动化/测试）：am start -n com.hyperdisplay.client/.MainActivity -e host <ip>:<port>
```

macOS host 必须以 `Hyperdisplay.app` 运行，而不是直接把 release 二进制交给用户：
`.app` 是包含 host 可执行文件、`Info.plist`、图标和签名的应用包，系统按 bundle id 记录
屏幕录制权限，菜单栏 host 和登录自启也依赖这个形态；本产品不需要辅助功能。
屏幕录制用于采集虚拟扩展屏。顶部栏使用单色模板 icon，
权限或 ColorSync 异常时在 icon 旁显示状态标记。`.build/release/HyperdisplayHost`
只保留给 `--check` 等开发自检。品牌源文件在 `branding/`，macOS 图标由
`macos/Scripts/generate-icon.sh` 生成并由 `make-app.sh` 自动放入 `Contents/Resources`。

默认 UDP 端口 `5277`。host 退出 → 全部虚拟屏自动销毁。

## 下载与开源发布

项目通过 GitHub Releases 直接分发，不走 Mac App Store：当前 Mac host 需要使用
`CGVirtualDisplay` 私有 API，不能按 App Store 的公开 API 要求提交。每个正式 Release 提供：

- `Hyperdisplay-macOS-arm64.dmg`：Developer ID 签名并经 Apple notarization 的 Mac 安装包；
- `Hyperdisplay-android.apk`：同一个持久发布密钥签名的 Android 安装包；
- `SHA256SUMS`：两个安装包的 SHA-256 校验值。

Mac 菜单栏的「下载 Android 客户端（GitHub Releases）…」会始终打开最新版下载页。平板下载
APK 后，按 Android 对所用浏览器或文件管理器的系统提示允许安装，之后打开 Hyperdisplay 即可。
构建者请使用 `script/package-release.sh`：它会拒绝未签名 APK 或未 notarize 的 Mac 包，避免把
开发产物误上传。发布到 GitHub 的命令在 `script/publish-github-release.sh`。

首次配置 Mac 直发时，运行 `script/setup-notary-profile.sh`，在终端安全提示中输入 Apple ID 与
app-specific password；凭据会被验证并仅保存到 macOS Keychain。随后执行：

```sh
HYPERDISPLAY_NOTARY_PROFILE=HyperdisplayNotary ./script/package-release.sh
./script/publish-github-release.sh 0.1.0
```

若 Android 已先发布，第二条命令会把已 notarize 的 Mac DMG 追加到同一个 GitHub Release。

## 里程碑

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M1 | 手动 IP 连接 + 扩展屏串流 | ✅ 完成 |
| M2 | 多虚拟屏 + 局域网/USB 网络共享 UDP 双通道 | Wi-Fi 已完成；USB 实现完成，待支持 RNDIS 的平板真机验证（DBY2-W00 不支持） |
| M3 | 局域网发现 + 扫码 + 关键帧 NACK | ✅ 完成（配对码并入后续） |
| M4 | 平板分屏多路显示（区域像素 1:1） | ✅ 完成（真机 2 屏并发 51fps） |
| M5 | 配对码 + 质量档 UI + 旋转重建 + 自适应码率 + 四分屏/缩略图 | 未开始 |
| M5 | 虚拟鼠标、多屏并发实测 | 未开始 |

## 工程约束

见 [AGENTS.md](AGENTS.md)：实时负载一律 UDP、双通道分离、HEVC 首选、latest-frame 丢帧策略、
虚拟屏随进程退出自动销毁。

## 致谢

- [DeskPad](https://github.com/Stengo/DeskPad)（MIT）：`CGVirtualDisplay` 的 Swift 绑定写法参考。
