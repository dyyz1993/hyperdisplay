#!/usr/bin/env python3
"""USB 隧道桥：把 adb reverse 过来的 TCP 流与 host 的 UDP 端口互转。

链路: 平板 app --TCP(127.0.0.1:5280)--> [adb reverse 走 USB 线] --> Mac TCP:5280
      --> 本桥接 --> UDP 127.0.0.1:5277 (hyperdisplay host)，回程同理。

帧格式: [len u32 LE][payload]（与 app 的 TCP 模式一致）
用法: python3 usb-tunnel.py [tcp_port] [host_udp_port]   # 默认 5280 5277
前置: adb reverse tcp:<tcp_port> tcp:<tcp_port>
"""
import socket
import struct
import sys
import threading

TCP_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 5280
UDP_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 5277

udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp.bind(("127.0.0.1", 0))  # 源端口固定，host 会把回包发回这里
UDP_SRC = udp.getsockname()[1]

tcp_conn = None
tcp_lock = threading.Lock()


def tcp_to_udp(conn):
    global tcp_conn
    with tcp_lock:
        tcp_conn = conn
    try:
        buf = b""
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            buf += chunk
            while len(buf) >= 4:
                (ln,) = struct.unpack("<I", buf[:4])
                if ln == 0 or ln > 65536:
                    print("bad frame len", ln)
                    return
                if len(buf) < 4 + ln:
                    break
                payload = buf[4:4 + ln]
                buf = buf[4 + ln:]
                stats[0] += 1
                if payload and payload[0] == 0x12:
                    stats[1] += 1
                udp.sendto(payload, ("127.0.0.1", UDP_PORT))
    finally:
        with tcp_lock:
            tcp_conn = None
        conn.close()


def udp_to_tcp():
    while True:
        data, _ = udp.recvfrom(65536)
        stats[2] += 1
        if data and data[0] == 0x02:
            stats[3] += 1
        with tcp_lock:
            conn = tcp_conn
        if conn is None:
            continue
        try:
            conn.sendall(struct.pack("<I", len(data)) + data)
        except Exception:
            pass


stats = [0, 0, 0, 0]  # [上行帧, INPUT帧, 下行帧, 视频分片帧]
import threading as _t
def _stat():
    import time as _time
    while True:
        _time.sleep(3)
        print(f"up={stats[0]} inputs={stats[1]} down={stats[2]} videofrags={stats[3]}", flush=True)
_t.Thread(target=_stat, daemon=True).start()

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", TCP_PORT))
server.listen(2)
print(f"usb-tunnel: TCP :{TCP_PORT} <-> UDP 127.0.0.1:{UDP_PORT} (udp src port {UDP_SRC})")

threading.Thread(target=udp_to_tcp, daemon=True).start()
while True:
    conn, addr = server.accept()
    print("tunnel client:", addr)
    threading.Thread(target=tcp_to_udp, args=(conn,), daemon=True).start()
