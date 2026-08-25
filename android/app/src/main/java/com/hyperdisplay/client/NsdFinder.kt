package com.hyperdisplay.client

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
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

    enum class Transport { USB, WIFI, OTHER }

    class HostEntry(
        val name: String,
        val host: String,
        val port: Int,
        val code: Int = 0,
        val network: Network? = null,
        val transport: Transport = Transport.OTHER
    ) {
        override fun toString(): String = "$name ($host)"
    }

    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val main = Handler(Looper.getMainLooper())
    private var listener: NsdManager.DiscoveryListener? = null
    private var onHost: ((HostEntry) -> Unit)? = null
    private var onStart: (() -> Unit)? = null
    private var onStop: ((String?) -> Unit)? = null
    private val resolving = mutableSetOf<String>()

    /**
     * Android ROM 对 USB 网络共享的上报并不统一：AOSP 新版本可给
     * TRANSPORT_USB，许多设备则只给 ETHERNET，接口名为 rndis0 / usb0。
     * 后一种仍是标准 USB IP 网络，必须和前一种一样走 USB 优先的 UDP 路径。
     */
    private fun isUsbNetwork(caps: NetworkCapabilities?, link: LinkProperties?): Boolean {
        if (caps == null) return false
        if (Build.VERSION.SDK_INT >= 31 && caps.hasTransport(NetworkCapabilities.TRANSPORT_USB)) {
            return true
        }
        if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) return false
        val name = link?.interfaceName?.lowercase().orEmpty()
        return name.contains("rndis") || name.startsWith("usb")
    }
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
                main.post {
                    service?.serviceName?.let { lostName ->
                        found.keys.removeAll { it.startsWith("$lostName|") }
                    }
                }
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
        // NsdServiceInfo.getNetwork() 不是 Android 12 / API 31 的 API；华为
        // DBY2（Android 12）会在 mDNS 回调线程直接抛 NoSuchMethodError。它从
        // Android 13（API 33）才可用于按网络解析服务。旧系统继续使用默认网络
        // 的普通 mDNS，Wi-Fi 路径仍完全可用。
        val discoveredNetwork = if (Build.VERSION.SDK_INT >= 33) service.network else null
        val resolveKey = "$name|${discoveredNetwork?.networkHandle ?: 0L}"
        synchronized(resolving) {
            if (!resolving.add(resolveKey)) return
        }
        try {
            nsd.resolveService(service, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo?, errorCode: Int) {
                    synchronized(resolving) { resolving.remove(resolveKey) }
                    Log.w(TAG, "resolve failed: $name ($errorCode)")
                }

                override fun onServiceResolved(info: NsdServiceInfo?) {
                    synchronized(resolving) { resolving.remove(resolveKey) }
                    val host = info?.host?.hostAddress ?: return
                    val port = if ((info?.port ?: 0) > 0) info.port else 5277
                    // TXT 携带配对码（单用户家用网络，AGENTS.md §7.4）：发现即得码，零点击
                    val code = info?.attributes?.get("code")
                        ?.let { bytes -> String(bytes, Charsets.UTF_8).toIntOrNull() } ?: 0
                    val network = if (Build.VERSION.SDK_INT >= 33) info?.network else null
                    val caps = network?.let { connectivity.getNetworkCapabilities(it) }
                    val link = network?.let { connectivity.getLinkProperties(it) }
                    val transport = when {
                        isUsbNetwork(caps, link) -> Transport.USB
                        caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true -> Transport.WIFI
                        else -> Transport.OTHER
                    }
                    val entry = HostEntry(name, host, port, code, network, transport)
                    main.post {
                        // 同一个 Bonjour 服务可能同时从 Wi-Fi 与 USB 网络共享解析到不同
                        // 地址。不能只按服务名覆盖，否则无法做 USB 优先和 Wi-Fi 回退。
                        found["$name|$host|$port"] = entry
                        onHost?.invoke(entry)
                    }
                }
            })
        } catch (e: Exception) {
            // 并发 resolve 限制（IllegalStateException）：稍后由下次发现重试
            synchronized(resolving) { resolving.remove(resolveKey) }
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
