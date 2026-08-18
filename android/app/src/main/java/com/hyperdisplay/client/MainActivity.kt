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
        @Volatile var width: Int = 0
        @Volatile var height: Int = 0
        @Volatile var surface: Surface? = null
        var lastRendered = 0
        var renderedNow = 0
    }

    private val pipelines = LinkedHashMap<Int, DisplayPipeline>()
    private val pipelineLock = Object()

    private enum class LayoutMode(val label: String) {
        SINGLE("单屏全屏"), SPLIT_LR("左右分屏"), SPLIT_TB("上下分屏")
    }

    private var layoutMode = LayoutMode.SINGLE
    private var subscribedIds = listOf<Int>()
    private val createdIds = mutableListOf<Int>() // 本客户端建的屏，布局重建时回收
    private var pendingRegions: List<Pair<Int, Int>>? = null
    private var pendingKeep = setOf<Int>()
    private var displays: List<HostSession.DisplayInfo> = emptyList()
    private var displayButton: Button? = null
    private var layoutButton: Button? = null

    @Volatile private var linkUp = false
    private val mainHandler = Handler(Looper.getMainLooper())
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
        intent.getStringExtra("host")?.trim()?.takeIf { it.isNotEmpty() }?.let { text ->
            parseEndpoint(text)?.let { (host, port) -> connect(host, port) }
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
        val buttonRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        buttonRow.addView(scanButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        buttonRow.addView(findButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
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
            val text = input.text.toString().trim()
            val (host, port) = parseEndpoint(text) ?: run {
                statusText.text = "地址格式不对，应形如 192.168.1.23:5277"
                return@setOnClickListener
            }
            prefs.edit().putString("host", text).apply()
            connect(host, port)
        }
        scanButton.setOnClickListener { launchQrScan() }
        findButton.setOnClickListener { showDiscoveryDialog() }
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
        statusText.text = "连接 $host:$port …"
        val s = HostSession.create(host, port, sessionListener)
        if (s == null) {
            statusText.text = "无法解析地址（仅支持数字 IPv4）"
            return
        }
        session = s
        showSessionView()
        s.start()
        mainHandler.post(statsTick)
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
                p.width = width
                p.height = height
                regionViews.firstOrNull { it.displayId == displayId }?.updateStreamSize(width, height)
                updateOverlay()
            }
        }

        override fun onConfig(displayId: Int, codec: Int, paramSets: ByteArray) {
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
                updateDisplayButton()
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
                val d = VideoDecoder("video/hevc", p.width, p.height, surface, csd)
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

        val container = FrameLayout(this)
        root.addView(container, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        sessionRoot = container

        val overlay = TextView(this).apply {
            text = "等待视频流…"
            textSize = 12f
            setTextColor(Color.WHITE)
            setBackgroundColor(0x66000000)
            setPadding(12, 6, 12, 6)
        }
        root.addView(overlay, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.START))
        statsOverlay = overlay

        val layoutBtn = Button(this).apply {
            text = "布局 ▾"
            textSize = 12f
            setTextColor(Color.WHITE)
            setBackgroundColor(0x66000000)
            setPadding(16, 8, 16, 8)
            setOnClickListener { showLayoutPicker() }
        }
        root.addView(layoutBtn, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.END))
        layoutButton = layoutBtn

        val picker = Button(this).apply {
            text = "显示器 ▾"
            textSize = 12f
            setTextColor(Color.WHITE)
            setBackgroundColor(0x66000000)
            setPadding(16, 8, 16, 8)
            setOnClickListener { showDisplayPicker() }
        }
        root.addView(picker, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.END).also {
            it.topMargin = 132
        })
        displayButton = picker

        rebuildRegionViews()
    }

    /** 按当前布局模式与订阅顺序布置每块屏的渲染区域 */
    @SuppressLint("ClickableViewAccessibility")
    private fun rebuildRegionViews() {
        val container = sessionRoot ?: return
        for (v in regionViews) container.removeView(v)
        regionViews.clear()
        val ids = if (subscribedIds.isNotEmpty()) subscribedIds else displays.take(1).map { it.id }
        if (ids.isEmpty()) return

        val sw = Resources.getSystem().displayMetrics.let { maxOf(it.widthPixels, it.heightPixels) }
        val sh = Resources.getSystem().displayMetrics.let { minOf(it.widthPixels, it.heightPixels) }

        ids.forEachIndexed { index, id ->
            val view = StreamView(this)
            view.displayId = id
            view.onSurfaceReady = { did, surface ->
                val p = pipelineOf(did)
                p.surface = surface
                maybeStartDecoder(p)
            }
            view.onSurfaceDestroyed = { did ->
                synchronized(pipelineLock) {
                    pipelines[did]?.let { p ->
                        p.decoder?.release()
                        p.decoder = null
                        p.surface = null
                    }
                }
            }
            view.onTouch = { did, event -> handleTouch(did, view, event); true }
            val lp = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT,
                Gravity.TOP or Gravity.START)
            when (layoutMode) {
                LayoutMode.SINGLE -> { /* 全屏 */ }
                LayoutMode.SPLIT_LR -> {
                    lp.width = if (index == 0) sw / 2 else sw - sw / 2
                    lp.height = sh
                    lp.leftMargin = if (index == 0) 0 else sw / 2
                }
                LayoutMode.SPLIT_TB -> {
                    lp.width = sw
                    lp.height = if (index == 0) sh / 2 else sh - sh / 2
                    lp.topMargin = if (index == 0) 0 else sh / 2
                }
            }
            container.addView(view, lp)
            val p = pipelineOf(id)
            if (p.width > 0) view.updateStreamSize(p.width, p.height)
            regionViews.add(view)
        }
    }

    // MARK: 布局切换

    private fun showLayoutPicker() {
        val labels = LayoutMode.values().map { it.label }.toTypedArray()
        val checked = layoutMode.ordinal
        var choice = checked
        android.app.AlertDialog.Builder(this)
            .setTitle("画面布局")
            .setSingleChoiceItems(labels, checked) { _, which -> choice = which }
            .setPositiveButton("应用") { d, _ ->
                d.dismiss()
                applyLayout(LayoutMode.values()[choice])
            }
            .setNegativeButton("取消", null)
            .show()
    }

    /** 分屏 = 虚拟屏尺寸取平板对应区域的物理像素（每格像素 1:1，总带宽≈单路原生） */
    private fun applyLayout(mode: LayoutMode) {
        val s = session ?: return
        layoutMode = mode
        if (mode == LayoutMode.SINGLE) {
            pendingRegions = null
            val first = displays.firstOrNull()?.id
            if (first != null) {
                subscribedIds = listOf(first)
                resetPipelines()
                rebuildRegionViews()
                s.selectDisplay(first)
            }
            updateDisplayButton()
            updateOverlay()
            return
        }

        val metrics = Resources.getSystem().displayMetrics
        val sw = maxOf(metrics.widthPixels, metrics.heightPixels)
        val sh = minOf(metrics.widthPixels, metrics.heightPixels)
        val regions = when (mode) {
            LayoutMode.SPLIT_LR -> listOf(sw / 2 to sh, (sw - sw / 2) to sh)
            LayoutMode.SPLIT_TB -> listOf(sw to sh / 2, sw to (sh - sh / 2))
            else -> return
        }
        pendingRegions = regions

        // 按唯一尺寸统计缺口（相同尺寸只算一次，避免重复 CREATE）
        for (r in regions.toSet()) {
            val need = regions.count { it == r }
            val have = displays.count { (it.width to it.height) == r }
            val missing = (need - have).coerceAtLeast(0)
            for (i in 0 until missing) {
                s.createDisplay(r.first, r.second, "分屏 ${r.first}x${r.second}")
            }
        }
        updateOverlay()
    }

    /** DISPLAYS 更新后：尺寸匹配凑齐即整体 SUBSCRIBE，并回收不再使用的自建屏 */
    private fun tryFulfillPendingLayout() {
        val regions = pendingRegions ?: return
        val s = session ?: return
        val matched = mutableListOf<Int>()
        val used = mutableListOf<Pair<Int, Int>>()
        for (d in displays.sortedBy { it.id }) {
            val size = d.width to d.height
            if (size in regions && used.count { it == size } < regions.count { it == size }) {
                matched.add(d.id)
                used.add(size)
            }
        }
        if (matched.size < regions.size) return

        pendingRegions = null
        // 回收：尺寸属于分屏需求但不在目标集里的屏（含本客户端多建的），其余（如默认屏）不动
        for (d in displays) {
            val size = d.width to d.height
            if (size in regions && d.id !in matched) {
                s.destroyDisplay(d.id)
                createdIds.remove(d.id)
            }
        }
        for (id in matched) if (id !in createdIds) createdIds.add(id)
        subscribedIds = matched
        resetPipelines()
        rebuildRegionViews()
        s.sendSubscribeDisplays(matched)
        Log.i(TAG, "split layout applied: screens=${matched.joinToString()}")
        updateDisplayButton()
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

    // MARK: 显示器选择（单屏切换保留）

    private fun updateDisplayButton() {
        val button = displayButton ?: return
        button.text = if (subscribedIds.size > 1) "屏×${subscribedIds.size}" else "显示器 ▾"
        button.isEnabled = displays.isNotEmpty()
    }

    private fun showDisplayPicker() {
        val s = session ?: return
        if (displays.isEmpty()) return
        val names = displays.mapIndexed { i, d -> "${i + 1}. ${d.width}×${d.height}" }.toTypedArray()
        val checked = displays.indexOfFirst { it.id == subscribedIds.firstOrNull() }.coerceAtLeast(0)
        var choice = checked
        android.app.AlertDialog.Builder(this)
            .setTitle("选择虚拟屏（单屏模式）")
            .setSingleChoiceItems(names, checked) { _, which -> choice = which }
            .setPositiveButton("切换") { dialog, _ ->
                dialog.dismiss()
                val target = displays[choice]
                layoutMode = LayoutMode.SINGLE
                subscribedIds = listOf(target.id)
                resetPipelines()
                rebuildRegionViews()
                s.selectDisplay(target.id)
            }
            .setNeutralButton("新建（适配本机）") { _, _ ->
                val metrics = Resources.getSystem().displayMetrics
                val w = maxOf(metrics.widthPixels, metrics.heightPixels)
                val h = minOf(metrics.widthPixels, metrics.heightPixels)
                s.createDisplay(w, h, "平板 ${w}×$h")
            }
            .setNegativeButton(if (displays.size > 1) "删除当前屏" else "关闭") { _, _ ->
                val current = subscribedIds.firstOrNull()
                if (displays.size > 1 && current != null) s.destroyDisplay(current)
            }
            .show()
    }

    // MARK: 触摸 → 输入（按区域路由）

    private var touchMode = 0 // 0=idle 1=single 2=wheel
    private var wheelLastX = 0f
    private var wheelLastY = 0f

    private fun handleTouch(displayId: Int, view: StreamView, event: MotionEvent) {
        val s = session ?: return
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

    // MARK: 状态

    private fun updateOverlay() {
        val overlay = statsOverlay ?: return
        val link = if (linkUp) "链路 OK" else "等待主机…"
        val screens = if (subscribedIds.size > 1) {
            "${subscribedIds.size} 屏分屏"
        } else {
            val p = pipelines.values.firstOrNull()
            if (p != null && p.width > 0) "${p.width}x${p.height}" else "?"
        }
        overlay.text = "$renderFps fps · $screens · $link · 返回键断开"
    }

    /** 状态落盘：锁屏/无屏环境下的可观测通道（adb pull 验证用） */
    private fun writeStatusFile() {
        try {
            val dir = getExternalFilesDir(null) ?: return
            val link = if (linkUp) "up" else "down"
            val pips = synchronized(pipelineLock) {
                pipelines.values.joinToString(";") { "${it.id}:${it.width}x${it.height}:${it.renderedNow}" }
            }
            val text = "link=$link fps=$renderFps layout=$layoutMode subs=${subscribedIds.joinToString()} pipelines=$pips\n"
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
        displayButton = null
        layoutButton = null
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
        if (connectView == null) showConnectView()
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
