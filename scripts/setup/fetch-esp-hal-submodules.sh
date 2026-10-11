#!/usr/bin/env bash
#
# fetch-esp-hal-submodules.sh — 获取 esp-hal-3rdparty 的 5 个子模块
#
# ## 为什么需要这个脚本
#
# NuttX 构建的 `context::` 目标会执行：
#   git -C chip/esp-hal-3rdparty submodule update --init \
#       components/mbedtls/mbedtls components/esp_phy/lib ... \
#   （见 arch/xtensa/src/esp32s3/Make.defs:286-295）
#
# 该步骤要求子模块是**真正的 git 子模块**。若用手工伪造的 `.git` 指针，
# 构建会报：
#   fatal: could not get a repository handle for submodule 'components/...'
#
# ## 两种策略（自动选择）
#
#   【策略 A：真实 git 子模块】—— 首选
#     前提：github.com 可达（本环境需 Windows 侧 relay_proxy.py + https_proxy）
#     做法：git submodule update --init --depth=1 <路径>
#     优点：与构建系统期望一致，后续 make 不会再尝试修复
#
#   【策略 B：codeload tarball 兜底】—— 仅当 git 协议不通时
#     前提：api.github.com 查 commit + codeload.github.com 下 tarball 可达
#     做法：下指定 commit 的 tarball 解压到目标路径
#     注意：**不写伪造的 .git 指针**（写了会让 make 报错，得不偿失）。
#           代价是 make 仍会尝试 submodule update 并失败 —— 因此策略 B
#           只适合「手工验证文件齐全」，不适合跑完整构建。
#           网络恢复后请重跑本脚本走策略 A。
#
# ## 用法
#
#   bash scripts/setup/fetch-esp-hal-submodules.sh [esp-hal 路径]
#   FORCE_TARBALL=1 bash scripts/setup/fetch-esp-hal-submodules.sh   # 强制 B
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENVELA_ROOT="${OPENVELA_ROOT:-$HOME/openvela}"
HAL="${1:-$OPENVELA_ROOT/nuttx/arch/xtensa/src/esp32s3/esp-hal-3rdparty}"
CACHE="${ESP_HAL_CACHE:-$HOME/.cache/esp-hal-3rdparty-cache}"
PIN="${ESP_HAL_PIN:-9fc713a95b1ff150dd0b0647e465d3c624056bb1}"

# 子模块：路径|仓库|commit（commit 由 api.github.com 查询得到，见 stage-02 §3.6）
SUBMODULES=(
  "components/mbedtls/mbedtls|espressif/mbedtls|72aa687352a469044cbb946f3fdb261430e41ce1"
  "components/esp_phy/lib|espressif/esp-phy-lib|06e7625de197bc12797dd701d6762229bca01826"
  "components/esp_wifi/lib|espressif/esp32-wifi-lib|dffb3f92194f571c18473387ab9fac62a1f64e67"
  "components/bt/controller/lib_esp32c3_family|espressif/esp32c3-bt-lib|29d5555ca1febeb132f5a13556893f3419d2d640"
  "components/esp_coex/lib|espressif/esp-coex-lib|94ebf43111a5889a3a97fd470b7148cd6b692b7c"
)

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
info() { printf '\033[36m%s\033[0m\n' "$1"; }

[ -d "$HAL" ] || { bad "找不到 $HAL（先跑 restore-esp-hal.sh）"; exit 1; }
cd "$HAL" || exit 1

is_filled() { [ -n "$(ls -A "$1" 2>/dev/null)" ]; }

PATHS=()
for entry in "${SUBMODULES[@]}"; do
  IFS='|' read -r path _ _ <<< "$entry"
  PATHS+=("$path")
done

# ---------------------------------------------------------- 策略选择
USE_TARBALL="${FORCE_TARBALL:-0}"
if [ "$USE_TARBALL" -eq 0 ]; then
  if git -C "$HAL" rev-parse --git-dir >/dev/null 2>&1 \
     && timeout 60 git ls-remote https://github.com/espressif/mbedtls.git HEAD >/dev/null 2>&1; then
    ok "github.com 可达 → 【策略 A：真实 git 子模块】"
  else
    warn "github.com 不可达或 esp-hal 非 git 仓库 → 【策略 B：tarball】"
    USE_TARBALL=1
  fi
fi

# ============================================================ 策略 A
if [ "$USE_TARBALL" -eq 0 ]; then
  info "获取子模块（真实 git submodule）"

  # 清掉任何伪造的 .git，避免干扰 git
  for p in "${PATHS[@]}"; do
    if [ -f "$p/.git" ]; then
      warn "清理伪造的 .git 指针：$p"
      rm -rf "$p"
    fi
  done

  for attempt in 1 2 3; do
    echo "  --- 第 $attempt 轮 ---"
    git submodule update --init --depth=1 "${PATHS[@]}" 2>&1 | tail -5 || true
    ALLOK=1
    for p in "${PATHS[@]}"; do is_filled "$p" || ALLOK=0; done
    [ "$ALLOK" -eq 1 ] && break
    echo "  仍有缺失，等 10 秒重试"
    sleep 10
  done

# ============================================================ 策略 B
else
  info "获取子模块（codeload tarball 兜底）"
  CL_IP=$(getent ahostsv4 codeload.github.com 2>/dev/null | head -1 | awk '{print $1}')
  API_IP=$(getent ahostsv4 api.github.com 2>/dev/null | head -1 | awk '{print $1}')
  [ -z "$CL_IP" ] && { bad "无法解析 codeload.github.com"; exit 1; }

  for entry in "${SUBMODULES[@]}"; do
    IFS='|' read -r path repo sha <<< "$entry"
    echo ">>> $path"
    if is_filled "$path"; then echo "    已存在，跳过"; continue; fi

    if [ -n "$API_IP" ]; then
      APISHA=$(timeout 40 curl -s --resolve "api.github.com:443:$API_IP" \
        "https://api.github.com/repos/espressif/esp-hal-3rdparty/contents/$path?ref=$PIN" 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null)
      [ -n "$APISHA" ] && sha="$APISHA"
    fi
    echo "    SHA: $sha"

    TMP=$(mktemp -d)
    if timeout 300 curl -sL --retry 3 --resolve "codeload.github.com:443:$CL_IP" \
         -o "$TMP/sub.tgz" "https://codeload.github.com/$repo/tar.gz/$sha" \
       && file "$TMP/sub.tgz" 2>/dev/null | grep -q gzip; then
      mkdir -p "$path"
      tar -xzf "$TMP/sub.tgz" -C "$path" --strip-components=1 && ok "解压完成"
    else
      bad "下载失败"
    fi
    rm -rf "$TMP"
  done

  warn "策略 B 不写伪造 .git 指针（写了会让 make 报 submodule 错误）"
  warn "因此本策略下 make 仍会尝试 submodule update 并失败。"
  warn "网络恢复后请重跑本脚本以走策略 A。"
  for p in "${PATHS[@]}"; do
    [ -f "$p/.git" ] && rm -f "$p/.git"
  done
fi

# ---------------------------------------------------------- 验证
echo
info "验证"
ALLOK=1
for p in "${PATHS[@]}"; do
  c=$(ls -A "$HAL/$p" 2>/dev/null | wc -l)
  printf '  %-52s %s files\n' "$p" "$c"
  [ "$c" -gt 0 ] || ALLOK=0
done
echo "  mbedtls aes.c: $([ -f "$HAL/components/mbedtls/mbedtls/library/aes.c" ] && echo yes || echo NO)"

if [ "$ALLOK" -ne 1 ] || [ ! -f "$HAL/components/mbedtls/mbedtls/library/aes.c" ]; then
  bad "仍有子模块不完整"; exit 1
fi
ok "全部子模块就位"

# 只有真实 git 子模块的缓存才可靠
if [ "$USE_TARBALL" -eq 0 ] && [ -n "$CACHE" ]; then
  info "刷新缓存 $CACHE"
  mkdir -p "$CACHE"
  rsync -a --delete --exclude='*.o' --exclude='*.d' --exclude='.git' "$HAL/" "$CACHE/" 2>/dev/null
  ok "缓存 $(du -sh "$CACHE" | cut -f1)"
fi
