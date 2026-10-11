#!/usr/bin/env bash
#
# flash.sh — 烧录 openvela 固件到 ESP32-S3
#
# ## 用法
#
#   bash scripts/flash/flash.sh <固件.bin> [串口设备]
#
# 示例：
#   bash scripts/flash/flash.sh assets/firmware/nuttx-esp32s3-eye-openvela-wifi.bin
#   bash scripts/flash/flash.sh /tmp/nuttx.bin /dev/ttyUSB0
#
# ## 关键事实（依据 NuttX tools/esp32s3/Config.mk）
#
#   - 工具是 **esptool.py**（不是 esptool-js），要求 >= 4.8.0
#   - 默认 **Simple Boot**：固件直接烧到 **0x0**，不需要 bootloader、不需要分区表
#   - 波特率默认 921600
#   - 物理连接必须用 **USB-ISP** 口（接 CH340 的那个），不是 USB-OTG
#   - 板载 ISP 一键下载电路，通常无需手动按 BOOT
#
# ## WSL 串口前置条件
#
#   WSL2 默认看不到 Windows 的 USB 串口。需要 usbipd-win 透传：
#     Windows 管理员 PowerShell:
#       winget install usbipd
#       usbipd list                          # 找到 CH340 的 BUSID
#       usbipd bind --busid <BUSID>          # 只需一次
#       usbipd attach --wsl --busid <BUSID>  # 每次插拔后都要重新执行
#   之后 WSL 里会出现 /dev/ttyUSB0（或 ttyUSB1）
#
# 详见 docs/bringup/wsl-esp32s3-build-notes.md
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CHIP="esp32s3"
BAUD="${BAUD:-921600}"
FLASH_ADDR="${FLASH_ADDR:-0x0}"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
info() { printf '\033[36m%s\033[0m\n' "$1"; }

usage() {
  cat <<EOF
用法: bash scripts/flash/flash.sh <固件.bin> [串口设备]

参数:
  固件.bin     要烧录的固件（默认烧到 $FLASH_ADDR）
  串口设备     如 /dev/ttyUSB0；省略时自动探测

环境变量:
  BAUD         波特率，默认 $BAUD
  FLASH_ADDR   烧录地址，默认 $FLASH_ADDR（Simple Boot）
  ERASE_FIRST  设为 1 则先整片擦除

可用固件:
$(ls -1 "$PROJECT_ROOT/assets/firmware/"*.bin 2>/dev/null | sed 's|^|  |' || echo "  (assets/firmware/ 下暂无 .bin)")
EOF
}

# ---------------------------------------------------------------- 参数
if [ $# -lt 1 ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

FW="$1"
PORT="${2:-}"

# 相对路径按项目根解析
if [ ! -f "$FW" ] && [ -f "$PROJECT_ROOT/$FW" ]; then
  FW="$PROJECT_ROOT/$FW"
fi

[ -f "$FW" ] || { bad "找不到固件：$1"; echo; usage; exit 1; }

info "openvela ESP32-S3 烧录"
echo "  固件   : $FW"
echo "  大小   : $(stat -c%s "$FW" 2>/dev/null || echo '?') 字节"
echo "  芯片   : $CHIP"
echo "  地址   : $FLASH_ADDR"
echo "  波特率 : $BAUD"
echo

# ---------------------------------------------------------------- 校验和
echo "固件校验和（建议与 assets/firmware/README.md 记录的值核对）："
if command -v md5sum >/dev/null 2>&1; then
  echo "  $(md5sum "$FW" | awk '{print "MD5     " $1}')"
fi
if command -v sha256sum >/dev/null 2>&1; then
  echo "  $(sha256sum "$FW" | awk '{print "SHA-256 " $1}')"
fi
echo

# ---------------------------------------------------------------- esptool
ESPTOOL=""
if command -v esptool.py >/dev/null 2>&1; then
  ESPTOOL="esptool.py"
elif [ -x "$HOME/.local/bin/esptool.py" ]; then
  ESPTOOL="$HOME/.local/bin/esptool.py"
elif python3 -c "import esptool" 2>/dev/null; then
  ESPTOOL="python3 -m esptool"
elif [ -x "$HOME/myenv/bin/python3" ] && "$HOME/myenv/bin/python3" -c "import esptool" 2>/dev/null; then
  ESPTOOL="$HOME/myenv/bin/python3 -m esptool"
else
  bad "找不到 esptool"
  echo "  安装：bash scripts/setup/setup-esptool.sh"
  echo "  （官方要求 >= 4.8.0；NuttX 的 MKIMAGE 调用命令名 esptool.py）"
  exit 1
fi
ok "esptool: $ESPTOOL"

# ---------------------------------------------------------------- 串口
if [ -z "$PORT" ]; then
  # 自动探测
  for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyACM0 /dev/ttyACM1; do
    [ -e "$p" ] && { PORT="$p"; break; }
  done
fi

if [ -z "$PORT" ]; then
  bad "找不到串口设备（/dev/ttyUSB* 或 /dev/ttyACM*）"
  echo
  echo "  WSL2 默认看不到 Windows 的 USB 串口，需要 usbipd-win 透传："
  echo "    1. Windows 管理员 PowerShell 执行："
  echo "         winget install usbipd"
  echo "         usbipd list"
  echo "         usbipd bind --busid <CH340 的 BUSID>"
  echo "         usbipd attach --wsl --busid <CH340 的 BUSID>"
  echo "    2. 然后回到 WSL 重新运行本脚本"
  echo
  echo "  也可以显式指定：bash $0 <固件> /dev/ttyUSB0"
  exit 1
fi

[ -e "$PORT" ] || { bad "串口不存在：$PORT"; exit 1; }
ok "串口: $PORT"

# 权限检查
if [ ! -r "$PORT" ] || [ ! -w "$PORT" ]; then
  warn "当前用户可能无权限访问 $PORT"
  echo "  解决：sudo usermod -aG dialout $USER  （然后重新登录 WSL）"
  echo "  或临时：sudo chmod 666 $PORT"
fi

# ---------------------------------------------------------------- 烧录
echo
info "开始烧录（Ctrl-C 可中断）"
echo

ERASE_ARG=""
if [ "${ERASE_FIRST:-0}" = "1" ]; then
  info "先整片擦除（ERASE_FIRST=1）"
  $ESPTOOL --chip "$CHIP" -p "$PORT" erase_flash || warn "擦除失败，继续尝试烧录"
  echo
fi

# shellcheck disable=SC2086
$ESPTOOL --chip "$CHIP" -p "$PORT" -b "$BAUD" \
  --before default-reset --after hard-reset \
  write_flash "$FLASH_ADDR" "$FW"
RC=$?

echo
if [ $RC -eq 0 ]; then
  info "烧录成功"
  echo
  echo "查看串口输出（115200 8N1）："
  echo "  minicom -D $PORT -b 115200"
  echo "  或 picocom -b 115200 $PORT"
  echo
  echo "上电后应出现 NSH 提示符：  nsh>"
  echo "先试这几条命令：  help  /  uname -a  /  free  /  ps  /  ifconfig"
else
  bad "烧录失败（rc=$RC）"
  echo
  echo "常见原因："
  echo "  - 插错口：必须用 USB-ISP（CH340），不是 USB-OTG"
  echo "  - 串口被占用：关掉 minicom / 串口助手"
  echo "  - 供电不足：换一根好点的 USB 线，或换 USB 口"
  echo "  - 波特率过高：试 BAUD=460800 或 BAUD=115200"
  echo "  - 需要擦除：ERASE_FIRST=1 bash $0 $FW $PORT"
fi

exit $RC
