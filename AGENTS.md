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
- 进程退出（含崩溃）= 屏自动销毁，这是预期清理语义，不要另做持久化。
- 坐标注入 = 流坐标 → 该屏 CGDisplayBounds 全局坐标的线性映射；注入必须 clamp 在屏内。

## 5. 诚实显示

请求值（requested）≠ 实测值（effective）。任何统计 UI / 实测文档必须区分二者，禁止拿请求帧率冒充实测。
丢帧只允许在：编码前、解码后（只渲染最新）、传输背压。禁止在编码后解码前丢弃依赖帧。

## 6. v1 边界

局域网 only；公网/中继、多客户端、音频、剪贴板、多块虚拟屏 UI 均不在 M1 范围（见 README 里程碑）。
