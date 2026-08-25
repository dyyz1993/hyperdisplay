# USB 有线隧道恢复实测（2026-08-25）

> 恢复 8-24 删除的 adb reverse 隧道（AGENTS §1 当日新增有线例外条款），
> 并在无局域网环境下完成冷启动、性能、抗震荡三项验证。全部通过。

## 恢复内容（源自 86f6d78，非重写）

- host：`UsbTunnel.swift`（TCP 127.0.0.1:5280 ↔ UDP host 帧互转，4MB 缓冲，
  adb reverse 轮询 5s/闲时 60s 退避）；探针 HELLO（proto=0xFF）只回声不注册；
  隧道客户端（127.0.0.1）跳过视频分片 usleep 节流；菜单栏隧道状态项。
- 客户端：`UsbProbe.kt`（完整握手探测，防 adbd 半开连接假阳性）；
  `HostSession` TCP 隧道分支（独立心跳、[len u32] 帧解析、发送出口）；
  `Transport.TUNNEL` 第三传输；smartConnect 隧道优先；30s 升级探测含隧道；
  连接页「USB 连线」按钮；无局域网时发现等待循环内持续探隧道。

## 过程中修掉的两个真 bug

1. **reverse 静默丢失后永不重注册**（host）。旧优化"serial 集合不变就跳过
   reverse 调用"在 reverse 被系统清空（实测：平板关 WiFi 导致其 WiFi-adb
   transport 掉线时触发清理）而 USB serial 仍在场时失效——平板探测永远失败。
   修复：每轮 `reverse --list` 核对 tcp:5280 是否在场，缺失才注册。
2. **刚升级的有线会话被死链重连当场掐死**（客户端）。切到隧道瞬间 linkUp
   仍为 false，tick 的 `!linkUp && 有线` 触发 400ms 后降级 WiFi——而隧道握手
   +建屏+首个 PONG 需要 ~1.5s。表现为隧道↔WiFi 每 30s 震荡（日志可见第二次
   升级已收到 159 个视频包仍被杀）。修复：新会话 3s 宽限（sessionStartedAt）
   再允许判死降级。

## 验证结果（华为 DBY2-W00，平板 WiFi 关闭 = 无局域网）

- **冷启动零点击**：`am start --es host smart` → **t+3s 内 link=up
  transport=usb-tunnel**，虚拟屏 1440x960 建屏订阅完成。
- **性能**：虚拟屏全屏变色动画（30Hz 源）持续 24s：**fps 29-34 稳定无尖刺**，
  链路零掉线，平板端 CPU ~21%（含解码渲染）。静止桌面回落 ~5fps（内容驱动，
  符合 §7.5）。
- **抗震荡**：动画停止、WiFi 恢复后连续采样，会话稳定保持 usb-tunnel 不回落。
- 配对码 771866 两端一致（注意：旧文档/记忆中的 543062 已过期）。

## 未测项

- 物理拔线 → WiFi 降级 → 再插线升回的完整循环：该平板 USB 物理性掉线问题
  （见测试环境记忆）使拔插测试本身有风险，且逻辑与已验证的"死链降级+30s
  升级"同路径，留待日常使用观察。
- USB 网络共享（RNDIS/NCM）UDP 路径：本机不支持，无变化。
