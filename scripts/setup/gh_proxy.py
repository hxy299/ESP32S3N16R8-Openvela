#!/usr/bin/env python3
"""
gh_proxy.py — 绕过 github.com DNS 污染的本机 HTTP CONNECT 代理

## 问题背景

本项目所在的网络环境把 `github.com` 解析到 `127.0.0.1`（DNS 污染），
导致 `git clone https://github.com/...` 直接 "Connection refused"。
而 ESP32 全系列的 openvela 构建必须从 GitHub 克隆 `esp-hal-3rdparty`
及其 5 个子模块，因此不解决这个问题就无法编译。

实测发现：
  - `github.com`            -> 127.0.0.1        （被污染）
  - `codeload.github.com`   -> 20.205.243.165   （可达）
  - 直连 `20.205.243.166:443` 带 Host: github.com 返回 200（可达）

即：**真实服务可达，只是域名解析被劫持**。

## 原理

在本机回环地址起一个极简 HTTP CONNECT 代理。收到 `CONNECT github.com:443`
时**忽略域名**，一律连接到 `UPSTREAM_IP:443`。TLS 由客户端与真实
github.com 端到端完成，代理只搬运 TCP 字节，证书校验正常，无中间人风险。

**不需要修改 /etc/hosts，不需要 root/sudo。**

## 用法

    nohup python3 gh_proxy.py 8888 20.205.243.166 >/tmp/gh_proxy.log 2>&1 &
    git config --global http.https://github.com/.proxy http://127.0.0.1:8888
    git ls-remote https://github.com/espressif/esp-hal-3rdparty.git HEAD

推荐直接用封装脚本：`bash setup-github-proxy.sh`

## 健壮性设计

子模块克隆会并发发起多个连接，代理必须抗压：
  - 每个连接独立线程，异常被捕获，绝不影响其他连接
  - 上游连接失败时返回 502 而不是静默挂死
  - accept 循环本身不因单次异常退出
  - 连接数与错误数打印到日志，便于诊断

## 注意

- `github.com` 公网 IP 可能变化。失效时用
  `getent ahostsv4 codeload.github.com` 取新值，然后
  `GH_UPSTREAM_IP=<新IP> bash setup-github-proxy.sh`
- 只监听回环地址，不对外暴露。
"""

import socket
import sys
import threading

LISTEN_HOST = "127.0.0.1"
DEFAULT_PORT = 8888

# github.com 的候选 IP。
# 【为什么是列表】实测发现单个 IP 会失效：2026-10-10 时 20.205.243.166 的
# git 端点（/info/refs?service=git-upload-pack）已不通，而 140.82.112.4 /
# 140.82.113.4 可用。因此代理会按顺序尝试，直到有一个能建立连接。
#
# 【IP 全部失效时怎么找新的】
#   for ip in 140.82.112.4 140.82.113.4 ...; do
#     curl -s -o /dev/null -w "$ip %{http_code}\n" --resolve github.com:443:$ip \
#       "https://github.com/espressif/esp-hal-3rdparty.git/info/refs?service=git-upload-pack"
#   done
# 返回 200 的即可用。也可用 DoH 查真实 IP：
#   curl -s 'https://dns.alidns.com/resolve?name=github.com&type=A'
DEFAULT_UPSTREAMS = [
    "140.82.112.4",
    "140.82.113.4",
    "140.82.121.4",
    "20.205.243.166",
]

MAX_HEADER = 65536
ACCEPT_TIMEOUT = 30
UPSTREAM_TIMEOUT = 15

_lock = threading.Lock()
_stats = {"conns": 0, "errors": 0, "fallbacks": 0}


def _bump(key):
    with _lock:
        _stats[key] += 1
        return _stats[key]


def _connect_any(upstreams, port):
    """按顺序尝试候选 IP，返回 (socket, ip)。全失败则抛最后一个异常。"""
    last_exc = None
    for i, ip in enumerate(upstreams):
        try:
            s = socket.create_connection((ip, port), timeout=UPSTREAM_TIMEOUT)
            if i > 0:
                n = _bump("fallbacks")
                print("[fallback] 使用备用 IP %s (第 %d 次回退)" % (ip, n), flush=True)
            return s, ip
        except OSError as exc:
            last_exc = exc
            continue
    raise last_exc if last_exc else OSError("no upstream available")


def _pipe(src, dst):
    """单向搬运字节，直到任一方向关闭或出错。"""
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


def _handle(client, upstreams, upstream_port):
    remote = None
    try:
        client.settimeout(ACCEPT_TIMEOUT)

        # 读取 CONNECT 请求头
        buf = b""
        while b"\r\n\r\n" not in buf:
            try:
                chunk = client.recv(4096)
            except OSError:
                return
            if not chunk:
                return
            buf += chunk
            if len(buf) > MAX_HEADER:
                break

        first_line = buf.split(b"\r\n", 1)[0].decode("latin-1", "replace")
        parts = first_line.split()
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

        # 关键：忽略 CONNECT 中的域名，强制连到候选 IP 之一
        try:
            remote, used_ip = _connect_any(upstreams, upstream_port)
        except OSError as exc:
            e = _bump("errors")
            print(
                "[%d] upstream connect failed (%s): %s  (errors=%d)"
                % (n, target, exc, e),
                flush=True,
            )
            try:
                client.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            except OSError:
                pass
            return

        try:
            client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        except OSError:
            return
        client.settimeout(None)

        threading.Thread(target=_pipe, args=(client, remote), daemon=True).start()
        threading.Thread(target=_pipe, args=(remote, client), daemon=True).start()
        remote = None  # 所有权已交给 pipe 线程

    except Exception as exc:  # 兜底：单连接异常绝不拖垮主循环
        _bump("errors")
        print("handle error: %s: %s" % (type(exc).__name__, exc), flush=True)
    finally:
        if remote is not None:
            try:
                remote.close()
            except OSError:
                pass
        try:
            client.close()
        except OSError:
            pass


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PORT
    if len(sys.argv) > 2:
        # 支持逗号分隔的多个 IP
        upstreams = [x.strip() for x in sys.argv[2].split(",") if x.strip()]
    else:
        upstreams = list(DEFAULT_UPSTREAMS)
    upstream_port = int(sys.argv[3]) if len(sys.argv) > 3 else 443

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((LISTEN_HOST, port))
    srv.listen(256)

    print(
        "gh_proxy: CONNECT %s:%d -> try %s:%d"
        % (LISTEN_HOST, port, ",".join(upstreams), upstream_port),
        flush=True,
    )

    try:
        while True:
            try:
                conn, _ = srv.accept()
            except OSError as exc:
                print("accept error: %s" % exc, flush=True)
                continue
            threading.Thread(
                target=_handle, args=(conn, upstreams, upstream_port), daemon=True
            ).start()
    except KeyboardInterrupt:
        print("\ngh_proxy: stopped", flush=True)
    finally:
        srv.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
