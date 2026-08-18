package com.hyperdisplay.client

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * 局域网发现 hyperdisplay host（_hyperdisplay._udp）。
 * 发现 → 解析 → 回调 (名字, ip, port)；解析失败自动重试一次。
 */
class NsdFinder(context: Context) {
    companion object {
        private const val TAG = "NsdFinder"
        private const val SERVICE_TYPE = "_hyperdisplay._udp."
    }

    class HostEntry(val name: String, val host: String, val port: Int) {
        override fun toString(): String = "$name ($host)"
    }

    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val main = Handler(Looper.getMainLooper())
    private var listener: NsdManager.DiscoveryListener? = null
    private var onHost: ((HostEntry) -> Unit)? = null
    private var onStart: (() -> Unit)? = null
    private var onStop: ((String?) -> Unit)? = null
    private val resolving = mutableSetOf<String>()
    private val found = linkedMapOf<String, HostEntry>()
    private var startRetries = 0
    private var startedOnce = false

    fun setCallbacks(onStart: () -> Unit, onHost: (HostEntry) -> Unit, onStop: (String?) -> Unit) {
        this.onStart = onStart
        this.onHost = onHost
        this.onStop = onStop
    }

    fun startDiscovery() {
        stopDiscovery()
        found.clear()
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String?) {
                startRetries = 0
                startedOnce = true
                main.post { onStart?.invoke() }
            }

            override fun onServiceFound(service: NsdServiceInfo?) {
                if (!service?.serviceType.orEmpty().startsWith("_hyperdisplay")) return
                resolve(service)
            }

            override fun onServiceLost(service: NsdServiceInfo?) {
                main.post { service?.serviceName?.let { found.remove(it) } }
            }

            override fun onDiscoveryStopped(serviceType: String?) {
                if (!startedOnce) return // 启动失败后的 stop 回调，勿覆盖错误信息
                main.post { onStop?.invoke(null) }
            }

            override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) {
                if (startRetries < 1) {
                    // 部分机型首次注册偶发失败，稍后重试一次
                    startRetries++
                    listener = null
                    main.postDelayed({ startDiscovery() }, 500)
                    return
                }
                main.post { onStop?.invoke("发现启动失败 ($errorCode)：可改用扫码或手动输入 IP") }
            }

            override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) {}
        }
        listener = l
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
    }

    private fun resolve(service: NsdServiceInfo?) {
        val name = service?.serviceName ?: return
        synchronized(resolving) {
            if (!resolving.add(name)) return
        }
        try {
            nsd.resolveService(service, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo?, errorCode: Int) {
                    synchronized(resolving) { resolving.remove(name) }
                    Log.w(TAG, "resolve failed: $name ($errorCode)")
                }

                override fun onServiceResolved(info: NsdServiceInfo?) {
                    synchronized(resolving) { resolving.remove(name) }
                    val host = info?.host?.hostAddress ?: return
                    val port = if ((info?.port ?: 0) > 0) info.port else 5277
                    val entry = HostEntry(name, host, port)
                    main.post {
                        found[name] = entry
                        onHost?.invoke(entry)
                    }
                }
            })
        } catch (e: Exception) {
            // 并发 resolve 限制（IllegalStateException）：稍后由下次发现重试
            synchronized(resolving) { resolving.remove(name) }
            Log.w(TAG, "resolve busy: ${e.message}")
        }
    }

    fun stopDiscovery() {
        listener?.let {
            try { nsd.stopServiceDiscovery(it) } catch (_: Exception) { }
        }
        listener = null
    }

    fun currentHosts(): List<HostEntry> = synchronized(found) { found.values.toList() }
}
