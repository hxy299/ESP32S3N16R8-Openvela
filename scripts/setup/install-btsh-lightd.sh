#!/bin/bash
# 把 TCP 灯控守护进程安装进 openvela 树
#
# 幂等：可重复执行。--check 只检查，--revert 卸载。
#
# 用法：
#   bash scripts/setup/install-btsh-lightd.sh [--check|--revert]
#
set -u

OPENVELA="${OPENVELA_DIR:-$HOME/openvela}"
APPS="$OPENVELA/apps"
DEST="$APPS/wireless/bluetooth/btsh_lightd"
SRC="$(cd "$(dirname "$0")/../.." && pwd)/src/app/lightd"
BT_KCONFIG="$APPS/wireless/bluetooth/Kconfig"

MODE="install"
case "${1:-}" in
  --check)  MODE="check"  ;;
  --revert) MODE="revert" ;;
esac

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
hdr() { printf '\n\033[36m%s\033[0m\n' "$*"; }

hdr "1. 检查源文件"
for f in btsh_lightd_main.c Kconfig Makefile Make.defs; do
  if [ -f "$SRC/$f" ]; then
    printf '  %-22s ok  %s 字节\n' "$f" "$(stat -c%s "$SRC/$f")"
  else
    red "  ✗ 缺少 $SRC/$f"; exit 1
  fi
done

hdr "2. 目标环境"
[ -d "$APPS/wireless/bluetooth" ] || { red "  ✗ 找不到 $APPS/wireless/bluetooth"; exit 1; }
echo "  DEST = $DEST"

if [ "$MODE" = "check" ]; then
  hdr "3. 检查安装状态"
  [ -d "$DEST" ] && grn "  ✓ 已安装" || ylw "  ✗ 未安装"
  grep -q "btsh_lightd/Kconfig" "$BT_KCONFIG" 2>/dev/null \
    && grn "  ✓ Kconfig 已挂接" || ylw "  ✗ Kconfig 未挂接"
  exit 0
fi

if [ "$MODE" = "revert" ]; then
  hdr "3. 卸载"
  rm -rf "$DEST" && grn "  ✓ 已删除 $DEST"
  if grep -q "btsh_lightd/Kconfig" "$BT_KCONFIG" 2>/dev/null; then
    sed -i '/btsh_lightd\/Kconfig/d' "$BT_KCONFIG"
    sed -i '/远程灯控守护进程（TCP 版）/,+1d' "$BT_KCONFIG" 2>/dev/null || true
    grn "  ✓ 已移除 Kconfig 挂接"
  fi
  exit 0
fi

hdr "3. 安装文件"
mkdir -p "$DEST"
for f in btsh_lightd_main.c Kconfig Makefile Make.defs; do
  cp "$SRC/$f" "$DEST/$f"
  printf '  ok %s\n' "$f"
done

hdr "4. 挂接 Kconfig"
if grep -q "btsh_lightd/Kconfig" "$BT_KCONFIG" 2>/dev/null; then
  ylw "  已挂接，跳过"
else
  LINE=$(grep -n "^endmenu" "$BT_KCONFIG" | head -1 | cut -d: -f1)
  if [ -n "$LINE" ]; then
    {
      head -n $((LINE - 1)) "$BT_KCONFIG"
      echo ""
      echo "# 远程灯控守护进程（TCP 版，OpenvelaESP-BTSH 项目）"
      echo "# 由 scripts/setup/install-btsh-lightd.sh 添加（kconfig 需绝对路径）"
      echo "source \"$DEST/Kconfig\""
      echo ""
      tail -n +"$LINE" "$BT_KCONFIG"
    } > "$BT_KCONFIG.new"
    mv "$BT_KCONFIG.new" "$BT_KCONFIG"
    grn "  ✓ 已挂接 Kconfig"
  else
    red "  ✗ 找不到 endmenu"; exit 1
  fi
fi

hdr "5. 结果"
ls -1 "$DEST" | sed 's/^/      /'
echo ""
grep -n "btsh_lightd" "$BT_KCONFIG" | sed 's/^/      /'

hdr "完成"
echo "  下一步：构建带 CONFIG_BTSH_LIGHTD=y 的配置"
