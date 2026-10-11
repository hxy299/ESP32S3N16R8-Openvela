# scripts/build/ — 编译（脚本实现中）

本目录的脚本将在**阶段 S1** 编写。

计划实现的第一个脚本是 `check-env.sh` 的配套：`build.sh <board> <config>`。

```bash
#!/usr/bin/env bash
# 用法: build.sh <board> <config>
# 示例: build.sh esp32s3-devkit nsh
set -euo pipefail

OPENVELA_ROOT="${OPENVELA_ROOT:-$HOME/openvela}"
BOARD="${1:?用法: build.sh <board> <config>}"
CONFIG="${2:?用法: build.sh <board> <config>}"

TOOLCHAIN="$OPENVELA_ROOT/prebuilts/gcc/linux-x86_64/xtensa-esp32s3-elf/bin"
export PATH="$TOOLCHAIN:$PATH"

cd "$OPENVELA_ROOT/nuttx"
./tools/configure.sh "${BOARD}:${CONFIG}"
make -j"$(nproc)"
```

> ⚠️ 上面这段是**待验证的草稿**，不是可用脚本。`configure.sh` 的确切调用形式、
> 以及是否应该改用 openvela 顶层的 `build.sh`，需在 S1 实机确认后再定稿。
> 详见 [`../../docs/bringup/README.md`](../../docs/bringup/README.md) 的 Q4。
