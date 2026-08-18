# hyperdisplay

把 Android 平板变成 Mac 的一块**虚拟扩展屏**：Mac 上用 `CGVirtualDisplay` 凭空创建一块显示器，
ScreenCaptureKit 采集 → VideoToolbox HEVC 编码 → 局域网 UDP 推流到平板；平板上的触摸作为输入
经 UDP 回传、`CGEventPost` 注入，直接操控那块屏。

```
┌─────────────── macOS host（纯 Swift 单进程）───────────────┐
│ CGVirtualDisplay → SCStream → VTCompressionSession(HEVC)   │
│        ▲                                    │ UDP 视频分片   │
│        │ CGEventPost                        ▼ (不可靠)      │
│   流坐标→全局坐标映射              UDP 控制/输入 (seq+ack)   │
└──────────────────────────┬─────────────────────────────────┘
                           │ 局域网
              ┌────────────┴───────────────┐
              │ Android 平板（Kotlin）      │
              │ MediaCodec HEVC 低延迟解码  │
              │ SurfaceView 全屏 + 触摸回传 │
              └────────────────────────────┘
```

## M1（当前）：最小可用

- 局域网，同一 WiFi/路由器；Android 端手输 `Mac的IP:端口` 连接。
- 虚拟屏默认 1920×1200（参数可调）；平板显示扩展桌面，触摸点/拖、双指滚轮。
- host 退出/崩溃 → 虚拟屏自动消失。

## 构建与运行

```sh
# macOS host
cd macos
swift build -c release
./Scripts/make-app.sh          # 组装 Hyperdisplay.app（含 ad-hoc 签名）
open build/Hyperdisplay.app    # 首次运行需授权：屏幕录制 + 辅助功能

# 自检（无需任何权限）：造屏→列出→销毁
.build/release/HyperdisplayHost --check

# Android 客户端
cd android
./gradlew assembleDebug
adb install app/build/outputs/apk/debug/app-debug.apk
```

默认 UDP 端口 `5277`。host 菜单栏图标会显示本机 IP 与端口。

## 里程碑

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M1 | 手动 IP 连接 + 扩展屏串流 + 触摸/滚轮 | 🚧 进行中 |
| M2 | Bonjour 自动发现 + 配对码 | 未开始 |
| M3 | 质量档（分辨率/帧率）+ 平板旋转重建虚拟屏 | 未开始 |
| M4 | 断线重连 + 菜单栏统计（请求/有效 fps、码率、限制因素） | 未开始 |
| M5 | 虚拟鼠标、多块虚拟屏 | 未开始 |

## 工程约束

见 [AGENTS.md](AGENTS.md)：实时负载一律 UDP、双通道分离、HEVC 首选、latest-frame 丢帧策略、
虚拟屏随进程退出自动销毁。

## 致谢

- [DeskPad](https://github.com/Stengo/DeskPad)（MIT）：`CGVirtualDisplay` 的 Swift 绑定写法参考。
