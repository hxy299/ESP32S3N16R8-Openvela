#!/usr/bin/env bash
#
# apply-board-ws2812.sh — 为 esp32s3-devkit 板级添加 WS2812 支持
#
# ## 为什么需要
#
# 上游 `esp32s3-devkit` 板级**没有** WS2812 初始化代码，而我们的目标板
# （ESP32-S3-N16R8）板载了一颗 WS2812B（GPIO48）。
# 仅开 `CONFIG_WS2812=y` 不够 —— 还需要在板级 bringup 里调用
# `board_ws2812_initialize()` 来注册 `/dev/leds0`。
#
# 上游只有 `esp32s3-lcd-ev` 提供了该实现。本脚本把一份等价的实现
# （去掉 LCD 依赖）安装到 devkit 板级，并接上 bringup 调用。
#
# ## 安装内容（全部幂等）
#
#   1. 拷贝源文件
#        config/boards/esp32s3-n16r8-generic/src/esp32s3_btsh_ws2812.c
#      -> nuttx/boards/xtensa/esp32s3/esp32s3-devkit/src/
#
#   2. 在该板级 src/Make.defs 追加一行（带 CONFIG_WS2812 条件）
#        ifeq ($(CONFIG_WS2812),y)
#        CSRCS += esp32s3_btsh_ws2812.c
#        endif
#
#   3. 在该板级 src/esp32s3_bringup.c 插入初始化调用
#        #if defined(CONFIG_WS2812) && !defined(CONFIG_WS2812_NON_SPI_DRIVER)
#          ret = board_ws2812_initialize(0, ESP32S3_SPI2,
#                                        CONFIG_WS2812_LED_COUNT);
#        #endif
#
# ## 用法
#
#   bash scripts/setup/apply-board-ws2812.sh           # 安装
#   bash scripts/setup/apply-board-ws2812.sh --check   # 检查状态
#   bash scripts/setup/apply-board-ws2812.sh --revert  # 撤销
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OPENVELA_ROOT="${OPENVELA_ROOT:-$HOME/openvela}"

SRC_FILE="$PROJECT_ROOT/config/boards/esp32s3-n16r8-generic/src/esp32s3_btsh_ws2812.c"
BOARD_DIR="$OPENVELA_ROOT/nuttx/boards/xtensa/esp32s3/esp32s3-devkit/src"
DST_FILE="$BOARD_DIR/esp32s3_btsh_ws2812.c"
MAKEDEFS="$BOARD_DIR/Make.defs"
BRINGUP="$BOARD_DIR/esp32s3_bringup.c"

MARK_BEGIN="/* === BTSH-WS2812-BEGIN === */"
MARK_END="/* === BTSH-WS2812-END === */"
MAKE_MARK="# === BTSH-WS2812 ==="

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
info() { printf '\033[36m%s\033[0m\n' "$1"; }

check_state() {
  echo "WS2812 板级支持状态："
  [ -f "$DST_FILE" ] && ok "源文件已安装: $DST_FILE" || warn "源文件未安装"
  grep -q "BTSH-WS2812" "$MAKEDEFS" 2>/dev/null && ok "Make.defs 已挂钩" || warn "Make.defs 未挂钩"
  grep -q "BTSH-WS2812-BEGIN" "$BRINGUP" 2>/dev/null && ok "bringup 已插入调用" || warn "bringup 未插入调用"
}

case "${1:-}" in
  --check)
    check_state
    exit 0
    ;;
  --revert)
    info "撤销 WS2812 板级支持"
    [ -f "$DST_FILE" ] && rm -f "$DST_FILE" && ok "已删除源文件"
    if grep -q "$MAKE_MARK" "$MAKEDEFS" 2>/dev/null; then
      # 删除从标记行起的三行（标记 + ifeq + CSRCS + endif 共 4 行）
      sed -i "/$MAKE_MARK/,+3d" "$MAKEDEFS"
      ok "已移除 Make.defs 挂钩"
    fi
    if grep -q "BTSH-WS2812-BEGIN" "$BRINGUP" 2>/dev/null; then
      sed -i "/\Q$MARK_BEGIN\E/,/\Q$MARK_END\E/d" "$BRINGUP" 2>/dev/null || \
        sed -i "/BTSH-WS2812-BEGIN/,/BTSH-WS2812-END/d" "$BRINGUP"
      ok "已移除 bringup 调用"
    fi
    check_state
    exit 0
    ;;
esac

info "安装 WS2812 板级支持到 esp32s3-devkit"

# ---------------------------------------------------------------- 前置检查
[ -d "$BOARD_DIR" ] || { bad "找不到板级目录：$BOARD_DIR"; exit 1; }
[ -f "$SRC_FILE" ] || { bad "找不到源文件：$SRC_FILE"; exit 1; }

# ---------------------------------------------------------------- 1. 拷贝源文件
if [ -f "$DST_FILE" ] && cmp -s "$SRC_FILE" "$DST_FILE"; then
  ok "源文件已是最新，跳过"
else
  cp "$SRC_FILE" "$DST_FILE"
  ok "源文件已安装（$(wc -l < "$DST_FILE") 行）"
fi

# ---------------------------------------------------------------- 2. Make.defs
if grep -q "$MAKE_MARK" "$MAKEDEFS"; then
  ok "Make.defs 已挂钩，跳过"
else
  cat >> "$MAKEDEFS" <<'EOF'

# === BTSH-WS2812 ===
# 由 OpenvelaESP-BTSH 项目添加：板载 WS2812B (GPIO48) 支持
# 见 scripts/setup/apply-board-ws2812.sh
ifeq ($(CONFIG_WS2812),y)
CSRCS += esp32s3_btsh_ws2812.c
endif
EOF
  ok "Make.defs 已追加挂钩"
fi

# ---------------------------------------------------------------- 3. bringup
if grep -q "BTSH-WS2812-BEGIN" "$BRINGUP"; then
  ok "bringup 已插入，跳过"
else
  # 找到 esp32s3_bringup 函数里的 return OK，在其前插入
  # 稳妥做法：找最后一个 "  UNUSED(ret);" 或 "  return OK;" 之前插入
  TMP=$(mktemp)
  awk -v begin="$MARK_BEGIN" -v end="$MARK_END" '
    /^[[:space:]]*return OK;/ && !inserted {
      print begin
      print "  /* 板载 WS2812B (GPIO48)：注册 /dev/leds0 */"
      print "  #if defined(CONFIG_WS2812) && !defined(CONFIG_WS2812_NON_SPI_DRIVER)"
      print "  ret = board_ws2812_initialize(0, ESP32S3_SPI2,"
      print "                                CONFIG_WS2812_LED_COUNT);"
      print "  if (ret < 0)"
      print "    {"
      print "      syslog(LOG_ERR, \"Failed to initialize ws2812 driver\\n\");"
      print "    }"
      print "  #endif"
      print end
      print ""
      inserted = 1
    }
    { print }
    END { if (!inserted) exit 3 }
  ' "$BRINGUP" > "$TMP"

  if [ $? -eq 0 ] && [ -s "$TMP" ]; then
    cp "$TMP" "$BRINGUP"
    ok "bringup 已插入初始化调用"
  else
    bad "bringup 插入失败（未找到合适的插入点 'return OK;'）"
    rm -f "$TMP"
    exit 1
  fi
  rm -f "$TMP"
fi

echo
check_state
echo
echo "下一步：bash scripts/build/build-n16r8.sh statusled"
