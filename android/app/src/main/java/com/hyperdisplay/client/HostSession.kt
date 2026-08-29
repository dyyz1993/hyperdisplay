package com.hyperdisplay.client

import android.util.Log
import android.provider.Settings
import android.os.Build
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * 与 macOS host 的 UDP 会话。
 * 线协议见 macos/Sources/HyperdisplayHost/Protocol.swift（v1，little-endian）。
 *
 * 视频分片不可靠（新帧覆盖旧帧）；按键/滚轮输入 seq+ack 超时重传；
 * 指针绝对坐标不重传（新值自然覆盖旧值）。
 */
class HostSession private constructor(
    private val address: InetAddress,
    private val port: Int,
    private val listener: Listener,
    private val pairingCode: Int,
    private val deviceId: Int,
    /** 不可逆的系统设备指纹；Host 用它把卸载后的新随机 ID 归并回原有显示器档案。 */
    private val deviceFingerprint: Long,
    /** 设备的系统显示名，仅用于 Host 菜单的当前会话标识，不参与设备身份。 */
    private val deviceName: String,
    /** 当前平板持久布局对应的目标副屏组；可在同一会话内随 HELLO 更新。 */
    @Volatile private var requestedDisplays: List<Pair<Int, Int>>,
    /** 由 Host 备份的跨卸载布局快照；与目标屏组一起原子语义地更新。 */
    @Volatile private var layout: LayoutState,
    private val network: android.net.Network?
) {
    interface Listener {
        fun onCursor(displayId: Int, x: Float, y: Float) // did=0=光标离开虚拟屏（隐藏）
        /** Host 从系统读取到的真实 BGRA 光标；位置仍由 onCursor 的 60Hz 小包驱动。 */
        fun onCursorImage(width: Int, height: Int, hotX: Int, hotY: Int, pixels: ByteArray)
        fun onWelcome(displayId: Int, codec: Int, width: Int, height: Int, fps: Int, controlEnabled: Boolean)
        fun onConfig(displayId: Int, codec: Int, paramSets: ByteArray)
        fun onVideoFragment(displayId: Int, frameId: Int, fragIdx: Int, fragCount: Int, keyframe: Boolean, payload: ByteArray)
        fun onDisplays(displays: List<DisplayInfo>)
        /** 卸载重装后，Host 回传该平板此前保存的布局；普通重连不会收到。 */
        fun onSavedLayout(layout: LayoutState)
        /** Host 的实测显示模式状态。只有 actualScale=2 的 ready 才能称为 Retina。 */
        fun onDisplayModeStatus(transaction: Int, status: Int, slot: Int, requestedScale: Int, actualScale: Int)
        /** 连续 unknown PONG：保存的地址/配对码可能已指向旧 Host，会话无法自愈。 */
        fun onSessionNeedsRediscovery()
        fun onLinkEvent(connected: Boolean)
    }

    class DisplayInfo(val id: Int, val width: Int, val height: Int, val name: String) {
        override fun toString(): String = name
    }

    /** 固定 15B 的跨端布局快照，不包含用户内容或设备原始标识。 */
    class LayoutState(
        val kind: Int = 0,
        val fractionPermille: Int = 5000,
        val sideLeft: Boolean = false,
        val pipRatio: Int = 0,
        val pipCustomW: Int = 0,
        val pipCustomH: Int = 0,
        val displayLongEdge: Int = 0,
        val pipLeft: Int = -1,
        val pipTop: Int = -1,
        /** 固定 15B 布局之后的向后兼容扩展。 */
        val displaySizePreset: Int = 0,
        /** 0=明确 1x，1=严格请求实际 Retina 2x。 */
        val clarity: Int = 0,
        val transaction: Int = 0
    ) {
        fun writeTo(out: ByteBuffer) {
            out.put(kind.coerceIn(0, 4).toByte())
            out.putShort(fractionPermille.coerceIn(2000, 8000).toShort())
            out.put(if (sideLeft) 1 else 0)
            out.put(pipRatio.coerceIn(0, 3).toByte())
            out.putShort(pipCustomW.coerceIn(0, 16_368).toShort())
            out.putShort(pipCustomH.coerceIn(0, 16_368).toShort())
            out.putShort(displayLongEdge.coerceIn(0, 16_368).toShort())
            out.putShort(pipLeft.coerceIn(-1, 16_368).toShort())
            out.putShort(pipTop.coerceIn(-1, 16_368).toShort())
        }

        companion object {
            const val WIRE_BYTES = 15
            fun readFrom(buf: ByteBuffer, offset: Int): LayoutState = LayoutState(
                kind = buf.get(offset).toInt() and 0xFF,
                fractionPermille = buf.getShort(offset + 1).toInt() and 0xFFFF,
                sideLeft = (buf.get(offset + 3).toInt() and 1) != 0,
                pipRatio = buf.get(offset + 4).toInt() and 0xFF,
                pipCustomW = buf.getShort(offset + 5).toInt() and 0xFFFF,
                pipCustomH = buf.getShort(offset + 7).toInt() and 0xFFFF,
                displayLongEdge = buf.getShort(offset + 9).toInt() and 0xFFFF,
                pipLeft = buf.getShort(offset + 11).toInt(),
                pipTop = buf.getShort(offset + 13).toInt()
            )
        }
    }

    companion object {
        private const val TAG = "HostSession"

        /**
         * 旧版安装内的设备 ID。保留已存值以保证普通升级绝不改 EDID；新安装时只是
         * 本地会话编号，跨卸载的身份由 [loadDeviceFingerprint] 负责。
         */
        fun loadOrCreateDeviceId(ctx: android.content.Context): Int {
            val prefs = ctx.getSharedPreferences("hyperdisplay", android.content.Context.MODE_PRIVATE)
            var id = prefs.getInt("deviceId", 0)
            if (id == 0) {
                id = java.util.Random().nextInt(Int.MAX_VALUE - 1) + 1
                prefs.edit().putInt("deviceId", id).apply()
            }
            return id
        }

        /**
         * Android ID 会随「设备 + 用户 + 签名证书」保持稳定，且不需要任何敏感权限。
         * 只取 SHA-256 的前 64 位发送给已配对的 Host；原始 Android ID 从不离开平板。
         */
        fun loadDeviceFingerprint(ctx: android.content.Context): Long {
            val androidId = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ANDROID_ID)
                ?: "unavailable"
            val digest = MessageDigest.getInstance("SHA-256")
                .digest("com.hyperdisplay.client/device-identity/v1:$androidId".toByteArray(Charsets.UTF_8))
            val fingerprint = ByteBuffer.wrap(digest, 0, Long.SIZE_BYTES)
                .order(ByteOrder.LITTLE_ENDIAN)
                .long
            // 0 是协议中的“旧客户端未提供指纹”保留值，极低概率碰到时改成 1。
            return if (fingerprint == 0L) 1L else fingerprint
        }

        fun loadDeviceDisplayName(ctx: android.content.Context): String {
            val customName = try {
                Settings.Global.getString(ctx.contentResolver, "device_name")
            } catch (_: Exception) { null }
            val fallback = Build.MODEL?.trim().orEmpty().ifBlank { "Android 设备" }
            return (customName?.trim().takeUnless { it.isNullOrBlank() } ?: fallback).take(48)
        }
        private const val TYPE_WELCOME = 0x01
        private const val TYPE_VIDEO_FRAG = 0x02
        private const val TYPE_CONFIG = 0x03
        private const val TYPE_INPUT_ACK = 0x05
        private const val TYPE_PONG = 0x06
        private const val TYPE_DISPLAYS = 0x07
        private const val TYPE_CURSOR = 0x08
        private const val TYPE_CURSOR_IMAGE = 0x09
        private const val TYPE_SAVED_LAYOUT = 0x0A
        private const val TYPE_DISPLAY_MODE_STATUS = 0x0B
        private const val TYPE_HELLO = 0x10
        private const val TYPE_KEYFRAME_REQ = 0x11
        private const val TYPE_INPUT = 0x12
        private const val TYPE_PING = 0x13
        private const val TYPE_SELECT_DISPLAY = 0x14
        private const val TYPE_CREATE_DISPLAY = 0x15
        private const val TYPE_DESTROY_DISPLAY = 0x16
        private const val TYPE_NACK = 0x17
        private const val TYPE_SUBSCRIBE_DISPLAYS = 0x18
        private const val TYPE_CURSOR_IMAGE_ACK = 0x19
        private const val TYPE_BYE = 0x1A
        private const val TYPE_LAYOUT_RESTORE_ACK = 0x1D
        private const val TYPE_DISPLAY_MODE_STATUS_ACK = 0x1E
        private const val DISPLAY_ID_BROADCAST = 0xFFFF
        private const val PROTO_VERSION = 1
        private const val RETRANSMIT_MS = 40L
        private const val MAX_TRIES = 12
        private const val PING_INTERVAL_MS = 1500L

        fun create(
            host: String,
            port: Int,
            listener: Listener,
            code: Int = 0,
            deviceId: Int = 0,
            deviceFingerprint: Long = 0L,
            deviceName: String = "",
            requestedDisplays: List<Pair<Int, Int>> = emptyList(),
            layout: LayoutState = LayoutState(),
            network: android.net.Network? = null
        ): HostSession? {
            return try {
                // M1 只支持数字 IPv4，避免主线程 DNS 解析
                val parts = host.split(".").map { it.toInt() }
                require(parts.size == 4 && parts.all { it in 0..255 })
                val addr = InetAddress.getByAddress(parts.map { it.toByte() }.toByteArray())
                HostSession(addr, port, listener, code, deviceId, deviceFingerprint, deviceName,
                    requestedDisplays.take(4), layout, network)
            } catch (e: Exception) {
                Log.e(TAG, "invalid host address: $host", e)
                null
            }
        }
    }

    private val socket = DatagramSocket().apply {
        receiveBufferSize = 4 shl 20
        sendBufferSize = 1 shl 20
        // mDNS 告诉我们端点来自哪张 Android Network。显式绑定后，同一个 Mac
        // 的 USB 与 Wi-Fi 地址可并存，切换不会被系统默认路由误送到另一张网卡。
        network?.bindSocket(this)
    }
    // USB 隧道模式（adb reverse，AGENTS.md §1 有线例外）：连 127.0.0.1 走 TCP
    // （帧格式 [len u32][payload]），Mac 侧 UsbTunnelController 桥接回 host 的 UDP。
    // WiFi 版平板没有原生 USB 网络共享时的有线通路；有线无损，TCP 无丢包重传惩罚。
    private val useTcpTunnel = address.hostAddress == "127.0.0.1"
    @Volatile private var tcpSocket: java.net.Socket? = null
    @Volatile private var tcpOut: java.io.OutputStream? = null
    private val tcpFrames = longArrayOf(0, 0, 0, 0, 0) // total/welcome/video/config/pong
    @Volatile private var running = true
    @Volatile private var threadLinkUp = false
    @Volatile private var lastPongAt = System.currentTimeMillis()
    /** unknown PONG 应只覆盖建屏期间的短窗口；连续多次才判定保存的 Host 已过期。 */
    @Volatile private var consecutiveUnknownPongs = 0
    /**
     * 合法 Host 会在接受 HELLO 后立即回一份 DISPLAYS（即使暂时是空列表）。
     * 因此「收到了 DISPLAYS，但还在建虚拟屏」不能被误判成保存的 Host 过期；否则
     * 客户端会在 macOS 正常回收旧屏的窗口里反复切 mDNS，反而把首次出画拖慢。
     */
    @Volatile private var receivedDisplaysForSession = false
    @Volatile private var remoteControlEnabled = true
    private val inputSeq = AtomicInteger(1)
    private val pingSeq = AtomicInteger(1)

    // Android 禁止主线程网络操作（NetworkOnMainThreadException）——
    // 所有出口包统一投递到该发送线程执行；触摸/看门狗/选屏都从主线程调用。
    private val sendThread = android.os.HandlerThread("hyperdisplay-send").apply { start() }
    private val sendHandler = android.os.Handler(sendThread.looper)

    private class Pending(val packet: ByteArray, @Volatile var lastSentAt: Long, @Volatile var tries: Int)
    private val pendingAcks = ConcurrentHashMap<Int, Pending>()

    /**
     * 光标样式是可靠的小状态，不应塞进视频 latest-frame 组装器。Host 发送一组不超过
     * 1KB 的 UDP 分片；只有完整 BGRA 位图才替换当前样式，乱序/重复包不会闪回旧光标。
     */
    private class CursorImageAssembler {
        private var assemblingId = -1
        private var deliveredId = -1
        private var width = 0
        private var height = 0
        private var hotX = 0
        private var hotY = 0
        private var parts: Array<ByteArray?> = emptyArray()
        private var received = 0

        data class Result(val id: Int, val width: Int, val height: Int,
                          val hotX: Int, val hotY: Int, val pixels: ByteArray)

        fun offer(id: Int, index: Int, count: Int, w: Int, h: Int, hx: Int, hy: Int,
                  payload: ByteArray): Result? {
            if (count !in 1..64 || index !in 0 until count || w !in 1..256 || h !in 1..256 ||
                w * h * 4 > 32 * 1024) return null
            // Host imageId 单调递增；旧重传到得更晚时绝不覆盖已经绘制的新形状。
            if (deliveredId >= 0 && id <= deliveredId) return null
            if (id != assemblingId) {
                assemblingId = id
                width = w; height = h; hotX = hx; hotY = hy
                parts = arrayOfNulls(count)
                received = 0
            }
            if (w != width || h != height || hx != hotX || hy != hotY || parts.size != count) return null
            if (parts[index] == null) {
                parts[index] = payload
                received++
            }
            if (received != count) return null
            val expected = width * height * 4
            val joined = ByteArray(expected)
            var offset = 0
            for (part in parts) {
                val bytes = part ?: return null
                if (offset + bytes.size > expected) return null
                System.arraycopy(bytes, 0, joined, offset, bytes.size)
                offset += bytes.size
            }
            if (offset != expected) return null
            deliveredId = id
            return Result(id, width, height, hotX, hotY, joined)
        }
    }
    private val cursorImageAssembler = CursorImageAssembler()

    private val thread = Thread({
        threadLinkUp = false // 每条新会话从「未连通」开始（否则旧会话的 true 会吞掉新会话的 onLinkEvent）
        lastPongAt = System.currentTimeMillis()
        consecutiveUnknownPongs = 0
        receivedDisplaysForSession = false
        if (useTcpTunnel) {
            // 独立心跳：TCP 读循环在有视频流时永不空闲，靠读超时触发 PING 会饿死
            // （链路永远判定不通 → 反复重连闪屏）。启动即 HELLO+PING，之后每 1.5s 一个 PING。
            sendHandler.postDelayed(object : Runnable {
                override fun run() {
                    if (!running) return
                    send(buildPacket(TYPE_PING, pingSeq.getAndIncrement()))
                    sendHandler.postDelayed(this, 1500)
                }
            }, 300)
            try {
                val s = java.net.Socket()
                s.tcpNoDelay = true
                // adb reverse 的监听绑在 IPv6（::）上，必须连 ::1 而不是 127.0.0.1
                val v6 = java.net.InetAddress.getByAddress(
                    byteArrayOf(0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,1))
                s.connect(java.net.InetSocketAddress(v6, port), 3000)
                s.soTimeout = 500 // 读超时驱动心跳周期任务
                tcpSocket = s
                tcpOut = s.getOutputStream()
            } catch (e: Exception) {
                Log.e(TAG, "tcp tunnel connect failed: ${e.javaClass.simpleName}: ${e.message}")
                running = false
                listener.onLinkEvent(false)
                return@Thread
            }
        }
        socket.soTimeout = 200
        sendHello()
        var lastPingAt = 0L
        val buf = ByteArray(65_536)
        if (useTcpTunnel) {
            // TCP 隧道接收循环
            val inp = tcpSocket?.getInputStream() ?: ByteArray(0).inputStream()
            val fbuf = ByteArray(65536 + 8)
            var acc = 0
            try {
                while (running) {
                    val n = try {
                        inp.read(fbuf, acc, fbuf.size - acc)
                    } catch (e: java.net.SocketTimeoutException) {
                        // 心跳与重连（与 UDP 循环同职责）
                        val now = System.currentTimeMillis()
                        send(buildPacket(TYPE_PING, pingSeq.getAndIncrement()))
                        val pongAge = now - lastPongAt
                        if (threadLinkUp && pongAge > 5000) {
                            threadLinkUp = false
                            listener.onLinkEvent(false)
                            sendHello()
                        }
                        if (!threadLinkUp && pongAge > 2500) {
                            sendHello()
                            lastPongAt = now
                        }
                        continue
                    }
                    if (n < 0) break
                    acc += n
                    tcpFrames[0] += n.toLong()
                    while (acc >= 4) {
                        val ln = ((fbuf[0].toInt() and 0xFF) or
                            ((fbuf[1].toInt() and 0xFF) shl 8) or
                            ((fbuf[2].toInt() and 0xFF) shl 16) or
                            ((fbuf[3].toInt() and 0xFF) shl 24))
                        if (ln <= 0 || ln > 65536) { acc = 0; break }
                        if (acc < 4 + ln) break
                        val pkt = fbuf.copyOfRange(4, 4 + ln)
                        System.arraycopy(fbuf, 4 + ln, fbuf, 0, acc - 4 - ln)
                        acc -= 4 + ln
                        when (pkt[0].toInt() and 0xFF) {
                            0x01 -> tcpFrames[1]++
                            0x02 -> tcpFrames[2]++
                            0x03 -> tcpFrames[3]++
                            0x06 -> tcpFrames[4]++
                        }
                        dispatch(pkt, ln)
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "tcp read loop died: ${e.javaClass.simpleName}: ${e.message}")
            }
            Log.i(TAG, "tcp frames: bytes=${tcpFrames[0]} welcome=${tcpFrames[1]} video=${tcpFrames[2]} config=${tcpFrames[3]} pong=${tcpFrames[4]}")
            if (running) { running = false; listener.onLinkEvent(false) }
        }
        while (running) {
            val now = System.currentTimeMillis()
            // 心跳 / 掉线重连（host 重启后靠重复 HELLO 重新入会）
            if (now - lastPingAt >= PING_INTERVAL_MS) {
                lastPingAt = now
                send(buildPacket(TYPE_PING, pingSeq.getAndIncrement()))
            }
            val pongAge = now - lastPongAt
            if (threadLinkUp && pongAge > 5000) {
                threadLinkUp = false
                listener.onLinkEvent(false)
                sendHello()
            }
            if (!threadLinkUp && now - lastPongAt > 2500) {
                // 未连通时持续重试 HELLO（host 重启/换网络后必须能无限重连，
                // 此前的 pongAge<4000 上限会导致断开 4 秒后永远不再尝试）
                sendHello()
                lastPongAt = now
            }
            // 输入 ARQ 重传
            retransmitDue(now)

            try {
                val packet = DatagramPacket(buf, buf.size)
                socket.receive(packet)
                val len = packet.length
                if (len < 5) continue
                dispatch(buf.copyOf(len), len)
            } catch (_: java.net.SocketTimeoutException) {
                // 周期循环继续
            } catch (e: Exception) {
                if (running) Log.e(TAG, "receive failed", e)
            }
        }
        socket.close()
    }, "hyperdisplay-session")

    private fun dispatch(pkt: ByteArray, len: Int) {
        val buf = pkt
        val bb = ByteBuffer.wrap(buf, 0, buf.size).order(ByteOrder.LITTLE_ENDIAN)
        when (buf[0].toInt() and 0xFF) {
                    TYPE_WELCOME -> {
                        // [displayId u16][proto u8][codec u8][w u16][h u16][fps u8][controlEnabled u8]
                        if (len < 14) return
                        val displayId = bb.getShort(5).toInt() and 0xFFFF
                        val proto = buf[7].toInt() and 0xFF
                        val codec = buf[8].toInt() and 0xFF
                        val w = bb.getShort(9).toInt() and 0xFFFF
                        val h = bb.getShort(11).toInt() and 0xFFFF
                        val fps = buf[13].toInt() and 0xFF
                        // 尾字段是新增的向后兼容字段；老 host 不带时默认可控制。
                        val controlEnabled = len < 15 || (buf[14].toInt() and 0xFF) != 0
                        if (proto == PROTO_VERSION) listener.onWelcome(displayId, codec, w, h, fps, controlEnabled)
                    }
                    TYPE_CONFIG -> {
                        // [displayId u16][codec u8][len u16][bytes]
                        val displayId = bb.getShort(5).toInt() and 0xFFFF
                        val codec = buf[7].toInt() and 0xFF
                        val paramLen = bb.getShort(8).toInt() and 0xFFFF
                        if (len >= 10 + paramLen) {
                            listener.onConfig(displayId, codec, buf.copyOfRange(10, 10 + paramLen))
                        }
                    }
                    TYPE_VIDEO_FRAG -> {
                        // [displayId u16][fragIdx u16][fragCount u16][flags u8][payload]
                        val frameId = bb.getInt(1)
                        val displayId = bb.getShort(5).toInt() and 0xFFFF
                        val fragIdx = bb.getShort(7).toInt() and 0xFFFF
                        val fragCount = bb.getShort(9).toInt() and 0xFFFF
                        val flags = buf[11].toInt() and 0xFF
                        val payloadStart = 12
                        // fragIdx ≥ fragCount = FEC 校验片（组号 = idx - count）。
                        // 曾在此 `fragIdx < fragCount` 一刀切丢弃校验片（与 iOS 同源坑）。
                        if (len > payloadStart && fragCount < 4096 && fragIdx < fragCount + 512) {
                            listener.onVideoFragment(displayId, frameId, fragIdx, fragCount, flags and 1 == 1,
                                buf.copyOfRange(payloadStart, len))
                        }
                    }
                    TYPE_DISPLAYS -> {
                        val count = buf[5].toInt() and 0xFF
                        var off = 6
                        val list = ArrayList<DisplayInfo>(count)
                        var ok = true
                        for (i in 0 until count) {
                            if (len < off + 9) { ok = false; break }
                            val id = bb.getInt(off)
                            val w = bb.getShort(off + 4).toInt() and 0xFFFF
                            val h = bb.getShort(off + 6).toInt() and 0xFFFF
                            val nameLen = buf[off + 8].toInt() and 0xFF
                            if (len < off + 9 + nameLen) { ok = false; break }
                            val name = String(buf, off + 9, nameLen, Charsets.UTF_8)
                            list.add(DisplayInfo(id, w, h, name))
                            off += 9 + nameLen
                        }
                        if (ok) {
                            receivedDisplaysForSession = true
                            listener.onDisplays(list)
                        }
                    }
                    TYPE_SAVED_LAYOUT -> {
                        if (len >= 5 + LayoutState.WIRE_BYTES) {
                            val base = LayoutState.readFrom(bb, 5)
                            // [D2][version][size][clarity] 是新 Host 可选尾部；旧包仍按基础布局恢复。
                            val restored = if (len >= 5 + LayoutState.WIRE_BYTES + 4 &&
                                (buf[5 + LayoutState.WIRE_BYTES].toInt() and 0xFF) == 0xD2 &&
                                (buf[6 + LayoutState.WIRE_BYTES].toInt() and 0xFF) == 1) {
                                LayoutState(
                                    kind = base.kind, fractionPermille = base.fractionPermille,
                                    sideLeft = base.sideLeft, pipRatio = base.pipRatio,
                                    pipCustomW = base.pipCustomW, pipCustomH = base.pipCustomH,
                                    displayLongEdge = base.displayLongEdge, pipLeft = base.pipLeft,
                                    pipTop = base.pipTop,
                                    displaySizePreset = buf[7 + LayoutState.WIRE_BYTES].toInt() and 0xFF,
                                    clarity = buf[8 + LayoutState.WIRE_BYTES].toInt() and 0xFF
                                )
                            } else base
                            listener.onSavedLayout(restored)
                        }
                    }
                    TYPE_DISPLAY_MODE_STATUS -> {
                        // [transaction seq u32][status][slot][requestedScale][actualScale]
                        if (len >= 9) {
                            val transaction = bb.getInt(1)
                            listener.onDisplayModeStatus(
                                transaction,
                                buf[5].toInt() and 0xFF,
                                buf[6].toInt() and 0xFF,
                                buf[7].toInt() and 0xFF,
                                buf[8].toInt() and 0xFF
                            )
                            // 状态属于控制通道：必须确认，Host 才停止短暂重发。
                            send(buildPacket(TYPE_DISPLAY_MODE_STATUS_ACK, transaction))
                        }
                    }
                    TYPE_CURSOR -> {
                        // [displayId u16][x f32][y f32]
                        if (len >= 15) {
                            val did = bb.getShort(5).toInt() and 0xFFFF
                            val fx = Float.fromBits(bb.getInt(7))
                            val fy = Float.fromBits(bb.getInt(11))
                            listener.onCursor(did, fx, fy)
                        }
                    }
                    TYPE_CURSOR_IMAGE -> {
                        // [fragIdx u16][fragCount u16][w u16][h u16][hotX i16][hotY i16][BGRA]
                        val payloadStart = 17
                        if (len <= payloadStart) return
                        val imageId = bb.getInt(1)
                        val index = bb.getShort(5).toInt() and 0xFFFF
                        val count = bb.getShort(7).toInt() and 0xFFFF
                        val w = bb.getShort(9).toInt() and 0xFFFF
                        val h = bb.getShort(11).toInt() and 0xFFFF
                        val hotX = bb.getShort(13).toInt()
                        val hotY = bb.getShort(15).toInt()
                        val complete = cursorImageAssembler.offer(
                            imageId, index, count, w, h, hotX, hotY, buf.copyOfRange(payloadStart, len))
                        if (complete != null) {
                            listener.onCursorImage(complete.width, complete.height, complete.hotX, complete.hotY, complete.pixels)
                            // ACK 使用 imageId 作公共头 seq；Host 最多短暂重发三轮，空闲时零定时器。
                            send(buildPacket(TYPE_CURSOR_IMAGE_ACK, complete.id))
                        }
                    }
                    TYPE_INPUT_ACK -> {
                        val seq = bb.getInt(1)
                        pendingAcks.remove(seq)
                    }
                    TYPE_PONG -> {
                        // 尾字节（老 host 无此字节则按 known）：host 是否仍有本会话的
                        // 可用显示器。UDP 端口漂移、BYE 回收、Host 重启后的空订阅都必须
                        // 立即重 HELLO；不能只在 threadLinkUp 后才做，否则冷启动收到
                        // unknown PONG 会被持续心跳掩盖，永远停在“等待 Mac 主机”。
                        val known = buf.size < 6 || (buf[5].toInt() and 0xFF) != 0
                        if (!known) {
                            Log.w(TAG, "host has no active displays for this session — re-HELLO")
                            sendHello()
                            // 不把 unknown PONG 当作“链路已正常”：等待下一枚 known PONG
                            // 才对 UI 宣布连通，避免空会话遮住等待提示。
                            threadLinkUp = false
                            // 合法 Host 建屏通常只会短暂返回 unknown。若连续约 9 秒仍无
                            // 可用屏，保存的地址或配对码大概率属于旧 Host；交给 Activity
                            // 重新 mDNS 发现，而不是无限发 HELLO 占用网络和 UI。
                            consecutiveUnknownPongs += 1
                            if (consecutiveUnknownPongs >= 6 && !receivedDisplaysForSession) {
                                consecutiveUnknownPongs = 0
                                listener.onSessionNeedsRediscovery()
                            } else if (receivedDisplaysForSession) {
                                // 建屏还未完成时只继续 HELLO/PING 等待，不能重发现。
                                consecutiveUnknownPongs = 0
                            }
                            return
                        }
                        consecutiveUnknownPongs = 0
                        if (known && !threadLinkUp) {
                            threadLinkUp = true
                            listener.onLinkEvent(true)
                        }
                        lastPongAt = System.currentTimeMillis()
                    }
        }
    }

    fun start() {
        thread.start()
    }

    fun close(sendBye: Boolean = true) {
        // 只有平板真正离开（后台/关闭）才发 BYE 并移除虚拟屏；USB↔Wi-Fi
        // 换路由时静默换 socket，让 Host 复用同一个稳定 EDID 的显示器对象。
        // BYE 不能复用普通异步 send：若先把它入队、随即 running=false，发送线程
        // 会把这枚包当作已关闭会话直接丢弃，Mac 只能等心跳超时才回收显示器。
        // 仍由专用发送线程执行网络 I/O；这里只等待很短的确认，避免主线程网络操作。
        if (sendBye && running) sendBeforeClose(buildPacket(TYPE_BYE, 0))
        running = false
        // 幂等：重连流程可能多次 close（自动降级/升级路径）
        if (!socket.isClosed) {
            try { socket.soTimeout = 1 } catch (_: Exception) { }
        }
        try { thread.join(500) } catch (_: InterruptedException) {}
        sendHandler.removeCallbacksAndMessages(null)
        sendThread.quitSafely()
        try { tcpSocket?.close() } catch (_: Exception) { }
        socket.close()
    }

    /** Host 只在收到此确认前保护旧档案；之后本次安装的用户设置立即成为新权威。 */
    fun acknowledgeSavedLayout() {
        send(buildPacket(TYPE_LAYOUT_RESTORE_ACK, 0))
    }

    /**
     * 布局/尺寸变更不需要断开 UDP 会话。保留旧解码 Surface 到 Host 的新屏首帧到来，
     * 避免“松手调分隔条 → 客户端主动清空画面 → 两边黑屏”。
     */
    fun updateDisplayTopology(displays: List<Pair<Int, Int>>, newLayout: LayoutState) {
        requestedDisplays = displays.take(4).map { it.first to it.second }
        layout = newLayout
        sendHello()
    }

    // MARK: 发送

    private fun buildPacket(type: Int, seq: Int, body: ByteArray = ByteArray(0)): ByteArray {
        val out = ByteArray(5 + body.size)
        out[0] = type.toByte()
        val bb = ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN)
        bb.putInt(1, seq)
        System.arraycopy(body, 0, out, 5, body.size)
        return out
    }

    private fun send(packet: ByteArray) {
        if (!running) return
        sendHandler.post {
            if (!running) return@post
            try {
                writePacket(packet)
            } catch (e: Exception) {
                if (running) Log.w(TAG, "send failed: ${e.javaClass.simpleName}: ${e.message}")
            }
        }
    }

    private fun sendBeforeClose(packet: ByteArray) {
        val written = CountDownLatch(1)
        sendHandler.post {
            try {
                writePacket(packet)
            } catch (e: Exception) {
                Log.w(TAG, "final BYE send failed: ${e.javaClass.simpleName}: ${e.message}")
            } finally {
                written.countDown()
            }
        }
        try {
            if (!written.await(250, TimeUnit.MILLISECONDS)) {
                Log.w(TAG, "final BYE send timed out; Host stale-session cleanup will handle it")
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    @Throws(java.io.IOException::class)
    private fun writePacket(packet: ByteArray) {
        val out = tcpOut
        if (useTcpTunnel && out != null) {
            val frame = ByteBuffer.allocate(4 + packet.size).order(ByteOrder.LITTLE_ENDIAN)
                .putInt(packet.size).put(packet).array()
            out.write(frame)
            out.flush()
        } else {
            socket.send(DatagramPacket(packet, packet.size, address, port))
        }
    }

    private fun sendHello() {
        val metrics = android.content.res.Resources.getSystem().displayMetrics
        val w = maxOf(metrics.widthPixels, metrics.heightPixels)
        val h = minOf(metrics.widthPixels, metrics.heightPixels)
        // [proto][w][h][code][deviceId][目标屏数][w,h]×n[fingerprint u64][layout 15B][name][extension]。
        // 首次默认一块平板尺寸；后续分屏/画中画则一次性让 Host 创建整组，避免先黑屏
        // 再逐块补建和错误地把它们当成新显示器。
        val specs = requestedDisplays.take(4)
        val nameBytes = deviceName.toByteArray(Charsets.UTF_8).copyOf(minOf(64, deviceName.toByteArray(Charsets.UTF_8).size))
        val body = ByteBuffer.allocate(14 + specs.size * 4 + Long.SIZE_BYTES + LayoutState.WIRE_BYTES + 1 + nameBytes.size + 8)
            .order(ByteOrder.LITTLE_ENDIAN)
            .put(PROTO_VERSION.toByte()).putShort(w.toShort()).putShort(h.toShort())
            .putInt(pairingCode).putInt(deviceId).put(specs.size.toByte())
        for ((sw, sh) in specs) {
            body.putShort(sw.coerceIn(640, 16_368).toShort())
            body.putShort(sh.coerceIn(480, 16_368).toShort())
        }
        body.putLong(deviceFingerprint)
        layout.writeTo(body)
        body.put(nameBytes.size.toByte()).put(nameBytes)
        // 放在 name 之后，旧 Host 仍会正确读取人类设备名并忽略本尾部。
        body.put(0xD2.toByte()).put(1).put(layout.displaySizePreset.coerceIn(0, 4).toByte())
            .put(layout.clarity.coerceIn(0, 1).toByte()).putInt(layout.transaction)
        send(buildPacket(TYPE_HELLO, 0, body.array()))
    }

    private fun retransmitDue(now: Long) {
        if (pendingAcks.isEmpty()) return
        val it = pendingAcks.entries.iterator()
        while (it.hasNext()) {
            val entry = it.next()
            val p = entry.value
            if (now - p.lastSentAt >= RETRANSMIT_MS) {
                if (p.tries >= MAX_TRIES) {
                    it.remove()
                    continue
                }
                p.tries++
                p.lastSentAt = now
                send(p.packet)
            }
        }
    }

    private fun sendReliable(body: ByteArray) {
        if (!remoteControlEnabled) return
        val seq = inputSeq.getAndIncrement()
        val packet = buildPacket(TYPE_INPUT, seq, body)
        pendingAcks[seq] = Pending(packet, System.currentTimeMillis(), 1)
        send(packet)
    }

    fun sendMove(displayId: Int, x: Float, y: Float) {
        if (!remoteControlEnabled) return
        val body = ByteBuffer.allocate(11).order(ByteOrder.LITTLE_ENDIAN)
            .putShort(displayId.toShort()).put(0).putFloat(x).putFloat(y).array()
        send(buildPacket(TYPE_INPUT, inputSeq.getAndIncrement(), body))
    }

    fun sendButton(displayId: Int, button: Int, down: Boolean, x: Float, y: Float) {
        val body = ByteBuffer.allocate(13).order(ByteOrder.LITTLE_ENDIAN)
            .putShort(displayId.toShort()).put(1).put(button.toByte()).put(if (down) 1 else 0.toByte())
            .putFloat(x).putFloat(y).array()
        sendReliable(body)
    }

    fun sendWheel(displayId: Int, dx: Float, dy: Float, x: Float, y: Float) {
        val body = ByteBuffer.allocate(19).order(ByteOrder.LITTLE_ENDIAN)
            .putShort(displayId.toShort()).put(2).putFloat(dx).putFloat(dy).putFloat(x).putFloat(y).array()
        sendReliable(body)
    }

    fun setRemoteControlEnabled(enabled: Boolean) {
        remoteControlEnabled = enabled
        if (!enabled) pendingAcks.clear()
    }

    /** displayId < 0 = 请求全部屏 */
    fun requestKeyframe(displayId: Int = -1) {
        val id = if (displayId < 0) DISPLAY_ID_BROADCAST else displayId
        val body = ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN).putShort(id.toShort()).array()
        send(buildPacket(TYPE_KEYFRAME_REQ, pingSeq.getAndIncrement(), body))
    }

    /** 请求 host 只重建该屏的编码器会话（绿屏自愈；不动屏/流——永生流架构） */
    fun sendEncoderReset(displayId: Int) {
        val body = java.nio.ByteBuffer.allocate(2).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            .putShort(displayId.toShort()).array()
        send(buildPacket(0x1B, 0, body))
    }

    /** 显示大小档位切换：host 落盘后自重启，客户端自动重连按新档建屏 */
    fun sendSetTier(displayId: Int, w: Int, h: Int) {
        val body = java.nio.ByteBuffer.allocate(6).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            .putShort(displayId.toShort()).putShort(w.toShort()).putShort(h.toShort()).array()
        send(buildPacket(0x1C, 0, body))
    }

    fun sendSubscribeDisplays(ids: List<Int>) {
        val body = ByteBuffer.allocate(1 + ids.size * 4).order(ByteOrder.LITTLE_ENDIAN)
            .put(ids.size.toByte())
        for (id in ids) body.putInt(id)
        send(buildPacket(TYPE_SUBSCRIBE_DISPLAYS, 0, body.array()))
    }

    fun selectDisplay(id: Int) {
        val body = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(id).array()
        send(buildPacket(TYPE_SELECT_DISPLAY, 0, body))
    }

    fun createDisplay(width: Int, height: Int, name: String) {
        val nameBytes = name.toByteArray(Charsets.UTF_8).copyOf(minOf(60, name.toByteArray(Charsets.UTF_8).size))
        val body = ByteBuffer.allocate(5 + nameBytes.size).order(ByteOrder.LITTLE_ENDIAN)
            .putShort(width.toShort()).putShort(height.toShort()).put(nameBytes.size.toByte())
            .put(nameBytes).array()
        send(buildPacket(TYPE_CREATE_DISPLAY, 0, body))
    }

    fun destroyDisplay(id: Int) {
        val body = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(id).array()
        send(buildPacket(TYPE_DESTROY_DISPLAY, 0, body))
    }

    fun sendNack(displayId: Int, frameId: Int, indices: List<Int>) {
        val body = ByteBuffer.allocate(8 + indices.size * 2).order(ByteOrder.LITTLE_ENDIAN)
            .putShort(displayId.toShort()).putInt(frameId).putShort(indices.size.toShort())
        for (i in indices) body.putShort(i.toShort())
        send(buildPacket(TYPE_NACK, 0, body.array()))
    }
}
