package com.hyperdisplay.client

import android.annotation.SuppressLint
import android.content.res.Resources
import android.graphics.Color
import android.graphics.Typeface
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
    private var sessionRoot: FrameLayout? = null
    private val regionViews = mutableListOf<StreamView>()

    private class DisplayPipeline(val id: Int) {
        var assembler: FrameAssembler? = null
        var decoder: VideoDecoder? = null
        @Volatile var csd: ByteArray? = null
        @Volatile var codec = 1 // WELCOME 上报：1=HEVC 2=H.264（host 硬编会话耗尽时回退）
        @Volatile var width: Int = 0
        @Volatile var height: Int = 0
        @Volatile var surface: Surface? = null
        @Volatile var lastKeyframeDeliveredAt = 0L
        var lastRendered = 0
        var renderedNow = 0
        var stallTicks = 0
        var stallDecoderRef: VideoDecoder? = null
        var stallInputBase = 0L
        var stallOutputBase = 0
        var deadTicks = 0 // csd 已到但零渲染的持续秒数（华为坏会话自动恢复用）
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
        val pipCustomH: Int = 0
    )

    private var layoutConfig = LayoutConfig()
    private var subscribedIds = listOf<Int>()
    private val createdIds = mutableListOf<Int>()
    private var pendingRegions: List<Pair<Int, Int>>? = null
    private var displays: List<HostSession.DisplayInfo> = emptyList()
    private var configButton: Button? = null
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
    private enum class Transport { USB, WIFI }
    private var transport = Transport.WIFI
    private var reconnecting = false
    private var usbProbeCounter = 0
    private var renderFps = 0
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
            // 坏解码器自动恢复：csd 已到但持续 6 秒零渲染（华为硬解坏会话=绿屏）——
            // 自动重建一次；若重建后仍死则不再自动（避免循环），留给长按手动修复
            for (p in snapshot) {
                val d = p.decoder
                if (d != null && p.csd != null && p.renderedNow == 0) {
                    p.deadTicks++
                    if (p.deadTicks == 6) {
                        Log.w(TAG, "dead decoder (0 renders with csd), auto-bounce display=" + p.id)
                        p.decoder = null
                        d.release()
                        maybeStartDecoder(p)
                    }
                } else {
                    p.deadTicks = 0
                }
            }
            val s = session
            if (s != null && linkUp) {
                for (p in snapshot) {
                    if (p.decoder == null && p.csd == null) {
                        val now = System.currentTimeMillis()
                        if (now - lastWatchdogKfAt > 1200) {
                            lastWatchdogKfAt = now
                            s.requestKeyframe(p.id)
                        }
                    }
                }
            }
            // USB 会话已死但没人处理（如重连时桥接还没恢复）：持续重试智能重连
            val s1 = session
            if (transport == Transport.USB && !linkUp && s1 != null && !reconnecting
                && System.currentTimeMillis() - lastReconnectAt > 5000) {
                mainHandler.post { scheduleSmartReconnect() }
            }
            // WiFi 期间每 10s 探测 USB，可用即自动升级（有线优先）
            usbProbeCounter++
            val s0 = session
            if (usbProbeCounter >= 10) {
                usbProbeCounter = 0
                if (transport == Transport.WIFI && linkUp && s0 != null) {
                    probeUsb { usbOk ->
                        if (usbOk && transport == Transport.WIFI) {
                            openSession("127.0.0.1", 5280)
                            transport = Transport.USB
                        }
                    }
                }
            }
            updateOverlay()
            writeStatusFile()
            mainHandler.postDelayed(this, 1000)
        }
    }

    // MARK: 生命周期

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        root = FrameLayout(this)
        setContentView(root)
        showConnectView()
        when (intent.getStringExtra("host")?.trim()?.lowercase()) {
            "smart" -> smartConnect() // 自动选路：USB 优先，否则历史 WiFi
            null, "" -> Unit
            else -> intent.getStringExtra("host")!!.trim().let { text ->
                parseEndpoint(text)?.let { (host, port) -> connect(host, port) }
            }
        }
    }

    // MARK: 连接界面

    @SuppressLint("ApplySharedPref")
    private fun showConnectView() {
        disconnectSession()
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
            text = "把这块平板变成 Mac 的扩展屏（局域网 UDP）"
            textSize = 14f
            gravity = Gravity.CENTER
            setPadding(0, 8, 0, 32)
        }
        val input = EditText(this).apply {
            hint = "Mac 的 IP:端口（如 192.168.1.23:5277）"
            setText(prefs.getString("host", ""))
            textSize = 16f
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
        box.addView(button)
        box.addView(buttonRow)
        box.addView(statusText)
        root.addView(box, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        connectView = box
        hostInput = input

        button.setOnClickListener {
            // 智能连接：优先 USB（插线即用），否则用手输/历史 WiFi 主机
            val text = input.text.toString().trim()
            if (text.isNotEmpty()) {
                val (host, port) = parseEndpoint(text) ?: run {
                    statusText.text = "地址格式不对，应形如 192.168.1.23:5277"
                    return@setOnClickListener
                }
                prefs.edit().putString("host", text).apply()
                connect(host, port)
            } else {
                smartConnect()
            }
        }
        scanButton.setOnClickListener { launchQrScan() }
        findButton.setOnClickListener { showDiscoveryDialog() }
        usbButton.setOnClickListener {
            // USB 隧道：adb reverse 把 127.0.0.1:5280 经 USB 线转到 Mac 的隧道桥
            statusText.text = "USB 隧道连接中…（需插线且 Mac 侧桥接在运行）"
            connect("127.0.0.1", 5280)
        }
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
        if (host != "127.0.0.1") {
            getPreferences(MODE_PRIVATE).edit().putString("host", "$host:$port").apply()
            transport = Transport.WIFI
        } else {
            transport = Transport.USB
        }
        openSession(host, port)
    }

    /** 建立会话（连接页与自动重连共用） */
    private fun openSession(host: String, port: Int) {
        disconnectSession()
        val s = HostSession.create(host, port, sessionListener)
        if (s == null) {
            transport = Transport.WIFI
            showConnectView()
            statusText.text = "无法解析地址（仅支持数字 IPv4）"
            return
        }
        session = s
        showSessionView()
        s.start()
        mainHandler.post(statsTick)
    }

    /** USB 链路探测：完整握手（连上 + 发 HELLO + 等任意回包）。
     *  线断时 adbd 的监听 socket 仍在、connect 能成，但字节到不了 Mac——必须验回包。 */
    private fun probeUsb(result: (Boolean) -> Unit) {
        Thread {
            var ok = false
            try {
                val s = java.net.Socket()
                s.tcpNoDelay = true
                val v6 = java.net.InetAddress.getByAddress(
                    byteArrayOf(0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,1))
                s.connect(java.net.InetSocketAddress(v6, 5280), 1500)
                s.soTimeout = 1500
                val hello = byteArrayOf(0x10.toByte(), 0,0,0,0, 1, 0x20,3, 0xE8.toByte(),7)
                s.getOutputStream().write(java.nio.ByteBuffer.allocate(4 + hello.size)
                    .order(java.nio.ByteOrder.LITTLE_ENDIAN)
                    .putInt(hello.size).put(hello).array())
                s.getOutputStream().flush()
                ok = s.getInputStream().read(ByteArray(64)) > 0
                s.close()
            } catch (_: Exception) { }
            android.util.Log.i("UsbProbe", "result=$ok")
            val r = ok
            mainHandler.post { result(r) }
        }.start()
    }

    /** 智能连接：有 USB 走 USB，否则走保存过的 WiFi 主机 */
    private fun smartConnect() {
        statusText.text = "探测 USB 连接…"
        probeUsb { usbOk ->
            if (usbOk) {
                statusText.text = "USB 隧道可用"
                openSession("127.0.0.1", 5280)
                transport = Transport.USB
            } else {
                val saved = getPreferences(MODE_PRIVATE).getString("host", null)
                val ep = saved?.let { parseEndpoint(it) }
                if (ep != null) {
                    statusText.text = "走 WiFi：${ep.first}:${ep.second}"
                    openSession(ep.first, ep.second)
                    transport = Transport.WIFI
                } else {
                    statusText.text = "USB 未连接且无历史主机——请扫码 / 局域网发现 / 输入 IP"
                }
            }
        }
    }

    /** 自动重连（USB 断开时降级；恢复时优先升回 USB） */
    private var lastReconnectAt = 0L

    private fun scheduleSmartReconnect() {
        if (reconnecting) return
        reconnecting = true
        lastReconnectAt = System.currentTimeMillis()
        mainHandler.postDelayed({
            reconnecting = false
            probeUsb { usbOk ->
                if (usbOk) {
                    openSession("127.0.0.1", 5280)
                    transport = Transport.USB
                } else {
                    val saved = getPreferences(MODE_PRIVATE).getString("host", null)
                    val ep = saved?.let { parseEndpoint(it) }
                    if (ep != null) {
                        openSession(ep.first, ep.second)
                        transport = Transport.WIFI
                    } else {
                        // 无历史主机：回到连接页让用户选（不留死会话）
                        transport = Transport.WIFI
                        showConnectView()
                        statusText.text = "USB 已断开且无历史 WiFi 主机——请扫码 / 发现 / 输入 IP"
                    }
                }
            }
        }, 1200)
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
        val cleaned = content.removePrefix("hyperdisplay://").trim()
        val (host, port) = parseEndpoint(cleaned) ?: run {
            statusText.text = "二维码内容无法识别：$content"
            return@registerForActivityResult
        }
        getPreferences(MODE_PRIVATE).edit().putString("host", "$host:$port").apply()
        connect(host, port)
    }

    // MARK: 局域网发现

    private val nsdFinder by lazy { NsdFinder(this) }
    private var discoveryDialog: android.app.AlertDialog? = null

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

    private fun rebuildDiscoveryDialog() {
        discoveryDialog?.dismiss()
        val hosts = nsdFinder.currentHosts()
        val items = if (hosts.isEmpty()) {
            arrayOf("搜索中…（确认 Mac 正在运行且同一 WiFi）")
        } else {
            hosts.map { "${it.name}\n${it.host}:${it.port}" }.toTypedArray()
        }
        discoveryDialog = android.app.AlertDialog.Builder(this)
            .setTitle("局域网设备")
            .setItems(items) { _, which ->
                nsdFinder.stopDiscovery()
                hosts.getOrNull(which)?.let { connect(it.host, it.port) }
            }
            .setNegativeButton("取消") { d, _ ->
                nsdFinder.stopDiscovery()
                d.dismiss()
            }
            .show()
    }

    // MARK: 会话回调

    private val sessionListener = object : HostSession.Listener {
        override fun onWelcome(displayId: Int, codec: Int, width: Int, height: Int, fps: Int) {
            mainHandler.post {
                val p = pipelineOf(displayId)
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
                Log.w(TAG, "dropping malformed csd for display=$displayId len=${'$'}{paramSets.size}")
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
                pendingRegions?.let { tryFulfillPendingLayout() }
                // 连接初期（单屏默认）：DISPLAYS 首次到达时视图还没建——
                // 默认订阅第一块屏并立即建渲染区，否则永远灰屏
                if (regionViews.isEmpty() && pendingRegions == null && list.isNotEmpty()) {
                    if (layoutConfig.kind != LayoutKind.SINGLE) {
                        // 重连/换通道后恢复之前的布局（画中画/分屏）
                        applyLayout(layoutConfig)
                    } else {
                        if (subscribedIds.isEmpty()) {
                            subscribedIds = listOf(list.first().id)
                        }
                        rebuildRegionViews()
                    }
                }
                updateConfigButton()
            }
        }

        override fun onLinkEvent(connected: Boolean) {
            linkUp = connected
            if (!connected && transport == Transport.USB && session != null) {
                // USB 断开（拔线/桥接重启）：自动降级 WiFi 或升回恢复的 USB
                mainHandler.post { scheduleSmartReconnect() }
            }
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
                    val csd = p.csd
                    val payload: ByteArray = if (keyframe && csd != null) csd + data else data
                    p.decoder?.submit(VideoDecoder.Frame(keyframe, payload))
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
                val d = VideoDecoder(mime, p.width, p.height, surface, csd)
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

        val cfgBtn = Button(this).apply {
            text = "⚙ 屏幕配置"
            textSize = 12f
            setTextColor(Color.WHITE)
            setBackgroundColor(0x66000000)
            setPadding(16, 8, 16, 8)
            setOnClickListener { showConfigPanel() }
        }
        root.addView(cfgBtn, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.END))
        configButton = cfgBtn

        rebuildRegionViews()
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
            // 半透明表面 + 黑色垫底：首帧到达前显示黑（加载态）而非显存残色（绿）
            view.holder.setFormat(android.graphics.PixelFormat.TRANSLUCENT)
            view.onSurfaceReady = { did, surface ->
                val pl = pipelineOf(did)
                pl.surface = surface
                maybeStartDecoder(pl)
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
        view.holder.setFormat(android.graphics.PixelFormat.TRANSLUCENT)
        view.setZOrderMediaOverlay(true)
        view.onSurfaceReady = { did, surface ->
            val pl = pipelineOf(did)
            pl.surface = surface
            maybeStartDecoder(pl)
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
                applyLayout(LayoutConfig(selected, frac, sideLeft, pipRatio))
            }
            .setNeutralButton("新建（适配本机）") { _, _ ->
                val (sw2, sh2) = screenDims()
                session?.createDisplay(sw2, sh2, "平板 ${'$'}{sw2}×${'$'}{sh2}")
            }
            .setNegativeButton("取消", null)
            .show()
    }

    // MARK: 布局应用引擎

    private fun applyLayout(cfg: LayoutConfig) {
        val s = session ?: return
        layoutConfig = cfg
        if (cfg.kind == LayoutKind.SINGLE) {
            pendingRegions = null
            val first = displays.firstOrNull()?.id
            if (first != null) {
                subscribedIds = listOf(first)
                resetPipelines()
                rebuildRegionViews()
                s.selectDisplay(first)
                // 回收布局模式创建的多余屏，避免越积越多
                for (id in createdIds.toList()) {
                    if (id != first) {
                        s.destroyDisplay(id)
                        createdIds.remove(id)
                    }
                }
            }
            updateConfigButton(); updateOverlay()
            return
        }
        pendingRegions = regionSizes(cfg)
        val regions = pendingRegions!!
        // 按唯一尺寸计数补建（同尺寸多块也正确）
        for (size in regions.toSet()) {
            val need = regions.count { it == size }
            val have = displays.count { (it.width to it.height) == size }
            repeat((need - have).coerceAtLeast(0)) {
                s.createDisplay(size.first, size.second, "布局 ${'$'}{size.first}x${'$'}{size.second}")
            }
        }
        updateConfigButton(); updateOverlay()
    }

    /** DISPLAYS 更新后：按尺寸（含重复）分配屏，凑齐即订阅；回收未用到的自建屏 */
    private fun tryFulfillPendingLayout() {
        val regions = pendingRegions ?: return
        val s = session ?: return
        val matched = mutableListOf<Int>()
        val usedIds = mutableSetOf<Int>()
        for (region in regions) {
            val found = displays.filter { (it.width to it.height) == region && it.id !in usedIds }
                .minByOrNull { it.id }
            if (found != null) { matched.add(found.id); usedIds.add(found.id) }
        }
        if (matched.size < regions.size) return

        pendingRegions = null
        for (d in displays) {
            if (d.id in createdIds && d.id !in usedIds) {
                s.destroyDisplay(d.id)
                createdIds.remove(d.id)
            }
        }
        for (id in matched) if (id !in createdIds) createdIds.add(id)
        subscribedIds = matched
        resetPipelines()
        rebuildRegionViews()
        s.sendSubscribeDisplays(matched)
        Log.i(TAG, "layout ${'$'}{layoutConfig.kind} applied: screens=${'$'}{matched.joinToString()}")
        updateConfigButton()
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
        button.text = layoutConfig.kind.label +
            (if (subscribedIds.size > 1) "·" + subscribedIds.size + "屏" else "")
    }

    // MARK: 触摸 → 输入（按区域路由）

    private var touchMode = 0 // 0=idle 1=single 2=wheel
    private var wheelLastX = 0f
    private var wheelLastY = 0f

    private fun handleTouch(displayId: Int, view: StreamView, event: MotionEvent) {
        val s = session ?: return
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
        val overlay = statsOverlay ?: return
        val link = if (linkUp) "链路 OK" else "等待主机…"
        val screens = if (subscribedIds.size > 1) {
            "${subscribedIds.size} 屏"
        } else {
            val p = pipelines.values.firstOrNull()
            if (p != null && p.width > 0) "${p.width}x${p.height}" else "?"
        }
        val tr = if (transport == Transport.USB) "USB" else "WiFi"
        overlay.text = "$renderFps fps · $screens · $tr · $link · 长按修复画面"
    }

    /** 状态落盘：锁屏/无屏环境下的可观测通道（adb pull 验证用） */
    private fun writeStatusFile() {
        try {
            val dir = getExternalFilesDir(null) ?: return
            val link = if (linkUp) "up" else "down"
            val pips = synchronized(pipelineLock) {
                pipelines.values.joinToString(";") { "${it.id}:${it.width}x${it.height}:${it.renderedNow}" }
            }
            val text = "link=$link fps=$renderFps transport=$transport layout=${layoutConfig.kind} subs=${subscribedIds.joinToString()} pipelines=$pips\n"
            java.io.File(dir, "status.txt").writeText(text)
        } catch (_: Exception) { }
    }

    // MARK: 生命周期收尾

    private fun disconnectSession() {
        mainHandler.removeCallbacks(statsTick)
        synchronized(pipelineLock) {
            for (p in pipelines.values) p.decoder?.release()
            pipelines.clear()
        }
        session?.close()
        session = null
        linkUp = false
        renderFps = 0
        statsOverlay = null
        configButton = null
        pipRoot = null
        displays = emptyList()
        subscribedIds = emptyList()
        createdIds.clear()
        pendingRegions = null
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

    override fun onPause() {
        super.onPause()
        // 副屏应用：切走/锁屏不主动断流（此前 onPause 直接断连，回来像「断开了」）
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
