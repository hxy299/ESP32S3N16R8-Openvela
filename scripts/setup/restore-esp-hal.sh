#!/usr/bin/env bash
#
# restore-esp-hal.sh — 完整恢复 esp-hal-3rdparty（主仓库 + 5 个子模块）
#
# ## 为什么需要
#
# NuttX 的 `distclean` 会**删除整个 esp-hal-3rdparty 目录**
# （见 arch/xtensa/src/esp32s3/Make.defs 的 `distclean::` 规则），
# 而 `./build.sh <cfg>` 内部的 `configure.sh -e` 在配置变化时触发 distclean。
# 因此在不同配置之间切换时，这个目录会消失。
#
# ## 恢复策略（三级回退）
#
#   1. **本地缓存**（`~/.cache/esp-hal-3rdparty-cache`）—— 秒级恢复，首选
#   2. **git clone + submodule** —— 标准做法，但本网络下 github.com 常不通
#      （实测 `gnutls_handshake() failed`，TCP 通但 TLS 被中断）
#   3. **codeload tarball**（配合 fetch-esp-hal-submodules.sh）——
#      实测可用的兜底通道：api.github.com 查 commit + codeload 下 tarball
#
# ## 用法
#
#   bash scripts/setup/restore-esp-hal.sh            # 恢复（自动选策略）
#   bash scripts/setup/restore-esp-hal.sh --refresh  # 强制重取并刷新缓存
#   bash scripts/setup/restore-esp-hal.sh --status   # 只看状态
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENVELA_ROOT="${OPENVELA_ROOT:-$HOME/openvela}"
NUTTX="$OPENVELA_ROOT/nuttx"
HAL="$NUTTX/arch/xtensa/src/esp32s3/esp-hal-3rdparty"
CACHE="${ESP_HAL_CACHE:-$HOME/.cache/esp-hal-3rdparty-cache}"
PIN="${ESP_HAL_PIN:-9fc713a95b1ff150dd0b0647e465d3c624056bb1}"

SUBMODULES=(
  components/mbedtls/mbedtls
  components/esp_phy/lib
  components/esp_wifi/lib
  components/bt/controller/lib_esp32c3_family
  components/esp_coex/lib
)

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
info() { printf '\033[36m%s\033[0m\n' "$1"; }

is_complete() {
  local d="$1"
  [ -f "$d/components/mbedtls/mbedtls/library/aes.c" ] || return 1
  local m
  for m in "${SUBMODULES[@]}"; do
    [ -n "$(ls -A "$d/$m" 2>/dev/null)" ] || return 1
  done
  return 0
}

apply_patches() {
  local f1="$HAL/components/esp_hw_support/clk_ctrl_os.c"
  local f2="$HAL/components/esp_hw_support/modem_clock.c"
  [ -f "$f1" ] && sed -i 's/#define LOCK_INITIALIZER_UNLOCKED       0$/#define LOCK_INITIALIZER_UNLOCKED       {0}/' "$f1"
  [ -f "$f2" ] && sed -i 's/#define LOCK_INITIALIZER_UNLOCKED       0$/#define LOCK_INITIALIZER_UNLOCKED       {0}/' "$f2"

  local w="$NUTTX/arch/xtensa/src/esp32s3"
  local f
  for f in esp32s3_wifi_utils.c esp32s3_wireless.c esp32s3_wifi_adapter.c; do
    [ -f "$w/$f" ] || continue
    grep -q 'nuttx/semaphore.h' "$w/$f" || \
      sed -i '0,/^#include <nuttx\//s//#include <nuttx\/semaphore.h>\n#include <nuttx\//' "$w/$f"
  done
  if [ -f "$w/esp32s3_wifi_adapter.c" ]; then
    grep -q 'nuttx/tls_task.h' "$w/esp32s3_wifi_adapter.c" || \
      sed -i '0,/^#include <nuttx\//s//#include <nuttx\/tls_task.h>\n#include <nuttx\//' "$w/esp32s3_wifi_adapter.c"
  fi
}

refresh_cache() {
  is_complete "$HAL" || return 1
  info "刷新缓存 $CACHE"
  mkdir -p "$CACHE"
  rsync -a --delete --exclude='*.o' --exclude='*.d' --exclude='.git' "$HAL/" "$CACHE/" 2>/dev/null
  ok "缓存 $(du -sh "$CACHE" 2>/dev/null | cut -f1)"
}

# ------------------------------------------------------------------ status
if [ "${1:-}" = "--status" ]; then
  echo "esp-hal-3rdparty："
  if [ -d "$HAL" ]; then
    if is_complete "$HAL"; then
      ok "完整（$(du -sh "$HAL" 2>/dev/null | cut -f1)）"
    else
      bad "不完整"
      for m in "${SUBMODULES[@]}"; do
        printf '    %-52s %s files\n' "$m" "$(ls -A "$HAL/$m" 2>/dev/null | wc -l)"
      done
    fi
  else
    bad "不存在（被 distclean 删除）"
  fi
  echo
  echo "缓存："
  if is_complete "$CACHE"; then
    ok "$CACHE（$(du -sh "$CACHE" 2>/dev/null | cut -f1)）"
  else
    warn "$CACHE 不存在或不完整"
  fi
  exit 0
fi

REFRESH=0
[ "${1:-}" = "--refresh" ] && REFRESH=1

info "esp-hal-3rdparty 恢复"
echo "  目标: $HAL"
echo "  缓存: $CACHE"
echo

# ---------------------------------------------------------------- 1. 已完整
if [ "$REFRESH" -eq 0 ] && is_complete "$HAL"; then
  ok "已完整，跳过获取"
  apply_patches; ok "补丁已确认"
  refresh_cache
  exit 0
fi

# ---------------------------------------------------------------- 2. 缓存
if [ "$REFRESH" -eq 0 ] && is_complete "$CACHE"; then
  info "[策略 1] 从本地缓存恢复"
  mkdir -p "$HAL"
  rsync -a "$CACHE/" "$HAL/"
  if is_complete "$HAL"; then
    ok "恢复完成（$(du -sh "$HAL" | cut -f1)）"
    apply_patches; ok "补丁已应用"
    exit 0
  fi
  warn "缓存恢复后仍不完整，改用其它策略"
fi

# ------------------------------------------------------- 3. git clone 主仓库
info "[策略 2] 获取主仓库（git clone）"
mkdir -p "$NUTTX/arch/xtensa/src/esp32s3"
cd "$NUTTX/arch/xtensa/src/esp32s3" || { bad "无法进入源码目录"; exit 1; }
rm -rf esp-hal-3rdparty

MAIN_OK=0
if timeout 90 git clone --depth=1 --no-checkout \
     https://github.com/espressif/esp-hal-3rdparty.git esp-hal-3rdparty 2>&1 | tail -3 \
   && [ -d esp-hal-3rdparty/.git ]; then
  cd esp-hal-3rdparty || exit 1
  timeout 600 git fetch --depth=1 origin "$PIN" 2>&1 | tail -2
  if git checkout --quiet "$PIN" 2>/dev/null; then
    ok "主仓库就位（HEAD=$(git rev-parse --short HEAD)，$(du -sh "$HAL" | cut -f1)）"
    MAIN_OK=1
    cd "$NUTTX/arch/xtensa/src/esp32s3" || exit 1
  fi
fi

# ------------------------------------------- 4. tarball 方式（主仓库兜底）
if [ "$MAIN_OK" -ne 1 ]; then
  warn "git clone 失败，改用 codeload tarball 获取主仓库"
  CL_IP=$(getent ahostsv4 codeload.github.com 2>/dev/null | head -1 | awk '{print $1}')
  [ -z "$CL_IP" ] && { bad "无法解析 codeload.github.com"; exit 1; }
  TMP=$(mktemp -d)
  if timeout 900 curl -sL --retry 3 --retry-delay 3 \
       --resolve "codeload.github.com:443:$CL_IP" -o "$TMP/hal.tgz" \
       "https://codeload.github.com/espressif/esp-hal-3rdparty/tar.gz/$PIN" \
     && file "$TMP/hal.tgz" 2>/dev/null | grep -q gzip; then
    rm -rf esp-hal-3rdparty
    mkdir -p esp-hal-3rdparty
    tar -xzf "$TMP/hal.tgz" -C esp-hal-3rdparty --strip-components=1
    mkdir -p esp-hal-3rdparty/.git
    printf 'ref: refs/heads/main\n' > esp-hal-3rdparty/.git/HEAD
    printf '%s\n' "$PIN" > esp-hal-3rdparty/.git/HEAD_SHA
    ok "主仓库通过 tarball 就位（$(du -sh "$HAL" | cut -f1)）"
    MAIN_OK=1
    rm -rf "$TMP"
  else
    rm -rf "$TMP"
    bad "主仓库获取失败"
    exit 1
  fi
fi

# ---------------------------------------------------------- 5. 子模块
info "[策略 3] 获取 5 个子模块"
if [ -x "$SCRIPT_DIR/fetch-esp-hal-submodules.sh" ]; then
  bash "$SCRIPT_DIR/fetch-esp-hal-submodules.sh" "$HAL" || warn "tarball 方式有问题"
else
  warn "找不到 fetch-esp-hal-submodules.sh，尝试 git submodule"
  cd "$HAL" || exit 1
  git submodule update --init --depth=1 "${SUBMODULES[@]}" 2>&1 | tail -5
fi

echo
info "最终验证"
if is_complete "$HAL"; then
  ok "esp-hal-3rdparty 完整（$(du -sh "$HAL" | cut -f1)）"
  apply_patches; ok "补丁已应用"
  refresh_cache
  echo
  ok "全部完成，可以构建了"
  exit 0
else
  bad "仍不完整，请检查上方输出"
  for m in "${SUBMODULES[@]}"; do
    printf '    %-52s %s files\n' "$m" "$(ls -A "$HAL/$m" 2>/dev/null | wc -l)"
  done
  exit 1
fi
