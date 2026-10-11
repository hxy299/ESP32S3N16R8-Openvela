#!/bin/bash
# 把 NimBLE 版 BLE GATT 灯控应用安装进 openvela 树
#
# ## 安装策略（重要）
#
# NimBLE 自带的容器 `apps/wireless/bluetooth/nimble/` 已经会把
# NimBLE 协议栈源码编进 libapps.a —— 但它的 CSRCS/MAINSRC 全部来自
# `porting/examples/nuttx/Make.defs`（只在 CONFIG_NIMBLE_PORTING_EXAMPLE=y 时生效）。
#
# 因此**最干净的做法**是：
#   1. 打开 CONFIG_NIMBLE_PORTING_EXAMPLE=y（让容器编协议栈）
#   2. 但把该 Make.defs 的 `MAINSRC` 换成**我们自己的** btsh_light_main.c
#      —— 这样照样例的 main.c 不被编，我们的应用接管入口
#
# 这样避免了两个坑：
#   - 协议栈被编两遍 -> multiple definition of `ble_sm_alg_s1'
#   - CSRCS 全局变量泄漏（容器与应用的 Makefile 谁后处理谁覆盖）
#
# 用法：
#   bash scripts/setup/install-btsh-light-nimble.sh [--check|--revert]
#
set -u

OPENVELA="${OPENVELA_DIR:-$HOME/openvela}"
APPS="$OPENVELA/apps"
DEST="$APPS/wireless/bluetooth/btsh_light_nimble"
SRC="$(cd "$(dirname "$0")/../.." && pwd)/src/app/nimble"
BT_KCONFIG="$APPS/wireless/bluetooth/Kconfig"
NIMBLE_DIR="$APPS/wireless/bluetooth/nimble"
EX_MK="$NIMBLE_DIR/mynewt-nimble/porting/examples/nuttx/Make.defs"

MODE="install"
case "${1:-}" in
  --check)  MODE="check"  ;;
  --revert) MODE="revert" ;;
esac

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
hdr() { printf '\n\033[36m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
hdr "1. 检查源文件"
# ---------------------------------------------------------------------------
for f in btsh_light_main.c Kconfig Makefile Make.defs; do
  if [ -f "$SRC/$f" ]; then
    printf '  %-22s ok  %s 字节\n' "$f" "$(stat -c%s "$SRC/$f")"
  else
    red "  ✗ 缺少 $SRC/$f"
    exit 1
  fi
done

# ---------------------------------------------------------------------------
hdr "2. 检查目标环境"
# ---------------------------------------------------------------------------
[ -d "$APPS/wireless/bluetooth" ] || { red "  ✗ 找不到 $APPS/wireless/bluetooth"; exit 1; }
echo "  APPS       = $APPS"
echo "  DEST       = $DEST"
echo "  NIMBLE_DIR = $NIMBLE_DIR"

# ---------------------------------------------------------------------------
if [ "$MODE" = "check" ]; then
  hdr "3. 检查安装状态（--check，不修改）"
  [ -d "$DEST" ] && grn "  ✓ 应用目录存在" || ylw "  ✗ 应用目录不存在"
  grep -q "btsh_light_nimble/Kconfig" "$BT_KCONFIG" 2>/dev/null \
    && grn "  ✓ Kconfig 已挂接" || ylw "  ✗ Kconfig 未挂接"
  if [ -f "$EX_MK" ] && grep -q "btsh_light_main.c" "$EX_MK" 2>/dev/null; then
    grn "  ✓ 示例 Make.defs 的 MAINSRC 已指向本应用"
  else
    ylw "  ✗ 示例 Make.defs 未改（MAINSRC 仍指向样例 main.c）"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
if [ "$MODE" = "revert" ]; then
  hdr "3. 卸载（--revert）"
  rm -rf "$DEST" && grn "  ✓ 已删除 $DEST"

  if grep -q "btsh_light_nimble/Kconfig" "$BT_KCONFIG" 2>/dev/null; then
    sed -i '/btsh_light_nimble\/Kconfig/d' "$BT_KCONFIG"
    grn "  ✓ 已移除 Kconfig 挂接"
  fi

  if [ -f "$EX_MK.btsh-orig" ]; then
    cp "$EX_MK.btsh-orig" "$EX_MK"
    grn "  ✓ 已还原示例 Make.defs"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
hdr "3. 安装应用文件"
# ---------------------------------------------------------------------------
mkdir -p "$DEST"
for f in btsh_light_main.c Kconfig Makefile Make.defs; do
  cp "$SRC/$f" "$DEST/$f"
  printf '  ok %s\n' "$f"
done

# ---------------------------------------------------------------------------
hdr "4. 挂接 Kconfig"
# ---------------------------------------------------------------------------
if grep -q "btsh_light_nimble/Kconfig" "$BT_KCONFIG" 2>/dev/null; then
  ylw "  已挂接，跳过"
else
  LINE=$(grep -n "^endmenu" "$BT_KCONFIG" | head -1 | cut -d: -f1)
  if [ -n "$LINE" ]; then
    {
      head -n $((LINE - 1)) "$BT_KCONFIG"
      echo ""
      echo "# BLE GATT 灯控服务（NimBLE 版，OpenvelaESP-BTSH 项目）"
      echo "# 由 scripts/setup/install-btsh-light-nimble.sh 添加"
      echo "# 注意：kconfig 的 source 不展开变量，必须用绝对路径"
      echo "source \"$DEST/Kconfig\""
      echo ""
      tail -n +"$LINE" "$BT_KCONFIG"
    } > "$BT_KCONFIG.new"
    mv "$BT_KCONFIG.new" "$BT_KCONFIG"
    grn "  ✓ 已挂接 Kconfig"
  else
    red "  ✗ 在 $BT_KCONFIG 里找不到 endmenu"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
hdr "5. ★ 让容器编译我们的 main（关键步骤）"
# ---------------------------------------------------------------------------
# 原理：
#   NimBLE 容器 `apps/wireless/bluetooth/nimble/Makefile` 里有
#       -include $(NIMBLE_ROOT)/porting/examples/nuttx/Make.defs
#   该 Make.defs 定义 CSRCS（协议栈全部源码）与 MAINSRC（样例 main.c）。
#
#   我们只改 MAINSRC 指向自己的 main.c —— 于是：
#     - 协议栈仍由容器编（只编一遍，不会重复定义）
#     - 样例的 main.c 不再被编（避免两个 main 冲突）
#     - NIMBLE_ROOT / include 路径等构建上下文全部沿用容器的，不用自己搭
#
if [ ! -f "$EX_MK" ]; then
  ylw "  ⚠ 尚未下载 NimBLE 源码（$EX_MK 不存在）"
  echo "    首次构建时会自动下载，届时请重新运行本脚本的第 5 步："
  echo "      bash $0"
else
  if [ ! -f "$EX_MK.btsh-orig" ]; then
    cp "$EX_MK" "$EX_MK.btsh-orig"
    echo "  已备份原文件 -> Make.defs.btsh-orig"
  fi

  python3 - "$EX_MK" "$DEST" <<'PYEOF'
import sys

mk, dest = sys.argv[1], sys.argv[2]
s = open(mk).read()

if 'BTSH-MAINSRC' in s:
    print('  已打过补丁，跳过')
    sys.exit(0)

# 1) MAINSRC 指向我们的应用
#    用字符串替换而非正则 —— 替换文本里的反斜杠会被 re 当转义符处理
old_main = 'MAINSRC = $(NIMBLE_ROOT)/porting/examples/nuttx/main.c'
new_main = ('# BTSH-MAINSRC: 指向 OpenvelaESP-BTSH 项目自己的 BLE 灯控应用\n'
            '# （原值：$(NIMBLE_ROOT)/porting/examples/nuttx/main.c）\n'
            '# 由 scripts/setup/install-btsh-light-nimble.sh 修改；\n'
            '# 原文件备份在同目录 Make.defs.btsh-orig\n'
            'MAINSRC = ' + dest + '/btsh_light_main.c')

if old_main not in s:
    print('  ! 未找到 MAINSRC 原行，尝试宽松匹配')
    import re as _re
    m = _re.search(r'(?m)^MAINSRC\s*=.*$', s)
    if not m:
        print('  X 无法定位 MAINSRC，请人工检查 ' + mk)
        sys.exit(1)
    s = s[:m.start()] + new_main + s[m.end():]
else:
    s = s.replace(old_main, new_main, 1)

# 2) 头文件顺序：把我们的应用目录排最前
#    目的：让 `#include "syscfg/syscfg.h"` 优先命中 NuttX 专用那份
#    （BLE_SOCK_USE_NUTTX=1），而不是 porting/nimble/include 下的 Linux 默认版
old_inc = 'INC = \\'
new_inc = ('INC = \\\n'
           '  ' + dest + ' \\')

if old_inc in s:
    s = s.replace(old_inc, new_inc, 1)
else:
    print('  ! 未找到 INC = \\ 这一行，跳过 INC 修改')

open(mk, 'w').write(s)
print('  ok 已改 MAINSRC 与 INC 顺序')
PYEOF

  echo ""
  echo "  --- 改动后的关键行 ---"
  grep -n "BTSH\|^MAINSRC\|^INC" "$EX_MK" | head -12
fi

# ---------------------------------------------------------------------------
hdr "6. 结果确认"
# ---------------------------------------------------------------------------
echo "  应用目录："
ls -1 "$DEST" | sed 's/^/      /'
echo ""
echo "  Kconfig 挂接："
grep -n "btsh_light_nimble" "$BT_KCONFIG" | sed 's/^/      /' || echo "      (无)"

hdr "完成"
grn "  下一步："
echo "    bash scripts/build/build-n16r8.sh nimblelight"
echo ""
echo "  卸载："
echo "    bash scripts/setup/install-btsh-light-nimble.sh --revert"
