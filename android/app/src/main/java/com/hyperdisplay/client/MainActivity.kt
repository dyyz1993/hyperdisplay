package com.hyperdisplay.client

import android.annotation.SuppressLint
import android.app.ActivityManager
import android.content.res.Resources
import android.graphics.Color
import android.graphics.Typeface
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.SystemClock
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.Surface
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

class MainActivity : androidx.appcompat.app.AppCompatActivity() {
    companion object {
        private const val TAG = "MainActivity"
        private const val DEFAULT_PORT = 5277
    }

    // MARK: 连接界面

    private lateinit var root: FrameLayout
    private lateinit var statusText: TextView
    private var hostInput: EditText? = null
    private var connectView: LinearLayout? = null

    // MARK: 会话状态

    private var session: HostSession? = null
    /** 防止旧 Host 持续回 unknown PONG 时重复启动多个发现会话。 */
    private var staleHostRecoveryInFlight = false
    /** 本会话中已提交的自动规格校正，防止旧屏尚未销毁时每枚 DISPLAYS 都重复建屏。 */
    private var profileSyncRequested: List<Pair<Int, Int>>? = null
    private var statsOverlay: TextView? = null
    private var chromeHandle: TextView? = null
    private var chromeHideRunnable: Runnable? = null

    /** 呼出临时状态条；配置按钮常驻，不能让屏幕/分辨率入口藏在手势里。 */
    private fun showChrome() {
        statsOverlay?.visibility = android.view.View.VISIBLE
        configButton?.visibility = android.view.View.VISIBLE
        // 状态条自带传输明细（左上同位）：角标让位，收起后回归。
        transportBadge?.visibility = android.view.View.GONE
        chromeHideRunnable?.let { mainHandler.removeCallbacks(it) }
        val r = Runnable { hideChrome() }
        chromeHideRunnable = r
        mainHandler.postDelayed(r, 6000)
    }

    private fun hideChrome() {
        // 配置面板挂在 root 上的场景不隐藏（用户正在操作）——简化判定：面板类弹窗
        // 存在时 statsTick 的 6s 计时照走，但面板自身是 Dialog 生命周期不受影响
        statsOverlay?.visibility = android.view.View.GONE
        transportBadge?.visibility = android.view.View.VISIBLE
        // ⚙ 配置必须常驻：它是分辨率、双屏和画中画唯一的显式入口。
    }
    private var sessionRoot: FrameLayout? = null
    private val waitingOverlay by lazy { WaitingOverlay(this) }
    private var waitingSince = 0L
    /** Host 已回包但 DISPLAYS 为空：保持会话，展示明确等待态，绝不把它当断线。 */
    private var waitingForDisplay = false
    private var switchingBanner: android.widget.LinearLayout? = null
    private var switchingBannerShow: Runnable? = null
    private var switchingBannerTitle: TextView? = null
    private var switchingBannerDetail: TextView? = null
    /** 布局替换必须等整组新屏都至少渲染一帧，不能被仍在播放的旧屏提前取消动画。 */
    private var topologyTransitionInFlight = false
    private var topologyTransitionSinceMs = 0L
    private var topologyTransitionOldIds = emptySet<Int>()
    private var topologyTransitionExpectedIds = emptySet<Int>()
    private val regionViews = mutableListOf<StreamView>()

    private class DisplayPipeline(val id: Int) {
        var assembler: FrameAssembler? = null
        var decoder: VideoDecoder? = null
        @Volatile var csd: ByteArray? = null
        @Volatile var codec = 1 // WELCOME 上报：1=HEVC 2=H.264（host 硬编会话耗尽时回退）
        @Volatile var width: Int = 0
        @Volatile var height: Int = 0
        @Volatile var fps: Int = 60
        @Volatile var surface: Surface? = null
        @Volatile var lastKeyframeDeliveredAt = 0L
        var lastRendered = 0
        var renderedNow = 0
        var stallTicks = 0
        var stallDecoderRef: VideoDecoder? = null
        var stallInputBase = 0L
        var stallOutputBase = 0
        var deadTicks = 0 // csd 已到但零渲染的持续秒数（华为坏会话自动恢复用）
        var decoderAgeTicks = 0   // 解码器已存活 tick 数（绿屏取证调度用）
        var greenChecks = 0       // 已执行的绿屏取证次数（上限后交给手动）
    }

    private val pipelines = LinkedHashMap<Int, DisplayPipeline>()
    private val pipelineLock = Object()

    enum class LayoutKind(val label: String) {
        SINGLE("单屏全屏"), SPLIT_LR("左右分屏"), SPLIT_TB("上下分屏"),
        SIDE("主屏+侧边"), PIP("画中画")
    }

    data class LayoutConfig(
        val kind: LayoutKind = LayoutKind.SINGLE,
        val fraction: Float = 0.5f,       // 分割位置/侧边占比/画中画高度占比
        val sideLeft: Boolean = false,    // 侧边在左
        val pipRatio: String = "16:10",   // 画中画宽高比（初始形状）
        val pipCustomW: Int = 0,          // 手指自由缩放后的画中画尺寸（0=按比例默认）
        val pipCustomH: Int = 0,
        /** 0=本机原生尺寸；其余为虚拟屏长边档位，仅随本机布局持久化。 */
        val displayLongEdge: Int = 0,
        /** 0=明确标准 1x；1=严格请求实际 Retina 2x。 */
        val clarity: Int = 0
    )

    private var layoutConfig = LayoutConfig()
    /** 仅在 Host 实测成功后才落盘的最后有效配置。 */
    private var committedLayoutConfig = layoutConfig
    private var pendingLayoutConfig: LayoutConfig? = null
    private var pendingModeTransaction = 0
    private var nextModeTransaction = 1

    private fun loadLayoutConfig(): LayoutConfig {
        val p = getSharedPreferences("hyperdisplay", MODE_PRIVATE)
        val kind = runCatching {
            LayoutKind.valueOf(p.getString("layout.kind", LayoutKind.SINGLE.name)!!)
        }.getOrDefault(LayoutKind.SINGLE)
        return LayoutConfig(
            kind = kind,
            fraction = p.getFloat("layout.fraction", 0.5f).coerceIn(0.2f, 0.8f),
            sideLeft = p.getBoolean("layout.sideLeft", false),
            pipRatio = p.getString("layout.pipRatio", "16:10") ?: "16:10",
            pipCustomW = p.getInt("layout.pipCustomW", 0).coerceAtLeast(0),
            pipCustomH = p.getInt("layout.pipCustomH", 0).coerceAtLeast(0),
            displayLongEdge = DisplayResolution.normalize(p.getInt("layout.displayLongEdge", 0)),
            clarity = p.getInt("layout.clarity", 0).coerceIn(0, 1)
        )
    }

    private fun saveLayoutConfig(cfg: LayoutConfig) {
        getSharedPreferences("hyperdisplay", MODE_PRIVATE).edit()
            .putString("layout.kind", cfg.kind.name)
            .putFloat("layout.fraction", cfg.fraction)
            .putBoolean("layout.sideLeft", cfg.sideLeft)
            .putString("layout.pipRatio", cfg.pipRatio)
            .putInt("layout.pipCustomW", cfg.pipCustomW)
            .putInt("layout.pipCustomH", cfg.pipCustomH)
            .putInt("layout.displayLongEdge", cfg.displayLongEdge)
            .putInt("layout.clarity", cfg.clarity)
            .putInt("layout.pipLeft", pipLeft)
            .putInt("layout.pipTop", pipTop)
            .apply()
    }

    private fun layoutStateForHost(cfg: LayoutConfig, transaction: Int = 0): HostSession.LayoutState {
        val ratio = when (cfg.pipRatio) {
            "3:2" -> 1
            "4:3" -> 2
            "1:1" -> 3
            else -> 0 // 16:10
        }
        return HostSession.LayoutState(
            kind = cfg.kind.ordinal,
            fractionPermille = (cfg.fraction * 10_000f).toInt(),
            sideLeft = cfg.sideLeft,
            pipRatio = ratio,
            pipCustomW = cfg.pipCustomW,
            pipCustomH = cfg.pipCustomH,
            displayLongEdge = cfg.displayLongEdge,
            pipLeft = pipLeft,
            pipTop = pipTop,
            displaySizePreset = DisplayResolution.presetId(cfg.displayLongEdge),
            clarity = cfg.clarity,
            transaction = transaction
        )
    }

    /** 仅用于 Host 识别出“同一平板但已卸载重装”的一次性恢复。 */
    private fun restoreLayoutFromHost(state: HostSession.LayoutState) {
        val kind = LayoutKind.values().getOrElse(state.kind) { LayoutKind.SINGLE }
        val ratio = listOf("16:10", "3:2", "4:3", "1:1").getOrElse(state.pipRatio) { "16:10" }
        layoutConfig = LayoutConfig(
            kind = kind,
            fraction = (state.fractionPermille / 10_000f).coerceIn(0.2f, 0.8f),
            sideLeft = state.sideLeft,
            pipRatio = ratio,
            pipCustomW = state.pipCustomW,
            pipCustomH = state.pipCustomH,
            displayLongEdge = DisplayResolution.normalize(state.displayLongEdge),
            clarity = state.clarity.coerceIn(0, 1)
        )
        pipLeft = state.pipLeft
        pipTop = state.pipTop
        saveLayoutConfig(layoutConfig)
        committedLayoutConfig = layoutConfig
        updateConfigButton()
        updateOverlay()
        // UDP 不保证这个恢复包一定先于 DISPLAYS 到达。若默认单屏视图已经建好，
        // 在这里按刚恢复的布局补齐订阅与区域，避免 Host 虽复用了双屏而平板只显示一块。
        val desiredIds = displays.take(requestedDisplaySpecs().size).map { it.id }
        if (desiredIds.isNotEmpty() && desiredIds != subscribedIds) {
            subscribedIds = desiredIds
            resetPipelines()
            rebuildRegionViews()
            if (desiredIds.size == 1) session?.selectDisplay(desiredIds.first())
            else session?.sendSubscribeDisplays(desiredIds)
            desiredIds.forEach { session?.requestKeyframe(it) }
        }
    }
    private var subscribedIds = listOf<Int>()
    private var displays: List<HostSession.DisplayInfo> = emptyList()
    private var configButton: TextView? = null
    /** 常驻传输角标（右上，与配置按钮同行）：一眼区分有线/无线。 */
    private var transportBadge: TextView? = null
    private var localCursor: LocalCursorView? = null
    private var systemBarRehide: Runnable? = null
    private var pipRoot: FrameLayout? = null
    private var pipLeft = -1
    private var pipTop = -1
    private var pipSelected = false
    private val pipHandles = mutableListOf<View>()
    private var pipChip: View? = null
    private var pipTapStartX = 0f
    private var pipTapStartY = 0f
    private var pipTapAt = 0L
    private var pipDragActivated = false

    @Volatile private var linkUp = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private var reconnecting = false
    private var activeTransport = NsdFinder.Transport.OTHER
    private var routeProbeTicks = 0
    private var routeProbeActive = false
    /** 插线后的短窗口重试：Mac 需要先收到 IOKit 事件并执行一次 adb reverse。
     *  这不是常驻轮询；只在 POWER_CONNECTED 后最多探测约 5 秒，避免先连 Wi‑Fi
     *  又被 30 秒兜底轮询拖住才升级到 USB。 */
    private var usbTunnelBurstGeneration = 0
    // 产品定位是外置显示器；不申请辅助功能，也不把触摸转换为 Mac 输入。
    @Volatile private var remoteControlEnabled = false
    /** 用户偏好（配置面板开关，持久化）；生效与否还要看 host 在 WELCOME 里宣告的能力。 */
    private var remoteControlUserPref = false
    /** host 通过 WELCOME.controlEnabled 宣告支持注入；旧 host 恒 false。 */
    @Volatile private var hostControlSupported = false
    private var renderFps = 0
    private var appCpuPercent = 0.0
    private var appMemoryMB = 0
    private var lastResourceSampleAt = 0L
    private var lastProcessCpuMs = 0L
    private var lastWatchdogKfAt = 0L
    private val statsTick = object : Runnable {
        override fun run() {
            var total = 0
            val snapshot = synchronized(pipelineLock) {
                for (p in pipelines.values) {
                    val d = p.decoder
                    if (d != null) {
                        p.renderedNow = d.renderedFrames
                        total += p.renderedNow - p.lastRendered
                        p.lastRendered = p.renderedNow
                    }
                }
                pipelines.values.toList()
            }
            renderFps = total
            // 通道切换的任意首帧即可收起；布局替换则必须等完整新屏组都出过一帧，
            // 旧屏仍在播放时不能把“正在优化布局”的提示提前撤掉。
            // 2026-08-30 平板实测横幅永挂：期望集只在「新屏 id ≠ 旧 id」的 DISPLAYS
            // 到达时才被填充——拓扑重建复用同 id/列表不再推送时恒为空，
            // isNotEmpty() 门控把撤除条件判死。回落：期望空时用订阅集判断首帧；
            // 另加 12s 兜底（iOS 同款）：静态桌面等任何等不到新屏组首帧的场景，
            // 到时强收——旧画面仍在播放，提示滞留只会让用户以为卡死。
            val readinessIds = synchronized(pipelineLock) {
                if (topologyTransitionExpectedIds.isNotEmpty()) topologyTransitionExpectedIds
                else subscribedIds.toSet()
            }
            val topologyReady = synchronized(pipelineLock) {
                readinessIds.isNotEmpty() && readinessIds.all { id ->
                    (pipelines[id]?.renderedNow ?: 0) > 0
                }
            }
            if (topologyTransitionInFlight && topologyReady) {
                topologyTransitionInFlight = false
                topologyTransitionExpectedIds = emptySet()
                cancelSwitchingBanner()
            } else if (topologyTransitionInFlight &&
                SystemClock.elapsedRealtime() - topologyTransitionSinceMs > 12_000) {
                Log.w(TAG, "topology banner timeout — dismissing (first frames may be retained textures)")
                topologyTransitionInFlight = false
                topologyTransitionExpectedIds = emptySet()
                cancelSwitchingBanner()
            } else if (!topologyTransitionInFlight && total > 0) {
                cancelSwitchingBanner()
            }
            for (p in snapshot) p.assembler?.stallCheck()
            // 解码器死亡检测：仅在「有输入提交但输出 3 秒不涨」时重建——
            // 静止桌面（内容驱动、无新帧）下输出冻结是合法状态，不能误杀
            for (p in snapshot) {
                val d = p.decoder
                if (d != null) {
                    val input = d.snapshotInputCount()
                    val output = d.renderedFrames
                    if (d !== p.stallDecoderRef) {
                        p.stallDecoderRef = d
                        p.stallInputBase = input
                        p.stallOutputBase = output
                        p.stallTicks = 0
                    } else if (output == p.stallOutputBase && input > p.stallInputBase) {
                        p.stallTicks++
                        if (p.stallTicks >= 3) {
                            Log.w(TAG, "decoder dead (input growing, no output), rebuilding display=" + p.id)
                            p.decoder = null
                            d.release()
                            p.stallDecoderRef = null
                            p.stallTicks = 0
                            maybeStartDecoder(p)
                        }
                    } else {
                        p.stallTicks = 0
                    }
                    p.stallInputBase = input
                    p.stallOutputBase = output
                } else {
                    p.stallDecoderRef = null
                    p.stallTicks = 0
                }
            }
            // 坏解码器自动恢复（两种形态）：
            // a) 零渲染型：csd 已到但 6 秒零渲染
            // b) 绿屏型：解码器「正常渲染」但输出全零 YUV（华为坏会话）——渲染计数无法
            //    发现，必须画面取证：PixelCopy 采样三点，识别 (r<30, 45<g<110, b<30)
            //    且均匀的特征绿。两种都在解码器启动后第 5/12/19 秒各查一次，最多三轮。
            for (p in snapshot) {
                val d = p.decoder
                if (d == null) { p.deadTicks = 0; p.decoderAgeTicks = 0; continue }
                p.decoderAgeTicks++
                if (d != null && p.csd != null && p.renderedNow == 0) {
                    p.deadTicks++
                    if (p.deadTicks == 6) {
                        Log.w(TAG, "dead decoder (0 renders), auto-bounce display=" + p.id)
                        p.decoder = null
                        d.release()
                        maybeStartDecoder(p)
                        continue
                    }
                } else {
                    p.deadTicks = 0
                }
                // 华为 HEVC 坏会话会把首帧渲染为均匀绿屏。原先首次取证在 3 秒，
                // 再等 host 编码器重建后用户会看见约 5 秒绿屏；提前到第 1 秒即可
                // 在首帧阶段完成自愈，后两次保留为网络抖动后的兜底。
                if (p.decoderAgeTicks in listOf(1, 3, 8) && p.csd != null) {
                    val view = regionViews.firstOrNull { it.displayId == p.id }
                    if (view != null) detectGreenAndBounce(view, p)
                }
            }
            val s = session
            if (s != null && linkUp && !waitingForDisplay) {
                waitingSince = 0
                if (waitingOverlay.parent != null) waitingOverlay.dismiss()
                for (p in snapshot) {
                    if (p.decoder == null && p.csd == null) {
                        val now = System.currentTimeMillis()
                        if (now - lastWatchdogKfAt > 1200) {
                            lastWatchdogKfAt = now
                            s.requestKeyframe(p.id)
                        }
                    }
                }
            } else if (s != null && linkUp && waitingForDisplay && sessionRoot != null) {
                waitingSince = 0
                waitingOverlay.state = WaitingOverlay.State.CONNECTED_NO_DISPLAY
                waitingOverlay.tryingUsb = isWiredTransport()
                waitingOverlay.tryingWifi = !isWiredTransport()
                mainHandler.post { waitingOverlay.show(root) }
            } else if (s != null && sessionRoot != null) {
                // 断链等待 >3s 且还没恢复：全屏等待页（双通道动画 + 动态文案）。
                // 3s 宽限是为了不给快闪断（WiFi 探测的瞬时失败）闪屏。
                val now = System.currentTimeMillis()
                if (waitingSince == 0L) waitingSince = now
                if (now - waitingSince > 3000) {
                    waitingOverlay.tryingUsb = true
                    waitingOverlay.tryingWifi = true // 智能重连两条路都在试
                    waitingOverlay.state = WaitingOverlay.State.CONNECTING
                    val rootF = root
                    mainHandler.post { waitingOverlay.show(rootF) }
                }
            }
            // Wi-Fi 首连/Host 重启期间，HostSession 会在同一 UDP socket 上无限静默
            // 重发 HELLO。这里若每 5 秒 destroy + 重新发现，会让全屏等待页反复
            // 销毁重建（用户看到“一闪一闪”），还会把 UDP 源端口不断换掉。
            // 只有当前已在有线（USB 网络或 adb 隧道）上，才需要主动拆会话回退到已知
            // Wi-Fi 地址——拔线后隧道/网卡即死，等 mDNS 重发现太慢。新会话给 3s
            // 宽限：隧道握手 + 建屏 + 首个 PONG 需要 ~1.5s，刚切换就判死会把
            // 升级上来的有线会话当场掐死（2026-08-25 无局域网实测：隧道↔WiFi
            // 每 30s 震荡，视频已在流仍被杀）。
            val s1 = session
            if (!linkUp && isWiredTransport() && s1 != null && !reconnecting
                && System.currentTimeMillis() - sessionStartedAt > 3000
                && System.currentTimeMillis() - lastReconnectAt > 5000) {
                mainHandler.post { scheduleSmartReconnect() }
            }
            // 会话存在时才探测更优链路：插线广播会立即触发；30 秒低频轮询只作
            // OEM 漏广播兜底。无线链路已死也要探——无局域网时隧道是唯一通路。
            // 有线（USB UDP / adb 隧道）已就位时不再轮询。
            routeProbeTicks++
            if (s1 != null && !isWiredTransport() && routeProbeTicks >= 30) {
                routeProbeTicks = 0
                mainHandler.post { probeForUsbUpgrade() }
            }
            if (s1 != null) sampleAppResources(System.currentTimeMillis())
            updateOverlay()
            writeStatusFile()
            mainHandler.postDelayed(this, 1000)
        }
    }

    // MARK: 生命周期

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        configureDisplayViewport()
        layoutConfig = loadLayoutConfig()
        committedLayoutConfig = layoutConfig
        val layoutPrefs = getSharedPreferences("hyperdisplay", MODE_PRIVATE)
        pipLeft = layoutPrefs.getInt("layout.pipLeft", -1)
        pipTop = layoutPrefs.getInt("layout.pipTop", -1)
        remoteControlUserPref = layoutPrefs.getBoolean("remoteControl", false)
        root = FrameLayout(this)
        setContentView(root)
        showConnectView()
        when (intent.getStringExtra("host")?.trim()?.lowercase()) {
            "discover" -> startAutoDiscovery() // USB 网络变化后由 mDNS 重新解析可达地址
            "smart" -> smartConnect() // 优先复用已保存地址，否则自动发现
            null, "" -> smartConnect() // 零点击基线（AGENTS.md §7.1）：打开 app 即自动连接
            else -> intent.getStringExtra("host")!!.trim().let { text ->
                parseEndpoint(text)?.let { (host, port) -> connect(host, port) }
            }
        }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // 桌面再次点开只应唤回现有副屏会话，不能在同一任务叠一层 MainActivity。
        // 有明确的 USB/通知指令时才重新探测；普通启动不打断已经存活的 Wi-Fi UDP 会话。
        when (intent.getStringExtra("host")?.trim()?.lowercase()) {
            "discover" -> startAutoDiscovery()
            "smart" -> if (session == null) smartConnect()
        }
    }

    // MARK: 连接界面

    @SuppressLint("ApplySharedPref")
    private fun showConnectView() {
        disconnectSession(removeDisplay = true)
        root.removeAllViews()
        window.clearFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN)

        val prefs = getPreferences(MODE_PRIVATE)
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(64, 64, 64, 64)
        }
        val title = TextView(this).apply {
            text = "Hyperdisplay"
            textSize = 28f
            setTypeface(Typeface.DEFAULT_BOLD, Typeface.BOLD)
            gravity = Gravity.CENTER
        }
        val subtitle = TextView(this).apply {
            text = connectionPathHint()
            textSize = 14f
            gravity = Gravity.CENTER
            setPadding(0, 8, 0, 32)
        }
        val input = EditText(this).apply {
            hint = "Mac 的 IP:端口（如 192.168.1.23:5277）"
            setText(prefs.getString("host", ""))
            textSize = 16f
        }
        val codeInput = EditText(this).apply {
            hint = "配对码（Mac 菜单栏 ◧ 里查看，6 位数字）"
            setText(if (prefs.getInt("pairingCode", 0) > 0) prefs.getInt("pairingCode", 0).toString() else "")
            textSize = 16f
            inputType = android.text.InputType.TYPE_CLASS_NUMBER
        }
        val button = Button(this).apply { text = "连接" }
        val scanButton = Button(this).apply { text = "扫码连接" }
        val findButton = Button(this).apply { text = "局域网发现" }
        val usbButton = Button(this).apply { text = "USB 连线" }
        val buttonRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        buttonRow.addView(scanButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        buttonRow.addView(findButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        buttonRow.addView(usbButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        statusText = TextView(this).apply {
            text = ""
            textSize = 13f
            gravity = Gravity.CENTER
            setPadding(0, 16, 0, 0)
            setTextColor(Color.GRAY)
        }
        box.addView(title)
        box.addView(subtitle)
        box.addView(input)
        box.addView(codeInput)
        box.addView(button)
        box.addView(buttonRow)
        box.addView(statusText)
        root.addView(box, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        connectView = box
        hostInput = input

        usbButton.setOnClickListener {
            // 手动有线入口：完整握手探测（Mac 侧隧道在才连得上），失败给明确提示。
            statusText.text = "正在探测 USB 有线链路（需平板开启 USB 调试）…"
            UsbProbe.probe(this) { ok ->
                if (ok) {
                    connectTunnel()
                } else {
                    statusText.text = "USB 隧道不通：确认 Type-C 数据线已插、Mac 端 Hyperdisplay 在运行、平板 USB 调试已授权本机"
                }
            }
        }

        button.setOnClickListener {
            // 已保存地址会自动连接；这里仅保留首次手输的兜底入口。
            val text = input.text.toString().trim()
            if (text.isNotEmpty()) {
                val (host, port) = parseEndpoint(text) ?: run {
                    statusText.text = "地址格式不对，应形如 192.168.1.23:5277"
                    return@setOnClickListener
                }
                prefs.edit().putString("host", text).apply()
                saveCode(codeInput.text.toString().trim())
                connect(host, port)
            } else {
                smartConnect()
            }
        }
        scanButton.setOnClickListener { launchQrScan() }
        findButton.setOnClickListener { showDiscoveryDialog() }
    }

    /**
     * 只依据当前真正存在的网络接口判断 USB 是否可用。插上数据线、选择 MTP
     * 并不等于建立了网络；部分平板 ROM（例如当前实测的华为 DBY2-W00）根本不
     * 暴露 USB 网络共享开关，这时必须诚实走 Wi-Fi。
     */
    private fun hasUsbUdpNetwork(): Boolean {
        val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
        return cm.allNetworks.any { network ->
            val caps = cm.getNetworkCapabilities(network) ?: return@any false
            if (Build.VERSION.SDK_INT >= 31 &&
                caps.hasTransport(NetworkCapabilities.TRANSPORT_USB)) {
                return@any true
            }
            // 有些 RNDIS 实现上报为 Ethernet；仅在接口名也明确是 USB/RNDIS 时认定，
            // 避免把扩展坞的普通有线网卡误标成“直连 USB”。
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) return@any false
            val ifName = cm.getLinkProperties(network)?.interfaceName?.lowercase().orEmpty()
            ifName.contains("rndis") || ifName.startsWith("usb")
        }
    }

    /** 当前会话是否走在有线链路上（USB 网卡 UDP 或 adb TCP 隧道）。
     *  有线 = 拔线即死要降级 Wi-Fi + 已是最优路径不再探测升级。 */
    private fun isWiredTransport(): Boolean =
        activeTransport == NsdFinder.Transport.USB || activeTransport == NsdFinder.Transport.TUNNEL

    private fun connectionPathHint(): String = if (hasUsbUdpNetwork()) {
        "USB UDP 已就绪，会优先使用；拔线后自动切回 Wi-Fi"
    } else {
        "插 Type-C 线走 USB 隧道（需平板开 USB 调试）；无有线时使用 Wi-Fi"
    }

    private fun saveCode(text: String) {
        text.toIntOrNull()?.let { getPreferences(MODE_PRIVATE).edit().putInt("pairingCode", it).apply() }
    }

    private fun parseEndpoint(text: String): Pair<String, Int>? {
        if (text.isBlank()) return null
        val parts = text.split(":")
        val host = parts[0]
        val port = if (parts.size > 1) parts[1].toIntOrNull() ?: return null else DEFAULT_PORT
        if (port !in 1..65535) return null
        return host to port
    }

    private fun connect(host: String, port: Int) {
        getPreferences(MODE_PRIVATE).edit()
            .putString("host", "$host:$port")
            .putString("lastWifiHost", "$host:$port")
            .apply()
        openSession(host, port, transport = NsdFinder.Transport.WIFI)
    }

    /** 发现结果直接连接：主机地址 + TXT 配对码一并记住（零点击，AGENTS.md §7） */
    private fun connectEntry(e: NsdFinder.HostEntry, isSwitch: Boolean = false) {
        staleHostRecoveryInFlight = false
        val editor = getPreferences(MODE_PRIVATE).edit()
            .putString("host", "${e.host}:${e.port}")
        if (e.code != 0) editor.putInt("pairingCode", e.code)
        when (e.transport) {
            NsdFinder.Transport.USB -> editor.putString("lastUsbHost", "${e.host}:${e.port}")
            NsdFinder.Transport.WIFI -> editor.putString("lastWifiHost", "${e.host}:${e.port}")
            // 隧道不经 mDNS 发现，永远不会出现在 HostEntry 里
            NsdFinder.Transport.TUNNEL, NsdFinder.Transport.OTHER -> Unit
        }
        editor.apply()
        openSession(e.host, e.port, isSwitch, e.network, e.transport)
    }

    /** 建立会话（连接页与自动重连共用）。
     *  isSwitch=true 才显示切换横幅：横幅语义是「正在换通道」，取消条件是首帧渲染。
     *  初次连接/重连不该用它——host 不健康时永远等不到首帧，横幅挂死不撤
     *  （2026-08-20 用户实测：开 app 一直"正在切换通道"）。初连用等待页语义。 */
    private fun openSession(
        host: String,
        port: Int,
        isSwitch: Boolean = false,
        network: android.net.Network? = null,
        transport: NsdFinder.Transport = NsdFinder.Transport.OTHER
    ) {
        disconnectSession()
        if (isSwitch) scheduleSwitchingBanner()
        // 新会话重新协商：host 能力以新 WELCOME 为准，协商前不注入。
        hostControlSupported = false
        remoteControlEnabled = false
        val code = getPreferences(MODE_PRIVATE).getInt("pairingCode", 0)
        val deviceId = HostSession.loadOrCreateDeviceId(this)
        val deviceFingerprint = HostSession.loadDeviceFingerprint(this)
        val deviceName = HostSession.loadDeviceDisplayName(this)
        val s = HostSession.create(host, port, sessionListener, code, deviceId, deviceFingerprint, deviceName,
            requestedDisplaySpecs(), layoutStateForHost(layoutConfig), network)
        if (s == null) {
            showConnectView()
            statusText.text = "无法解析地址（仅支持数字 IPv4）"
            return
        }
        activeTransport = transport
        session = s
        sessionStartedAt = System.currentTimeMillis()
        waitingForDisplay = false
        showSessionView()
        s.start()
        mainHandler.post(statsTick)
        // 前台服务最后启动（会话已成立）：先启后停会触发
        // ForegroundServiceDidNotStartInTimeException（启动被 stopService 取消）
        // Android 12+ 禁止已退到后台的 Activity/重连回调任意拉起前台服务。
        // 这不是连接失败，却会抛 ForegroundServiceStartNotAllowedException 并把
        // 整个 App 打死。前台时服务正常启动；被系统拒绝时保留当前 UDP 会话，
        // 下次回到前台再启动，而不是闪退。
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                startForegroundService(android.content.Intent(this, SessionService::class.java))
            } else {
                startService(android.content.Intent(this, SessionService::class.java))
            }
        } catch (e: Exception) {
            Log.w(TAG, "foreground session service start deferred by Android", e)
        }
    }

    /** HELLO 的零点击设备档案：单屏=当前平板尺寸；分屏/画中画=上次保存的完整屏幕组。 */
    private fun requestedDisplaySpecs(config: LayoutConfig = layoutConfig): List<Pair<Int, Int>> {
        val (sw, sh) = screenDims()
        val raw = if (config.kind == LayoutKind.SINGLE) listOf(sw to sh)
        else regionSizes(config).ifEmpty { listOf(sw to sh) }.take(4)
        val longEdge = DisplayResolution.normalize(config.displayLongEdge)
        val deviceCanvasLongEdge = maxOf(sw, sh)
        return raw.map { (w, h) -> DisplayResolution.scale(w, h, deviceCanvasLongEdge, longEdge) }
    }

    // MARK: 通道/布局切换过渡层（旧画面保留，中心卡片解释正在做什么）

    private fun scheduleSwitchingBanner(
        title: String = "正在切换通道…",
        detail: String = "画面即将恢复",
        delayMillis: Long = 1_500L
    ) {
        cancelSwitchingBanner()
        switchingBannerTitle?.text = title
        switchingBannerDetail?.text = detail
        val r = Runnable {
            val b = switchingBanner ?: return@Runnable
            b.visibility = android.view.View.VISIBLE
            b.alpha = 0f
            b.scaleX = 0.98f; b.scaleY = 0.98f
            b.animate()?.alpha(1f)?.scaleX(1f)?.scaleY(1f)?.setDuration(220)?.start()
            // 兜底只处理普通通道切换。布局替换由完整新屏组的首帧完成收尾，不能
            // 因仍在播放的旧画面而在 10 秒后悄悄撤掉说明。
            switchingBannerShow = null
            if (!topologyTransitionInFlight) {
                mainHandler.postDelayed({
                    if (!topologyTransitionInFlight) cancelSwitchingBanner()
                }, 10_000)
            }
        }
        switchingBannerShow = r
        mainHandler.postDelayed(r, delayMillis)
    }

    private fun cancelSwitchingBanner() {
        switchingBannerShow?.let { mainHandler.removeCallbacks(it) }
        switchingBannerShow = null
        switchingBanner?.let {
            it.animate().cancel()
            it.visibility = android.view.View.GONE
        }
    }

    private fun beginTopologyTransition() {
        topologyTransitionInFlight = true
        topologyTransitionSinceMs = SystemClock.elapsedRealtime()
        topologyTransitionOldIds = subscribedIds.toSet()
        topologyTransitionExpectedIds = emptySet()
        scheduleSwitchingBanner(
            title = "正在应用新的屏幕布局",
            detail = "保留当前画面，正在优化副屏…",
            delayMillis = 220L
        )
    }

    /** 智能连接：先探 adb 有线隧道（插线默认走有线，最快），否则复用已保存的
     *  UDP 主机，最后搜索局域网内的 Mac。 */
    private fun smartConnect() {
        statusText.text = "正在探测 USB 有线链路…"
        UsbProbe.probe(this) { tunnelOk ->
            if (tunnelOk && session == null && !isFinishing) {
                connectTunnel()
                return@probe
            }
            if (session != null) return@probe // 探测期间已有会话接管
            val prefs = getPreferences(MODE_PRIVATE)
            val saved = prefs.getString("host", null)
            val ep = saved?.let { parseEndpoint(it) }
            if (ep != null && ep.first != "127.0.0.1") {
                statusText.text = "连接 UDP 主机：${ep.first}:${ep.second}"
                val transport = when (saved) {
                    prefs.getString("lastUsbHost", null) -> NsdFinder.Transport.USB
                    prefs.getString("lastWifiHost", null) -> NsdFinder.Transport.WIFI
                    else -> NsdFinder.Transport.OTHER
                }
                openSession(ep.first, ep.second, transport = transport)
            } else {
                statusText.text = "无历史主机——自动搜索局域网内的 Mac…"
                startAutoDiscovery()
            }
        }
    }

    /** 走 adb 有线隧道（TCP 127.0.0.1:5280，AGENTS.md §1 有线例外）。
     *  不写入 host/lastWifiHost 偏好——隧道总是活体探测，不该被当成 UDP 地址复用。 */
    private fun connectTunnel(isSwitch: Boolean = false) {
        // ADB reverse 只证明物理链路可达，无法携带 Host 的配对码。首次安装若先命中
        // USB、而本地还没有配对码，Host 会拒绝 HELLO，客户端便会循环收到 unknown
        // PONG，也不会创建副屏。先经 mDNS 自动发现唯一的局域网 Host，读到其广播的
        // 配对码并保存；随后本次走 Wi-Fi 接入，后续插线则会自动升级回 USB 隧道。
        if (getPreferences(MODE_PRIVATE).getInt("pairingCode", 0) == 0) {
            Log.i(TAG, "USB tunnel ready but pairing code missing; discovering host first")
            if (session != null) {
                disconnectSession()
                showConnectView()
            }
            startAutoDiscovery()
            return
        }
        Log.i(TAG, "connecting via adb USB tunnel (127.0.0.1:5280)")
        openSession("127.0.0.1", 5280, isSwitch, transport = NsdFinder.Transport.TUNNEL)
    }

    /** 当前会话建立时刻：死链重连的宽限基准（握手+建屏+首 PONG ~1.5s）。 */
    @Volatile private var sessionStartedAt = 0L

    /** 自动重连 UDP 主机。 */
    private var lastReconnectAt = 0L

    private fun scheduleSmartReconnect() {
        if (reconnecting) return
        reconnecting = true
        lastReconnectAt = System.currentTimeMillis()
        mainHandler.postDelayed({
            reconnecting = false
            val prefs = getPreferences(MODE_PRIVATE)
            val wifi = prefs.getString("lastWifiHost", null)?.let { parseEndpoint(it) }
            if (isWiredTransport() && wifi != null) {
                // 拔线（USB 网卡或 adb 隧道断）：优先用已经验证过的 Wi-Fi 地址，
                // 不等一轮发现。
                openSession(wifi.first, wifi.second, isSwitch = true,
                    transport = NsdFinder.Transport.WIFI)
            } else {
                // 地址失效或网络切换：mDNS 同时覆盖 Wi-Fi 与 USB 网络共享。
                // 没有可用 Wi-Fi（无局域网场景）时回到 smart——它会持续探隧道。
                val hasWifiFallback = wifi != null ||
                    (getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager).activeNetwork != null
                if (hasWifiFallback) {
                    disconnectSession()
                    showConnectView()
                    startAutoDiscovery()
                } else {
                    disconnectSession()
                    showConnectView()
                    smartConnect()
                }
            }
        }, 400)
    }

    // MARK: 扫码

    private fun launchQrScan() {
        val intent = com.journeyapps.barcodescanner.ScanContract().createIntent(
            this,
            com.journeyapps.barcodescanner.ScanOptions().apply {
                setPrompt("对准 Mac 菜单栏二维码（显示连接二维码…）")
                setBeepEnabled(false)
                setDesiredBarcodeFormats(com.journeyapps.barcodescanner.ScanOptions.QR_CODE)
            })
        qrActivityResult.launch(intent)
    }

    private val qrActivityResult = registerForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult()
    ) { result ->
        val content = com.journeyapps.barcodescanner.ScanContract().parseResult(result.resultCode, result.data)?.contents
        if (content.isNullOrBlank()) return@registerForActivityResult
        var cleaned = content.removePrefix("hyperdisplay://").trim()
        val hash = cleaned.indexOf('#')
        if (hash >= 0) {
            saveCode(cleaned.substring(hash + 1).trim())
            cleaned = cleaned.substring(0, hash).trim()
        }
        val (host, port) = parseEndpoint(cleaned) ?: run {
            statusText.text = "二维码内容无法识别：$content"
            return@registerForActivityResult
        }
        getPreferences(MODE_PRIVATE).edit().putString("host", "$host:$port").apply()
        connect(host, port)
    }

    // MARK: 局域网发现

    private val nsdFinder by lazy { NsdFinder(this) }
    private val routeFinder by lazy { NsdFinder(this) }
    private var discoveryDialog: android.app.AlertDialog? = null

    /** 已连接时探测更优链路：adb 隧道（快，毫秒级握手）优先；隧道不在再找同一
     *  配对码的 USB UDP 端点（RNDIS/NCM 网卡）。不碰当前会话，确认可用才切换。
     *  无线链路已死时同样要走这里——无局域网场景下 tunnel 是唯一出路。 */
    private fun probeForUsbUpgrade() {
        if (routeProbeActive || isWiredTransport()) return
        routeProbeActive = true
        UsbProbe.probe(this) { tunnelOk ->
            if (!routeProbeActive) return@probe // 期间已被别的路径接管/取消
            if (tunnelOk) {
                routeProbeActive = false
                Log.i(TAG, "adb tunnel alive; upgrading to wired")
                connectTunnel(isSwitch = true)
                return@probe
            }
            val expectedCode = getPreferences(MODE_PRIVATE).getInt("pairingCode", 0)
            routeFinder.setCallbacks(
                onStart = { },
                onHost = { e ->
                    val sameHost = expectedCode == 0 || e.code == expectedCode
                    if (routeProbeActive && sameHost && e.transport == NsdFinder.Transport.USB) {
                        routeProbeActive = false
                        routeFinder.stopDiscovery()
                        Log.i(TAG, "USB UDP endpoint discovered: ${e.host}:${e.port}; upgrading")
                        connectEntry(e, isSwitch = true)
                    }
                },
                onStop = { }
            )
            routeFinder.startDiscovery()
            mainHandler.postDelayed({
                if (routeProbeActive) {
                    routeProbeActive = false
                    routeFinder.stopDiscovery()
                }
            }, 2500)
        }
    }

    /** POWER_CONNECTED 的有线升级快速通道。
     *
     * Android 的插线广播与 Mac 上 adb reverse 注册是两个独立事件，第一次探测可能
     * 恰好早于 Mac 的注册完成。这里有界地串行重试，成功即停；无设备/无授权时仍由
     * 同时进行的 Wi‑Fi 连接立即出画面，不把失败变成用户可见等待。 */
    private fun startUsbTunnelUpgradeBurst() {
        val generation = ++usbTunnelBurstGeneration
        fun attempt(remaining: Int) {
            if (generation != usbTunnelBurstGeneration || isFinishing || isWiredTransport()) return
            UsbProbe.probe(this) { ok ->
                if (generation != usbTunnelBurstGeneration || isFinishing || isWiredTransport()) {
                    return@probe
                }
                if (ok) {
                    Log.i(TAG, "adb tunnel became ready after USB plug; upgrading")
                    connectTunnel(isSwitch = session != null)
                } else if (remaining > 0) {
                    mainHandler.postDelayed({ attempt(remaining - 1) }, 250L)
                }
            }
        }
        attempt(3)
    }

    private fun showDiscoveryDialog() {
        nsdFinder.setCallbacks(
            onStart = { statusText.text = "正在搜索局域网内的 Mac…" },
            onHost = { rebuildDiscoveryDialog() },
            onStop = { error ->
                statusText.text = error ?: "发现已停止"
                discoveryDialog?.dismiss()
            }
        )
        nsdFinder.startDiscovery()
        rebuildDiscoveryDialog()
    }

    // MARK: 自动发现（零点击：唯一主机直接连，多台才弹列表，AGENTS.md §7.4）

    private var autoDiscoveryArmed = false
    private val autoDiscoveryTick = Runnable { settleAutoDiscovery() }

    private fun startAutoDiscovery() {
        autoDiscoveryArmed = true
        statusText.text = if (hasUsbUdpNetwork()) {
            "USB 网卡已就绪，正在优先搜索 Mac…"
        } else {
            "未检测到 USB 网卡，正在通过 Wi-Fi 搜索 Mac…（MTP 仅传文件）"
        }
        nsdFinder.setCallbacks(
            onStart = { },
            onHost = {
                // 去抖：发现结果稳定 1.2s 后再决断（避免第一台出现就抢连）
                mainHandler.removeCallbacks(autoDiscoveryTick)
                mainHandler.postDelayed(autoDiscoveryTick, 1200)
            },
            onStop = { error ->
                if (autoDiscoveryArmed) {
                    autoDiscoveryArmed = false
                    statusText.text = error ?: "发现已停止——可扫码或手动输入 IP"
                }
            }
        )
        nsdFinder.startDiscovery()
    }

    private fun settleAutoDiscovery() {
        if (!autoDiscoveryArmed) return
        val endpoints = nsdFinder.currentHosts()
        // 同一台 Mac 可从 USB 与 Wi-Fi 各解析出一个地址；按配对码合并为一台主机，
        // 并在组内选 USB。不能因此误判成“多主机”要求用户点选。
        val hosts = endpoints.groupBy { if (it.code != 0) "code:${it.code}" else "name:${it.name}" }
        when (hosts.size) {
            0 -> {
                // host 未上线：继续等。同时探 adb 隧道——无局域网场景 mDNS 永远
                // 空手而归，隧道（host 侧 adb 轮询注册 reverse 可能慢插线几秒）
                // 是唯一出路，每轮顺带探一次，就绪即连。
                UsbProbe.probe(this) { tunnelOk ->
                    if (tunnelOk && autoDiscoveryArmed && !isFinishing) {
                        autoDiscoveryArmed = false
                        nsdFinder.stopDiscovery()
                        connectTunnel()
                    }
                }
                mainHandler.postDelayed(autoDiscoveryTick, 1200)
            }
            1 -> {
                autoDiscoveryArmed = false
                nsdFinder.stopDiscovery()
                val e = hosts.values.first().minByOrNull {
                    when (it.transport) {
                        NsdFinder.Transport.USB -> 0
                        NsdFinder.Transport.WIFI -> 1
                        NsdFinder.Transport.TUNNEL, NsdFinder.Transport.OTHER -> 2
                    }
                } ?: return
                statusText.text = "发现 ${e.name}（${e.host}），自动连接…"
                connectEntry(e)
            }
            else -> {
                autoDiscoveryArmed = false
                showDiscoveryDialog() // 多台才需要人选
            }
        }
    }

    private fun rebuildDiscoveryDialog() {
        discoveryDialog?.dismiss()
        val hosts = nsdFinder.currentHosts()
        val items = if (hosts.isEmpty()) {
            arrayOf("搜索中…（确认 Mac 正在运行且同一 WiFi）")
        } else {
            hosts.map {
                val tr = when (it.transport) {
                    NsdFinder.Transport.USB -> "USB"
                    NsdFinder.Transport.WIFI -> "Wi-Fi"
                    NsdFinder.Transport.TUNNEL -> "有线"
                    NsdFinder.Transport.OTHER -> "UDP"
                }
                "${it.name} · $tr\n${it.host}:${it.port}"
            }.toTypedArray()
        }
        discoveryDialog = android.app.AlertDialog.Builder(this)
            .setTitle("局域网设备")
            .setItems(items) { _, which ->
                nsdFinder.stopDiscovery()
                hosts.getOrNull(which)?.let { connectEntry(it) }
            }
            .setNegativeButton("取消") { d, _ ->
                nsdFinder.stopDiscovery()
                d.dismiss()
            }
            .show()
    }

    // MARK: 会话回调

    private val sessionListener = object : HostSession.Listener {
        override fun onCursor(displayId: Int, x: Float, y: Float) {
            val lc = localCursor ?: return
            if (displayId == 0) {
                mainHandler.post { lc.hide() }
                return
            }
            val view = regionViews.firstOrNull { it.displayId == displayId } ?: return
            val v = view.streamToView(x, y) ?: return
            val w = windowPos(view, v[0], v[1])
            mainHandler.post {
                // 触摸期间光标保持隐藏（手指即指针），host 推送一律不显示；
                // 抬手后由 finishTouch 的回显接管。
                if (touchMode != 0) return@post
                // 双写者仲裁（2026-08-21 卡顿根因）：触摸期间手指以零延迟驱动本地光标，
                // host 推送（20Hz+网络滞后）无条件覆盖 = 光标被反复拽回 → 顿挫。
                // 规则：250ms 内有手指回显且 host 位置就在附近（<48px）→ 手指权威，丢弃；
                // host 位置远离（Mac 侧真实移动/换屏）→ 照常接管。
                val now = System.currentTimeMillis()
                if (now - lastCursorEchoAt < 250) {
                    val dx = w[0] - lastCursorEchoX; val dy = w[1] - lastCursorEchoY
                    if (dx * dx + dy * dy < 48f * 48f) return@post
                }
                lc.moveTo(w[0], w[1])
            }
        }

        override fun onCursorImage(width: Int, height: Int, hotX: Int, hotY: Int, pixels: ByteArray) {
            val lc = localCursor ?: return
            mainHandler.post { lc.setSystemCursor(width, height, hotX, hotY, pixels) }
        }

        override fun onWelcome(displayId: Int, codec: Int, width: Int, height: Int, fps: Int, controlEnabled: Boolean) {
            mainHandler.post {
                // host 在 WELCOME 里宣告注入能力；用户偏好开启且 host 支持才生效。
                // 旧 host（无注入）恒为 false，自动退回纯显示。
                hostControlSupported = controlEnabled
                applyRemoteControlState()
                val p = pipelineOf(displayId)
                // WELCOME 是这一路编码流的格式边界。拓扑/分辨率切换后 Host 会用同一
                // displayId 建立新的 VideoToolbox 会话；若继续拿旧 MediaCodec（例如
                // 720x960）去解新 1072x1088 流，Android 会把旧 clean aperture 等比
                // 放进新 Surface，留下看似“视频有黑边”的大块空白。清空旧 CSD 后等待
                // 新 CONFIG，绝不以旧参数集抢跑新尺寸的解码器。
                val formatChanged = p.width != width || p.height != height || p.codec != codec
                if (formatChanged) {
                    synchronized(pipelineLock) {
                        p.decoder?.release()
                        p.decoder = null
                        p.csd = null
                        p.lastRendered = 0
                        p.assembler?.reset()
                    }
                    Log.i(TAG, "stream format changed: display=$displayId -> ${width}x${height} codec=$codec")
                }
                p.fps = fps.coerceIn(1, 144)
                p.codec = codec
                p.width = width
                p.height = height
                regionViews.firstOrNull { it.displayId == displayId }?.updateStreamSize(width, height)
                if (formatChanged) session?.requestKeyframe(displayId)
                updateOverlay()
            }
        }

        override fun onConfig(displayId: Int, codec: Int, paramSets: ByteArray) {
            // csd 完整性防御：CONFIG 走不可靠通道，坏参数集会毁掉之后所有解码器重建
            if (paramSets.size < 20 || paramSets[0] != 0x00.toByte() || paramSets[1] != 0x00.toByte()
                || paramSets[2] != 0x00.toByte() || paramSets[3] != 0x01.toByte()) {
                Log.w(TAG, "dropping malformed csd for display=$displayId len=${paramSets.size}")
                return
            }
            val p = pipelineOf(displayId)
            val old = p.csd
            if (old != null && p.decoder != null && !old.contentEquals(paramSets)) {
                mainHandler.post {
                    synchronized(pipelineLock) {
                        p.decoder?.release()
                        p.decoder = null
                        p.lastRendered = 0
                    }
                    p.csd = paramSets
                    maybeStartDecoder(p)
                }
                return
            }
            p.csd = paramSets
            maybeStartDecoder(p)
        }

        override fun onVideoFragment(displayId: Int, frameId: Int, fragIdx: Int, fragCount: Int,
                                     keyframe: Boolean, payload: ByteArray) {
            // fragIdx ≥ fragCount = FEC 校验片（组号 = idx - count）
            val asm = pipelineOf(displayId).assembler ?: return
            if (fragIdx >= fragCount) {
                asm.onParityFragment(frameId, fragIdx - fragCount, payload)
            } else {
                asm.onFragment(frameId, fragIdx, fragCount, keyframe, payload)
            }
        }

        override fun onDisplays(list: List<HostSession.DisplayInfo>) {
            mainHandler.post {
                displays = list
                // Host 只按 HELLO 中持久化的设备档案创建/恢复屏幕；Android 在这里仅订阅。
                // 不再因为 DISPLAYS 的一次刷新反向发 CREATE/DESTROY，避免拓扑 churn。
                // 多屏创建是安全串行的：第一块会先出现、第二块稍后才加入列表。第一块
                // 必须立刻渲染到它的正确半区，不能为了等第二块把整个平板黑住。
                if (list.isNotEmpty()) {
                    val wanted = requestedDisplaySpecs().size.coerceAtLeast(1)
                    waitingForDisplay = false
                    // Host 已按当前 canonical device ID 做过列表过滤，客户端无需再用本地
                    // 安装 ID 猜名称；卸载重装时两者不同会导致“明明有两块却只选一块”。
                    val selected = list.take(wanted)
                    val desiredIds = selected.map { it.id }
                    if (topologyTransitionInFlight && desiredIds.size == wanted &&
                        desiredIds.toSet() != topologyTransitionOldIds) {
                        topologyTransitionExpectedIds = desiredIds.toSet()
                        switchingBannerDetail?.text = "新副屏已建立，正在恢复清晰画面…"
                    }
                    if (regionViews.isEmpty()) {
                    subscribedIds = selected.map { it.id }
                    resetPipelines()
                    rebuildRegionViews()
                    if (subscribedIds.size == 1) {
                        session?.selectDisplay(subscribedIds.first())
                    } else if (subscribedIds.isNotEmpty()) {
                        session?.sendSubscribeDisplays(subscribedIds)
                    }
                    subscribedIds.forEach { session?.requestKeyframe(it) }
                    } else if (desiredIds.isNotEmpty() && desiredIds != subscribedIds) {
                        val oldIds = subscribedIds
                        subscribedIds = desiredIds
                        // 画中画只在后到的第二块屏上增量建小窗，主画面和它的解码器
                        // 不重建，避免把已经稳定的第一画面再次闪黑/闪绿。
                        if (layoutConfig.kind == LayoutKind.PIP && oldIds.size == 1 &&
                            desiredIds.size == 2 && oldIds[0] == desiredIds[0]) {
                            session?.sendSubscribeDisplays(desiredIds)
                            val (sw, sh) = screenDims()
                            buildPipWindow(desiredIds[1], sw, sh)
                            session?.requestKeyframe(desiredIds[1])
                        } else {
                            rebuildRegionViews()
                            session?.sendSubscribeDisplays(desiredIds)
                            desiredIds.forEach { session?.requestKeyframe(it) }
                        }
                    }
                }
                if (list.isEmpty()) waitingForDisplay = true
                reconcileCurrentDeviceDisplayProfile(list)
                updateConfigButton()
            }
        }

        override fun onSavedLayout(layout: HostSession.LayoutState) {
            mainHandler.post {
                // Host 只在“指纹命中、安装内 ID 已变化”时发这个包。它比显示列表先发；
                // 即便 UDP 极端乱序，后续 onDisplays 也会按新布局重新选择完整屏组。
                restoreLayoutFromHost(layout)
                session?.acknowledgeSavedLayout()
                // Host 收到 ACK 前会保护旧档案；确认后再提交本机真实画布。这样旧 APK
                // 遗留的规格不会在重装恢复后永久造成等比黑边。延迟只保证 ACK 先到达，
                // 不会中断当前 UDP 会话。
                mainHandler.postDelayed({
                    session?.updateDisplayTopology(requestedDisplaySpecs(), layoutStateForHost(layoutConfig))
                }, 250L)
            }
        }

        override fun onDisplayModeStatus(transaction: Int, status: Int, slot: Int,
                                         requestedScale: Int, actualScale: Int) {
            mainHandler.post {
                // 旧事务的 UDP 重传不能反过来改掉用户刚刚选择的新配置。
                if (transaction == 0 || transaction != pendingModeTransaction) return@post
                when (status) {
                    0 -> {
                        switchingBannerTitle?.text = "正在验证 Retina…"
                        switchingBannerDetail?.text = "正在确认 Mac 是否真正提供 2x"
                    }
                    1 -> {
                        if (requestedScale == 2 && actualScale != 2) return@post
                        pendingLayoutConfig = null
                        pendingModeTransaction = 0
                        committedLayoutConfig = layoutConfig
                        saveLayoutConfig(layoutConfig)
                        switchingBannerDetail?.text = "实测 ${actualScale}x，正在恢复画面…"
                    }
                    2, 3 -> {
                        var restore = committedLayoutConfig
                        // 上一套已提交配置若同样是 2x，"恢复一次"就是原地打转：再要 2x
                        // 只会再次被拒（host 已记录该组合不支持），屏永远建不出来，
                        // 平板停留在黑屏（2026-09-01）。此时显式退回标准 1x——
                        // 1x 请求不走严格 Retina 拒绝路径，必然能建屏。
                        if (requestedScale == 2 && restore.clarity == 1) {
                            restore = restore.copy(clarity = 0)
                        }
                        layoutConfig = restore
                        pendingLayoutConfig = null
                        pendingModeTransaction = 0
                        saveLayoutConfig(restore)
                        updateConfigButton(); updateOverlay()
                        switchingBannerTitle?.text = if (status == 2) "当前组合不支持 Retina" else "切换未完成"
                        switchingBannerDetail?.text = "已恢复上一套有效显示配置"
                        // Host 已停止失败事务；用上一套“已提交”配置只恢复一次，不进入自动重试。
                        beginTopologyTransition()
                        session?.updateDisplayTopology(requestedDisplaySpecs(restore), layoutStateForHost(restore))
                    }
                }
            }
        }

        override fun onSessionNeedsRediscovery() {
            mainHandler.post {
                if (staleHostRecoveryInFlight || isFinishing) return@post
                staleHostRecoveryInFlight = true
                Log.w(TAG, "saved host has no usable displays; clearing stale route and rediscovering")
                // 这是切换连接候选，而不是用户拔掉设备：不可发 BYE，否则可能把当前
                // Host 正在恢复的同一设备屏幕又立即销毁。新的 mDNS HostEntry 会原子
                // 覆盖地址与配对码，后续 USB 探测仍会自动升级到有线隧道。
                getPreferences(MODE_PRIVATE).edit()
                    .remove("host")
                    .remove("lastWifiHost")
                    .remove("lastUsbHost")
                    .remove("pairingCode")
                    .apply()
                disconnectSession()
                startAutoDiscovery()
            }
        }

        override fun onLinkEvent(connected: Boolean) {
            linkUp = connected
            if (!connected) {
                mainHandler.post {
                    synchronized(pipelineLock) {
                        for (p in pipelines.values) {
                            p.decoder?.release()
                            p.decoder = null
                            p.csd = null
                            p.lastRendered = 0
                        }
                    }
                    for (p in pipelines.values) p.assembler?.reset()
                }
            }
        }
    }

    private fun pipelineOf(id: Int): DisplayPipeline {
        return synchronized(pipelineLock) {
            val existing = pipelines[id]
            if (existing != null) return@synchronized existing
            val p = DisplayPipeline(id)
            p.assembler = FrameAssembler(object : FrameAssembler.Callback {
                override fun onFrame(frameId: Int, keyframe: Boolean, data: ByteArray) {
                    if (keyframe) p.lastKeyframeDeliveredAt = System.currentTimeMillis()
                    // CONFIG 已作为 MediaFormat 的 csd-0 配置解码器；把同一份 VPS/SPS/PPS
                    // 再拼到 IDR 前会让部分华为 HEVC 解码器偶发进入“有输出但全绿”的坏
                    // 状态。若 CONFIG 与 IDR 乱序，FrameAssembler 会请求下一帧关键帧。
                    val decoder = p.decoder ?: return
                    if (!decoder.submit(VideoDecoder.Frame(keyframe, data))) {
                        // 完整 P 帧一旦因解码背压被拒绝，后续依赖帧不能继续跨过缺口。
                        // FrameAssembler 会丢到下一张 IDR，同时把拥塞反馈给 Host。
                        p.assembler?.requireKeyframeAfterDecoderBackpressure(frameId)
                    }
                }
                override fun onKeyframeNeeded(reason: String) {
                    session?.requestKeyframe(p.id)
                }
                override fun onNackKeyframeFragments(frameId: Int, missing: List<Int>) {
                    session?.sendNack(p.id, frameId, missing)
                }
            })
            pipelines[id] = p
            p
        }
    }

    private fun maybeStartDecoder(p: DisplayPipeline) {
        synchronized(pipelineLock) {
            if (p.decoder != null) return
            val csd = p.csd ?: return
            if (p.width <= 0) return
            val surface = p.surface ?: return
            try {
                // 按 host 实际使用的编码选解码器——硬编 HEVC 会话耗尽回退 H.264 时，
                // 若仍开 HEVC 解码器会输出全零（绿屏）
                val mime = if (p.codec == 2) "video/avc" else "video/hevc"
                val d = VideoDecoder(mime, p.width, p.height, p.fps, surface, csd)
                d.start()
                p.decoder = d
                Log.i(TAG, "decoder started: display=${p.id} ${p.width}x${p.height}")
            } catch (e: Exception) {
                Log.e(TAG, "decoder start failed display=${p.id}", e)
            }
        }
    }

    // MARK: 会话视图（分区渲染）

    @SuppressLint("ClickableViewAccessibility")
    private fun showSessionView() {
        root.removeAllViews()
        connectView = null
        hideSystemBarsSoon()
        fun dp(value: Int): Int = (value * resources.displayMetrics.density + 0.5f).toInt()

        val container = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        // 部分 OEM 会在沉浸式切换完成后异步改变可用画布。这里只重新布局客户端的
        // SurfaceView（保留同一解码器/同一虚拟显示器），不能把一次系统 inset 变化
        // 升级成 Mac 端的建屏 churn。
        container.addOnLayoutChangeListener { _, left, top, right, bottom, oldLeft, oldTop, oldRight, oldBottom ->
            if ((right - left) != (oldRight - oldLeft) || (bottom - top) != (oldBottom - oldTop)) {
                container.post {
                    if (sessionRoot === container && container.width > 0 && container.height > 0) {
                        rebuildRegionViews()
                    }
                }
            }
        }
        root.addView(container, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        sessionRoot = container

        // 通道/布局替换的过渡层：背景只轻微压暗，旧画面仍可见；中心卡片带原生旋转
        // 指示器和入场缩放，明确系统正在恢复副屏而不是无故黑屏。
        val banner = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(0x33000000)
            visibility = android.view.View.GONE
        }
        val card = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            // 全部使用 dp：高密度平板上 raw px 会让进度圈与卡片显得极小、贴边时更像被裁掉。
            setPadding(dp(26), dp(18), dp(26), dp(17))
            background = android.graphics.drawable.GradientDrawable().apply {
                setColor(0xE6202938.toInt())
                cornerRadius = 28f
                setStroke(1, 0x556B7C93)
            }
        }
        card.addView(android.widget.ProgressBar(this).apply {
            isIndeterminate = true
            contentDescription = "正在处理显示模式"
        }, android.widget.LinearLayout.LayoutParams(dp(28), dp(28)).apply { bottomMargin = dp(10) })
        val title = android.widget.TextView(this).apply {
            text = "正在切换通道…"
            textSize = 18f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            // 卡片在 root 未完成首次布局时创建会测得极窄宽度且不再重测
            // （实测截断成“正/保留”单字竖排）——最小宽度兜底
            minWidth = dp(240)
        }
        card.addView(title)
        val detail = android.widget.TextView(this).apply {
            text = "画面即将恢复"
            textSize = 12f
            setTextColor(0xFFD0D8E4.toInt())
            gravity = Gravity.CENTER
            setPadding(0, 10, 0, 0)
            minWidth = dp(240)
        }
        card.addView(detail)
        banner.addView(card, android.widget.LinearLayout.LayoutParams(
            android.widget.LinearLayout.LayoutParams.WRAP_CONTENT,
            android.widget.LinearLayout.LayoutParams.WRAP_CONTENT
        ))
        root.addView(banner, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT))
        // 沉浸式/刘海/手势导航会让 root 覆盖到物理边缘。状态层收缩到真实安全区后再
        // 居中，任何 OEM 的边缘裁剪都不会只露出半个 loading 圆环。
        root.setOnApplyWindowInsetsListener { _, insets ->
            val lp = banner.layoutParams as FrameLayout.LayoutParams
            lp.leftMargin = insets.systemWindowInsetLeft
            lp.topMargin = insets.systemWindowInsetTop
            lp.rightMargin = insets.systemWindowInsetRight
            lp.bottomMargin = insets.systemWindowInsetBottom
            banner.layoutParams = lp
            insets
        }
        root.requestApplyInsets()
        switchingBanner = banner
        switchingBannerTitle = title
        switchingBannerDetail = detail

        val overlay = TextView(this).apply {
            text = "等待视频流…"
            textSize = 12f
            setTextColor(Color.WHITE)
            setBackgroundColor(0x66000000)
            setPadding(12, 6, 12, 6)
            // 绿屏逃生口：华为硬解偶发坏会话（流正常但输出全零），长按重建全部解码器即恢复
            setOnLongClickListener {
                bounceAllDecoders()
                true
            }
        }
        root.addView(overlay, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.START))
        statsOverlay = overlay

        // 配置入口：纯图标小药丸（无文字，占地最小），样式与左上传输角标同族。
        val cfgBtn = TextView(this).apply {
            text = "⚙"
            textSize = 14f
            setTextColor(Color.WHITE)
            setPadding(11, 4, 11, 6)
            background = android.graphics.drawable.GradientDrawable().apply {
                setColor(0x99000000.toInt())
                cornerRadius = 18f
            }
            contentDescription = "屏幕配置：分辨率、双屏、画中画"
            setOnClickListener { showConfigPanel() }
        }
        val cfgLp = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.TOP or Gravity.END)
        cfgLp.marginEnd = 12
        cfgLp.topMargin = 10
        root.addView(cfgBtn, cfgLp)
        configButton = cfgBtn

        // 传输角标：左上角常驻小药丸（USB=绿 / Wi-Fi=蓝，断链降透明度）。
        // 统计条（同在左上、含传输明细）呼出期间隐藏，避免重叠。
        val badge = TextView(this).apply {
            text = ""
            textSize = 10f
            setTypeface(Typeface.DEFAULT_BOLD)
            setTextColor(Color.WHITE)
            setPadding(14, 5, 14, 5)
            background = android.graphics.drawable.GradientDrawable().apply {
                setColor(0x99000000.toInt())
                cornerRadius = 18f
            }
        }
        val badgeLp = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.TOP or Gravity.START)
        badgeLp.marginStart = 12
        badgeLp.topMargin = 10
        root.addView(badge, badgeLp)
        transportBadge = badge

        // 统计条默认隐藏；右上角配置常驻。顶部中央小把手只负责临时显示统计信息。
        overlay.visibility = android.view.View.GONE
        cfgBtn.visibility = android.view.View.VISIBLE
        val handle = TextView(this).apply {
            text = "⌄"
            textSize = 14f
            setTextColor(0x40FFFFFF.toInt())
            gravity = Gravity.CENTER
            setPadding(24, 2, 24, 6)
            setOnClickListener { showChrome() }
        }
        root.addView(handle, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.CENTER_HORIZONTAL))
        chromeHandle = handle

        // 本地光标层（最顶层）：手指位置零延迟反馈
        val cursor = LocalCursorView(this)
        root.addView(cursor, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        localCursor = cursor

        rebuildRegionViews()
    }

    /** 绿屏取证：PixelCopy 采三点，特征绿（全零 YUV）→ 重建该屏解码器 */
    private fun detectGreenAndBounce(view: StreamView, p: DisplayPipeline) {
        p.greenChecks++
        val w = view.width; val h = view.height
        if (w <= 0 || h <= 0) return
        val points = listOf(w / 4 to h / 4, w / 2 to h / 2, 3 * w / 4 to 3 * h / 4)
        val results = java.util.concurrent.atomic.AtomicInteger(0)
        var sampled = java.util.concurrent.atomic.AtomicInteger(0)
        for ((px, py) in points) {
            val rect = android.graphics.Rect(px - 2, py - 1, px + 2, py + 1)
            val bmp = android.graphics.Bitmap.createBitmap(4, 2, android.graphics.Bitmap.Config.ARGB_8888)
            try {
                android.view.PixelCopy.request(view, rect, bmp, { _ ->
                    sampled.incrementAndGet()
                    var greens = 0
                    for (i in 0 until 8) {
                        val c = bmp.getPixel(i % 4, i / 4)
                        val r = android.graphics.Color.red(c); val g = android.graphics.Color.green(c); val b = android.graphics.Color.blue(c)
                        if (r < 30 && g in 45..110 && b < 30) greens++
                    }
                    if (greens >= 7) results.incrementAndGet()
                }, mainHandler)
            } catch (_: Exception) { sampled.incrementAndGet() }
        }
        mainHandler.postDelayed({
            if (results.get() >= 2) {
                Log.w(TAG, "GREEN detected (pixel forensics), recover display=" + p.id +
                    " check#" + p.greenChecks + " recoveries=" + greenRecoveries)
                recoverFromGreen()
            }
        }, 400)
    }

    private var greenRecoveries = 0

    /** 绿屏自动恢复（最多两次）：ENCODER_RESET 让 host 只重建编码器会话。
     *  只 bounce 解码器救不了——坏流来自 host 侧编码会话污染；也不能用 RECYCLE
     *  （全量重建会销毁永生屏 → 新 SCStream 在本 macOS 构建上必死 → 黑屏）。 */
    private fun recoverFromGreen() {
        val s = session ?: return
        if (greenRecoveries >= 2) {
            Log.w(TAG, "green recoveries exhausted — leaving manual (long-press)")
            return
        }
        greenRecoveries++
        val id = subscribedIds.firstOrNull() ?: pipelines.keys.firstOrNull()
        if (id != null) {
            Log.w(TAG, "requesting host encoder reset for display=$id (green #$greenRecoveries)")
            s.sendEncoderReset(id)
        }
    }

    /**
     * 把子视图内坐标换算为本地光标叠加层的坐标。
     *
     * 不能把 `getLocationInWindow` 的结果直接喂给 `LocalCursorView`：后者是 root
     * 内的子 View，不是窗口本身。手机的状态栏/挖孔 inset 会令两个原点不同，表现为
     * 鼠标已经指到目标，手机叠加箭头却稳定偏下；平板的 inset 接近零，所以不明显。
     */
    private fun windowPos(view: View, x: Float, y: Float): FloatArray {
        val viewLoc = IntArray(2)
        val overlayLoc = IntArray(2)
        view.getLocationInWindow(viewLoc)
        (localCursor ?: sessionRoot ?: root).getLocationInWindow(overlayLoc)
        return mapPointToOverlay(x, y, viewLoc[0], viewLoc[1], overlayLoc[0], overlayLoc[1])
    }

    private fun screenDims(): Pair<Int, Int> {
        // 使用 Android 已授予本 app 的稳定画布，而不是未经授权可覆盖的物理面板。
        // Redmi Note 7 的 MIUI 横屏会保留一条右侧系统手势区（2131×1080）；按完整
        // 2340×1080 建屏会让等比渲染必然留黑。getMetrics 在沉浸式完成后反映的是
        // 实际可渲染区域，且同一设备/同一系统设置下稳定。
        @Suppress("DEPRECATION")
        val display = windowManager.defaultDisplay
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        display.getMetrics(metrics)
        return DisplayResolution.landscapeCanvas(metrics.widthPixels, metrics.heightPixels)
    }

    /**
     * 重装恢复会优先保留 Host 端的旧显示器档案，保证桌面位置不丢；但旧版本可能
     * 把 MIUI 的可用区域误写成像素规格。检测到规格与当前真实设备不一致时，仅在
     * 本会话发起一次受控替换，保留同一 EDID 身份和 macOS 编排位置。
     */
    private fun reconcileCurrentDeviceDisplayProfile(list: List<HostSession.DisplayInfo>) {
        val desired = requestedDisplaySpecs()
        if (list.size < desired.size || desired.isEmpty()) return
        val actual = list.take(desired.size).map { it.width to it.height }
        // HELLO 发送的是逻辑请求值，Host 在 CGVirtualDisplay 前会按 16px 对齐。
        // 必须与该规则比较，否则 1064×1080 ↔ 1072×1088 会被误判成永久拓扑切换。
        val expected = desired.map { (width, height) -> DisplayResolution.hostAligned(width, height) }
        if (actual == expected) {
            profileSyncRequested = null
            return
        }
        if (profileSyncRequested == expected) return
        profileSyncRequested = expected
        Log.i(TAG, "correcting stale display profile $actual -> $expected")
        beginTopologyTransition()
        session?.updateDisplayTopology(desired, layoutStateForHost(layoutConfig))
    }

    private fun evenOf(v: Int) = (v / 2) * 2

    /** 画中画最小边：约大屏短边的 1/10（用户口径 1/20 太小点不中），下限 160px */
    private fun pipMinSide(sw: Int, sh: Int) = maxOf(160, minOf(sw, sh) / 10)

    private fun pipH0(sh: Int) = evenOf((sh * layoutConfig.fraction).toInt().coerceIn(sh / 4, sh / 2))
    private fun pipW0(rn: Int, rd: Int, sh: Int) = evenOf(pipH0(sh) * rn / rd)

    private fun ratioOf(r: String): Pair<Int, Int> = when (r) {
        "3:2" -> 3 to 2
        "4:3" -> 4 to 3
        "1:1" -> 1 to 1
        else -> 16 to 10
    }

    /** 布局 → 各区域虚拟屏像素尺寸（顺序即订阅顺序，第一个是主屏） */
    private fun regionSizes(cfg: LayoutConfig): List<Pair<Int, Int>> {
        // 这里故意使用整机物理尺寸：它决定 macOS 虚拟屏的原生像素规格。
        // Android 的实际内容区尺寸只用于下面 rebuildRegionViews 的本地排版。
        val (sw, sh) = screenDims()
        val f = cfg.fraction.coerceIn(0.2f, 0.8f)
        return when (cfg.kind) {
            LayoutKind.SINGLE -> emptyList()
            LayoutKind.SPLIT_LR -> {
                val lw = evenOf((sw * f).toInt().coerceIn(sw / 5, sw * 4 / 5))
                listOf(lw to sh, evenOf(sw - lw) to sh)
            }
            LayoutKind.SPLIT_TB -> {
                val th = evenOf((sh * f).toInt().coerceIn(sh / 5, sh * 4 / 5))
                listOf(sw to th, sw to evenOf(sh - th))
            }
            LayoutKind.SIDE -> {
                val sideW = evenOf((sw * f).toInt().coerceIn(sw / 5, sw * 2 / 5))
                listOf(evenOf(sw - sideW) to sh, sideW to sh)
            }
            LayoutKind.PIP -> {
                val minSide = pipMinSide(sw, sh)
                if (cfg.pipCustomW > 0 && cfg.pipCustomH > 0) {
                    // 手指自由缩放过的尺寸：直接采用（夹在最小边与 3/4 屏之间）
                    val w = evenOf(cfg.pipCustomW.coerceIn(minSide, sw * 3 / 4))
                    val h = evenOf(cfg.pipCustomH.coerceIn(minSide, sh * 3 / 4))
                    listOf(sw to sh, w to h)
                } else {
                    val (rn, rd) = ratioOf(cfg.pipRatio)
                    val ph = evenOf((sh * f).toInt().coerceIn(sh / 4, sh / 2))
                    listOf(sw to sh, evenOf(ph * rn / rd) to ph)
                }
            }
        }
    }

    private val decorViews = mutableListOf<View>()
    private val regionWrappers = mutableListOf<FrameLayout>()

    /**
     * 可拖分隔把手：手指拖动时只实时重排本地视图；松手才按新比例受控重建虚拟屏。
     * 触控热区故意比可见细线宽，避免用户必须精确点中一条 1px 的缝。
     */
    @SuppressLint("ClickableViewAccessibility")
    private fun addDivider(container: FrameLayout, vertical: Boolean, pos: Int, sw: Int, sh: Int,
                           minFrac: Float, maxFrac: Float, side: Boolean) {
        val density = resources.displayMetrics.density
        val thickness = (36 * density).toInt()
        val visibleThickness = maxOf(2, (2 * density).toInt())
        val divider = FrameLayout(this).apply {
            contentDescription = if (vertical) "拖动以调整左右屏大小" else "拖动以调整上下屏大小"
            isClickable = true
        }
        val lp = if (vertical) {
            FrameLayout.LayoutParams(thickness, sh, Gravity.TOP or Gravity.START).also { it.leftMargin = pos - thickness / 2 }
        } else {
            FrameLayout.LayoutParams(sw, thickness, Gravity.TOP or Gravity.START).also { it.topMargin = pos - thickness / 2 }
        }
        container.addView(divider, lp)
        decorViews.add(divider)

        // 中央细线 + 小把手只负责提示；外围透明区域才是实际可触控热区。
        val line = View(this).apply { setBackgroundColor(0xD9FFFFFF.toInt()) }
        divider.addView(line, if (vertical) {
            FrameLayout.LayoutParams(visibleThickness, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER)
        } else {
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, visibleThickness, Gravity.CENTER)
        })
        val grip = TextView(this).apply {
            text = if (vertical) "⋮" else "⋯"
            textSize = 25f
            setTextColor(0xEE1D2A3A.toInt())
            setShadowLayer(3f, 0f, 1f, 0x99FFFFFF.toInt())
            gravity = Gravity.CENTER
        }
        divider.addView(grip, FrameLayout.LayoutParams(
            if (vertical) thickness else (52 * density).toInt(),
            if (vertical) (52 * density).toInt() else thickness,
            Gravity.CENTER
        ))

        divider.setOnTouchListener(object : View.OnTouchListener {
            var liveFrac = 0f
            override fun onTouch(v: View, e: MotionEvent): Boolean {
                when (e.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        liveFrac = layoutConfig.fraction
                        v.parent?.requestDisallowInterceptTouchEvent(true)
                    }
                    MotionEvent.ACTION_MOVE -> {
                        val location = IntArray(2)
                        container.getLocationOnScreen(location)
                        val localPosition = if (vertical) e.rawX - location[0] else e.rawY - location[1]
                        val edge = if (vertical) sw else sh
                        val visualFrac = (localPosition / edge).coerceIn(0f, 1f)
                        // “侧边在右”保存的是右侧宽度，分隔条在视觉上则位于 1-f；此前
                        // 直接使用 rawX 会让把手与实际区域错位。
                        val f = (if (side && !layoutConfig.sideLeft) 1f - visualFrac else visualFrac)
                            .coerceIn(minFrac, maxFrac)
                        liveFrac = f
                        // 实时预览：只改视图布局，不动流
                        val p = ((if (side && !layoutConfig.sideLeft) 1f - f else f) * edge).toInt()
                        for (region in regionWrappers) {
                            val rlp = region.layoutParams as FrameLayout.LayoutParams
                            if (vertical) {
                                if (rlp.leftMargin == 0) rlp.width = p
                                else { rlp.leftMargin = p; rlp.width = sw - p }
            } else {
                                if (rlp.topMargin == 0) rlp.height = p
                                else { rlp.topMargin = p; rlp.height = sh - p }
                            }
                            region.layoutParams = rlp
                        }
                        val dlp = divider.layoutParams as FrameLayout.LayoutParams
                        if (vertical) dlp.leftMargin = p - thickness / 2 else dlp.topMargin = p - thickness / 2
                        divider.layoutParams = dlp
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        v.parent?.requestDisallowInterceptTouchEvent(false)
                        if (kotlin.math.abs(liveFrac - layoutConfig.fraction) > 0.015f) {
                            applyLayout(layoutConfig.copy(fraction = liveFrac))
                        }
                    }
                }
                return true
            }
        })
    }

    /** 布局当前配置布置渲染区域 */
    @SuppressLint("ClickableViewAccessibility")
    private fun rebuildRegionViews() {
        val container = sessionRoot ?: return
        // MIUI 10 横屏的 View 测量宽度可能仍是完整面板，而 WindowSurface 实际会在
        // 右侧裁掉系统手势区。副屏规格与视图排版必须共同使用 screenDims() 的稳定
        // 可见画布；否则第二块 SurfaceView 会被裁短，aspect-fit 便留下大面积黑边。
        val (canvasW, canvasH) = screenDims()
        val sw = minOf(container.width, canvasW)
        val sh = minOf(container.height, canvasH)
        if (sw <= 0 || sh <= 0) {
            container.post {
                if (sessionRoot === container) rebuildRegionViews()
            }
            return
        }
        for (v in regionWrappers) container.removeView(v)
        regionWrappers.clear()
        for (v in regionViews) container.removeView(v)
        regionViews.clear()
        for (v in decorViews) container.removeView(v)
        decorViews.clear()
        pipRoot?.let { container.removeView(it) }
        pipRoot = null
        pipHandles.clear()
        pipChip = null
        pipSelected = false
        val ids = subscribedIds.ifEmpty { displays.take(1).map { it.id } }
        if (ids.isEmpty()) return

        fun makeView(id: Int): StreamView {
            val view = StreamView(this)
            view.displayId = id
            // 使用不透明解码 surface，首帧到达前由黑色垫底显示加载态；透明 surface
            // 在部分华为驱动上会把尚未初始化的解码缓冲合成为绿色。
            view.holder.setFormat(android.graphics.PixelFormat.OPAQUE)
            view.onSurfaceReady = { did, surface ->
                val pl = pipelineOf(did)
                pl.surface = surface
                maybeStartDecoder(pl)
                session?.requestKeyframe(did) // 新 surface 需要一帧 IDR 立即点亮
            }
            view.onSurfaceDestroyed = { did ->
                synchronized(pipelineLock) {
                    pipelines[did]?.let { pl ->
                        pl.decoder?.release()
                        pl.decoder = null
                        pl.surface = null
                    }
                }
            }
            view.onTouch = { did, event -> handleTouch(did, view, event); true }
            val pl = pipelineOf(id)
            if (pl.width > 0) view.updateStreamSize(pl.width, pl.height)
            return view
        }

        fun place(v: View, w: Int, h: Int, x: Int, y: Int) {
            val wrap = FrameLayout(this@MainActivity)
            wrap.addView(View(this@MainActivity).apply { setBackgroundColor(Color.BLACK) },
                FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
            wrap.addView(v, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
            val lp = FrameLayout.LayoutParams(w, h, Gravity.TOP or Gravity.START)
            lp.leftMargin = x
            lp.topMargin = y
            container.addView(wrap, lp)
            regionWrappers.add(wrap)
            if (v is StreamView) regionViews.add(v)
        }

        fun pendingSecondScreen(): View = FrameLayout(this@MainActivity).apply {
            setBackgroundColor(0xFF111827.toInt())
            addView(TextView(this@MainActivity).apply {
                text = "正在建立第 2 块副屏…"
                textSize = 15f
                setTextColor(0xFFD1D5DB.toInt())
                gravity = Gravity.CENTER
            }, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            ))
        }

        when (layoutConfig.kind) {
            LayoutKind.SINGLE -> {
                place(makeView(ids[0]), sw, sh, 0, 0)
            }
            LayoutKind.SPLIT_LR -> {
                val lw = evenOf((sw * layoutConfig.fraction).toInt().coerceIn(sw / 5, sw * 4 / 5))
                if (ids.size >= 2) {
                    place(makeView(ids[0]), lw, sh, 0, 0)
                    place(makeView(ids[1]), evenOf(sw - lw), sh, lw, 0)
                } else {
                    // 第一块先在正确半区出画，避免为安全串行建第二块而整屏黑 8 秒。
                    place(makeView(ids[0]), lw, sh, 0, 0)
                    place(pendingSecondScreen(), evenOf(sw - lw), sh, lw, 0)
                }
                addDivider(container, true, lw, sw, sh, 0.3f, 0.7f, false)
            }
            LayoutKind.SPLIT_TB -> {
                val th = evenOf((sh * layoutConfig.fraction).toInt().coerceIn(sh / 5, sh * 4 / 5))
                if (ids.size >= 2) {
                    place(makeView(ids[0]), sw, th, 0, 0)
                    place(makeView(ids[1]), sw, evenOf(sh - th), 0, th)
                } else {
                    place(makeView(ids[0]), sw, th, 0, 0)
                    place(pendingSecondScreen(), sw, evenOf(sh - th), 0, th)
                }
                addDivider(container, false, th, sw, sh, 0.3f, 0.7f, false)
            }
            LayoutKind.SIDE -> {
                val sideW = evenOf((sw * layoutConfig.fraction).toInt().coerceIn(sw / 5, sw * 2 / 5))
                if (ids.size >= 2) {
                    val main = makeView(ids[0]); val side = makeView(ids[1])
                    if (layoutConfig.sideLeft) {
                        place(side, sideW, sh, 0, 0)
                        place(main, evenOf(sw - sideW), sh, sideW, 0)
                    } else {
                        place(main, evenOf(sw - sideW), sh, 0, 0)
                        place(side, sideW, sh, evenOf(sw - sideW), 0)
                    }
                } else if (layoutConfig.sideLeft) {
                    place(pendingSecondScreen(), sideW, sh, 0, 0)
                    place(makeView(ids[0]), evenOf(sw - sideW), sh, sideW, 0)
                } else {
                    place(makeView(ids[0]), evenOf(sw - sideW), sh, 0, 0)
                    place(pendingSecondScreen(), sideW, sh, evenOf(sw - sideW), 0)
                }
                addDivider(container, true,
                    if (layoutConfig.sideLeft) sideW else sw - sideW,
                    sw, sh, 0.2f, 0.4f, true)
            }
            LayoutKind.PIP -> {
                place(makeView(ids[0]), sw, sh, 0, 0)
                if (ids.size >= 2) buildPipWindow(ids[1], sw, sh)
            }
        }
    }

    /** 画中画悬浮窗：轻点=选中（仅选中时显示 8 个小方块手柄）；选中态按住中间拖动整窗（偏移量） */
    @SuppressLint("ClickableViewAccessibility")
    private fun buildPipWindow(displayId: Int, sw: Int, sh: Int) {
        val container = sessionRoot ?: return
        val (rn, rd) = ratioOf(layoutConfig.pipRatio)
        val minSide = pipMinSide(sw, sh)
        var pipH: Int
        var pipW: Int
        if (layoutConfig.pipCustomW > 0 && layoutConfig.pipCustomH > 0) {
            pipW = layoutConfig.pipCustomW.coerceIn(minSide, sw * 3 / 4)
            pipH = layoutConfig.pipCustomH.coerceIn(minSide, sh * 3 / 4)
        } else {
            pipH = (sh * layoutConfig.fraction).toInt().coerceIn(sh / 4, sh / 2)
            pipW = pipH * rn / rd
        }
        val root = FrameLayout(this)
        // 黑色垫底：surface 首帧到达前保持黑色（替代曾导致 MediaCodec configure 失败的 lockCanvas 方案）
        root.addView(View(this).apply { setBackgroundColor(Color.BLACK) }, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))

        val view = StreamView(this)
        view.displayId = displayId
        view.holder.setFormat(android.graphics.PixelFormat.OPAQUE)
        view.setZOrderMediaOverlay(true)
        view.onSurfaceReady = { did, surface ->
            val pl = pipelineOf(did)
            pl.surface = surface
            maybeStartDecoder(pl)
            session?.requestKeyframe(did)
        }
        view.onSurfaceDestroyed = { did ->
            synchronized(pipelineLock) {
                pipelines[did]?.let { pl ->
                    pl.decoder?.release()
                    pl.decoder = null
                    pl.surface = null
                }
            }
        }
        val pl = pipelineOf(displayId)
        if (pl.width > 0) view.updateStreamSize(pl.width, pl.height)
        root.addView(view, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        regionViews.add(view)

        // 选中态：中间拖动=移动窗口；未选中：轻点=选中（不点 Mac），按住拖=远程操作
        view.onTouch = { did, event ->
            if (pipSelected) {
                movePipByTouch(root, event, sw, sh)
                true
            } else {
                pipUnselectedTouch(view, did, event, root)
            }
        }

        // 8 个缩放手柄：四角 + 四边中点（web 端样式：小白方块；触摸热区 44dp 全在窗口内，
        // 避免点手柄时手指落到窗外被「点外部=取消选中」吃掉）
        val touchD = (44 * resources.displayMetrics.density).toInt()
        val visualD = (12 * resources.displayMetrics.density).toInt()
        fun handleGravity(role: String): Int = when (role) {
            "TL" -> Gravity.TOP or Gravity.START
            "TR" -> Gravity.TOP or Gravity.END
            "BL" -> Gravity.BOTTOM or Gravity.START
            "BR" -> Gravity.BOTTOM or Gravity.END
            "T" -> Gravity.TOP or Gravity.CENTER_HORIZONTAL
            "B" -> Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            "L" -> Gravity.START or Gravity.CENTER_VERTICAL
            else -> Gravity.END or Gravity.CENTER_VERTICAL
        }
        for (role in listOf("TL", "TR", "BL", "BR", "T", "B", "L", "R")) {
            // 热区容器（44dp，透明）+ 居中的 12dp 视觉小方块
            val h = FrameLayout(this).apply { visibility = View.GONE }
            val dot = View(this).apply {
                background = android.graphics.drawable.GradientDrawable().apply {
                    setColor(0xFFFFFFFF.toInt())
                    setStroke(2, 0xFF1565C0.toInt())
                    cornerRadius = 3f
                }
            }
            h.addView(dot, FrameLayout.LayoutParams(visualD, visualD, Gravity.CENTER))
            val hlp = FrameLayout.LayoutParams(touchD, touchD, handleGravity(role))
            root.addView(h, hlp)
            pipHandles.add(h)
            h.setOnTouchListener(object : View.OnTouchListener {
                var x0 = 0f; var y0 = 0f; var l0 = 0; var t0 = 0; var w0 = 0; var hh0 = 0
                override fun onTouch(v: View, e: MotionEvent): Boolean {
                    when (e.actionMasked) {
                        MotionEvent.ACTION_DOWN -> {
                            x0 = e.rawX; y0 = e.rawY
                            l0 = pipLeft; t0 = pipTop; w0 = pipW; hh0 = pipH
                        }
                        MotionEvent.ACTION_MOVE -> {
                            val dx = (e.rawX - x0).toInt(); val dy = (e.rawY - y0).toInt()
                            var L = l0; var T = t0; var W = w0; var H = hh0
                            when (role) {
                                "TL" -> { L = l0 + dx; T = t0 + dy; W = w0 - dx; H = hh0 - dy }
                                "TR" -> { T = t0 + dy; W = w0 + dx; H = hh0 - dy }
                                "BL" -> { L = l0 + dx; W = w0 - dx; H = hh0 + dy }
                                "BR" -> { W = w0 + dx; H = hh0 + dy }
                                "T" -> { T = t0 + dy; H = hh0 - dy }
                                "B" -> { H = hh0 + dy }
                                "L" -> { L = l0 + dx; W = w0 - dx }
                                "R" -> { W = w0 + dx }
                            }
                            // 尺寸夹取；左/上柄同时校正位置，保证对边固定
                            W = W.coerceIn(minSide, sw * 3 / 4)
                            H = H.coerceIn(minSide, sh * 3 / 4)
                            if (role.contains("L")) L = (l0 + w0) - W
                            if (role == "T" || role == "TL" || role == "TR") T = (t0 + hh0) - H
                            pipW = W; pipH = H
                            pipLeft = L.coerceIn(0, (sw - W).coerceAtLeast(0))
                            pipTop = T.coerceIn(0, (sh - H).coerceAtLeast(0))
                            val pp = root.layoutParams as FrameLayout.LayoutParams
                            pp.width = W; pp.height = H
                            pp.leftMargin = pipLeft; pp.topMargin = pipTop
                            root.layoutParams = pp
                        }
                        MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                            val newW = evenOf(pipW); val newH = evenOf(pipH)
                            val oldW = layoutConfig.pipCustomW.takeIf { it > 0 } ?: pipW0(rn, rd, sh)
                            val oldH = layoutConfig.pipCustomH.takeIf { it > 0 } ?: pipH0(sh)
                            if (kotlin.math.abs(newW - oldW) > 24 || kotlin.math.abs(newH - oldH) > 24) {
                                applyLayout(layoutConfig.copy(pipCustomW = newW, pipCustomH = newH))
                            }
                        }
                    }
                    return true
                }
            })
        }

        val lp = FrameLayout.LayoutParams(pipW, pipH, Gravity.TOP or Gravity.START)
        if (pipLeft < 0) { pipLeft = sw - pipW - 48; pipTop = 48 }
        lp.leftMargin = pipLeft.coerceIn(0, (sw - pipW).coerceAtLeast(0))
        lp.topMargin = pipTop.coerceIn(0, (sh - pipH).coerceAtLeast(0))
        container.addView(root, lp)
        pipRoot = root
        setPipSelected(root, false)
    }

    /** 未选中画中画的触摸：轻点(<400ms 未移动)=选中且不点 Mac；移动超阈值=远程拖动
     *  （按下延迟到确认拖动后才发，轻点选中不会在 Mac 上留下点击） */
    @SuppressLint("ClickableViewAccessibility")
    private fun pipUnselectedTouch(view: StreamView, did: Int, e: MotionEvent, root: FrameLayout): Boolean {
        val s = session ?: return false
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                pipTapStartX = e.rawX; pipTapStartY = e.rawY
                pipTapAt = System.currentTimeMillis()
                pipDragActivated = false
            }
            MotionEvent.ACTION_MOVE -> {
                if (!pipDragActivated) {
                    val moved = kotlin.math.abs(e.rawX - pipTapStartX) > 24 ||
                        kotlin.math.abs(e.rawY - pipTapStartY) > 24
                    if (!moved) return true
                    pipDragActivated = true
                    view.viewToStream(e.x, e.y)?.let { s.sendButton(did, 0, true, it[0], it[1]) }
                }
                view.viewToStream(e.x, e.y)?.let { s.sendMove(did, it[0], it[1]) }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (!pipDragActivated) {
                    if (System.currentTimeMillis() - pipTapAt < 400) {
                        setPipSelected(root, true) // 轻点=选中
                    } else {
                        view.viewToStream(e.x, e.y)?.let { pt ->
                            s.sendMove(did, pt[0], pt[1])
                            s.sendButton(did, 0, true, pt[0], pt[1])
                            s.sendButton(did, 0, false, pt[0], pt[1])
                        }
                    }
                } else if (e.actionMasked == MotionEvent.ACTION_UP) {
                    view.viewToStream(e.x, e.y)?.let { pt -> s.sendButton(did, 0, false, pt[0], pt[1]) }
                }
            }
        }
        return true
    }

    /** 选中/取消选中：显示 8 手柄 + 高亮边框 */
    private fun setPipSelected(root: FrameLayout, on: Boolean) {
        pipSelected = on
        for (h in pipHandles) h.visibility = if (on) View.VISIBLE else View.GONE
        val bg = android.graphics.drawable.GradientDrawable().apply {
            setStroke(if (on) 4 else 2, if (on) 0xFF1976D2.toInt() else 0x33000000)
        }
        root.background = bg
    }

    private var moveStartRawX = 0f
    private var moveStartRawY = 0f
    private var moveStartL = 0
    private var moveStartT = 0
    // 光标双写者仲裁：手指回显的最后位置/时刻（handleTouch 写，onCursor 读）
    private var lastCursorEchoAt = 0L
    private var lastCursorEchoX = 0f
    private var lastCursorEchoY = 0f

    /** 手指拖动整窗：纯偏移量（按下点与窗口的相对关系保持不变，不吸附、不跳动） */
    private fun movePipByTouch(root: FrameLayout, e: MotionEvent, sw: Int, sh: Int) {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                moveStartRawX = e.rawX; moveStartRawY = e.rawY
                val p = root.layoutParams as FrameLayout.LayoutParams
                moveStartL = p.leftMargin; moveStartT = p.topMargin
            }
            MotionEvent.ACTION_MOVE -> {
                val p = root.layoutParams as FrameLayout.LayoutParams
                val w = p.width; val h = p.height
                pipLeft = (moveStartL + (e.rawX - moveStartRawX).toInt())
                    .coerceIn(0, (sw - w).coerceAtLeast(0))
                pipTop = (moveStartT + (e.rawY - moveStartRawY).toInt())
                    .coerceIn(0, (sh - h).coerceAtLeast(0))
                p.leftMargin = pipLeft; p.topMargin = pipTop
                root.layoutParams = p
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> saveLayoutConfig(layoutConfig)
        }
    }

    // MARK: 屏幕配置面板

    private fun showConfigPanel() {
        val pad = (16 * resources.displayMetrics.density).toInt()
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad / 2, pad, 0)
        }

        var selected = layoutConfig.kind
        lateinit var refreshParams: () -> Unit
        val radio = android.widget.RadioGroup(this).apply { orientation = android.widget.RadioGroup.VERTICAL }
        val kindBtns = LinkedHashMap<LayoutKind, android.widget.RadioButton>()
        for (k in LayoutKind.values()) {
            val rb = android.widget.RadioButton(this).apply {
                // 动态加入 RadioGroup 的 RadioButton 不会自动拿到稳定 ID；没有 ID 时
                // 多个选项可同时 checked，onCheckedChange 又会错误命中首个“单屏”。
                // 这会让“左右分屏/上下分屏”在 UI 看似选中但提交后仍是单屏。
                id = View.generateViewId()
                text = k.label
                isChecked = k == layoutConfig.kind
            }
            kindBtns[k] = rb
            radio.addView(rb)
        }
        radio.setOnCheckedChangeListener { _, id ->
            kindBtns.entries.firstOrNull { it.value.id == id }?.let { selected = it.key; refreshParams() }
        }
        panel.addView(radio)

        // 显示大小与清晰度是两件事：前者决定 Mac 内容看起来多大，后者只决定
        // 真实 1x/2x backing。Retina 失败时绝不悄悄降级，Host 会回报实际倍率。
        panel.addView(TextView(this).apply {
            val nativeLongEdge = maxOf(screenDims().first, screenDims().second)
            val current = if (layoutConfig.displayLongEdge == 0) "原生 ${nativeLongEdge}p" else "${layoutConfig.displayLongEdge}p"
            text = "显示大小（当前：${DisplayResolution.label(layoutConfig.displayLongEdge)} · $current）"
            textSize = 13f
            setPadding(0, 20, 0, 4)
        })
        val tiers = listOf("原生" to DisplayResolution.NATIVE, "特大" to 1440,
            "大" to 1600, "标准" to 1920, "紧凑" to 2240)
        val tierRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        tiers.forEach { (label, longEdge) ->
            tierRow.addView(android.widget.Button(this).apply {
                text = label
                textSize = 13f
                setOnClickListener {
                    // 档位与布局共用同一条“会话内受控更新”路径：保留旧画面，等新屏首帧。
                    Log.i(TAG, "tier switch -> $label; updating display profile in session")
                    applyLayout(layoutConfig.copy(displayLongEdge = longEdge))
                }
            }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        }
        panel.addView(tierRow)

        panel.addView(TextView(this).apply {
            val current = if (layoutConfig.clarity == 1) "Retina 2x（需实测支持）" else "标准 1x"
            text = "显示清晰度（当前：$current）"
            textSize = 13f
            setPadding(0, 16, 0, 4)
        })
        val clarityRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        listOf("标准 1x" to 0, "Retina 2x" to 1).forEach { (label, clarity) ->
            clarityRow.addView(android.widget.Button(this).apply {
                text = label
                textSize = 13f
                setOnClickListener {
                    if (clarity == 1) {
                        scheduleSwitchingBanner("正在验证 Retina…", "只有实际 2x 才会应用", 0)
                    }
                    applyLayout(layoutConfig.copy(clarity = clarity))
                }
            }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        }
        panel.addView(clarityRow)

        // 触控远控：点按=鼠标左键、双指滚动=滚轮、双指轻点=右键、三指拖动=中键。
        // 用户偏好持久化；是否真正生效还取决于 host 能力（WELCOME 协商）。
        panel.addView(android.widget.CheckBox(this).apply {
            text = "触控远控（点按/双指滚动/双指点右键/三指中键）"
            textSize = 13f
            setPadding(0, 18, 0, 0)
            isChecked = remoteControlUserPref
            setOnCheckedChangeListener { _, checked ->
                remoteControlUserPref = checked
                getSharedPreferences("hyperdisplay", MODE_PRIVATE).edit()
                    .putBoolean("remoteControl", checked).apply()
                applyRemoteControlState()
            }
        })
        panel.addView(TextView(this).apply {
            text = "首次使用时 Mac 会弹出「辅助功能」授权引导，允许后立即生效。" +
                "若 Mac 未弹窗，请检查 Mac 端 Hyperdisplay 是否在运行。"
            textSize = 11f
            setPadding(pad / 2, 2, pad / 2, 6)
        })

        // 参数区（随所选布局刷新）
        var frac = layoutConfig.fraction
        var sideLeft = layoutConfig.sideLeft
        var pipRatio = layoutConfig.pipRatio
        val paramsBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        panel.addView(paramsBox)

        fun seek(labelFmt: String, minPct: Int, maxPct: Int, get: () -> Int, set: (Int) -> Unit) {
            val row = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
            val label = TextView(this)
            val seek = android.widget.SeekBar(this).apply {
                max = maxPct - minPct
                progress = get() - minPct
                setOnSeekBarChangeListener(object : android.widget.SeekBar.OnSeekBarChangeListener {
                    override fun onProgressChanged(s: android.widget.SeekBar?, v: Int, fromUser: Boolean) {
                        set(v + minPct)
                        label.text = String.format(labelFmt, v + minPct)
                    }
                    override fun onStartTrackingTouch(s: android.widget.SeekBar?) {}
                    override fun onStopTrackingTouch(s: android.widget.SeekBar?) {}
                })
            }
            label.text = String.format(labelFmt, get())
            row.addView(label)
            row.addView(seek, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
            paramsBox.addView(row)
        }

        refreshParams = {
            paramsBox.removeAllViews()
            when (selected) {
                LayoutKind.SINGLE -> {
                    paramsBox.addView(TextView(this).apply {
                        text = "全屏显示一块虚拟屏。当前：${'$'}{displays.size} 块\n" + displays.mapIndexed { i, d -> "  ${'$'}{i + 1}. ${'$'}{d.width}×${'$'}{d.height}" }.joinToString("\n")
                        textSize = 12f
                    })
                }
                LayoutKind.SPLIT_LR -> seek("左右分割：%d%%", 30, 70, { (frac * 100).toInt() }) { frac = it / 100f }
                LayoutKind.SPLIT_TB -> seek("上下分割：%d%%", 30, 70, { (frac * 100).toInt() }) { frac = it / 100f }
                LayoutKind.SIDE -> {
                    seek("侧边宽度：%d%%", 20, 40, { (frac * 100).toInt() }) { frac = it / 100f }
                    val cb = android.widget.CheckBox(this).apply {
                        text = "侧边放左边"
                        isChecked = sideLeft
                        setOnCheckedChangeListener { _, c -> sideLeft = c }
                    }
                    paramsBox.addView(cb)
                }
                LayoutKind.PIP -> {
                    seek("画中画高度：%d%%", 25, 50, { (frac * 100).toInt() }) { frac = it / 100f }
                    val rlab = TextView(this).apply { text = "画中画宽高比：" }
                    val rg = android.widget.RadioGroup(this).apply { orientation = android.widget.RadioGroup.HORIZONTAL }
                    for (r in listOf("16:10", "3:2", "4:3", "1:1")) {
                        val rb = android.widget.RadioButton(this).apply {
                            text = r
                            isChecked = r == pipRatio
                            setOnCheckedChangeListener { _, c -> if (c) pipRatio = r }
                        }
                        rg.addView(rb)
                    }
                    paramsBox.addView(rlab)
                    paramsBox.addView(rg)
                }
            }
        }

        android.app.AlertDialog.Builder(this)
            .setTitle("屏幕布局配置")
            .setView(panel)
            .setPositiveButton("应用") { d, _ ->
                d.dismiss()
                applyLayout(layoutConfig.copy(kind = selected, fraction = frac, sideLeft = sideLeft, pipRatio = pipRatio))
            }
            .setNegativeButton("取消", null)
            .show()
    }

    // MARK: 布局应用引擎

    private fun applyLayout(cfg: LayoutConfig) {
        val previous = layoutConfig
        val changed = previous != cfg
        val virtualScreenChange = previous.kind != cfg.kind ||
            previous.clarity != cfg.clarity ||
            requestedDisplaySpecs(previous) != requestedDisplaySpecs(cfg)
        layoutConfig = cfg
        greenRecoveries = 0
        updateConfigButton(); updateOverlay()
        // 真实虚拟屏尺寸仍需 Host 受控替换，但无需断开 Android 的 UDP 会话，更不能
        // 预先释放旧 Surface/解码器。旧画面保留到完整新屏组出现后才一次性切换。
        if (changed && session != null) {
            Log.i(TAG, "display profile changed: in-session topology update")
            if (virtualScreenChange) {
                pendingLayoutConfig = cfg
                pendingModeTransaction = nextModeTransaction++
                beginTopologyTransition()
                session?.updateDisplayTopology(requestedDisplaySpecs(), layoutStateForHost(cfg, pendingModeTransaction))
            } else {
                saveLayoutConfig(cfg)
                committedLayoutConfig = cfg
                session?.updateDisplayTopology(requestedDisplaySpecs(), layoutStateForHost(cfg))
            }
        } else if (changed) {
            // 离线只保存用户已明确选择的布局；下一次连接仍会对 Retina 做严格验证。
            saveLayoutConfig(cfg)
            committedLayoutConfig = cfg
        }
    }

    /** 切换布局/屏集后清空全部解码管线，等各屏 WELCOME/CONFIG 重建 */
    private fun resetPipelines() {
        synchronized(pipelineLock) {
            for (p in pipelines.values) {
                p.decoder?.release()
                p.assembler?.reset()
            }
            pipelines.clear()
        }
        for (v in regionViews) pipelineOf(v.displayId)
        lastWatchdogKfAt = 0
    }

    private fun updateConfigButton() {
        val button = configButton ?: return
        // 纯图标不占版面；布局状态进无障碍描述，明细仍在统计条/配置面板里。
        button.contentDescription = "屏幕配置：" + layoutConfig.kind.label +
            (if (subscribedIds.size > 1) "，${subscribedIds.size} 屏" else "")
    }

    // MARK: 触摸 → 输入（按区域路由）

    /** 触控远控生效 = 用户偏好（配置面板）∧ host 在 WELCOME 宣告支持。 */
    private fun applyRemoteControlState() {
        val on = remoteControlUserPref && hostControlSupported
        remoteControlEnabled = on
        session?.setRemoteControlEnabled(on)
    }

    // 手势状态机（2026-09-04 重构为 slop 判定模型）：
    // 0=idle 1=按下待定 2=左键拖动 3=双指滚轮 4=双指点(右键)待定 5=三指中键 6=已消费
    // 原则：动作在「抬起」或「移动越界」时才定性，绝不在 ACTION_DOWN 瞬间发左键。
    // 旧版按下即发 button-down，第二根手指落下只能补发 button-up——双指滚动前必先
    // 闪一次幻影左键点击（在视频页面=暂停/播放各一次）。
    private var touchMode = 0
    /** 手势归属的屏。运动事件会按屏拆分派发，手势进行中其他屏的手指一律忽略，
     * 防止两块屏各拿半套共享状态互相踩。 */
    private var touchView: StreamView? = null
    private var touchDownX = 0f
    private var touchDownY = 0f
    private var secondFingerDownAt = 0L
    private var wheelLastX = 0f
    private var wheelLastY = 0f
    // by lazy：Activity 构造期 base context 尚未附加，字段初始化器里调
    // ViewConfiguration.get(this) 会 NPE 启动即崩（2026-09-04 真机实锤）。
    private val touchSlopSq: Float by lazy {
        val slop = android.view.ViewConfiguration.get(this).scaledTouchSlop.toFloat()
        slop * slop
    }
    private val twoFingerTapMs = 220L

    /** 全部指针的流坐标质心（三指手势/滚轮锚点用）。 */
    private fun centroid(view: StreamView, event: MotionEvent): FloatArray? {
        val n = event.pointerCount
        if (n == 0) return null
        var sx = 0f; var sy = 0f
        for (i in 0 until n) { sx += event.getX(i); sy += event.getY(i) }
        return view.viewToStream(sx / n, sy / n)
    }

    private fun handleTouch(displayId: Int, view: StreamView, event: MotionEvent) {
        if (!remoteControlEnabled) return
        val s = session ?: return
        if (touchMode != 0 && touchView !== view) return
        // 画中画处于选中（编辑）态时，第一次点其他区域=退出选中，不透传给 Mac
        if (pipSelected && event.actionMasked == MotionEvent.ACTION_DOWN && pipRoot != null) {
            pipRoot?.let { setPipSelected(it, false) }
            return
        }
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                touchView = view
                touchMode = 1
                touchDownX = event.x
                touchDownY = event.y
                secondFingerDownAt = 0L
                // 手指即指针：触摸期间隐藏本地光标，抬手后再回显——治「点击后
                // 光标飞回原位」的飘感（见 finishTouch）。
                localCursor?.hide()
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                val count = event.pointerCount
                if (count == 2 && touchMode == 1) {
                    touchMode = 4
                    secondFingerDownAt = System.currentTimeMillis()
                    wheelLastX = (event.getX(0) + event.getX(1)) / 2f
                    wheelLastY = (event.getY(0) + event.getY(1)) / 2f
                } else if (count >= 3 && (touchMode == 1 || touchMode == 4)) {
                    // 三指=中键：落下即按住、移动拖动、抬手释放；快速三指点=中键点击。
                    val c = centroid(view, event)
                    if (c != null) {
                        touchMode = 5
                        s.sendMove(displayId, c[0], c[1])
                        s.sendButton(displayId, 2, true, c[0], c[1])
                    }
                }
            }
            MotionEvent.ACTION_MOVE -> {
                when (touchMode) {
                    1 -> {
                        val dx = event.x - touchDownX
                        val dy = event.y - touchDownY
                        if (dx * dx + dy * dy > touchSlopSq) {
                            // 越界才定性为左键拖动：先定位再按下，保证落点正确。
                            val p = view.viewToStream(event.x, event.y) ?: return
                            touchMode = 2
                            s.sendMove(displayId, p[0], p[1])
                            s.sendButton(displayId, 0, true, p[0], p[1])
                        }
                    }
                    2 -> view.viewToStream(event.x, event.y)?.let { s.sendMove(displayId, it[0], it[1]) }
                    3 -> {
                        val cx = (event.getX(0) + event.getX(1)) / 2f
                        val cy = (event.getY(0) + event.getY(1)) / 2f
                        val dx = cx - wheelLastX
                        val dy = cy - wheelLastY
                        wheelLastX = cx
                        wheelLastY = cy
                        if (dx != 0f || dy != 0f) {
                            view.viewToStream(cx, cy)?.let { s.sendWheel(displayId, dx, dy, it[0], it[1]) }
                        }
                    }
                    4 -> {
                        val cx = (event.getX(0) + event.getX(1)) / 2f
                        val cy = (event.getY(0) + event.getY(1)) / 2f
                        val dx = cx - wheelLastX
                        val dy = cy - wheelLastY
                        if (dx * dx + dy * dy > touchSlopSq) touchMode = 3 // 双指移动越界 → 滚轮
                    }
                    5 -> centroid(view, event)?.let { s.sendMove(displayId, it[0], it[1]) }
                }
            }
            MotionEvent.ACTION_POINTER_UP -> {
                val count = event.pointerCount // 含正在抬起的手指
                if (count == 2 && touchMode == 4) {
                    if (System.currentTimeMillis() - secondFingerDownAt < twoFingerTapMs) {
                        // 双指轻点=右键：在双指中点完成一次右键点击。
                        val cx = (event.getX(0) + event.getX(1)) / 2f
                        val cy = (event.getY(0) + event.getY(1)) / 2f
                        view.viewToStream(cx, cy)?.let { p ->
                            s.sendMove(displayId, p[0], p[1])
                            s.sendButton(displayId, 1, true, p[0], p[1])
                            s.sendButton(displayId, 1, false, p[0], p[1])
                        }
                    }
                    // 按得太久=取消：既不是点击也不进滚轮。剩余手指只负责抬手。
                    touchMode = 6
                } else if (count == 2 && touchMode == 3) {
                    touchMode = 6 // 滚轮结束：剩余单指抬起不得触发点击
                } else if (count == 2 && touchMode == 5) {
                    centroid(view, event)?.let { s.sendButton(displayId, 2, false, it[0], it[1]) }
                    touchMode = 6
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                when (touchMode) {
                    1 -> view.viewToStream(event.x, event.y)?.let { p ->
                        // 纯点按：抬起时一次性完成按下+抬起（native 触屏语义）。
                        s.sendMove(displayId, p[0], p[1])
                        s.sendButton(displayId, 0, true, p[0], p[1])
                        s.sendButton(displayId, 0, false, p[0], p[1])
                    }
                    2 -> view.viewToStream(event.x, event.y)?.let { p ->
                        // CANCEL 同样释放，防止 Mac 侧按键卡死。
                        s.sendButton(displayId, 0, false, p[0], p[1])
                    }
                    5 -> centroid(view, event)?.let { s.sendButton(displayId, 2, false, it[0], it[1]) }
                }
                finishTouch(view, event)
            }
        }
    }

    /** 触摸收尾：复位手势并以抬起点为回显位。注入成功时 Mac 光标已在抬起点
     *  （拖动期间 host 光标推送被抑制），120ms 后重新显示；期间到达的 host 光标包
     *  由既有双写者仲裁处理（近=丢弃、远=接管）。可见的「光标飞回原位」就此消失。 */
    private fun finishTouch(view: StreamView, event: MotionEvent) {
        touchMode = 0
        touchView = null
        val w = windowPos(view, event.x, event.y)
        lastCursorEchoAt = System.currentTimeMillis()
        lastCursorEchoX = w[0]; lastCursorEchoY = w[1]
        mainHandler.postDelayed({
            if (touchMode == 0) localCursor?.moveTo(lastCursorEchoX, lastCursorEchoY)
        }, 120)
    }

    /** 重建全部解码管线（等效重启 app 的解码部分，不丢布局/连接） */
    private fun bounceAllDecoders() {
        val s = session ?: return
        val ids = subscribedIds.toList()
        if (ids.isEmpty()) return
        resetPipelines()
        rebuildRegionViews()
        s.sendSubscribeDisplays(ids)
        for (id in ids) s.requestKeyframe(id)
        Log.i(TAG, "decoder bounce: " + ids.joinToString())
    }

    // MARK: 状态

    private fun updateOverlay() {
        // 传输角标独立于统计条更新（统计条默认隐藏，角标常驻）
        transportBadge?.let { b ->
            when {
                isWiredTransport() -> {
                    b.text = "⚡USB"
                    b.setTextColor(0xFF6CE86C.toInt())
                }
                activeTransport == NsdFinder.Transport.WIFI -> {
                    b.text = "📶Wi-Fi"
                    b.setTextColor(0xFF6CB6FF.toInt())
                }
                else -> {
                    b.text = "·UDP"
                    b.setTextColor(Color.WHITE)
                }
            }
            b.alpha = if (linkUp) 1f else 0.45f
        }
        val overlay = statsOverlay ?: return
        val link = if (linkUp) "链路 OK" else "等待主机…"
        val screens = if (subscribedIds.size > 1) {
            "${subscribedIds.size} 屏"
        } else {
            val p = pipelines.values.firstOrNull()
            if (p != null && p.width > 0) "${p.width}x${p.height}" else "?"
        }
        val tr = when (activeTransport) {
            NsdFinder.Transport.USB -> "USB·UDP"
            NsdFinder.Transport.WIFI -> "Wi-Fi·UDP"
            NsdFinder.Transport.TUNNEL -> "USB·有线"
            NsdFinder.Transport.OTHER -> "UDP"
        }
        // 窗口模式提示（系统分屏等）：app 窗口明显小于物理屏时，流被缩小渲染、
        // 有效清晰度打折——明确告知而非默默降质（分辨率不跟随窗口变：切换成本 5s，
        // 拖动分屏线会灾难化；SurfaceView 自适应缩放 + 解码器重绑已自动处理布局）
        val dm = Resources.getSystem().displayMetrics
        val rw = root.width; val rh = root.height
        val windowed = rw > 0 && rh > 0 &&
            (rw < dm.widthPixels * 85 / 100 || rh < dm.heightPixels * 85 / 100)
        val winMark = if (windowed) " · 窗口模式(画质降低)" else ""
        val controlMark = " · 纯显示"
        val resourceMark = String.format(java.util.Locale.US, " · CPU %.1f%% · 内存 %dMB", appCpuPercent, appMemoryMB)
        overlay.text = "$renderFps fps · $screens · $tr · $link$controlMark$resourceMark$winMark · 长按修复画面"
    }

    /** 当前 app 的资源采样；5 秒一次，连接存活时才运行，避免监控本身成为常驻负担。 */
    private fun sampleAppResources(now: Long) {
        if (now - lastResourceSampleAt < 5_000) return
        val cpuMs = android.os.Process.getElapsedCpuTime()
        if (lastResourceSampleAt > 0) {
            appCpuPercent = ((cpuMs - lastProcessCpuMs).toDouble() * 100.0 /
                (now - lastResourceSampleAt).toDouble()).coerceAtLeast(0.0)
        }
        val manager = getSystemService(ACTIVITY_SERVICE) as ActivityManager
        val memoryKb = manager.getProcessMemoryInfo(intArrayOf(android.os.Process.myPid()))
            .firstOrNull()?.totalPss ?: 0
        appMemoryMB = (memoryKb + 1023) / 1024
        lastProcessCpuMs = cpuMs
        lastResourceSampleAt = now
    }

    /** 状态落盘：锁屏/无屏环境下的可观测通道（adb pull 验证用） */
    private var lastStatusText: String? = null

    private fun writeStatusFile() {
        try {
            val dir = getExternalFilesDir(null) ?: return
            val link = if (linkUp) "up" else "down"
            // renderedNow 每秒都变会让"变化才写"退化成每秒写——归零该字段做指纹
            val pips = synchronized(pipelineLock) {
                pipelines.values.joinToString(";") { "${it.id}:${it.width}x${it.height}" }
            }
            val transport = when (activeTransport) {
                NsdFinder.Transport.USB -> "usb-udp"
                NsdFinder.Transport.WIFI -> "wifi-udp"
                NsdFinder.Transport.TUNNEL -> "usb-tunnel"
                NsdFinder.Transport.OTHER -> "udp"
            }
            val text = "link=$link transport=$transport fps=$renderFps cpu=${String.format(java.util.Locale.US, "%.1f", appCpuPercent)} memory_mb=$appMemoryMB layout=${layoutConfig.kind} subs=${subscribedIds.joinToString()} pipelines=$pips\n"
            val f = java.io.File(dir, "status.txt")
            if (text == lastStatusText && f.exists()) return // 闪存友好：内容没变且文件在，不写盘
            lastStatusText = text
            val real = "link=$link fps=$renderFps cpu=${String.format(java.util.Locale.US, "%.1f", appCpuPercent)} memory_mb=$appMemoryMB transport=$transport layout=${layoutConfig.kind} subs=${subscribedIds.joinToString()} pipelines=${
                synchronized(pipelineLock) { pipelines.values.joinToString(";") { "${it.id}:${it.width}x${it.height}:${it.renderedNow}" } }
            }\n"
            java.io.File(dir, "status.txt").writeText(real)
        } catch (_: Exception) { }
    }

    // MARK: 生命周期收尾

    private fun disconnectSession(removeDisplay: Boolean = false) {
        waitingSince = 0
        if (waitingOverlay.parent != null) waitingOverlay.dismiss()
        stopService(android.content.Intent(this, SessionService::class.java))
        mainHandler.removeCallbacks(statsTick)
        synchronized(pipelineLock) {
            for (p in pipelines.values) p.decoder?.release()
            pipelines.clear()
        }
        session?.close(sendBye = removeDisplay)
        session = null
        linkUp = false
        waitingForDisplay = false
        renderFps = 0
        statsOverlay = null
        configButton = null
        transportBadge = null
        localCursor = null
        pipRoot = null
        displays = emptyList()
        subscribedIds = emptyList()
        regionViews.clear()
        sessionRoot = null
        touchMode = 0
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (connectView == null) {
            showConnectView()
        } else {
            super.onBackPressed()
        }
    }

    /** 普通退后台的短暂宽限；期间回来直接续用同一虚拟屏，不制造 CGVirtualDisplay churn。 */
    private val backgroundGraceMillis = 5_000L
    private var autoDisconnectedByBg = false
    private var backgroundDisconnectPending = false
    private val backgroundDisconnect = Runnable {
        backgroundDisconnectPending = false
        if (session != null && !isChangingConfigurations) {
            autoDisconnectedByBg = true
            Log.i(TAG, "background grace elapsed — disconnecting (bye, remove virtual displays)")
            disconnectSession(removeDisplay = true)
        }
    }

    private fun disconnectImmediatelyForTaskRemoval() {
        mainHandler.removeCallbacks(backgroundDisconnect)
        backgroundDisconnectPending = false
        if (session != null && !isChangingConfigurations) {
            autoDisconnectedByBg = true
            Log.i(TAG, "task removed — disconnecting immediately (bye, remove virtual displays)")
            disconnectSession(removeDisplay = true)
        }
    }

    override fun onPause() {
        super.onPause()
        usbTunnelBurstGeneration++ // 退后台即取消插线重试，避免后台抢占 Wi‑Fi 会话
        UsbPlugReceiver.onPlugged = null // 防泄漏；后台拉起走通知路径
    }

    override fun onStop() {
        super.onStop()
        // 普通切换应用不立刻拆屏：5 秒内回来可直接续流。超过宽限才等同物理拔线。
        if (session != null && !isChangingConfigurations) {
            backgroundDisconnectPending = true
            mainHandler.removeCallbacks(backgroundDisconnect)
            mainHandler.postDelayed(backgroundDisconnect, backgroundGraceMillis)
            Log.i(TAG, "background — holding display for ${backgroundGraceMillis}ms before BYE")
        }
    }

    override fun onResume() {
        super.onResume()
        // 短暂切换应用回来：取消待执行的后台拔屏，沿用原会话/虚拟屏/解码器。
        if (backgroundDisconnectPending) {
            mainHandler.removeCallbacks(backgroundDisconnect)
            backgroundDisconnectPending = false
            Log.i(TAG, "resumed within background grace — keeping existing virtual displays")
        }
        SessionService.onTaskRemovedCallback = {
            mainHandler.post { disconnectImmediatelyForTaskRemoval() }
        }
        // 插线（POWER_CONNECTED）：前台已运行只做升级探测（含 adb 隧道）；断连状态
        // 直接走 smart——隧道优先、无隧道回 Wi-Fi 历史/发现。
        UsbPlugReceiver.onPlugged = {
            mainHandler.post {
                // Mac 侧 IOKit 收到插线后会立即注册 reverse；短重试覆盖两端事件的
                // 正常竞态，消灭之前靠 30 秒低频兜底才出现 ⚡USB 的体验。
                startUsbTunnelUpgradeBurst()
                if (session == null) {
                    smartConnect()
                } else {
                    probeForUsbUpgrade()
                }
            }
        }
        // 后台自动断开过 → 无缝重连（EDID 档案屏：位置还原）
        if (autoDisconnectedByBg) {
            autoDisconnectedByBg = false
            Log.i(TAG, "resumed after auto disconnect — reconnecting")
            smartConnect()
        }
    }

    override fun onDestroy() {
        mainHandler.removeCallbacks(backgroundDisconnect)
        SessionService.onTaskRemovedCallback = null
        super.onDestroy()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // 配置弹窗、权限页或 OEM 的边缘手势会暂时拉出状态栏/三键导航。会话画面
        // 必须在焦点回来后重新进入沉浸式，否则手机内容区会改变，造成顶部漏出、
        // 分屏黑边和光标视觉坐标再次漂移。这里只改 Android chrome，绝不重建 Host 屏。
        if (hasFocus && sessionRoot != null) hideSystemBarsSoon(180)
    }

    private fun hideSystemBarsSoon(delayMs: Long = 0L) {
        systemBarRehide?.let { mainHandler.removeCallbacks(it) }
        val task = Runnable {
            systemBarRehide = null
            if (sessionRoot != null && !isFinishing) hideSystemBars()
        }
        systemBarRehide = task
        mainHandler.postDelayed(task, delayMs)
    }

    private fun hideSystemBars() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let {
                it.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = legacyEdgeToEdgeFlags() or (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION)
        }
    }

    private fun configureDisplayViewport() {
        // 小米 Android 10 即使已经请求 immersive，仍可能把导航手势区从普通 app
        // content 中扣掉。副屏无需在该边缘承接系统手势，允许窗口完整参与布局。
        window.addFlags(WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS)
        if (Build.VERSION.SDK_INT >= 28) {
            val attrs = window.attributes
            attrs.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            window.attributes = attrs
        }
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
        } else {
            @Suppress("DEPRECATION")
            run { window.decorView.systemUiVisibility = legacyEdgeToEdgeFlags() }
        }
    }

    @Suppress("DEPRECATION")
    private fun legacyEdgeToEdgeFlags() = View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
        View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
}
