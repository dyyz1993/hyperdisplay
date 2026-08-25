#!/usr/bin/env python3
"""USB vs WiFi A/B 数据采集（hyperdisplay 通道质量基准）

前置：host 运行中、平板 adb 在线、app 已打开且 smart 连上（任意通道）。
产出：/tmp/hyperdisplay-ab-<时间戳>.csv + 终端汇总表。

每秒采样（每个通道各 N 秒）：
  - transport / link（status.txt）
  - fps（该秒渲染帧数）与 rendered 累计（管线解码输出）
  - 控制包 RTT（对 host 5277 直发 PING×5 取均值/最大——测 host 端负载，
    隧道方向另测 5280 TCP RTT）
  - host keyframe 编码计数（日志累计，反映采集侧产出）
阶段：
  phase1 当前通道基线（默认 USB，若未连 USB 则提示）
  phase2 kill adb server 模拟拔线 → 等 WiFi 降级稳定 → 采样
  phase3 重启 adb → 等 USB 升级 → 采样（验证升级后恢复）
动画：每阶段由 vdanimate.swift 在虚拟屏制造确定性内容变化（若无此工具则跳过并标注）。

用法：python3 bench-ab.py [每阶段秒数=15]
"""
import socket, struct, subprocess, time, sys, os, glob, statistics

ADB = os.path.expanduser("~/Library/Android/sdk/platform-tools/adb")
SERIAL = "WXSYD23511203557"
HOST_LOG = "/tmp/hyperdisplay-flood.log"
CODE = 543062
PHASE_SECS = int(sys.argv[1]) if len(sys.argv) > 1 else 15

def setup_wifi_adb():
    """切换 adb 到 TCP 模式：P2 拔线模拟后仍能读平板状态。
    返回 TCP serial（如 192.168.0.10:5555），失败返回 None。"""
    ip = subprocess.run([ADB, "-s", SERIAL, "shell", "ip", "route"],
                        capture_output=True, text=True).stdout
    # "default via 192.168.0.1 dev wlan0 ..." → 取 wlan0 的源地址需另查；直接查 wlan0 ip
    ip = subprocess.run([ADB, "-s", SERIAL, "shell", "ip", "-f", "inet", "addr", "show", "wlan0"],
                        capture_output=True, text=True).stdout
    import re
    m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", ip)
    if not m:
        return None
    tip = m.group(1)
    subprocess.run([ADB, "-s", SERIAL, "tcpip", "5555"], capture_output=True)
    time.sleep(2)
    subprocess.run([ADB, "kill-server"], capture_output=True)
    subprocess.run([ADB, "start-server"], capture_output=True)
    r = subprocess.run([ADB, "connect", f"{tip}:5555"], capture_output=True, text=True)
    return f"{tip}:5555" if "connected" in r.stdout else None

def adb(*args):
    return subprocess.run([ADB, "-s", SERIAL] + list(args), capture_output=True, text=True).stdout.strip()

def status():
    out = adb("shell", "cat", "/sdcard/Android/data/com.hyperdisplay.client/files/status.txt")
    d = {}
    for kv in out.split():
        if "=" in kv:
            k, v = kv.split("=", 1)
            d[k] = v
    return d

def rtt_udp(n=5):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(1)
    rtts = []
    for i in range(n):
        t0 = time.time()
        s.sendto(struct.pack("<BIcHHI", 0x13, i, b"\x01", 800, 600, CODE), ("127.0.0.1", 5277))
        try:
            s.recvfrom(2048); rtts.append((time.time()-t0)*1000)
        except socket.timeout:
            pass
    s.close()
    return rtts

def rtt_tunnel(n=5):
    try:
        s = socket.create_connection(("127.0.0.1", 5280), 2); s.settimeout(1)
    except OSError:
        return None
    rtts = []
    for i in range(n):
        p = struct.pack("<BIcHHI", 0x13, i, b"\x01", 800, 600, CODE)
        t0 = time.time()
        try:
            s.sendall(struct.pack("<I", len(p)) + p)
            s.recv(64); rtts.append((time.time()-t0)*1000)
        except OSError:
            pass
    s.close()
    return rtts

def keyframe_count():
    try:
        with open(HOST_LOG) as f:
            return sum(1 for line in f if "keyframe encoded" in line)
    except FileNotFoundError:
        return -1

def animate():
    if os.path.exists("/tmp/vdanimate.swift"):
        return subprocess.Popen(["swift", "/tmp/vdanimate.swift"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return None

def sample_phase(name, secs, csv):
    anim = animate()
    rows = []
    print(f"\n=== {name}（{secs}s，动画进行中）===")
    for _ in range(secs):
        st = status()
        r_u = rtt_udp()
        r_t = rtt_tunnel()
        row = {
            "phase": name,
            "ts": time.strftime("%H:%M:%S"),
            "transport": st.get("transport", "?"),
            "link": st.get("link", "?"),
            "fps": st.get("fps", "0"),
            "rtt_udp_avg": round(statistics.mean(r_u), 2) if r_u else "",
            "rtt_udp_max": round(max(r_u), 2) if r_u else "",
            "rtt_tunnel_avg": round(statistics.mean(r_t), 2) if r_t else "",
            "keyframes_total": keyframe_count(),
        }
        rows.append(row)
        print(f"  {row['ts']} {row['transport']:<4} link={row['link']:<3} fps={row['fps']:>3} "
              f"rtt_udp={row['rtt_udp_avg']:>6}ms tunnel={row['rtt_tunnel_avg']:>6}ms")
        csv.write(",".join(str(v) for v in row.values()) + "\n"); csv.flush()
        time.sleep(1)
    if anim: anim.kill()
    fps_vals = [int(r["fps"]) for r in rows if r["fps"].isdigit()]
    if fps_vals:
        print(f"  → fps: avg={statistics.mean(fps_vals):.1f} max={max(fps_vals)} "
              f"非零占比={sum(1 for f in fps_vals if f>0)}/{len(fps_vals)}")
    return rows

csv_path = f"/tmp/hyperdisplay-ab-{time.strftime('%H%M%S')}.csv"
wifi_serial = setup_wifi_adb()
if wifi_serial:
    SERIAL = wifi_serial
    print(f"adb 已切 WiFi 模式（{SERIAL}）——拔线模拟期间状态采样不断")
else:
    print("⚠ WiFi adb 切换失败：P2（拔线模拟）期间将无法读取平板状态")

with open(csv_path, "w") as csv:
    csv.write("phase,ts,transport,link,fps,rtt_udp_avg,rtt_udp_max,rtt_tunnel_avg,keyframes_total\n")
    st = status()
    print(f"起始状态: transport={st.get('transport')} link={st.get('link')}")
    sample_phase("P1-USB基线", PHASE_SECS, csv)

    print("\n拔线模拟：adb kill-server（保持断开直到 P2 采样完）…")
    subprocess.run([ADB, "kill-server"], capture_output=True)
    time.sleep(6)
    sample_phase("P2-降级WiFi", PHASE_SECS, csv)

    print("\n恢复：adb start-server，等待 USB 自动升级（≤10s 探测）…")
    subprocess.run([ADB, "start-server"], capture_output=True, timeout=30)
    time.sleep(12)
    sample_phase("P3-升回USB", PHASE_SECS, csv)

print(f"\nCSV: {csv_path}")
