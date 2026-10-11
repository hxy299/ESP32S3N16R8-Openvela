# scripts/ — 自动化脚本

所有脚本以 **WSL2 Ubuntu 22.04 的 bash** 为运行环境（openvela 开发环境在 WSL 内）。
Windows 侧只负责调用 `wsl -e bash ...`。

## 子目录

| 目录 | 用途 |
| --- | --- |
| [`setup/`](setup/README.md) | 一次性环境准备：工具链入 PATH、依赖安装、串口权限、usbipd 透传 |
| [`build/`](build/README.md) | 编译：设 defconfig、编译、产物收集 |
| [`flash/`](flash/README.md) | 烧录到 ESP32-S3 |
| [`debug/`](debug/README.md) | 串口监视、GDB 调试、日志转存 |

## 脚本编写规范

1. 首行 `#!/usr/bin/env bash`，并 `set -euo pipefail`。
2. 顶部注释写清：**用途、前置条件、用法示例、影响的文件**。
3. 所有路径用变量集中在顶部，例如 `OPENVELA_ROOT="${OPENVELA_ROOT:-$HOME/openvela}"`。
4. **不做破坏性操作**：不 `rm -rf` 未知路径，不覆盖用户已有 `.config` 除非显式传参。
5. 输出加时间戳与步骤编号，便于和 `docs/stages/` 的记录对照。
6. 脚本本身也要能被 `shellcheck` 通过。

## 路径对照（Windows ↔ WSL）

| Windows | WSL |
| --- | --- |
| `D:\Myprogram\DeepSeekProgram\ESP32S3N16R8-One\OpenvelaESP-BTSH` | `/mnt/d/Myprogram/DeepSeekProgram/ESP32S3N16R8-One/OpenvelaESP-BTSH` |
| `C:\Users\hxy299` | `/mnt/c/Users/hxy299` |
| — | `~/openvela`（openvela 源码根） |
