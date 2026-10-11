#!/usr/bin/env bash
#
# build-n16r8.sh — 一键构建 ESP32-S3-N16R8 的 openvela 固件
#
# ## 为什么需要这个脚本
#
# 本项目目标板（芯路城 ESP32-S3-N16R8）不是官方支持的板子。
# 官方只适配了 `esp32s3-eye` / `esp32s3-box`，且用的是 `WROOM1N4`（4MB Flash、
# 无 PSRAM 或 Quad PSRAM）。我们的板子是 **16MB Flash + 8MB Octal PSRAM**，
# 必须用专门的 defconfig。
#
# 本脚本把项目的 defconfig（`config/boards/esp32s3-n16r8-generic/defconfig.*`）
# 同步到 openvela 的板级目录，然后用官方 `build.sh` 构建。
#
# ## 为什么必须走代理
#
# 构建会检查/克隆 `esp-hal-3rdparty`（GitHub）。本网络下需要代理，
# 见 `docs/bringup/wsl-esp32s3-build-notes.md`。
#
# ## 用法
#
#   bash scripts/build/build-n16r8.sh nsh        # 最小配置（先验证能启动）
#   bash scripts/build/build-n16r8.sh wifi       # 加 WiFi
#   bash scripts/build/build-n16r8.sh ble        # 加 BLE
#   bash scripts/build/build-n16r8.sh blepsram   # BLE + PSRAM
#   bash scripts/build/build-n16r8.sh full       # BLE + WiFi + PSRAM
#
# 额外透传参数：bash scripts/build/build-n16r8.sh nsh menuconfig
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OPENVELA_ROOT="${OPENVELA_ROOT:-$HOME/openvela}"

BOARD_DIR_LOCAL="$PROJECT_ROOT/config/boards/esp32s3-n16r8-generic"
BOARD_DIR_VENDOR="$OPENVELA_ROOT/vendor/espressif/boards/esp32s3/esp32s3-devkit/configs"

usage() {
  cat <<EOF
用法: bash scripts/build/build-n16r8.sh <配置名> [build.sh 的额外参数...]

可用配置（对应 $BOARD_DIR_LOCAL/defconfig.<名>）：
$(ls -1 "$BOARD_DIR_LOCAL"/defconfig.* 2>/dev/null | sed 's|.*/defconfig\.|  |' || echo "  (暂无)")

示例：
  bash scripts/build/build-n16r8.sh nsh                 # 构建最小配置
  bash scripts/build/build-n16r8.sh nsh menuconfig      # 图形化调整
  bash scripts/build/build-n16r8.sh nsh distclean       # 清理
EOF
}

if [ $# -lt 1 ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

CFGNAME="$1"
shift

SRC="$BOARD_DIR_LOCAL/defconfig.$CFGNAME"
if [ ! -f "$SRC" ]; then
  echo "错误：找不到 $SRC"
  echo
  usage
  exit 1
fi

info() { printf '\033[36m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }

info "构建 ESP32-S3-N16R8（配置：$CFGNAME）"

# ---------------------------------------------------------- 1. 代理
if [ -f "$HOME/.openvela-proxy-env" ]; then
  # shellcheck disable=SC1090
  source "$HOME/.openvela-proxy-env"
  if [ -n "${https_proxy:-}" ] && \
     timeout 30 git ls-remote https://github.com/espressif/esp-hal-3rdparty.git HEAD >/dev/null 2>&1; then
    ok "GitHub 可达（代理 $https_proxy）"
  else
    warn "代理环境已载入但 GitHub 不可达，构建可能在获取 esp-hal 时失败"
    warn "检查中转代理是否在运行（Windows 侧 relay_proxy.py）"
  fi
else
  warn "未找到 ~/.openvela-proxy-env（GitHub 代理配置）"
fi

# ---------------------------------------------------------- 2. 工具链
TOOLCHAIN="$OPENVELA_ROOT/prebuilts/gcc/linux-x86_64/xtensa-esp32s3-elf/bin"
export PATH="$HOME/.local/bin:$HOME/myenv/bin:$TOOLCHAIN:$PATH"
command -v xtensa-esp32s3-elf-gcc >/dev/null 2>&1 \
  && ok "xtensa 工具链就绪" \
  || { bad "找不到 xtensa-esp32s3-elf-gcc"; exit 1; }
command -v esptool.py >/dev/null 2>&1 \
  && ok "esptool.py 就绪" \
  || warn "找不到 esptool.py（不会生成 nuttx.bin，见 scripts/setup/setup-esptool.sh）"

# ---------------------------------------------------------- 3. 补丁
if [ -f "$OPENVELA_ROOT/nuttx/arch/xtensa/src/esp32s3/esp-hal-3rdparty/components/esp_hw_support/clk_ctrl_os.c" ]; then
  if grep -q 'define LOCK_INITIALIZER_UNLOCKED       {0}' \
       "$OPENVELA_ROOT/nuttx/arch/xtensa/src/esp32s3/esp-hal-3rdparty/components/esp_hw_support/clk_ctrl_os.c"; then
    ok "上游 bug 补丁 0002 已应用"
  else
    bad "补丁 0002 未应用 —— 编译必然失败"
    warn "执行：bash scripts/setup/apply-patches.sh"
    exit 1
  fi
else
  warn "esp-hal-3rdparty 不存在，构建时会自动获取"
fi

# ---------------------------------------------------------- 4. 同步配置
info "同步配置到 openvela 板级目录"
mkdir -p "$BOARD_DIR_VENDOR/$CFGNAME"
cp "$SRC" "$BOARD_DIR_VENDOR/$CFGNAME/defconfig"
ok "defconfig -> $BOARD_DIR_VENDOR/$CFGNAME/defconfig"

# 【必需，踩过的坑】Make.defs 必须一起放过去
#
# 依据 nuttx/tools/configure.sh:174-194，它按此顺序找 Make.defs：
#   1. ${TOPDIR}/boards/*/*/${boarddir}/configs/${configdir}/Make.defs  (in-tree 板级)
#   2. ${TOPDIR}/boards/*/*/${boarddir}/scripts/Make.defs              (in-tree 板级 scripts)
#   3. ${configpath}/Make.defs                                         (配置目录自身)
#   4. ${configpath}/../../scripts/Make.defs
#   5. ${configpath}/../../../common/scripts/Make.defs
#
# 走 vendor/ 路径时 (1)(2) 落空；官方 esp32s3-eye 的 vendor 配置目录里也只有
# defconfig，靠 (5) 命中 vendor/espressif/boards/esp32s3/common/scripts/ —— 但
# **该目录在 vendor/espressif 里不存在**（只有 boards/*/scripts）。
# 所以对 esp32s3-devkit 必须显式提供 Make.defs，否则报：
#   "File Make.defs could not be found"   (rc=4)
SRC_MAKEDEFS="$OPENVELA_ROOT/nuttx/boards/xtensa/esp32s3/esp32s3-devkit/scripts/Make.defs"
if [ -r "$SRC_MAKEDEFS" ]; then
  cp "$SRC_MAKEDEFS" "$BOARD_DIR_VENDOR/$CFGNAME/Make.defs"
  ok "Make.defs -> $BOARD_DIR_VENDOR/$CFGNAME/Make.defs"
else
  bad "找不到板级 Make.defs: $SRC_MAKEDEFS"
  exit 1
fi

# ---------------------------------------------------------- 5. 必要的编译宏注入
#
# 【为什么必须注入】openvela 当前树的 ESP32-S3 BLE/WiFi 有 Kconfig 桥接缺口：
#
#   esp-hal 为 NuttX 提供静态配置头
#     esp-hal-3rdparty/nuttx/esp32s3/include/sdkconfig.h
#   它把无线相关宏包在条件里：
#     #ifdef CONFIG_ESPRESSIF_BLE          -> 34 个 CONFIG_BT_CTRL_* 宏
#     #if defined(CONFIG_ESPRESSIF_BLE) && defined(CONFIG_ESPRESSIF_WIFI)
#                                          -> CONFIG_ESP_COEX_SW_COEXIST_ENABLE
#
#   但 `CONFIG_ESPRESSIF_BLE` 的 Kconfig **只在 RISC-V 侧存在**
#   （arch/risc-v/src/common/espressif/Kconfig:505，且 depends on ESPRESSIF_ESP32C3）；
#   **Xtensa 侧完全没有它**，`config ESP32S3_BLE` 也没 select 它。
#
#   不注入的后果：esp_bt.h 的静态断言直接编译失败
#     error: static assertion failed: "please enable bluetooth in menuconfig..."
#
# 好在缺口很小 —— sdkconfig.h 里那些宏本身是齐备的，只被一个 #ifdef 挡住。
# 因此用 build.sh 的 -e 参数透传编译宏即可，**无需 patch 源码树**。
#
# 详见 docs/stages/stage-03-peripherals.md §3.1
EXTRA_DEFINES=()
if grep -q '^CONFIG_ESP32S3_BLE=y' "$SRC"; then
  EXTRA_DEFINES+=("-e" "-DCONFIG_ESPRESSIF_BLE=1")
  ok "检测到 BLE → 注入 -DCONFIG_ESPRESSIF_BLE=1"
fi
if grep -q '^CONFIG_ESP32S3_WIFI=y' "$SRC"; then
  EXTRA_DEFINES+=("-e" "-DCONFIG_ESPRESSIF_WIFI=1")
  ok "检测到 WiFi → 注入 -DCONFIG_ESPRESSIF_WIFI=1"
fi

# 记录构建指纹，便于回溯
FINGERPRINT="$BOARD_DIR_VENDOR/$CFGNAME/.btsh-build-info"
{
  echo "built_at=$(date '+%F %T')"
  echo "config_name=$CFGNAME"
  echo "source=$SRC"
  echo "extra_defines=${EXTRA_DEFINES[*]:-（无）}"
  echo "nuttx_commit=$(git -C "$OPENVELA_ROOT/nuttx" rev-parse HEAD 2>/dev/null)"
  echo "host=$(uname -a)"
} > "$FINGERPRINT"
ok "构建指纹已写入"

# ---------------------------------------------------------- 6. 构建
info "开始构建：./build.sh vendor/espressif/boards/esp32s3/esp32s3-devkit/configs/$CFGNAME/ ${EXTRA_DEFINES[*]:-} $*"
echo "----------------------------------------------"
cd "$OPENVELA_ROOT" || exit 1

# 官方要求：切换配置时清 .config / Make.defs
if printf '%s' "$*" | grep -q distclean; then
  rm -f nuttx/.config nuttx/Make.defs
fi

./build.sh "vendor/espressif/boards/esp32s3/esp32s3-devkit/configs/$CFGNAME/" \
  "${EXTRA_DEFINES[@]}" "$@"
RC=$?

echo "----------------------------------------------"
if [ $RC -eq 0 ]; then
  ok "构建成功"
  echo
  ls -la nuttx/nuttx nuttx/nuttx.bin nuttx/nuttx.hex 2>/dev/null
  echo
  if [ -f nuttx/nuttx ]; then
    xtensa-esp32s3-elf-size nuttx/nuttx 2>/dev/null
  fi
  echo
  echo "烧录："
  echo "  python -m esptool --chip esp32s3 -p COM4 -b 921600 write_flash 0x0 nuttx/nuttx.bin"
  echo "  （或在 WSL：bash scripts/flash/flash.sh nuttx/nuttx.bin）"
else
  bad "构建失败（rc=$RC）"
  echo "  排错参考：docs/bringup/wsl-esp32s3-build-notes.md"
fi

exit $RC
