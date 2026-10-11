#!/usr/bin/env bash
#
# check-env.sh — openvela ESP32-S3 开发环境体检
#
# 用途：
#   在动手编译之前，一次性检查 ESP32-S3（N16R8）目标所需的全部前置条件，
#   并把已知的坑（GitHub DNS 污染、esp-hal 子模块、kconfig 等）逐条判定。
#
# 前置条件：WSL2 Ubuntu 22.04，openvela 源码在 $OPENVELA_ROOT（默认 ~/openvela）
#
# 用法：
#   bash scripts/setup/check-env.sh
#   OPENVELA_ROOT=/path/to/openvela bash scripts/setup/check-env.sh
#
# 退出码：0 = 全部通过；1 = 存在阻塞项
#
# 背景：本文档所述检查项均来自实际踩坑记录，见
#       docs/bringup/wsl-esp32s3-build-notes.md
#
set -uo pipefail

OPENVELA_ROOT="${OPENVELA_ROOT:-$HOME/openvela}"
TC_BIN="$OPENVELA_ROOT/prebuilts/gcc/linux-x86_64/xtensa-esp32s3-elf/bin"
HAL="$OPENVELA_ROOT/nuttx/arch/xtensa/src/esp32s3/esp-hal-3rdparty"
PROXY_PORT="${GH_PROXY_PORT:-8888}"

PASS=0
WARN=0
FAIL=0

ok()   { printf '  \033[32m[ OK ]\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
warn() { printf '  \033[33m[WARN]\033[0m %s\n' "$1"; WARN=$((WARN+1)); }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
sec()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

printf '\033[1mopenvela ESP32-S3 环境体检\033[0m\n'
printf 'OPENVELA_ROOT = %s\n' "$OPENVELA_ROOT"
printf '时间          = %s\n' "$(date '+%F %T')"

# ---------------------------------------------------------------- 1. 源码树
sec "1. openvela 源码树"
if [ -d "$OPENVELA_ROOT" ]; then
  ok "openvela 根目录存在"
else
  bad "找不到 $OPENVELA_ROOT（用 OPENVELA_ROOT=... 指定）"
fi

[ -d "$OPENVELA_ROOT/nuttx" ]                && ok "nuttx 内核树存在" || bad "缺少 nuttx/（可能被 distclean 误删，见文档的恢复方法）"
[ -d "$OPENVELA_ROOT/apps" ]                 && ok "apps 应用树存在"  || bad "缺少 apps/"
[ -d "$OPENVELA_ROOT/vendor/espressif" ]     && ok "vendor/espressif 存在" || warn "缺少 vendor/espressif（官方 ESP32-S3 板级配置在此）"

if [ -d "$OPENVELA_ROOT/nuttx/boards/xtensa/esp32s3" ]; then
  n=$(ls -1 "$OPENVELA_ROOT/nuttx/boards/xtensa/esp32s3" 2>/dev/null | wc -l)
  ok "ESP32-S3 板级目录共 $n 个"
else
  bad "缺少 nuttx/boards/xtensa/esp32s3"
fi

# ------------------------------------------------------------- 2. 交叉工具链
sec "2. Xtensa 交叉工具链"
if [ -x "$TC_BIN/xtensa-esp32s3-elf-gcc" ]; then
  ver=$("$TC_BIN/xtensa-esp32s3-elf-gcc" --version 2>/dev/null | head -1)
  ok "工具链存在：$ver"
  case "$ver" in
    *12.2.0*) ok "版本 12.2.0，与官方文档一致" ;;
    *)        warn "版本非 12.2.0，官方文档推荐 esp-12.2.0_20230208" ;;
  esac
else
  bad "缺少 $TC_BIN/xtensa-esp32s3-elf-gcc"
fi

if command -v xtensa-esp32s3-elf-gcc >/dev/null 2>&1; then
  ok "xtensa-esp32s3-elf-gcc 已在 PATH 中"
else
  warn "xtensa-esp32s3-elf-gcc 不在 PATH（build.sh 内部会处理，一般不影响）"
fi

# ------------------------------------------------------- 3. GitHub 可达性
sec "3. GitHub 可达性（ESP32 系列必需，最容易踩坑）"
gh_ip=$(getent ahostsv4 github.com 2>/dev/null | head -1 | awk '{print $1}')
cl_ip=$(getent ahostsv4 codeload.github.com 2>/dev/null | head -1 | awk '{print $1}')

printf '    github.com          -> %s\n' "${gh_ip:-（无解析）}"
printf '    codeload.github.com -> %s\n' "${cl_ip:-（无解析）}"

if [ "$gh_ip" = "127.0.0.1" ] || [ -z "$gh_ip" ]; then
  bad "github.com 被解析到 127.0.0.1（DNS 污染）→ git clone / 子模块会失败"
  echo "         解决：运行 scripts/setup/setup-github-proxy.sh 起本机 CONNECT 代理，"
  echo "               它会设置 git 的 http.https://github.com/.proxy"
else
  ok "github.com 解析正常（$gh_ip）"
fi

# 实测 git 是否真的能访问
if timeout 25 git ls-remote https://github.com/espressif/esp-hal-3rdparty.git HEAD >/dev/null 2>&1; then
  ok "git 实际可访问 github.com（clone 可用）"
else
  if pgrep -f gh_proxy.py >/dev/null 2>&1; then
    bad "代理在跑，但 git 仍访问不了 github.com（检查 http.proxy 配置）"
  else
    bad "git 无法访问 github.com，且未检测到本机代理进程"
    echo "         解决：bash scripts/setup/setup-github-proxy.sh"
  fi
fi

# --------------------------------------------------- 4. esp-hal-3rdparty
sec "4. esp-hal-3rdparty（ESP32 系列编译的核心外部依赖）"
if [ -d "$HAL/.git" ]; then
  ok "esp-hal-3rdparty 是完整 git 仓库（$(du -sh "$HAL" 2>/dev/null | cut -f1)）"

  # 关键：完整克隆才有的完整文件内容（部分克隆会得到空宏）
  f="$HAL/components/esp_hw_support/clk_ctrl_os.c"
  if [ -f "$f" ] && grep -q 'LOCK_INITIALIZER_UNLOCKED' "$f"; then
    ok "源码内容完整（clk_ctrl_os.c 宏定义正常）"
  else
    bad "源码内容不完整！很可能是用 --filter=blob:none 做的部分克隆"
    echo "         解决：删除 $HAL 后重新完整 clone（见文档）"
  fi

  missing=""
  for d in components/mbedtls/mbedtls components/esp_phy/lib components/esp_wifi/lib \
           components/bt/controller/lib_esp32c3_family components/esp_coex/lib; do
    if [ -z "$(ls -A "$HAL/$d" 2>/dev/null)" ]; then missing="$missing $d"; fi
  done
  if [ -z "$missing" ]; then
    ok "5 个必需子模块均已就位"
  else
    bad "以下子模块为空：$missing"
    echo "         解决：cd $HAL && git submodule update --init --depth=1 <path>"
  fi
else
  bad "esp-hal-3rdparty 不存在或不是 git 仓库"
  echo "         注意：NuttX 构建会尝试 git clone，github 不通时会直接失败"
fi

# ------------------------------------------------------------- 5. 烧录工具
sec "5. 烧录与串口工具"
if python3 -c "import esptool" 2>/dev/null; then
  ok "python3 可 import esptool（$(python3 -c 'import esptool;print(esptool.__version__)' 2>/dev/null)）"
else
  warn "未安装 esptool（烧录时需要；官方建议装在 venv：python3 -m venv myenv && pip install esptool）"
fi

if ls /dev/ttyUSB* /dev/ttyACM* >/dev/null 2>&1; then
  ok "检测到串口设备：$(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | tr '\n' ' ')"
else
  warn "WSL 中无 /dev/ttyUSB* 或 /dev/ttyACM*（WSL2 需 usbipd-win 透传 USB 串口）"
  echo "         Windows 侧：winget install usbipd && usbipd bind --busid <id> && usbipd attach --wsl --busid <id>"
fi

if command -v minicom >/dev/null 2>&1 || command -v picocom >/dev/null 2>&1; then
  ok "已安装串口终端工具"
else
  warn "未安装 minicom / picocom（看串口日志需要）"
fi

# --------------------------------------------------------------- 6. 构建依赖
sec "6. 构建依赖"
for t in make gcc g++ bison flex python3 git; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t"; else bad "缺少 $t"; fi
done

if command -v kconfig-conf >/dev/null 2>&1 || [ -x "$OPENVELA_ROOT/prebuilts/kconfig-frontends/bin/kconfig-conf" ]; then
  ok "kconfig-conf 可用（menuconfig / olddefconfig 需要）"
else
  warn "未找到 kconfig-conf（build.sh 会尝试自建；若自建失败会导致 olddefconfig 报错）"
fi

if command -v ninja >/dev/null 2>&1; then ok "ninja"; else warn "缺少 ninja（仅 --cmake 构建需要）"; fi

printf '\n\033[1m===== 汇总 =====\033[0m\n'
printf '  通过 %d 项，警告 %d 项，阻塞 %d 项\n' "$PASS" "$WARN" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
  printf '\n\033[31m存在阻塞项，建议先解决再编译。\033[0m\n'
  exit 1
fi
printf '\n\033[32m环境就绪，可以编译。\033[0m\n'
exit 0
