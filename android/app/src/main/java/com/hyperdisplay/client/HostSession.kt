package com.hyperdisplay.client

import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
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
    private val listener: Listener
) {
    interface Listener {
        fun onWelcome(codec: Int, width: Int, height: Int, fps: Int)
        fun onConfig(codec: Int, paramSets: ByteArray)
        fun onVideoFragment(frameId: Int, fragIdx: Int, fragCount: Int, keyframe: Boolean, payload: ByteArray)
        fun onDisplays(displays: List<DisplayInfo>)
        fun onLinkEvent(connected: Boolean)
    }

    class DisplayInfo(val id: Int, val width: Int, val height: Int, val name: String) {
        override fun toString(): String = name
    }

    companion object {
        private const val TAG = "HostSession"
        private const val TYPE_WELCOME = 0x01
        private const val TYPE_VIDEO_FRAG = 0x02
        private const val TYPE_CONFIG = 0x03
        private const val TYPE_INPUT_ACK = 0x05
        private const val TYPE_PONG = 0x06
        private const val TYPE_DISPLAYS = 0x07
        private const val TYPE_HELLO = 0x10
        private const val TYPE_KEYFRAME_REQ = 0x11
        private const val TYPE_INPUT = 0x12
        private const val TYPE_PING = 0x13
        private const val TYPE_SELECT_DISPLAY = 0x14
        private const val TYPE_CREATE_DISPLAY = 0x15
        private const val TYPE_DESTROY_DISPLAY = 0x16
        private const val TYPE_NACK = 0x17
        private const val PROTO_VERSION = 1
        private const val RETRANSMIT_MS = 40L
        private const val MAX_TRIES = 12
        private const val PING_INTERVAL_MS = 1500L

        fun create(host: String, port: Int, listener: Listener): HostSession? {
            return try {
                // M1 只支持数字 IPv4，避免主线程 DNS 解析
                val parts = host.split(".").map { it.toInt() }
                require(parts.size == 4 && parts.all { it in 0..255 })
                val addr = InetAddress.getByAddress(parts.map { it.toByte() }.toByteArray())
                HostSession(addr, port, listener)
            } catch (e: Exception) {
                Log.e(TAG, "invalid host address: $host", e)
                null
            }
        }
    }

    private val socket = DatagramSocket().apply {
        receiveBufferSize = 4 shl 20
        sendBufferSize = 1 shl 20
    }
    @Volatile private var running = true
    private val inputSeq = AtomicInteger(1)
    private val pingSeq = AtomicInteger(1)

    // Android 禁止主线程网络操作（NetworkOnMainThreadException）——
    // 所有出口包统一投递到该发送线程执行；触摸/看门狗/选屏都从主线程调用。
    private val sendThread = android.os.HandlerThread("hyperdisplay-send").apply { start() }
    private val sendHandler = android.os.Handler(sendThread.looper)

    private class Pending(val packet: ByteArray, @Volatile var lastSentAt: Long, @Volatile var tries: Int)
    private val pendingAcks = ConcurrentHashMap<Int, Pending>()

    private val thread = Thread({
        socket.soTimeout = 200
        sendHello()
        var lastPingAt = 0L
        var linkUp = false
        var lastPongAt = System.currentTimeMillis()
        val buf = ByteArray(65_536)
        while (running) {
            val now = System.currentTimeMillis()
            // 心跳 / 掉线重连（host 重启后靠重复 HELLO 重新入会）
            if (now - lastPingAt >= PING_INTERVAL_MS) {
                lastPingAt = now
                send(buildPacket(TYPE_PING, pingSeq.getAndIncrement()))
            }
            val pongAge = now - lastPongAt
            if (linkUp && pongAge > 5000) {
                linkUp = false
                listener.onLinkEvent(false)
                sendHello()
            }
            if (!linkUp && pongAge < 4000 && now - lastPongAt > 2500) {
                // 未连通时低频重试 HELLO
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
                val bb = ByteBuffer.wrap(buf, 0, len).order(ByteOrder.LITTLE_ENDIAN)
                when (buf[0].toInt() and 0xFF) {
                    TYPE_WELCOME -> {
                        val proto = buf[5].toInt() and 0xFF
                        val codec = buf[6].toInt() and 0xFF
                        val w = bb.getShort(7).toInt() and 0xFFFF
                        val h = bb.getShort(9).toInt() and 0xFFFF
                        val fps = buf[11].toInt() and 0xFF
                        if (proto == PROTO_VERSION) listener.onWelcome(codec, w, h, fps)
                    }
                    TYPE_CONFIG -> {
                        val codec = buf[5].toInt() and 0xFF
                        val paramLen = bb.getShort(6).toInt() and 0xFFFF
                        if (len >= 8 + paramLen) {
                            listener.onConfig(codec, buf.copyOfRange(8, 8 + paramLen))
                        }
                    }
                    TYPE_VIDEO_FRAG -> {
                        val frameId = bb.getInt(1)
                        val fragIdx = bb.getShort(5).toInt() and 0xFFFF
                        val fragCount = bb.getShort(7).toInt() and 0xFFFF
                        val flags = buf[9].toInt() and 0xFF
                        val payloadStart = 10
                        if (len > payloadStart && fragIdx < fragCount && fragCount < 4096) {
                            listener.onVideoFragment(frameId, fragIdx, fragCount, flags and 1 == 1,
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
                        if (ok) listener.onDisplays(list)
                    }
                    TYPE_INPUT_ACK -> {
                        val seq = bb.getInt(1)
                        pendingAcks.remove(seq)
                    }
                    TYPE_PONG -> {
                        if (!linkUp) {
                            linkUp = true
                            listener.onLinkEvent(true)
                        }
                        lastPongAt = System.currentTimeMillis()
                    }
                }
            } catch (_: java.net.SocketTimeoutException) {
                // 周期循环继续
            } catch (e: Exception) {
                if (running) Log.e(TAG, "receive failed", e)
            }
        }
        socket.close()
    }, "hyperdisplay-session")

    fun start() {
        thread.start()
    }

    fun close() {
        running = false
        socket.soTimeout = 1 // 立刻打断阻塞的 receive
        try { thread.join(500) } catch (_: InterruptedException) {}
        sendHandler.removeCallbacksAndMessages(null)
        sendThread.quitSafely()
        socket.close()
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
                socket.send(DatagramPacket(packet, packet.size, address, port))
            } catch (e: Exception) {
                if (running) Log.w(TAG, "send failed: ${e.javaClass.simpleName}: ${e.message}")
            }
        }
    }

    private fun sendHello() {
        val metrics = android.content.res.Resources.getSystem().displayMetrics
        val w = maxOf(metrics.widthPixels, metrics.heightPixels)
        val h = minOf(metrics.widthPixels, metrics.heightPixels)
        val body = ByteBuffer.allocate(5).order(ByteOrder.LITTLE_ENDIAN)
            .put(PROTO_VERSION.toByte()).putShort(w.toShort()).putShort(h.toShort()).array()
        send(buildPacket(TYPE_HELLO, 0, body))
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
        val seq = inputSeq.getAndIncrement()
        val packet = buildPacket(TYPE_INPUT, seq, body)
        pendingAcks[seq] = Pending(packet, System.currentTimeMillis(), 1)
        send(packet)
    }

    fun sendMove(x: Float, y: Float) {
        val body = ByteBuffer.allocate(9).order(ByteOrder.LITTLE_ENDIAN)
            .put(0).putFloat(x).putFloat(y).array()
        send(buildPacket(TYPE_INPUT, inputSeq.getAndIncrement(), body))
    }

    fun sendButton(button: Int, down: Boolean, x: Float, y: Float) {
        val body = ByteBuffer.allocate(11).order(ByteOrder.LITTLE_ENDIAN)
            .put(1).put(button.toByte()).put(if (down) 1 else 0.toByte())
            .putFloat(x).putFloat(y).array()
        sendReliable(body)
    }

    fun sendWheel(dx: Float, dy: Float, x: Float, y: Float) {
        val body = ByteBuffer.allocate(17).order(ByteOrder.LITTLE_ENDIAN)
            .put(2).putFloat(dx).putFloat(dy).putFloat(x).putFloat(y).array()
        sendReliable(body)
    }

    fun requestKeyframe() {
        send(buildPacket(TYPE_KEYFRAME_REQ, pingSeq.getAndIncrement()))
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

    fun sendNack(frameId: Int, indices: List<Int>) {
        val body = ByteBuffer.allocate(6 + indices.size * 2).order(ByteOrder.LITTLE_ENDIAN)
            .putInt(frameId).putShort(indices.size.toShort())
        for (i in indices) body.putShort(i.toShort())
        send(buildPacket(TYPE_NACK, 0, body.array()))
    }
}
