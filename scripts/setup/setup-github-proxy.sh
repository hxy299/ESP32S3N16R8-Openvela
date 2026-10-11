#!/usr/bin/env bash
#
# setup-github-proxy.sh — 解决 github.com DNS 污染，让 git 能克隆 esp-hal-3rdparty
#
# 用途：
#   本网络环境把 github.com 解析到 127.0.0.1，导致 ESP32-S3 的 openvela 构建
#   无法克隆 esp-hal-3rdparty 及其子模块。本脚本启动一个本机 CONNECT 代理
#   （scripts/setup/gh_proxy.py）并把它配置给 git。
#
# 为什么需要它：
#   ESP32/ESP32-S2/ESP32-S3/ESP32-C3 系列的 NuttX 构建会执行
#     git clone https://github.com/espressif/esp-hal-3rdparty.git
#   github.com 不通时构建必然失败（Make.defs:261）。
#
# 前置条件：python3 可用；不需要 root。
#
# 用法：
#   bash scripts/setup/setup-github-proxy.sh            # 启动并配置
#   bash scripts/setup/setup-github-proxy.sh --stop     # 停止并移除 git 配置
#   bash scripts/setup/setup-github-proxy.sh --status   # 查看状态
#
# 本脚本是幂等的：重复执行会复用已在运行的代理。
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY_PY="$SCRIPT_DIR/gh_proxy.py"
PORT="${GH_PROXY_PORT:-8888}"
LOG="${GH_PROXY_LOG:-/tmp/gh_proxy.log}"
# github.com 的真实 IP；若失效可用 `getent ahostsv4 codeload.github.com` 获取新值
UPSTREAM_IP="${GH_UPSTREAM_IP:-20.205.243.166}"

gitcfg_key="http.https://github.com/.proxy"
gitcfg_val="http://127.0.0.1:${PORT}"

is_running() { pgrep -f "gh_proxy.py" >/dev/null 2>&1; }

case "${1:-}" in
  --stop)
    echo "停止代理..."
    pkill -f "gh_proxy.py" && echo "已停止" || echo "（未在运行）"
    git config --global --unset "$gitcfg_key" 2>/dev/null && echo "已移除 git 代理配置" || true
    exit 0
    ;;
  --status)
    echo "代理进程 : $(is_running && echo 运行中 || echo 未运行)"
    echo "git 配置 : $(git config --global --get "$gitcfg_key" || echo '（无）')"
    echo "github.com 解析 : $(getent ahostsv4 github.com | head -1 | awk '{print $1}')"
    printf 'git 实测 : '
    timeout 20 git ls-remote https://github.com/espressif/esp-hal-3rdparty.git HEAD >/dev/null 2>&1 \
      && echo "可访问 OK" || echo "不可访问 FAIL"
    exit 0
    ;;
esac

echo "=== 1. 检查 github.com 解析 ==="
gh_ip=$(getent ahostsv4 github.com 2>/dev/null | head -1 | awk '{print $1}')
echo "github.com -> ${gh_ip:-（无解析）}"
if [ "$gh_ip" != "127.0.0.1" ] && [ -n "$gh_ip" ]; then
  echo "解析看起来正常，先直接测试 git..."
  if timeout 20 git ls-remote https://github.com/espressif/esp-hal-3rdparty.git HEAD >/dev/null 2>&1; then
    echo "git 可直接访问 github.com，无需代理。"
    exit 0
  fi
  echo "解析正常但访问失败，仍尝试代理方案。"
fi

echo
echo "=== 2. 启动本机 CONNECT 代理 ==="
if [ ! -f "$PROXY_PY" ]; then
  echo "错误：找不到 $PROXY_PY" >&2
  exit 1
fi
if is_running; then
  echo "代理已在运行，复用。"
else
  nohup python3 "$PROXY_PY" "$PORT" "$UPSTREAM_IP" >"$LOG" 2>&1 &
  sleep 2
  if is_running; then
    echo "已启动：$(cat "$LOG" 2>/dev/null | head -1)"
  else
    echo "启动失败，日志：" >&2
    cat "$LOG" 2>/dev/null >&2
    exit 1
  fi
fi

echo
echo "=== 3. 配置 git 走代理 ==="
git config --global "$gitcfg_key" "$gitcfg_val"
echo "已设置 $gitcfg_key = $gitcfg_val"

echo
echo "=== 4. 验证 ==="
if timeout 30 git ls-remote https://github.com/espressif/esp-hal-3rdparty.git HEAD; then
  echo
  echo "✅ 成功：git 现在可以访问 github.com"
  echo
  echo "后续如需重新编译 ESP32-S3，请确认代理在运行："
  echo "  bash $0 --status"
  echo
  echo "注意：本代理只在本机回环地址监听，不对外暴露；"
  echo "      TLS 由 git 与 github.com 端到端完成，无中间人风险。"
  exit 0
else
  echo
  echo "❌ 失败：代理已启动但 git 仍无法访问。" >&2
  echo "   可能是 github.com 的公网 IP 变了，请尝试：" >&2
  echo "     getent ahostsv4 codeload.github.com" >&2
  echo "     然后用新 IP 重跑：GH_UPSTREAM_IP=<新IP> bash $0" >&2
  exit 1
fi
