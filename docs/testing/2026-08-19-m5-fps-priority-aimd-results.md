# M5 实测记录：帧率优先自适应画质（2026-08-19）

环境：macOS 26.2 · 华为 DBY2-W00（2.4GHz WiFi）· Pixel 7 API 34 模拟器

## 已验证 ✅

- **AIMD 码率阶梯**：2s 窗口按 NACK 实测丢片率调档（>2% → ×0.7 降，地板 3M；
  零丢片 6 窗口（12s）→ ×1.25 升，顶=目标码率；起步 min(目标, 8M) 从低走高）。
  - 回环假 NACK 轰炸：8M→5.6M 降档 ✓
  - 真机自然触发：拖动期实测丢片 12.7%/7.7% → 12M→8.4M→5.88M 两级降 ✓；
    停止后 8.4M→10.5M→12M 回升 ✓
- **运行时改码率**：VTSessionSetProperty AverageBitRate+DataRateLimits+强制 IDR 立即生效。
- **采集分辨率阶梯**：码率到底仍 >10% 丢片时 captureScale -15%（地板 70%），流重启
  （新尺寸/新 csd，客户端自动重建解码器）；恢复后升回 100%。机制就绪，本轮未自然触发。
- **IDR 体积治理**：DataRateLimits 窗口 [2×,1s]→[0.5×,1s] 后，1920×1200@6M 的 IDR
  400KB→**61KB**——弱网下关键帧可完整送达+NACK 可补齐的量级。
- **解码器死亡检测**：有关键帧交付但输出 3 秒不涨 → 重建（窗口覆盖 25s GOP）。
- **csd 完整性防御**：CONFIG 走不可靠通道，坏参数集（起始码校验不过）直接丢弃。
- 菜单栏诚实显示：每屏「实测fps · 生效/目标码率 · 采集百分比 · 客户端数」。

## ✅ 回归已修复（2026-08-19 追记，根因三连）

二分定位（M4 client×M5 host / M5 client×M4 host 交叉测试 + 码流 ffmpeg 校验 + 屏幕像素统计）：

| # | 根因 | 修复 |
|---|---|---|
| 1 | 客户端重写后**普通连接不建渲染视图**（DISPLAYS 到达时无人调 rebuildRegionViews；M4 验证走了分屏路径掩盖了它） | onDisplays 首次到达即默认订阅+建视图 |
| 2 | M5 死亡检测**误杀健康解码器**（静止桌面输出合法冻结被当死亡→重建循环→灰） | 仅「输入在涨且输出冻结 3s」才重建 |
| 3 | **DataRateLimits [bitrate/2, 1] 超紧限制**：VideoToolbox 产出的流 ffmpeg 可解、华为硬解输出全零 YUV（屏幕纯绿，像素 0,72,0 实测） | 恢复 [bitrate×2, 1]；AIMD 运行中只调 AverageBitRate 不动 DataRateLimits |

修复后真机实测：壁纸正确渲染（像素校验）、**动态 49fps**、AIMD 保留生效。

## 原「未决」记录（留档）

现象：真机与模拟器均出现「链路 OK、WELCOME 正常、delta 帧在收（waitingForKeyframe
丢弃日志可见）、NACK 在补、host 关键帧在编」，但画面纯灰、0 fps、部分会话 app 自身
日志完全缺失（疑似会话早期异常中断）。

已排除：host 码流（Mac 本地虚拟屏壁纸完好；此前 ffmpeg 对客户端组装流 263 帧全解）；
虚拟屏内容；协议错位（M4 同协议分屏 51fps 实证过）。

时间盒耗尽，未定位到根因。**建议**：
1. 先 `git checkout d79b9c3`（M4 提交）使用——该版本真机分屏/单屏/输入全部验证可用；
2. M5 的改动按提交逐个二分（applyBitrate / AIMD / scaledW 闭包 / 客户端三处防御），
   首查对象：客户端 statsTick 中新增的 stall 检测块与 DisplayPipeline 并发访问、
   以及 startIfNeeded 的 scaledW/scaledH 捕获链。

## 设计结论（保留）

帧率优先 = 码率先降（画质弹性）→ 分辨率再降（采集缩放）→ 全程 latest-frame 不积压；
静止时 IDR 小步快跑立即恢复清晰度。方向经真机数据确认（降码率后帧完整率上升）。
