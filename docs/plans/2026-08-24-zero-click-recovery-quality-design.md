# Hyperdisplay 零点击恢复与动态画质设计

## 目标

- 移动画面以帧率和低延迟优先，静止后自动补发满目标码率 IDR 恢复清晰度。
- 实时负载只走 UDP；USB 网络共享优先，断开后自动回退 Wi-Fi，恢复 USB 后自动升级。
- Android 保存主机、设备身份、布局、比例及画中画参数；重新打开 APP 后自动恢复。
- 同一 Android 设备始终生成相同的 macOS 虚拟显示器 EDID 身份，不被识别为新显示器。
- 无客户端时回到零虚拟屏、零采集、零编码。

## 编码层

现有链路保持 VideoToolbox HEVC 硬编优先、H.264 兜底、RealTime、无 B 帧和编码前背压丢帧。码率采用 10Mbps/百万像素的画质优先上限，只有实测丢片才由 AIMD 下调。

ScreenCaptureKit 的内容驱动帧用于识别动静转换。运动停止后重放最近源帧，以目标码率编码关键帧，使静止画面恢复高清；静止桌面随后维持零帧发送。

## 连接层

Android mDNS 发现保留同一 Bonjour 服务在不同网络上的多个端点，不再按服务名互相覆盖。候选端点附带 Android `Network` 与传输类型；创建 UDP 会话时显式绑定对应 Network，避免 USB/Wi-Fi 并存时走错默认路由。

- 打开 APP：先连接上次端点；没有记录时自动发现唯一主机。
- Wi-Fi 使用中：插线广播立即探测 USB，活跃会话每 30 秒低频兜底；发现同一配对码的 USB 端点后切换。
- USB 断开：优先切回已验证的 Wi-Fi 端点；没有记录则重新 mDNS 发现。
- 同一 Mac 的 USB/Wi-Fi 两个端点按配对码合并为一台主机，不因此弹选择列表。
- 视频和输入始终是 UDP；无 UDP 路径时保持等待与重试，不降级 TCP。

## 状态与显示器身份

Android 使用持久 `deviceId`。Host 以 `vendor=0x1A2B, product=0x0001, serial=1000+(deviceId low 16)` 创建该设备的主虚拟屏；运行期同时记录设备与 DisplayStream 的绑定，不能只按分辨率误认其他屏。

Android 持久化布局类型、分割比例、侧栏方向、画中画比例/尺寸/位置。Display ID 是每次建屏后的临时值，不作为跨重启真值；重连后根据持久布局和当前 Host 屏列表重新订阅。

Host 不再启动即预建历史设备屏。HELLO 到来才按设备档案创建；正常 BYE 后约 5 秒、异常断链后从最后心跳起约 15 秒显式销毁。显式命令行 `--display` 创建的诊断屏除外。

## macOS 排列恢复边界

固定 EDID 的目标是让 macOS 自动恢复显示器排列、位置与窗口归属。此行为必须在健康系统上完成真实拔插和 APP 重启验收。目前不实现 `CGConfigureDisplayOrigin` 坐标兜底；只有真机证明系统恢复失败后，才保存 effective origin 并主动恢复，避免无依据增加私有显示 API 操作和 ColorSync churn。

## 验收

1. 无客户端启动 Host：虚拟屏数量为 0。
2. 华为平板打开 APP：5 秒内建屏并出首帧，目标 3 秒。
3. Wi-Fi 画面中插入 USB：自动显示 `USB·UDP`，不中断用户操作。
4. 拔掉 USB：自动显示 `Wi-Fi·UDP` 并恢复画面。
5. 滚动时保持实时，停止后约 0.5–1.5 秒恢复清晰；静止后 fps/发送归零。
6. 关闭再打开 Android APP：自动恢复布局、比例和画中画位置。
7. 重复拔插与 Host 正常重启：EDID 三元组不变，验证 macOS 排列和窗口归属。
8. 测试前后检查 `colorsync.displayservices` 与 `colorsyncd`；持续高 CPU 时立即停止，不做显示器实验。
