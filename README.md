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

## 当前功能（M1 + M2 + M3）

- 局域网 WiFi 与 **USB 连线（USB 网络共享）** 双通道——host 绑 0.0.0.0，菜单栏列出所有网卡
  IP（含 USB 虚拟网卡）；插线后在平板开「USB 网络共享」，连菜单栏里对应的 IP 即可
  （USB ~1–3ms 且无 WiFi 省电尖刺）。
- **多块虚拟显示器**：Mac 菜单栏增删（预设 1920×1200 / 2560×1600 / 2800×1840 / 4K）；
  平板「显示器 ▾」按钮切换、**新建适配本机分辨率的屏**（像素 1:1）、删除；多客户端各自订阅。
- **局域网发现 + 扫码连接**：Mac 菜单栏「显示连接二维码…」出二维码（hyperdisplay://ip:port）；
  平板「局域网发现」经 mDNS 自动找到 Mac 点一下即连，无需手输 IP。
- **关键帧分片 NACK 重传**：host 缓存近期关键帧分片，客户端上报缺失分片号定向重传
  （增量帧可丢、关键帧必须完整）——弱网（如 2.4GHz）下画面恢复的兜底机制。
- 触摸：单指点/拖，双指滚轮；按键/滚轮 seq+ack 重传；静态桌面不填充码率（静态 0fps 为诚实值）。
- 启动参数：`--display WxH`（可重复）、`--fps 30|60|90|144`、`--port`、`--bitrate`（缺省
  按分辨率自动）、`--codec h264`（诊断/兼容）。

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
# 也可 adb 直连（自动化/测试）：am start -n com.hyperdisplay.client/.MainActivity -e host <ip>:<port>
```

默认 UDP 端口 `5277`。host 退出 → 全部虚拟屏自动销毁。

## 里程碑

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M1 | 手动 IP 连接 + 扩展屏串流 + 触摸/滚轮 | ✅ 完成 |
| M2 | 多虚拟屏 + 局域网/USB 双通道 | ✅ 完成（真机画面验证待平板解锁） |
| M3 | 局域网发现 + 扫码 + 关键帧 NACK | ✅ 完成（配对码并入后续） |
| M4 | 配对码 + 质量档 UI + 旋转重建 + 自适应码率 | 未开始 |
| M5 | 虚拟鼠标、多屏并发实测 | 未开始 |

## 工程约束

见 [AGENTS.md](AGENTS.md)：实时负载一律 UDP、双通道分离、HEVC 首选、latest-frame 丢帧策略、
虚拟屏随进程退出自动销毁。

## 致谢

- [DeskPad](https://github.com/Stengo/DeskPad)（MIT）：`CGVirtualDisplay` 的 Swift 绑定写法参考。
