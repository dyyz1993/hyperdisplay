package com.hyperdisplay.client

import android.annotation.SuppressLint
import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

class MainActivity : Activity() {
    companion object {
        private const val TAG = "MainActivity"
        private const val DEFAULT_PORT = 5277
    }

    private lateinit var root: FrameLayout
    private lateinit var statusText: TextView
    private var hostInput: EditText? = null
    private var connectView: LinearLayout? = null

    private var session: HostSession? = null
    private var assembler: FrameAssembler? = null
    private var decoder: VideoDecoder? = null
    private var streamView: StreamView? = null
    private var statsOverlay: TextView? = null

    private var streamWidth = 0
    private var streamHeight = 0
    private var codecId = 1
    @Volatile private var latestCsd: ByteArray? = null
    @Volatile private var surfaceReady = false
    @Volatile private var linkUp = false
    private val decoderLock = Object()

    private val mainHandler = Handler(Looper.getMainLooper())
    private var lastRendered = 0
    private var renderFps = 0
    private var lastWatchdogKfAt = 0L
    private val statsTick = object : Runnable {
        override fun run() {
            val d = decoder
            if (d != null) {
                val now = d.renderedFrames
                renderFps = now - lastRendered
                lastRendered = now
            }
            assembler?.stallCheck()
            // 视频看门狗：链路已通但没有任何帧（host 侧静态桌面不出新帧）→ 主动要 IDR
            val s = session
            if (s != null && linkUp && decoder == null && latestCsd == null) {
                val now = System.currentTimeMillis()
                if (now - lastWatchdogKfAt > 700) {
                    lastWatchdogKfAt = now
                    s.requestKeyframe()
                }
            }
            updateOverlay()
            mainHandler.postDelayed(this, 1000)
        }
    }

    // 触摸状态机
    private var touchMode = 0 // 0=idle 1=single 2=wheel
    private var wheelLastX = 0f
    private var wheelLastY = 0f

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        root = FrameLayout(this)
        setContentView(root)
        showConnectView()
        // 支持 adb/自动化直连：am start -e host 192.168.1.23:5277
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
            statusText.text = "无法解析地址（M1 仅支持数字 IPv4）"
            return
        }
        session = s
        assembler = FrameAssembler(object : FrameAssembler.Callback {
            override fun onFrame(frameId: Int, keyframe: Boolean, data: ByteArray) {
                decoder?.submit(VideoDecoder.Frame(keyframe, data))
            }
            override fun onKeyframeNeeded(reason: String) {
                session?.requestKeyframe()
            }
        })
        showSessionView()
        s.start()
        mainHandler.post(statsTick)
    }

    private val sessionListener = object : HostSession.Listener {
        override fun onWelcome(codec: Int, width: Int, height: Int, fps: Int) {
            mainHandler.post {
                codecId = codec
                streamWidth = width
                streamHeight = height
                streamView?.updateStreamSize(width, height)
                updateOverlay()
            }
        }

        override fun onConfig(codec: Int, paramSets: ByteArray) {
            latestCsd = paramSets
            maybeStartDecoder()
        }

        override fun onVideoFragment(frameId: Int, fragIdx: Int, fragCount: Int, keyframe: Boolean, payload: ByteArray) {
            assembler?.onFragment(frameId, fragIdx, fragCount, keyframe, payload)
        }

        override fun onLinkEvent(connected: Boolean) {
            linkUp = connected
            if (!connected) {
                mainHandler.post {
                    // 链路断开：解码器状态不可信，释放等新的 CONFIG 重建
                    synchronized(decoderLock) {
                        decoder?.release()
                        decoder = null
                        latestCsd = null
                        lastRendered = 0
                    }
                    assembler?.reset()
                }
            }
        }
    }

    private fun maybeStartDecoder() {
        synchronized(decoderLock) {
            if (decoder != null || !surfaceReady) return
            val csd = latestCsd ?: return
            if (streamWidth <= 0) return
            val mime = if (codecId == 2) "video/avc" else "video/hevc"
            val surface = streamView?.holder?.surface ?: return
            try {
                val d = VideoDecoder(mime, streamWidth, streamHeight, surface, csd)
                d.start()
                decoder = d
                Log.i(TAG, "decoder started: $mime ${streamWidth}x$streamHeight")
            } catch (e: Exception) {
                Log.e(TAG, "decoder start failed", e)
            }
        }
    }

    // MARK: 会话界面

    @SuppressLint("ClickableViewAccessibility")
    private fun showSessionView() {
        root.removeAllViews()
        connectView = null
        hideSystemBars()

        val view = StreamView(this)
        view.onSurfaceReady = { _ ->
            surfaceReady = true
            maybeStartDecoder()
        }
        view.onSurfaceDestroyed = {
            surfaceReady = false
            synchronized(decoderLock) {
                decoder?.release()
                decoder = null
            }
        }
        view.onTouch = { event -> handleTouch(event); true }
        root.addView(view, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))

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
        streamView = view
    }

    private fun updateOverlay() {
        val overlay = statsOverlay ?: return
        val codecName = if (codecId == 2) "H.264" else "HEVC"
        val link = if (linkUp) "链路 OK" else "等待主机…"
        val size = if (streamWidth > 0) "${streamWidth}x${streamHeight}" else "?"
        overlay.text = "$codecName $size · ${renderFps} fps · $link · 返回键断开"
    }

    // MARK: 触摸 → 输入

    private fun handleTouch(event: MotionEvent) {
        val view = streamView ?: return
        val s = session ?: return
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val p = view.viewToStream(event.x, event.y) ?: return
                s.sendMove(p[0], p[1])
                s.sendButton(0, true, p[0], p[1])
                touchMode = 1
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                if (event.pointerCount == 2) {
                    if (touchMode == 1) {
                        // 单指拖动中加第二指：抬起左键进入滚轮模式
                        view.viewToStream(event.x, event.y)?.let { s.sendButton(0, false, it[0], it[1]) }
                    }
                    touchMode = 2
                    wheelLastX = centroidX(event)
                    wheelLastY = centroidY(event)
                }
            }
            MotionEvent.ACTION_MOVE -> {
                if (touchMode == 2 && event.pointerCount >= 2) {
                    val cx = centroidX(event)
                    val cy = centroidY(event)
                    val dx = cx - wheelLastX
                    val dy = cy - wheelLastY
                    wheelLastX = cx
                    wheelLastY = cy
                    if (dx != 0f || dy != 0f) {
                        view.viewToStream(cx, cy)?.let { s.sendWheel(dx, dy, it[0], it[1]) }
                    }
                } else if (event.pointerCount == 1) {
                    // 单指（拖动或滚轮后余指）：只发绝对坐标
                    view.viewToStream(event.x, event.y)?.let { s.sendMove(it[0], it[1]) }
                }
            }
            MotionEvent.ACTION_POINTER_UP -> {
                // 2→1 指后保持 touchMode=2：余指移动不触发按键，直到全部抬起
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (touchMode == 1) {
                    view.viewToStream(event.x, event.y)?.let { p ->
                        s.sendMove(p[0], p[1])
                        s.sendButton(0, false, p[0], p[1])
                    }
                }
                touchMode = 0
            }
        }
    }

    private fun centroidX(event: MotionEvent): Float =
        (event.getX(0) + event.getX(event.pointerCount - 1)) / 2f

    private fun centroidY(event: MotionEvent): Float =
        (event.getY(0) + event.getY(event.pointerCount - 1)) / 2f

    // MARK: 生命周期

    private fun disconnectSession() {
        mainHandler.removeCallbacks(statsTick)
        synchronized(decoderLock) {
            decoder?.release()
            decoder = null
        }
        decoder = null
        session?.close()
        session = null
        assembler = null
        latestCsd = null
        linkUp = false
        lastRendered = 0
        renderFps = 0
        streamWidth = 0
        streamHeight = 0
        statsOverlay = null
        streamView = null
        surfaceReady = false
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
