# 显示大小与清晰度独立控制设计

日期：2026-08-27

## 1. 背景

当前 Android 设置使用 `displayLongEdge` 一个字段同时表达虚拟屏像素档位和 Mac
界面大小。用户选择“原生”时像素增加，但字体和控件也会变小；选择“特大”时内容
变大，却不能保证 Retina 清晰度。请求值与实际值也没有在产品界面中严格区分。

现有 Host 已经可以分别描述逻辑尺寸、物理像素和 backing scale，但
`CGVirtualDisplay` 在部分布局（当前真机尤其是竖向左右分屏）会接受 2x 请求后实际
发布为 1x。生产代码目前允许 `compatibleOneXFallback`，这与用户确定的“可以就做，
不可以就不做，绝不降级”原则冲突。

## 2. 目标与非目标

### 目标

- 将“显示大小”与“显示清晰度”拆成两个独立设置。
- Retina 只有在实际模式满足 `physical = logical × 2` 时才算成功。
- 不支持的组合保持上一套有效配置，不接受或静默回退到 1x。
- 首次能力验证结果可缓存；普通重连、升级和 USB/Wi-Fi 切换不重复验证。
- 切换过程中保留可理解的旧画面，正常单屏 2–3 秒、双屏完整完成不超过 6 秒。
- 修复 Android 切换 Loading 在屏幕边缘只显示一部分的问题。
- 不增加常驻截图、轮询或编码负载，不扩大虚拟屏 churn。

### 非目标

- 不实现软件超采样、视频后处理锐化或伪 Retina。
- 不把标准 1x 描述成高清；用户明确选择标准 1x 时它仍是合法模式。
- 不修改视频的 UDP/USB 隧道策略、码率控制或编码器参考链。
- 不通过随机 EDID、重复试建或后台探针穷举系统能力。

## 3. 产品交互

设置面板包含两组独立控件：

1. **显示大小**：大、标准、小。档位映射到逻辑尺寸；每个档位在 2x 模式下仍保持
   精确二倍物理像素。
2. **显示清晰度**：标准 1x、Retina 2x。Retina 是严格能力请求，不是偏好提示。

状态区域始终区分请求值和实测值，显示：逻辑尺寸、物理像素、实际倍率和能力状态。
只有 Host 回报实际 2x 时，UI 才显示“Retina 已启用”。不支持时保持旧选择，并提示
“当前 Mac 系统、布局和显示大小组合不支持 Retina”。

切换时立即显示状态卡片，依次呈现：

- 正在验证 Retina；
- 正在建立第 N/M 块副屏；
- 正在恢复清晰画面；
- 已完成，或明确失败原因。

成功状态在 220ms 内淡出；失败状态保留关闭按钮。超过事务时限时停止本次事务，绝不
进入分钟级自动重试。

## 4. 数据模型与兼容协议

Android `LayoutConfig` 新增两个概念字段：

- `displaySizePreset`：大、标准、小；
- `clarityRequest`：standard1x、retina2x。

旧 `displayLongEdge` 在迁移时转换成最接近的显示大小，旧安装默认保持当前视觉结果，
不会因升级自动请求 Retina。

现有 15-byte `LayoutState` 基础部分保持字节级兼容。新客户端在设备名称之后追加带
版本号的可选扩展，包含显示大小、清晰度请求和事务能力位；旧 Host 会忽略尾部，新 Host
按协议版本解析。Host 回传的 saved-layout 同样在原基础数据后增加可选扩展，旧客户端只
读取原有字段。

新增可靠控制消息 `DISPLAY_MODE_STATUS`，通过现有 UDP 控制通道的 seq/ack 迷你 ARQ
传输，包含：

- transaction ID、display ID 和 slot；
- requested logical/physical/scale；
- effective logical/physical/scale；
- validating、ready、unsupported、failed 状态及枚举原因码。

Android 只接受当前 transaction ID 的状态，迟到的旧 UDP 响应不能覆盖新的用户意图。
请求配置只有在整组屏幕验证并出首帧后才原子保存；失败不修改上一套有效配置。

## 5. 能力缓存

Host 维护三态缓存：unknown、supported、unsupported。键由以下字段组成：

- 稳定设备 fingerprint；
- macOS build version；
- topology 类型；
- 每个 slot 的逻辑尺寸与请求倍率。

macOS 升级或屏幕组几何变化会形成新键并允许一次新验证。应用升级、卸载重装后的设备
身份恢复、USB/Wi-Fi 选路变化和普通断线重连继续使用原键。unsupported 不进入重试；
用户更换布局或显示大小后才可能验证另一个键。

能力缓存不参与 EDID 生成。分辨率和清晰度变化继续复用同一设备、topology、slot 的
恒定 `(vendor, product, serial)` 身份，避免破坏 macOS 的显示器排列与窗口记忆。

## 6. 严格切换事务

macOS 没有可依赖的只读 HiDPI 能力查询接口，且不安全地同时创建相同 EDID 的旧屏和
候选屏。因此首次验证采用可回滚事务：

1. Android 用一次性 PixelCopy 捕获当前合成画面，作为过渡静态层；不做持续截图。
2. Host 保存当前已批准 topology、屏幕 placement 和配置。
3. Host 正常销毁旧屏并等待 WindowServer removal barrier 清空。
4. 按 slot 串行创建严格候选屏，逐屏读取实际 mode。
5. mode 一旦稳定且倍率不匹配，立即判定 unsupported；禁止走
   `compatibleOneXFallback`，也禁止 5 秒/60 秒重试。
6. 全部屏幕实际匹配、进入 CG active list、可被 SCK 枚举并产生首帧后，事务提交。
7. 失败时清理候选屏并只恢复一次上一套已批准配置；若恢复本身失败，明确报错并停止，
   不盲目循环创建。

Android 过渡层保证用户不会看到纯黑屏，但它不伪装成实时画面：状态卡片持续显示当前
步骤与耗时。健康目标为不支持结果 1–2 秒、恢复或双屏成功总时长不超过 6 秒。

## 7. Loading 与安全区

当前真机截图显示平板右下角存在被边界裁剪的圆形 Loading。新实现移除边缘 Loading，
统一使用 Activity 根 `FrameLayout` 上的全屏状态层：

- 依据 `WindowInsetsCompat` 计算 status bar、navigation bar、display cutout 和手势区；
- 在实际 safe rectangle 中心布局卡片，不使用绝对屏幕坐标；
- 宽高、padding、圆角和 ProgressBar 尺寸全部使用 dp；
- 横竖屏、刘海和容器尺寸变化时只重排状态层，不触发 decoder 或虚拟屏重建；
- 状态层不遮掉旧画面，只使用轻度半透明背景；
- 无障碍描述包含当前步骤，但本产品不因此申请辅助功能权限。

## 8. 测试与验收

### 自动化测试

- v1/v2 HELLO、saved-layout 与状态消息的协议契约测试。
- 旧 `displayLongEdge` 到新字段的迁移测试。
- 能力缓存命中、系统版本失效和设备隔离测试。
- 实际 mode 不匹配时严格失败，确认没有进入 1x fallback。
- transaction ID 乱序、重复和迟到消息测试。
- 成功提交、失败回滚和恢复失败不循环的状态机测试。
- Android 不同 Insets、横竖屏及手机/平板尺寸的 Loading 布局测试。

### 真机验收

- 单屏、左右分屏、上下分屏、侧边和画中画分别验证标准 1x 与 Retina 2x。
- 当前已知不支持的竖向左右分屏不得显示 Retina 成功，也不得改变旧配置。
- 受支持单屏 2–3 秒出画，双屏完整就绪不超过 6 秒。
- Loading 始终完整居中，无右下角残缺圆环，切换全程无纯黑屏。
- USB/Wi-Fi 互切、退后台恢复和 Host 重启不重复能力验证。
- 验证前后检查 `colorsync.displayservices` 和 `colorsyncd`：空闲 CPU 均低于 1%。
- Host 无客户端时零虚拟屏、停止采集编码，且无新增常驻截图或高频轮询。

## 9. 实施顺序

1. 协议扩展、数据迁移与状态机单元测试。
2. Host 严格 mode 验证、能力缓存和无重试回滚。
3. Android 独立设置、事务状态处理和请求/实测状态展示。
4. 安全区 Loading 与一次性旧画面过渡层。
5. 自动化测试、两台 Android 真机测试和 macOS/ColorSync 性能检查。
