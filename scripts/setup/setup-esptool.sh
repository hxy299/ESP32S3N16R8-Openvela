#!/usr/bin/env bash
#
# setup-esptool.sh — 按官方文档安装 esptool（用于生成 nuttx.bin）
#
# 用途：
#   NuttX 的 ESP32-S3 构建在最后一步用 esptool 把 nuttx (ELF) 转成 nuttx.bin。
#   没有 esptool 时**编译和链接都会成功**，但不会生成可烧录的 .bin。
#
# 官方要求（见 quickstart/development_board/ESP32-S3-EYE.md 第三节）：
#   1. 建议装在 Python 虚拟环境里，避免与系统包冲突
#   2. NuttX 要求 esptool >= 4.8.0（tools/esp32s3/Config.mk 中的 ESPTOOL_MIN_VERSION）
#
# 用法：
#   bash scripts/setup/setup-esptool.sh
#
# 本脚本做的事：
#   1. 若缺 python3-venv/python3-pip，尝试用 apt 安装（需要 sudo 密码，会提示）
#   2. 创建 ~/myenv 虚拟环境并 pip install esptool
#   3. 在 ~/.local/bin 放置 esptool.py 包装脚本（NuttX 的 MKIMAGE 规则调用这个名字）
#
# 说明：Ubuntu 22.04 上若 sudo 不可用，也可手动执行：
#   python3 -m venv ~/myenv && ~/myenv/bin/pip install esptool
#   mkdir -p ~/.local/bin
#   printf '#!/bin/bash\nexec "$HOME/myenv/bin/python3" -m esptool "$@"\n' > ~/.local/bin/esptool.py
#   chmod +x ~/.local/bin/esptool.py
#
set -uo pipefail

VENV="${VENV_DIR:-$HOME/myenv}"
LOCALBIN="$HOME/.local/bin"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
info() { printf '\033[36m%s\033[0m\n' "$1"; }

info "[1/4] 检查 python3 与 venv/pip"
python3 --version || { bad "没有 python3"; exit 1; }

NEED_APT=0
python3 -c "import venv" 2>/dev/null && ok "venv 模块可用" || { warn "缺少 venv 模块"; NEED_APT=1; }
python3 -m pip --version >/dev/null 2>&1 && ok "pip 可用" || { warn "缺少 pip"; NEED_APT=1; }

if [ "$NEED_APT" -eq 1 ]; then
  info "尝试安装 python3-venv / python3-pip（需要 sudo）"
  echo "  若下面提示密码失败，请手动执行："
  echo "    sudo apt install python3-venv python3-pip"
  echo "  然后重新运行本脚本。"
  echo
  if sudo -n true 2>/dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y python3-venv python3-pip
  else
    echo "  请输入 sudo 密码（或 Ctrl-C 退出后手动安装）："
    sudo apt-get update -qq && sudo apt-get install -y python3-venv python3-pip
  fi
  python3 -c "import venv" 2>/dev/null && ok "venv 现在可用" || bad "venv 仍不可用"
fi

info "[2/4] 创建虚拟环境 $VENV"
if [ -d "$VENV" ]; then
  ok "已存在，复用"
else
  python3 -m venv "$VENV" || { bad "创建虚拟环境失败"; exit 1; }
  ok "已创建"
fi

info "[3/4] 安装 esptool"
"$VENV/bin/python3" -m pip install --quiet --upgrade pip 2>/dev/null || true
"$VENV/bin/python3" -m pip install --quiet esptool || { bad "pip install esptool 失败"; exit 1; }
VER="$("$VENV/bin/python3" -c 'import esptool; print(esptool.__version__)' 2>/dev/null)"
ok "esptool $VER"

# 版本检查：NuttX 要求 >= 4.8.0
if [ -n "$VER" ]; then
  if printf '%s\n' "4.8.0" "$VER" | sort -V -C 2>/dev/null; then
    ok "版本满足 NuttX 要求（>= 4.8.0）"
  else
    warn "版本可能低于 NuttX 要求（>= 4.8.0），但通常仍可用"
  fi
fi

info "[4/4] 建立 esptool.py 入口（NuttX 的 MKIMAGE 调用此名字）"
mkdir -p "$LOCALBIN"
cat > "$LOCALBIN/esptool.py" <<EOS
#!/bin/bash
# 由 OpenvelaESP-BTSH/scripts/setup/setup-esptool.sh 生成
exec "$VENV/bin/python3" -m esptool "\$@"
EOS
chmod +x "$LOCALBIN/esptool.py"
ok "$LOCALBIN/esptool.py"
"$LOCALBIN/esptool.py" version 2>&1 | head -3

echo
echo "完成。构建脚本（scripts/build/build-esp32s3.sh）会自动把 $LOCALBIN 加入 PATH。"
