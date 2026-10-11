# thirdparty/patches/ — openvela 上游修复补丁

> **这两个补丁不是可选项。** openvela 当前 dev 分支上，**所有 ESP32-S3 配置
> 都无法直接编译**，必须先应用 `0002`；启用 WiFi 的配置还需要 `0001`。

## 补丁清单

| 编号 | 目标仓库 | 影响的文件 | 症状 |
| --- | --- | --- | --- |
| `0001-esp32s3-add-missing-includes-for-wireless.patch` | `nuttx` | `arch/xtensa/src/esp32s3/esp32s3_wifi_utils.c`<br>`.../esp32s3_wireless.c`<br>`.../esp32s3_wifi_adapter.c` | 启用 WiFi 时链接失败：<br>`undefined reference to 'nxsem_post' / 'nxsem_tickwait'` |
| `0002-esp-hal-fix-spinlock-initializer.patch` | `esp-hal-3rdparty` | `components/esp_hw_support/clk_ctrl_os.c`<br>`components/esp_hw_support/modem_clock.c` | **所有** ESP32-S3 配置编译失败：<br>`error: invalid initializer` |

详细分析（含根因、行号、证据）见
[`../../docs/bringup/wsl-esp32s3-build-notes.md`](../../docs/bringup/wsl-esp32s3-build-notes.md) 第 9 节。

## 用法

```bash
bash scripts/setup/apply-patches.sh           # 应用（幂等，可重复执行）
bash scripts/setup/apply-patches.sh --check   # 只检查状态
bash scripts/setup/apply-patches.sh --revert  # 撤销
```

## 基线

| 项 | 值 |
| --- | --- |
| 补丁生成日期 | 2026-10-10 |
| openvela 分支 | `dev` |
| `nuttx` commit | `5315a2b7f0ab864efa34d7ee13532b34ee4e926b` |
| `esp-hal-3rdparty` commit | `9fc713a95b1ff150dd0b0647e465d3c624056bb1` |

> ⚠️ 若 `repo sync` 后这两个 commit 变化，补丁可能失效。
> 请先跑 `apply-patches.sh --check`，必要时重新生成补丁。

## 上游状态追踪

| 项 | 状态 |
| --- | --- |
| 是否已向上游反馈 | ❌ 尚未提交 issue/PR |
| 是否已在更新的 openvela 版本修复 | ❓ 未核实（本机 github.com 受限） |

> **建议**：修复本身很小（`0`→`{0}`、补 4 行 include），
> 值得向 openvela / NuttX 提 issue 或 PR。
> 提交前请先在无补丁的干净树上复现，并附上本文档第 9 节的证据。

## 为什么用脚本 sed 而不是 `git apply`

`apply-patches.sh` 对 `0002` 使用 `sed` 而非 `git apply`：
`LOCK_INITIALIZER_UNLOCKED` 这个宏在文件里出现两次（NuttX 分支与非 NuttX 分支），
且上下文可能随上游变化。`sed` 用行尾锚点 `0$` 精确匹配，
比依赖上下文行的 patch 更耐受漂移。`0001` 则用正规 `git apply`。
