package com.hyperdisplay.client

import android.annotation.SuppressLint
import android.app.ActivityManager
import android.content.res.Resources
import android.graphics.Color
import android.graphics.Typeface
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
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
        /** 0=平板原生尺寸；其余为虚拟屏长边档位，随设备布局一起持久化。 */
        val displayLongEdge: Int = 0
    )

    private var layoutConfig = LayoutConfig()

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
            displayLongEdge = p.getInt("layout.displayLongEdge", 0)
                .takeIf { it in listOf(1440, 1600, 1920, 2240) } ?: 0
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
            .putInt("layout.pipLeft", pipLeft)
            .putInt("layout.pipTop", pipTop)
            .apply()
    }

    private fun layoutStateForHost(cfg: LayoutConfig): HostSession.LayoutState {
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
            pipTop = pipTop
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
            displayLongEdge = state.displayLongEdge.takeIf { it in listOf(1440, 1600, 1920, 2240) } ?: 0
        )
        pipLeft = state.pipLeft
        pipTop = state.pipTop
        saveLayoutConfig(layoutConfig)
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
    // 产品定位是外置显示器；不申请辅助功能，也不把触摸转换为 Mac 输入。
    @Volatile private var remoteControlEnabled = false
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
            // 新会话首帧落地 → 撤切换横幅（快切换时它根本没来得及浮现）
            if (total > 0) cancelSwitchingBanner()
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
        layoutConfig = loadLayoutConfig()
        val layoutPrefs = getSharedPreferences("hyperdisplay", MODE_PRIVATE)
        pipLeft = layoutPrefs.getInt("layout.pipLeft", -1)
        pipTop = layoutPrefs.getInt("layout.pipTop", -1)
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
        val code = getPreferences(MODE_PRIVATE).getInt("pairingCode", 0)
        val deviceId = HostSession.loadOrCreateDeviceId(this)
        val deviceFingerprint = HostSession.loadDeviceFingerprint(this)
        val s = HostSession.create(host, port, sessionListener, code, deviceId, deviceFingerprint,
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
    private fun requestedDisplaySpecs(): List<Pair<Int, Int>> {
        val (sw, sh) = screenDims()
        val raw = if (layoutConfig.kind == LayoutKind.SINGLE) listOf(sw to sh)
        else regionSizes(layoutConfig).ifEmpty { listOf(sw to sh) }.take(4)
        val longEdge = layoutConfig.displayLongEdge
        if (longEdge == 0) return raw
        return raw.map { (w, h) ->
            val scale = longEdge.toFloat() / maxOf(sw, sh).toFloat()
            val rw = (((w * scale).toInt() + 15) and 15.inv()).coerceAtLeast(640)
            val rh = (((h * scale).toInt() + 15) and 15.inv()).coerceAtLeast(480)
            rw to rh
        }
    }

    // MARK: 通道切换过渡横幅（快切换不浮现，慢 1.5s 后出现）

    private fun scheduleSwitchingBanner() {
        cancelSwitchingBanner()
        val r = Runnable {
            val b = switchingBanner ?: return@Runnable
            b.visibility = android.view.View.VISIBLE
            b.alpha = 0f
            b.animate()?.alpha(1f)?.setDuration(200)?.start()
            // 兜底自动消失：首帧取消是主路径，但 host 不健康时永远等不到首帧——
            // 横幅最多挂 10s，之后让位给会话视图自身的"等待视频流"状态
            switchingBannerShow = null
            mainHandler.postDelayed({ cancelSwitchingBanner() }, 10_000)
        }
        switchingBannerShow = r
        mainHandler.postDelayed(r, 1500)
    }

    private fun cancelSwitchingBanner() {
        switchingBannerShow?.let { mainHandler.removeCallbacks(it) }
        switchingBannerShow = null
        switchingBanner?.let {
            it.animate().cancel()
            it.visibility = android.view.View.GONE
        }
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
                // Host 即使收到旧版本协商结果，也始终保持纯显示模式。
                remoteControlEnabled = false
                session?.setRemoteControlEnabled(false)
                val p = pipelineOf(displayId)
                p.fps = fps.coerceIn(1, 144)
                p.codec = codec
                p.width = width
                p.height = height
                regionViews.firstOrNull { it.displayId == displayId }?.updateStreamSize(width, height)
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
            pipelineOf(displayId).assembler?.onFragment(frameId, fragIdx, fragCount, keyframe, payload)
        }

        override fun onDisplays(list: List<HostSession.DisplayInfo>) {
            mainHandler.post {
                displays = list
                waitingForDisplay = list.isEmpty()
                // 对账：host 重启/屏回收后 display id 会整体换代。已订阅的 id 若全部
                // 不在新列表里（UI 已有视图时选屏器不会重跑），解码器将绑死死 id、
                // 丢弃全部视频分片且关键帧请求被 host 静默忽略——永久 idle-wait 冻屏。
                val liveIds = list.map { it.id }.toSet()
                val validSubs = subscribedIds.filter { it in liveIds }
                if (validSubs.size != subscribedIds.size && list.isNotEmpty()) {
                    if (validSubs.isEmpty()) {
                        subscribedIds = listOf(list.first().id)
                        resetPipelines()
                        rebuildRegionViews()
                        session?.selectDisplay(subscribedIds.first())
                        session?.requestKeyframe(subscribedIds.first())
                    } else {
                        subscribedIds = validSubs
                        session?.sendSubscribeDisplays(validSubs)
                    }
                }
                // Host 只按 HELLO 中持久化的设备档案创建/恢复屏幕；Android 在这里仅订阅。
                // 不再因为 DISPLAYS 的一次刷新反向发 CREATE/DESTROY，避免拓扑 churn。
                // 多屏创建是安全串行的：第一块会先出现、第二块稍后才加入列表。因此
                // 列表从 1→2 时必须增量订阅并重建画中画视图，不能只在首次空视图时选屏。
                if (list.isNotEmpty()) {
                    val deviceId = HostSession.loadOrCreateDeviceId(this@MainActivity)
                    val prefix = "Hyperdisplay 设备 ${deviceId % 10000}"
                    val wanted = requestedDisplaySpecs().size
                    val owned = list.filter { it.name.startsWith(prefix) }.take(wanted)
                    val selected = if (owned.size == wanted) owned else list.take(wanted)
                    val desiredIds = selected.map { it.id }
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
                updateConfigButton()
            }
        }

        override fun onSavedLayout(layout: HostSession.LayoutState) {
            mainHandler.post {
                // Host 只在“指纹命中、安装内 ID 已变化”时发这个包。它比显示列表先发；
                // 即便 UDP 极端乱序，后续 onDisplays 也会按新布局重新选择完整屏组。
                restoreLayoutFromHost(layout)
                session?.acknowledgeSavedLayout()
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
                    p.decoder?.submit(VideoDecoder.Frame(keyframe, data))
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
        hideSystemBars()

        val container = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        root.addView(container, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        sessionRoot = container

        // 通道切换过渡横幅：屏幕中央半透明黑底「正在切换到 USB/WiFi…」。
        // 快切换（<1.5s 出画面）不浮现——不打扰；慢了才出现，且半透明灰罩
        // 压住冻住的旧画面，明确「在切换」而非「卡死」。
        val banner = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(0xB3000000.toInt())
            setPadding(48, 36, 48, 36)
            visibility = android.view.View.GONE
        }
        banner.addView(android.widget.TextView(this).apply {
            text = "正在切换通道…"
            textSize = 18f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
        })
        banner.addView(android.widget.TextView(this).apply {
            text = "画面即将恢复"
            textSize = 12f
            setTextColor(0xFFAAAAAA.toInt())
            gravity = Gravity.CENTER
            setPadding(0, 10, 0, 0)
        })
        root.addView(banner, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT))
        switchingBanner = banner

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

    /** 把子视图内坐标换算为窗口坐标（本地光标用） */
    private fun windowPos(view: View, x: Float, y: Float): FloatArray {
        val loc = IntArray(2)
        view.getLocationInWindow(loc)
        return floatArrayOf(loc[0] + x, loc[1] + y)
    }

    private fun screenDims(): Pair<Int, Int> {
        val m = Resources.getSystem().displayMetrics
        return maxOf(m.widthPixels, m.heightPixels) to minOf(m.widthPixels, m.heightPixels)
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

    /** 可拖分割线：拖动实时预览两区大小，松手按新比例重建虚拟屏 */
    @SuppressLint("ClickableViewAccessibility")
    private fun addDivider(container: FrameLayout, vertical: Boolean, pos: Int, sw: Int, sh: Int,
                           minFrac: Float, maxFrac: Float, side: Boolean) {
        val thickness = (20 * resources.displayMetrics.density).toInt()
        val divider = View(this).apply { setBackgroundColor(0x99FFFFFF.toInt()) }
        val lp = if (vertical) {
            FrameLayout.LayoutParams(thickness, sh, Gravity.TOP or Gravity.START).also { it.leftMargin = pos - thickness / 2 }
        } else {
            FrameLayout.LayoutParams(sw, thickness, Gravity.TOP or Gravity.START).also { it.topMargin = pos - thickness / 2 }
        }
        container.addView(divider, lp)
        decorViews.add(divider)

        divider.setOnTouchListener(object : View.OnTouchListener {
            var liveFrac = 0f
            override fun onTouch(v: View, e: MotionEvent): Boolean {
                when (e.actionMasked) {
                    MotionEvent.ACTION_DOWN -> liveFrac = layoutConfig.fraction
                    MotionEvent.ACTION_MOVE -> {
                        val f = (if (vertical) e.rawX / sw else e.rawY / sh)
                            .coerceIn(minFrac, maxFrac)
                        liveFrac = f
                        // 实时预览：只改视图布局，不动流
                        val p = (f * (if (vertical) sw else sh)).toInt()
                        for (rv in regionViews) {
                            val rlp = rv.layoutParams as FrameLayout.LayoutParams
                            if (vertical) {
                                if (rlp.leftMargin == 0) rlp.width = p
                                else { rlp.leftMargin = p; rlp.width = sw - p }
            } else {
                                if (rlp.topMargin == 0) rlp.height = p
                                else { rlp.topMargin = p; rlp.height = sh - p }
                            }
                            rv.layoutParams = rlp
                        }
                        val dlp = divider.layoutParams as FrameLayout.LayoutParams
                        if (vertical) dlp.leftMargin = p - thickness / 2 else dlp.topMargin = p - thickness / 2
                        divider.layoutParams = dlp
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
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
        val (sw, sh) = screenDims()

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

        fun place(v: StreamView, w: Int, h: Int, x: Int, y: Int) {
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
            regionViews.add(v)
        }

        when (layoutConfig.kind) {
            LayoutKind.SINGLE -> {
                place(makeView(ids[0]), sw, sh, 0, 0)
            }
            LayoutKind.SPLIT_LR -> {
                if (ids.size >= 2) {
                    val lw = evenOf((sw * layoutConfig.fraction).toInt().coerceIn(sw / 5, sw * 4 / 5))
                    place(makeView(ids[0]), lw, sh, 0, 0)
                    place(makeView(ids[1]), evenOf(sw - lw), sh, lw, 0)
                    addDivider(container, true, lw, sw, sh, 0.3f, 0.7f, false)
                } else place(makeView(ids[0]), sw, sh, 0, 0)
            }
            LayoutKind.SPLIT_TB -> {
                if (ids.size >= 2) {
                    val th = evenOf((sh * layoutConfig.fraction).toInt().coerceIn(sh / 5, sh * 4 / 5))
                    place(makeView(ids[0]), sw, th, 0, 0)
                    place(makeView(ids[1]), sw, evenOf(sh - th), 0, th)
                    addDivider(container, false, th, sw, sh, 0.3f, 0.7f, false)
                } else place(makeView(ids[0]), sw, sh, 0, 0)
            }
            LayoutKind.SIDE -> {
                if (ids.size >= 2) {
                    val sideW = evenOf((sw * layoutConfig.fraction).toInt().coerceIn(sw / 5, sw * 2 / 5))
                    val main = makeView(ids[0]); val side = makeView(ids[1])
                    if (layoutConfig.sideLeft) {
                        place(side, sideW, sh, 0, 0)
                        place(main, evenOf(sw - sideW), sh, sideW, 0)
                    } else {
                        place(main, evenOf(sw - sideW), sh, 0, 0)
                        place(side, sideW, sh, evenOf(sw - sideW), 0)
                    }
                    addDivider(container, true, sideW, sw, sh, 0.2f, 0.4f, true)
                } else place(makeView(ids[0]), sw, sh, 0, 0)
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

        // 显示大小写入平板设备档案；下一次 HELLO 由 Host 受控恢复整组屏幕。
        panel.addView(TextView(this).apply {
            val current = if (layoutConfig.displayLongEdge == 0) "原生" else "${layoutConfig.displayLongEdge}p"
            text = "显示大小（当前：$current；切换会短暂断流约 3 秒）"
            textSize = 13f
            setPadding(0, 20, 0, 4)
        })
        val tiers = listOf("特大" to 1440, "大" to 1600, "标准" to 1920, "锐利" to 2240)
        val tierRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        tiers.forEach { (label, longEdge) ->
            tierRow.addView(android.widget.Button(this).apply {
                text = label
                textSize = 13f
                setOnClickListener {
                    // 无需重启 Host，更不能为档位变化全量销毁所有虚拟屏。
                    layoutConfig = layoutConfig.copy(displayLongEdge = longEdge)
                    saveLayoutConfig(layoutConfig)
                    statusText.text = ""
                    Log.i(TAG, "tier switch -> $label; reconnecting from saved profile")
                    if (session != null) reconnectForDisplayTopologyChange()
                }
            }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        }
        panel.addView(tierRow)

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
        val changed = layoutConfig != cfg
        layoutConfig = cfg
        saveLayoutConfig(cfg)
        greenRecoveries = 0
        updateConfigButton(); updateOverlay()
        // 用户明确改变布局/分辨率时才做一次受控的整组替换。普通断线和 DISPLAYS
        // 刷新永远不会触发建销；Host 使用稳定 EDID slot 复用未变的显示器身份。
        if (changed && session != null) reconnectForDisplayTopologyChange()
    }

    private fun reconnectForDisplayTopologyChange() {
        Log.i(TAG, "display profile changed: controlled reconnect")
        linkUp = false
        disconnectSession()
        mainHandler.postDelayed({
            if (!isFinishing && !isDestroyed) smartConnect()
        }, 600)
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

    private var touchMode = 0 // 0=idle 1=single 2=wheel
    private var wheelLastX = 0f
    private var wheelLastY = 0f

    private fun handleTouch(displayId: Int, view: StreamView, event: MotionEvent) {
        // 纯显示产品不向 Mac 注入触摸、鼠标或滚轮事件。
        if (!remoteControlEnabled) return
        val s = session ?: return
        // 本地光标：手指位置零延迟反馈（远程画面不再含系统光标）。
        // 记录回显位置/时刻供 onCursor 仲裁（防 host 滞后推送拽回，见 onCursor）
        val lc = localCursor
        if (lc != null) {
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE -> {
                    val w = windowPos(view, event.x, event.y)
                    lastCursorEchoAt = System.currentTimeMillis()
                    lastCursorEchoX = w[0]; lastCursorEchoY = w[1]
                    lc.moveTo(w[0], w[1])
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> Unit // 常驻：抬手不隐藏，由 host 光标包驱动
            }
        }
        // 画中画处于选中（编辑）态时，第一次点其他区域=退出选中，不透传给 Mac
        if (pipSelected && event.actionMasked == MotionEvent.ACTION_DOWN && pipRoot != null) {
            pipRoot?.let { setPipSelected(it, false) }
            return
        }
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val p = view.viewToStream(event.x, event.y) ?: return
                s.sendMove(displayId, p[0], p[1])
                s.sendButton(displayId, 0, true, p[0], p[1])
                touchMode = 1
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                if (event.pointerCount == 2) {
                    if (touchMode == 1) {
                        view.viewToStream(event.x, event.y)?.let { s.sendButton(displayId, 0, false, it[0], it[1]) }
                    }
                    touchMode = 2
                    wheelLastX = (event.getX(0) + event.getX(1)) / 2f
                    wheelLastY = (event.getY(0) + event.getY(1)) / 2f
                }
            }
            MotionEvent.ACTION_MOVE -> {
                if (touchMode == 2 && event.pointerCount >= 2) {
                    val cx = (event.getX(0) + event.getX(1)) / 2f
                    val cy = (event.getY(0) + event.getY(1)) / 2f
                    val dx = cx - wheelLastX
                    val dy = cy - wheelLastY
                    wheelLastX = cx
                    wheelLastY = cy
                    if (dx != 0f || dy != 0f) {
                        view.viewToStream(cx, cy)?.let { s.sendWheel(displayId, dx, dy, it[0], it[1]) }
                    }
                } else if (event.pointerCount == 1) {
                    view.viewToStream(event.x, event.y)?.let { s.sendMove(displayId, it[0], it[1]) }
                }
            }
            MotionEvent.ACTION_POINTER_UP -> { }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (touchMode == 1) {
                    view.viewToStream(event.x, event.y)?.let { p ->
                        s.sendMove(displayId, p[0], p[1])
                        s.sendButton(displayId, 0, false, p[0], p[1])
                    }
                }
                touchMode = 0
            }
        }
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

    /** 后台自动断开：切走/锁屏超过 10s 还没回来 → 断开会话（发 BYE，host 回收副屏、
     *  窗口弹回 Mac 主屏可见）。10s 内回来不中断（保留「短暂切换不断流」的体验） */
    // 后台即等同拔掉平板：onStop 立即发 BYE，Host 回收该设备的全部副屏。
    private var autoDisconnectedByBg = false

    override fun onPause() {
        super.onPause()
        UsbPlugReceiver.onPlugged = null // 防泄漏；后台拉起走通知路径
    }

    override fun onStop() {
        super.onStop()
        // onStop 才表示用户真正离开/锁屏，避免权限弹窗等短暂 onPause 误拔屏。
        if (session != null && !isChangingConfigurations) {
            autoDisconnectedByBg = true
            Log.i(TAG, "background — disconnect immediately (bye, remove virtual displays)")
            disconnectSession(removeDisplay = true)
        }
    }

    override fun onResume() {
        super.onResume()
        // 插线（POWER_CONNECTED）：前台已运行只做升级探测（含 adb 隧道）；断连状态
        // 直接走 smart——隧道优先、无隧道回 Wi-Fi 历史/发现。
        UsbPlugReceiver.onPlugged = {
            mainHandler.post {
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

    private fun hideSystemBars() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let {
                it.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION)
        }
    }
}
