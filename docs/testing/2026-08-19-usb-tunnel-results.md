# USB 有线（adb 隧道）实测记录（2026-08-19，已废弃）

> **2026-08-24 已废弃。** 这份记录保留为历史排障证据；当前产品已删除 adb reverse/TCP
> 隧道及相关脚本。视频、输入和控制一律走 UDP：有线场景仅支持系统提供的 USB 网络共享
> （RNDIS/以太网）上的 UDP 地址。没有可用 UDP 路径时，客户端会明确提示，不会降级到 TCP。

## 背景

用户需求：Type-C 有线连接，追求更低延迟与更高稳定性。原生路径（USB 网络共享）在
DBY2-W00（WiFi 版平板）上不存在该开关；程序化 `svc usb setFunctions rndis` 会把 USB
gadget 卡死（曾导致 adb/USB 整体掉线，需重启平板恢复）。最终采用 **adb reverse TCP 隧道**。

## 架构

```
平板 app --TCP(127.0.0.1:5280)--> adbd --USB线--> Mac adbd --> TCP:5280
      --> usb-tunnel.py（帧互转）<--> UDP 127.0.0.1:5277（host）
```

- 帧格式 `[len u32 LE][payload]`，双向；
- 桥接 `macos/Scripts/usb-tunnel.py`（含 up/inputs/down/videofrags 计数）；
- 一键启动 `macos/Scripts/usb-start.sh`（起桥接 + 每台设备 adb reverse）；
- 客户端：host 为 127.0.0.1 时自动进入 TCP 隧道模式（连接/收发/心跳全走 TCP，
  读超时驱动 PING/HELLO 周期任务）；连接页新增「USB 连线」按钮。

## 调试中排掉的坑（按发现顺序）

1. `svc usb setFunctions rndis` 会清掉 adb 功能 → USB 全断（避免使用，需重启平板恢复）；
2. adb reverse 的监听绑在 **IPv6 (::)**：app 必须连 `::1`，连 127.0.0.1 直接拒绝；
3. TCP connect 在主线程 → NetworkOnMainThreadException → 移入会话线程；
4. TCP 模式最初没有心跳循环 → linkUp 永假 → 看门狗不发 IDR → 无画面；
5. 桥接重启后 app 抱死旧 socket → 需重连（空闲重连机制已覆盖）；
6. 静默 catch 吞掉接收线程异常曾造成「输入通、视频断」假象（桥接回程被背压堵死）。

## 验证结果

- **视频**：Mac 本机伪客户端走隧道收 633 视频分片 ✓；真机（华为平板）经隧道渲染
  壁纸（像素 0x84abce 系）✓，连接初期解码器连续渲染 ~200 帧 ✓；
- **输入**：拖动产生 1000+ input 帧过桥，host 日志确认 `first input from 127.0.0.1`（坐标
  映射正确，display=102）✓；
- **心跳/掉线**：链路 OK 稳定，桥接重启后 app 自动重连 ✓。

## 待补

- 持续拖动下的 USB vs WiFi 帧率对比（多轮测试被真机前台切换打断，链路本身已验证；
  预期 USB 无线丢包为零、AIMD 恒满档）；
- adb 隧道为 TCP：无线场景的队头阻塞风险在此不存在（有线无损），但协议语义上
  违反「实时负载走 UDP」原则，属权宜方案——若未来换用支持 RNDIS 的设备应回到原生路径。

## 历史启动方式（不可再使用）

当时依赖的 `usb-start.sh`、`usb-tunnel.py`、客户端 TCP 分支和「USB 连线」按钮均已删除。
保留本节结论仅用于说明旧方案为何被废弃，不能作为当前使用说明。
