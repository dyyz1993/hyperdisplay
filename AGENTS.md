# AGENTS.md — hyperdisplay

> 所有 agent（含 AI 编程助手）在本仓库工作时的强制约束。

## 1. 实时负载一律 UDP

视频帧、输入事件一律走 UDP。禁止 TCP socket / WebSocket / TURN-TCP 承载任何实时负载。
没有可用 UDP 路径时必须显式报错，不得静默降级。

## 2. 通道分离（均在 UDP 之上）

| 通道 | 内容 | 可靠性 |
|---|---|---|
| 视频通道 | 编码后的视频分片 | 不可靠；新帧到达即丢弃旧帧未完成分片（latest-frame policy） |
| 控制/输入通道 | 会话控制、指针、按键、滚轮 | seq+ack 超时重传（迷你 ARQ）；指针绝对坐标允许新值覆盖旧值 |

## 3. 编码：HEVC 首选，H.264 兜底

- VideoToolbox HEVC（硬件、RealTime、无 B 帧）；硬件 HEVC 不可用时协商降级 H.264 并告知客户端。
- 码率上限是 ceiling 不是固定输出；严禁人为填充码率。
- 关键帧间隔 ≤ 10s；参数集（VPS/SPS/PPS 或 SPS/PPS）随每个关键帧以 CONFIG 报文在带内下发。

## 4. 虚拟屏生命周期

- 虚拟屏由 `CGVirtualDisplay`（CoreGraphics 私有 API）创建，实例必须常驻进程保活。
- 进程退出（含崩溃）= 屏自动销毁，这是预期清理语义，不要另做持久化——但这是**最后防线，不是借口**：正常退出路径必须显式 destroy 全部虚拟屏（见 4.1）。
- 坐标注入 = 流坐标 → 该屏 CGDisplayBounds 全局坐标的线性映射；注入必须 clamp 在屏内。

### 4.1 显示器 churn 卫生（防 ColorSync 中毒）——2026-08-19 实测血泪

当天调试中大量创建/销毁虚拟屏 + 一次建屏 API 中途崩溃，导致
`colorsync.displayservices`/`colorsyncd` 死循环（62%+38% CPU，系统明显卡顿）。
中毒状态在 windowserver 侧：杀进程无效（launchd 秒拉起、读到同一污染状态立刻复转，
甚至进入崩溃-重启循环），只能注销/重启清除。以下规则全部强制：

1. **严禁在生产 shim（`HyperdisplayObjC`）之外直接调用 `CGVirtualDisplay` 做实验**。
   实验一律走隔离的 swiftc 测试工具，且测试工具崩溃在 `initWithDescriptor` 中途
   即视为可能投毒——实验后必须检查 `~/Library/Logs/DiagnosticReports/` 有无新崩溃，
   有则停止后续实验并告知用户。
2. **调试禁止反复重启整个 host 进程**。每次重启 = 全部虚拟屏销毁+重建（全量 churn）。
   需要重置时优先：会话级重建（RECYCLE 路径）/ 单屏 destroyDisplay / 只回收编码器。
   单日 host 重启次数应保持在个位数。
3. **退出必清**：正常退出路径（菜单退出/SIGTERM）必须显式 `hyperdisplayDestroyAllVirtualDisplays()`；
   SIGKILL/崩溃由 windowserver 兜底回收。开发期用 `pkill` 收尾是坏习惯，用进程自己的退出通道。
4. **EDID 身份恒定**：同一设备的 (vendor, product, serial) 三元组必须恒定（serial =
   1000 + deviceId 低 16 位），禁止随机 serial——显示器身份 churn 会放大系统侧事件风暴。
5. **churn 预算意识**：`fullIdleReset()`（全量销毁+重建）是最大的单次 churn 源，只允许用于
   编码器池污染恢复；日常回收走单屏 `destroyDisplay`。已知的 25s 级 SCK 停流看门狗只重建
   采集流，不碰显示器对象——这是刻意设计，别"顺手"升级成重建屏。
6. **ColorSync 中毒处置预案**（再次发生时）：症状 = colorsync.displayservices 持续高 CPU；
   `kill` 无效属预期（不要反复尝试）；引导用户注销会话，未愈则重启；痊愈判据 = 该进程
   CPU < 1%。

## 5. 诚实显示

请求值（requested）≠ 实测值（effective）。任何统计 UI / 实测文档必须区分二者，禁止拿请求帧率冒充实测。
丢帧只允许在：编码前、解码后（只渲染最新）、传输背压。禁止在编码后解码前丢弃依赖帧。

## 6. v1 边界

局域网 only；公网/中继、多客户端、音频、剪贴板、多块虚拟屏 UI 均不在 M1 范围（见 README 里程碑）。
