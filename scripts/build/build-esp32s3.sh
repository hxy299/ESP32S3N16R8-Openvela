#!/usr/bin/env bash
#
# build.sh — 构建 openvela ESP32-S3 固件（官方 build.sh 的封装）
#
# 用法：
#   bash scripts/build/build-esp32s3.sh [配置目录] [构建选项...]
#
# 示例：
#   # 默认：ESP32-S3-EYE 的官方 openvela 配置（含 WiFi）
#   bash scripts/build/build-esp32s3.sh
#
#   # 自定义配置
#   bash scripts/build/build-esp32s3.sh vendor/espressif/boards/esp32s3/esp32s3-devkit/configs/btsh
#
#   # 图形化配置
#   bash scripts/build/build-esp32s3.sh "" menuconfig
#
#   # 清理后重建（切换架构/配置时**必须**）
#   bash scripts/build/build-esp32s3.sh "" distclean
#
# 本脚本自动处理四件官方文档未提及、但在本环境必需的事：
#   1. 把 Xtensa 工具链与 esptool 加入 PATH
#   2. 确保 github.com 代理在运行（ESP32 系列必须克隆 esp-hal-3rdparty）
#   3. 检查 esp-hal-3rdparty 是否完整（含子模块）
#   4. 检查已知的两处上游 bug 补丁是否已应用
#
# 背景与原理详见 docs/bringup/wsl-esp32s3-build-notes.md
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OPENVELA_ROOT="${OPENVELA_ROOT:-$HOME/openvela}"

DEFAULT_CFG="vendor/espressif/boards/esp32s3/esp32s3-eye/configs/openvela"
CFG="${1:-$DEFAULT_CFG}"
shift || true

# 传空字符串时用默认配置
[ -z "$CFG" ] && CFG="$DEFAULT_CFG"

TOOLCHAIN="$OPENVELA_ROOT/prebuilts/gcc/linux-x86_64/xtensa-esp32s3-elf/bin"
HAL="$OPENVELA_ROOT/nuttx/arch/xtensa/src/esp32s3/esp-hal-3rdparty"
LOCALBIN="$HOME/.local/bin"
VENVBIN="$HOME/myenv/bin"

die() { printf '\033[31m错误：%s\033[0m\n' "$1" >&2; exit 1; }
info() { printf '\033[36m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }

echo "=============================================="
echo " openvela ESP32-S3 构建"
echo " 配置：$CFG"
echo " 选项：$*"
echo "=============================================="

# ------------------------------------------------ 1. 源码树检查
info "[1/5] 检查源码树"
[ -d "$OPENVELA_ROOT/nuttx" ] || die "找不到 $OPENVELA_ROOT/nuttx（参考 build-notes 的恢复方法）"
[ -f "$OPENVELA_ROOT/build.sh" ] || die "找不到 $OPENVELA_ROOT/build.sh"
ok "openvela 源码树存在"

# ------------------------------------------------ 2. PATH 准备
info "[2/5] 准备 PATH"
export PATH="$LOCALBIN:$VENVBIN:$TOOLCHAIN:$PATH"

if command -v xtensa-esp32s3-elf-gcc >/dev/null 2>&1; then
  ok "xtensa-esp32s3-elf-gcc: $(xtensa-esp32s3-elf-gcc -dumpversion 2>/dev/null)"
else
  die "找不到 xtensa-esp32s3-elf-gcc（$TOOLCHAIN）"
fi

# esptool 用于生成 nuttx.bin；缺失时链接会成功但不出 .bin
if command -v esptool.py >/dev/null 2>&1; then
  ok "esptool.py 可用"
elif python3 -c "import esptool" 2>/dev/null; then
  ok "python3 可 import esptool"
else
  warn "找不到 esptool —— 编译会成功，但不会生成 nuttx.bin"
  warn "安装：bash scripts/setup/setup-esptool.sh"
fi

# ------------------------------------------------ 3. GitHub 代理
info "[3/5] 检查 GitHub 连通性（ESP32 系列必需）"
if timeout 20 git ls-remote https://github.com/espressif/esp-hal-3rdparty.git HEAD >/dev/null 2>&1; then
  ok "github.com 可访问"
else
  warn "github.com 不可访问，尝试启动代理"
  if [ -f "$PROJECT_ROOT/scripts/setup/setup-github-proxy.sh" ]; then
    bash "$PROJECT_ROOT/scripts/setup/setup-github-proxy.sh" >/tmp/btsh_proxy_setup.log 2>&1 \
      && ok "代理已就绪" \
      || { warn "代理启动失败，详见 /tmp/btsh_proxy_setup.log"; }
  else
    warn "未找到 setup-github-proxy.sh"
  fi
fi

# ------------------------------------------------ 4. esp-hal 完整性
info "[4/5] 检查 esp-hal-3rdparty"
if [ -d "$HAL/.git" ]; then
  ok "git 仓库存在（$(du -sh "$HAL" 2>/dev/null | cut -f1)）"
  MISSING=""
  for d in components/mbedtls/mbedtls components/esp_phy/lib components/esp_wifi/lib \
           components/bt/controller/lib_esp32c3_family components/esp_coex/lib; do
    [ -z "$(ls -A "$HAL/$d" 2>/dev/null)" ] && MISSING="$MISSING $d"
  done
  if [ -n "$MISSING" ]; then
    warn "子模块为空：$MISSING"
    warn "执行：cd $HAL && git submodule update --init --depth=1 <path>"
  else
    ok "5 个必需子模块就位"
  fi
else
  warn "esp-hal-3rdparty 不存在（构建时会自动克隆，需 github 可达）"
fi

# ------------------------------------------------ 5. 上游 bug 补丁
info "[5/5] 检查上游 bug 补丁"
PATCH_APPLIED=1

# bug 1: esp-hal 的 spinlock 初始化（不修则所有 ESP32-S3 配置都编译失败）
if [ -d "$HAL" ]; then
  f="$HAL/components/esp_hw_support/clk_ctrl_os.c"
  if [ -f "$f" ] && grep -q 'define LOCK_INITIALIZER_UNLOCKED       {0}' "$f"; then
    ok "补丁 0002（spinlock 初始化）已应用"
  else
    warn "补丁 0002（spinlock 初始化）**未应用** —— 编译会失败！"
    warn "执行：bash scripts/setup/apply-patches.sh"
    PATCH_APPLIED=0
  fi
fi

# bug 2: 无线相关文件缺 include
W="$OPENVELA_ROOT/nuttx/arch/xtensa/src/esp32s3"
if [ -f "$W/esp32s3_wifi_utils.c" ]; then
  if grep -q 'nuttx/semaphore.h' "$W/esp32s3_wifi_utils.c"; then
    ok "补丁 0001（无线缺 include）已应用"
  else
    warn "补丁 0001（无线缺 include）未应用 —— 启用 WiFi 时会链接失败"
    warn "（若本次配置不含 WiFi，可忽略）"
  fi
fi

if [ "$PATCH_APPLIED" -eq 0 ]; then
  die "关键补丁未应用，停止构建。请先运行 scripts/setup/apply-patches.sh"
fi

# ------------------------------------------------ 构建
echo
info "开始构建：./build.sh $CFG $*"
echo "----------------------------------------------"
cd "$OPENVELA_ROOT" || die "无法进入 $OPENVELA_ROOT"
echo

# 官方要求：切换配置时清理。若是 distclean 请求，先清理配置残留。
if printf '%s' "$*" | grep -q distclean; then
  info "检测到 distclean 请求，先清理 .config / Make.defs"
  rm -f "$OPENVELA_ROOT/nuttx/.config" "$OPENVELA_ROOT/nuttx/Make.defs"
fi

./build.sh "$CFG" "$@"
RC=$?

echo "----------------------------------------------"
if [ $RC -eq 0 ]; then
  info "构建成功"
  echo
  echo "产物："
  ls -la "$OPENVELA_ROOT/nuttx/nuttx" \
         "$OPENVELA_ROOT/nuttx/nuttx.bin" \
         "$OPENVELA_ROOT/nuttx/nuttx.hex" 2>/dev/null
  if [ -f "$OPENVELA_ROOT/nuttx/nuttx" ]; then
    echo
    xtensa-esp32s3-elf-size "$OPENVELA_ROOT/nuttx/nuttx" 2>/dev/null
  fi
  echo
  echo "烧录（开发板到手后）："
  echo "  cd $OPENVELA_ROOT/nuttx"
  echo "  make flash ESPTOOL_PORT=/dev/ttyUSB0 ESPTOOL_BINDIR=./"
else
  printf '\033[31m构建失败（rc=%d）\033[0m\n' "$RC"
  echo "排错请参考 docs/bringup/wsl-esp32s3-build-notes.md"
fi

exit $RC
