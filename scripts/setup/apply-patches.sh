#!/usr/bin/env bash
#
# apply-patches.sh — 把 thirdparty/patches/ 应用到 openvela 源码树
#
# 用途：
#   openvela 当前的 ESP32-S3 支持存在**两处上游 bug**，不修则无法编译。
#   本脚本把修复补丁按序应用到 ~/openvela。
#
# 补丁清单：
#   0001-esp32s3-add-missing-includes-for-wireless.patch
#        目标：nuttx 树
#        问题：esp32s3_wifi_utils.c 等文件缺 #include <nuttx/semaphore.h>，
#              导致 nxsem_post/nxsem_tickwait 隐式声明，链接期 undefined reference
#   0002-esp-hal-fix-spinlock-initializer.patch
#        目标：nuttx/arch/xtensa/src/esp32s3/esp-hal-3rdparty
#        问题：LOCK_INITIALIZER_UNLOCKED 定义为标量 0，而 NuttX 的 spinlock_t
#              是结构体，导致 "invalid initializer"，**所有 ESP32-S3 配置都编译不过**
#
# 用法：
#   bash scripts/setup/apply-patches.sh           # 应用
#   bash scripts/setup/apply-patches.sh --check   # 只检查状态
#   bash scripts/setup/apply-patches.sh --revert  # 撤销
#
# 幂等：重复执行不会重复打补丁。
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCHDIR="$PROJECT_ROOT/thirdparty/patches"
OPENVELA_ROOT="${OPENVELA_ROOT:-$HOME/openvela}"
NUTTX="$OPENVELA_ROOT/nuttx"
HAL="$NUTTX/arch/xtensa/src/esp32s3/esp-hal-3rdparty"

P1="$PATCHDIR/0001-esp32s3-add-missing-includes-for-wireless.patch"
P2="$PATCHDIR/0002-esp-hal-fix-spinlock-initializer.patch"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }

check_state() {
  echo "补丁状态检查："

  # 0001
  if [ -f "$NUTTX/arch/xtensa/src/esp32s3/esp32s3_wifi_utils.c" ]; then
    if grep -q 'nuttx/semaphore.h' "$NUTTX/arch/xtensa/src/esp32s3/esp32s3_wifi_utils.c"; then
      ok "0001 已应用（无线缺 include）"
    else
      warn "0001 未应用（启用 WiFi 时会链接失败）"
    fi
  else
    warn "0001 无法判断（找不到 esp32s3_wifi_utils.c）"
  fi

  # 0002
  if [ -f "$HAL/components/esp_hw_support/clk_ctrl_os.c" ]; then
    if grep -q 'define LOCK_INITIALIZER_UNLOCKED       {0}' \
         "$HAL/components/esp_hw_support/clk_ctrl_os.c"; then
      ok "0002 已应用（spinlock 初始化）"
    else
      bad "0002 未应用 —— 所有 ESP32-S3 配置都会编译失败"
    fi
  else
    warn "0002 无法判断（esp-hal-3rdparty 尚未克隆）"
  fi
}

case "${1:-}" in
  --check)
    check_state
    exit 0
    ;;
  --revert)
    echo "撤销补丁..."
    [ -d "$NUTTX/.git" ] && git -C "$NUTTX" checkout -- \
      arch/xtensa/src/esp32s3/esp32s3_wifi_utils.c \
      arch/xtensa/src/esp32s3/esp32s3_wireless.c \
      arch/xtensa/src/esp32s3/esp32s3_wifi_adapter.c 2>/dev/null \
      && ok "nuttx 侧已还原" || warn "nuttx 侧还原失败"
    [ -d "$HAL/.git" ] && git -C "$HAL" checkout -- \
      components/esp_hw_support/clk_ctrl_os.c \
      components/esp_hw_support/modem_clock.c 2>/dev/null \
      && ok "esp-hal 侧已还原" || warn "esp-hal 侧还原失败"
    check_state
    exit 0
    ;;
esac

echo "=============================================="
echo " 应用 openvela ESP32-S3 修复补丁"
echo " OPENVELA_ROOT = $OPENVELA_ROOT"
echo "=============================================="

[ -d "$NUTTX" ] || { bad "找不到 $NUTTX"; exit 1; }
[ -f "$P1" ] || { bad "缺少 $P1"; exit 1; }
[ -f "$P2" ] || { bad "缺少 $P2"; exit 1; }

# ---------------------------------------------------------- 0001
echo
echo "[1/2] 0001 无线缺 include（应用到 nuttx 树）"
if grep -q 'nuttx/semaphore.h' "$NUTTX/arch/xtensa/src/esp32s3/esp32s3_wifi_utils.c" 2>/dev/null; then
  ok "已应用，跳过"
else
  if git -C "$NUTTX" apply --check "$P1" 2>/dev/null; then
    git -C "$NUTTX" apply "$P1" && ok "已应用" || bad "应用失败"
  elif git -C "$NUTTX" apply --reverse --check "$P1" 2>/dev/null; then
    ok "已应用（reverse check 通过）"
  else
    bad "无法应用（源码树可能已变化，请人工检查）"
    echo "    可手动插入：在 esp32s3_wifi_utils.c / esp32s3_wireless.c 加"
    echo "      #include <nuttx/semaphore.h>"
    echo "    在 esp32s3_wifi_adapter.c 加"
    echo "      #include <nuttx/semaphore.h>"
    echo "      #include <nuttx/tls_task.h>"
  fi
fi

# ---------------------------------------------------------- 0002
echo
echo "[2/2] 0002 spinlock 初始化（应用到 esp-hal-3rdparty）"
if [ ! -d "$HAL/.git" ]; then
  warn "esp-hal-3rdparty 还不是 git 仓库，跳过"
  warn "（首次构建会自动克隆，克隆完成后再运行本脚本）"
else
  if grep -q 'define LOCK_INITIALIZER_UNLOCKED       {0}' \
       "$HAL/components/esp_hw_support/clk_ctrl_os.c" 2>/dev/null; then
    ok "已应用，跳过"
  else
    # 用 sed 直接改（比 patch 更耐受上下文漂移）
    sed -i 's/#define LOCK_INITIALIZER_UNLOCKED       0$/#define LOCK_INITIALIZER_UNLOCKED       {0}/' \
      "$HAL/components/esp_hw_support/clk_ctrl_os.c"
    sed -i 's/#define LOCK_INITIALIZER_UNLOCKED       0$/#define LOCK_INITIALIZER_UNLOCKED       {0}/' \
      "$HAL/components/esp_hw_support/modem_clock.c"
    if grep -q 'define LOCK_INITIALIZER_UNLOCKED       {0}' \
         "$HAL/components/esp_hw_support/clk_ctrl_os.c"; then
      ok "已应用"
    else
      bad "应用失败（未找到预期的宏定义）"
    fi
  fi
fi

echo
check_state
echo
echo "下一步：bash scripts/build/build-esp32s3.sh"
