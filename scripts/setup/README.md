# scripts/setup/ — 环境准备

一次性或低频的环境搭建脚本。**幂等**：重复执行不产生副作用。

## 计划中的脚本

| 脚本 | 用途 | 关键动作 |
| --- | --- | --- |
| `check-env.sh` | 环境体检 | 检查 openvela 源码、工具链、依赖、串口设备是否就绪，输出报告 |
| `setup-toolchain.sh` | 工具链入 PATH | 把 `~/openvela/prebuilts/gcc/linux-x86_64/xtensa-esp32s3-elf/bin` 加入 PATH |
| `install-deps.sh` | 装依赖 | `kconfig-frontends`（menuconfig 需要）、`minicom`/`picocom`、`esptool` |
| `setup-serial.sh` | 串口权限 | 用户加入 `dialout` 组 |
| `setup-usbipd.ps1` | USB 透传（Windows 侧） | 把 CH340 从 Windows 透传给 WSL |

## 当前环境已知缺口（2026-10 探测结果）

| 缺口 | 影响 | 解决脚本 |
| --- | --- | --- |
| `xtensa-esp32s3-elf-gcc` 不在 PATH | 无法编译 | `setup-toolchain.sh` |
| `kconfig-frontends` / `menuconfig` 未安装 | 无法 `make menuconfig` | `install-deps.sh` |
| `ninja` 未安装 | openvela 的 cmake 构建可能受影响 | `install-deps.sh` |
| WSL 中无 `/dev/ttyUSB*`，无 `usbipd` | **无法烧录、无法看串口** | `setup-usbipd.ps1` |
| Windows 侧 Python 无 `esptool` | 无法烧录 | `install-deps.sh` / Windows `pip install esptool` |

## 用法

```bash
# 在 WSL 中
bash /mnt/d/Myprogram/DeepSeekProgram/ESP32S3N16R8-One/OpenvelaESP-BTSH/scripts/setup/check-env.sh
```

> 脚本尚未实现，将在阶段 S1 编写。当前先用只读方式记录现状，
> 不做任何会改变系统状态的自动操作。
