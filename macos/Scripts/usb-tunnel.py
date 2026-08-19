#!/usr/bin/env python3
"""USB 隧道桥：把 adb reverse 过来的 TCP 流与 host 的 UDP 端口互转。

链路: 平板 app --TCP(127.0.0.1:5280)--> [adb reverse 走 USB 线] --> Mac TCP:5280
      --> 本桥接 --> UDP 127.0.0.1:5277 (hyperdisplay host)，回程同理。

帧格式: [len u32 LE][payload]（与 app 的 TCP 模式一致）
架构: 每条 TCP 连接配一个独立 UDP 套接字（独立源端口），
      host 的回包天然按源端口路由回各自连接——探测与正式会话可并存，
      不存在旧实现「单连接互相抢占回程」的问题。
用法: python3 usb-tunnel.py [tcp_port] [host_udp_port]   # 默认 5280 5277
前置: adb reverse tcp:<tcp_port> tcp:<tcp_port>
"""
import socket
import struct
import sys
import threading

TCP_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 5280
UDP_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 5277


def serve(conn, peer):
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    # 2800x1840 关键帧 ≈ 220KB / 200 分片在 8ms 突发到达：默认接收缓冲（~78KB）
    # 会被冲爆、内核静默丢片，客户端永远凑不齐帧也不发 NACK（首片即丢）。
    # 4MB 足够整帧落地，由 sendall 向 USB 侧匀速排空。
    udp.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
    udp.bind(("127.0.0.1", 0))
    print(f"tunnel client {peer} udp_src={udp.getsockname()[1]}", flush=True)

    def udp_to_tcp():
        try:
            while True:
                data, _ = udp.recvfrom(65536)
                conn.sendall(struct.pack("<I", len(data)) + data)
        except Exception:
            pass

    t = threading.Thread(target=udp_to_tcp, daemon=True)
    t.start()

    try:
        buf = b""
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            buf += chunk
            while len(buf) >= 4:
                (ln,) = struct.unpack("<I", buf[:4])
                if ln <= 0 or ln > 65536:
                    print(f"bad frame len {ln}", flush=True)
                    return
                if len(buf) < 4 + ln:
                    break
                payload = buf[4:4 + ln]
                buf = buf[4 + ln:]
                print(f"rx type={payload[0] if payload else -1} len={ln} first={payload[:16].hex()}", flush=True)
                udp.sendto(payload, ("127.0.0.1", UDP_PORT))
    except Exception:
        pass
    finally:
        udp.close()
        conn.close()
        t.join(timeout=1)
        print(f"tunnel client {peer} closed", flush=True)


server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", TCP_PORT))
server.listen(4)
print(f"usb-tunnel: TCP :{TCP_PORT} <-> UDP 127.0.0.1:{UDP_PORT} (per-connection UDP sockets)", flush=True)

while True:
    conn, addr = server.accept()
    threading.Thread(target=serve, args=(conn, addr), daemon=True).start()
