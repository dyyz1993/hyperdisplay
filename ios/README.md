# hyperdisplay iOS 客户端

iPad 版副屏客户端。线协议、会话语义与安卓客户端逐字段对照（见各源文件头注释与
`android/app/src/main/java/com/hyperdisplay/client/` 的同名 Kotlin 实现），同一台
macOS host 无需任何修改即可同时服务两种客户端。

## 当前范围（阶段一 · 单屏对齐）

- Wi-Fi UDP（端口 5277）。**没有 adb 有线隧道**——AGENTS.md §1 的 TCP 例外只属于
  安卓端内置的 `UsbTunnelController`；iPad 上 Type-C 仅充电。
- 打开 app 即自动连接（§7.1 第二入口）：优先复用保存的地址，否则 mDNS 自动发现；
  恰好发现一台 host 直连，多台才弹列表。
- 单屏全幅显示 + host 推送光标渲染；latest-frame 重组、IDR 缺口门控、NACK 拥塞
  反馈语义与安卓一致。
- 设备档案跨卸载稳定：deviceId 存 UserDefaults，fingerprint 存 Keychain UUID 的
  SHA-256 前 64 位（等效 ANDROID_ID），host 按 EDID 身份还原屏幕槽位。
- 前后台：退后台立即 BYE 并回收虚拟屏（iOS 会快速挂起 socket，不给宽限期），
  回前台自动重连复用原 EDID。

阶段二待做：分屏/PiP 布局引擎、15 字节布局快照恢复（savedLayout 目前沉默忽略，
故意不回 ACK 以免 host 提前放弃旧档案保护）、质量档位/clarity、扫码深链。

## 构建

```sh
brew install xcodegen          # 如未安装
cd ios
xcodegen generate
open hyperdisplay-ios.xcodeproj
```

首次在真机运行需要在 Xcode 里给两个 target 选择签名团队（免费个人 Apple ID 即可），
且 iPad 上需要允许本地网络权限（首连弹窗一次）。

命令行构建 / 测试：

```sh
xcodebuild -project hyperdisplay-ios.xcodeproj -scheme Hyperdisplay \
  -destination 'platform=iOS Simulator,name=iPad (A16)' build
xcodebuild -project hyperdisplay-ios.xcodeproj -scheme Hyperdisplay \
  -destination 'platform=iOS Simulator,name=iPad (A16)' test
```

## 与安卓端的协议对照表

| 模块 | Android | iOS |
|---|---|---|
| 线协议 | `HostSession.kt` 内联 | `Protocol.swift`（权威定义在 macos `Protocol.swift`） |
| 分片重组 | `FrameAssembler.kt` | `FrameAssembler.swift`（逐行对照） |
| 解码 | MediaCodec 低延迟 | VTDecompressionSession + AVSampleBufferDisplayLayer |
| 发现 | NSD `_hyperdisplay._udp` | NWBrowser 同服务名，TXT `code` 配对码 |
| 输入注入 | 协议保留但纯显示禁用 | 不移植 |

单测对齐：`Hyperdisplay/Tests/FrameAssemblerTests.swift` 移植了
`android/app/src/test/.../FrameAssemblerTest.kt` 的用例。
