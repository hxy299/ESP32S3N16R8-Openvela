"""
relay_proxy.py — 让 WSL 能用上 Windows 本地代理（回环 -> 局域网可达）

## 问题背景

用户的 GitHub 加速器（Clash Verge / mihomo）监听 Windows 的
`127.0.0.1:7897`，**只绑回环**，所以 WSL（NAT 模式）访问不到：
  - WSL 里的 `127.0.0.1:7897` 是 WSL 自己的回环，不是 Windows 的
  - WSL 里 `<Windows IP>:7897` 连不上，因为 Clash 没监听那块网卡

开启 Clash 的 "Allow LAN" 能解决，但那要改用户配置。
本脚本是**免配置**方案：在 Windows 上再起一个转发代理，
绑 `0.0.0.0:8890`（WSL 可达），把 CONNECT 请求转交给 `127.0.0.1:7897`。

## 原理

两级 HTTP CONNECT 代理：

    客户端(WSL) --CONNECT--> 本脚本:8890 --CONNECT--> Clash:7897 --> 目标站点

本脚本只搬运 TCP 字节，不解密、不改流量。TLS 由客户端与目标站点
端到端完成，证书校验正常。

## 关键实现细节（踩过的坑）

1. **必须先回复客户端 200，再开始搬数据**：否则客户端会等，
   而本脚本在等上游，形成互等。
2. **搬运阶段必须清除 socket 超时**（`settimeout(None)`）：
   否则空闲超过超时时间会静默关闭隧道，表现为
   `ConnectionResetError: 远程主机强迫关闭了一个现有的连接`。
   （这是最初版本的 bug：TLS 握手刚完成就被重置）
3. **上游响应中 200 之后可能已附带数据**：要把剩余字节一并转给客户端，
   不能丢弃。

## 用法（Windows 侧）

    python relay_proxy.py [监听端口] [上游地址]

默认：`python relay_proxy.py 8890 127.0.0.1:7897`

WSL 侧：
    WI=$(ip route show default | awk '{print $3}' | head -1)
    export https_proxy=http://$WI:8890
    git config --global http.https://github.com/.proxy http://$WI:8890
    git ls-remote https://github.com/espressif/esp-hal-3rdparty.git HEAD

## 安全提示

监听 `0.0.0.0` 意味着**同一局域网内其他机器也能借用这个代理**。
仅在可信网络下使用，用完 Ctrl-C 停止。
"""

import socket
import sys
import threading

LISTEN_HOST = "0.0.0.0"
DEFAULT_PORT = 8890
DEFAULT_UPSTREAM = "127.0.0.1:7897"

MAX_HEADER = 65536
CONNECT_TIMEOUT = 20
HEADER_TIMEOUT = 30

_lock = threading.Lock()
_stats = {"conns": 0, "errors": 0}


def _bump(key):
    with _lock:
        _stats[key] += 1
        return _stats[key]


def _pipe(src, dst, tag):
    """单向搬运，直到某一端关闭。搬运期间不能有超时。"""
    try:
        src.settimeout(None)
        dst.settimeout(None)
    except OSError:
        pass
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def _recv_until_header(sock):
    """读到 \\r\\n\\r\\n 为止，返回 (header_bytes, leftover_bytes)。"""
    buf = b""
    while b"\r\n\r\n" not in buf:
        try:
            chunk = sock.recv(4096)
        except OSError:
            return None, b""
        if not chunk:
            return None, b""
        buf += chunk
        if len(buf) > MAX_HEADER:
            break
    idx = buf.find(b"\r\n\r\n")
    if idx < 0:
        return buf, b""
    return buf[: idx + 4], buf[idx + 4:]


def _handle(client, upstream_host, upstream_port):
    remote = None
    handed_off = False
    try:
        client.settimeout(HEADER_TIMEOUT)
        header, _ = _recv_until_header(client)
        if not header:
            return

        first = header.split(b"\r\n", 1)[0].decode("latin-1", "replace")
        parts = first.split()
        if len(parts) < 2:
            return
        if parts[0].upper() != "CONNECT":
            try:
                client.sendall(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
            except OSError:
                pass
            return

        target = parts[1]
        n = _bump("conns")

        # 连上游（Clash）
        try:
            remote = socket.create_connection(
                (upstream_host, upstream_port), timeout=CONNECT_TIMEOUT
            )
        except OSError as exc:
            e = _bump("errors")
            print("[%d] upstream %s:%d 连接失败: %s (errors=%d)"
                  % (n, upstream_host, upstream_port, exc, e), flush=True)
            try:
                client.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            except OSError:
                pass
            return

        # 把同样的 CONNECT 转给上游
        remote.settimeout(HEADER_TIMEOUT)
        remote.sendall(header)

        # 读上游的 CONNECT 响应，注意可能已附带数据
        up_resp, up_leftover = _recv_until_header(remote)
        if not up_resp:
            _bump("errors")
            print("[%d] 上游无响应 (%s)" % (n, target), flush=True)
            return

        status = up_resp.split(b"\r\n", 1)[0].decode("latin-1", "replace")
        ok = " 200 " in status

        # 【关键】先把 200 回给客户端，再开始搬数据，避免互等
        try:
            client.sendall(up_resp)
            if up_leftover:
                client.sendall(up_leftover)
        except OSError:
            return

        if not ok:
            e = _bump("errors")
            print("[%d] 上游拒绝 %s: %s (errors=%d)" % (n, target, status, e), flush=True)
            return

        # 【关键】搬数据前清掉超时，否则空闲久了会静默断链
        client.settimeout(None)
        remote.settimeout(None)

        threading.Thread(target=_pipe, args=(client, remote, "c2r"), daemon=True).start()
        threading.Thread(target=_pipe, args=(remote, client, "r2c"), daemon=True).start()
        handed_off = True
        remote = None
        client = None

    except Exception as exc:
        _bump("errors")
        print("handle error: %s: %s" % (type(exc).__name__, exc), flush=True)
    finally:
        if not handed_off:
            for s in (remote, client):
                if s is not None:
                    try:
                        s.close()
                    except OSError:
                        pass


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PORT
    upstream = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_UPSTREAM
    if ":" in upstream:
        uh, up = upstream.rsplit(":", 1)
        up = int(up)
    else:
        uh, up = upstream, 7897

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((LISTEN_HOST, port))
    srv.listen(128)

    print("relay_proxy: %s:%d -> %s:%d" % (LISTEN_HOST, port, uh, up), flush=True)

    try:
        while True:
            try:
                conn, _ = srv.accept()
            except OSError as exc:
                print("accept error: %s" % exc, flush=True)
                continue
            threading.Thread(target=_handle, args=(conn, uh, up), daemon=True).start()
    except KeyboardInterrupt:
        print("\nrelay_proxy: stopped", flush=True)
    finally:
        srv.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
