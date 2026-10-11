# config/ — 板级与系统配置

存放 ESP32-S3-N16R8 的板级定义、NuttX defconfig 快照与自定义 Kconfig。

## 子目录

| 目录 | 用途 |
| --- | --- |
| [`boards/`](boards/README.md) | 板级描述：名称、引脚映射表、板级 Kconfig/defconfig 的**权威副本** |
| [`defconfig/`](defconfig/README.md) | 各构建配置的 defconfig 快照与差异说明（含 `ble`、`nsh`、`psram_octal` 基线） |
| [`kconfig/`](kconfig/README.md) | 自定义 Kconfig 片段（新增的板级选项） |

## 关键配置基线（来自 openvela 现有板级）

openvela 的 `nuttx/boards/xtensa/esp32s3/esp32s3-devkit/configs/` 下已存在下列可直接参考的配置：

| 配置 | 与本项目的关系 |
| --- | --- |
| `nsh` | 最简 shell 基线，板级适配第一目标 |
| `ble` | **BLE 基线，本项目核心参考** |
| `blewifi` | BLE + WiFi 共存参考 |
| `psram_octal` | **N16R8 的 8MB OPI PSRAM 必看** |
| `gpio` | GPIO 驱动与 `/dev/gpio` 用法参考 |
| `usbnsh` | 走原生 USB 的 console 参考 |
| `mcuboot_nsh` | 若需 MCUboot 方案的参考 |

> 具体裁剪与合并方案在阶段 S1/S2 确定，见 [`../docs/stages/`](../docs/stages/README.md)。

## 原则

- **配置文件必须入库**，且与实机烧录的固件一一对应（用 git tag 关联）。
- 任何「在 menuconfig 里点了一下」的改动，都必须回写成 defconfig 并提交。
- 不直接改 `~/openvela` 里的上游文件作为长期方案；改为产出 patch 放 `thirdparty/`。
