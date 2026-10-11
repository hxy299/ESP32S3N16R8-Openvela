# 预编译固件（assets/firmware/）

存放**已验证可构建**的 ESP32-S3 固件，便于在没有完整构建环境时直接烧录。

---

## 1. `nuttx-esp32s3-eye-openvela-wifi.bin`

| 项 | 值 |
| --- | --- |
| 文件 | `nuttx-esp32s3-eye-openvela-wifi.bin` |
| 大小 | **1,363,024 字节** |
| MD5 | 见下方「校验和」 |
| 构建日期 | 2026-10-10 |
| 构建配置 | `vendor/espressif/boards/esp32s3/esp32s3-eye/configs/openvela/` |
| 构建命令 | `./build.sh vendor/espressif/boards/esp32s3/esp32s3-eye/configs/openvela/ -j16` |
| 结果 | **rc=0，构建成功** |
| 需要补丁 | `thirdparty/patches/0001`、`0002`（见 `thirdparty/patches/README.md`） |
| 随附文件 | `System.map`（符号表）、`defconfig-wireless`（完整 .config 快照） |

### esptool 镜像信息（已验证合法）

```
ESP32-S3 Image Header
Image version: 1
Entry point: 0x40374fa0
Segments: 2
Flash size: 4MB
Flash freq: 40m
Flash mode: DIO
Chip ID: 9 (ESP32-S3)
```

首字节 `0xE9`（ESP32 镜像魔术字），Chip ID 9 = ESP32-S3。

### 包含的功能（实测 .config）

```
CONFIG_ESP32S3_WIFI=y
CONFIG_ESP32S3_SPIRAM=y
CONFIG_ESP32S3_SPIRAM_MODE_OCT=y     ← OPI PSRAM
CONFIG_SMP=y                          ← 双核
CONFIG_WIRELESS_WAPI=y
CONFIG_NSH_*                          ← NuttShell 命令行
```

内置命令（构建日志 Register 行）：`nsh` `sh` `ping` `iperf` `iperf2` `tcpdump`
`wapi` `renew` `renew6` `rand` `lvgldemo` `fb`

### ⚠️ 烧录前必读：与本板（N16R8）的差异

**这个固件是按 `ESP32S3-EYE` 板级 + `ARCH_CHIP_ESP32S3WROOM1N4`（4 MB Flash）构建的，
不是按我们的 N16R8 构建的。** 差异清单：

| 项 | 固件预期 | 本板实际 | 影响 |
| --- | --- | --- | --- |
| 模组 | ESP32-S3-WROOM-1 | **ESP32-S3-WROOM-1-N16R8** | 基本兼容 |
| Flash | 4 MB | **16 MB** | 固件只用前 4 MB，**能启动**，浪费 12 MB |
| PSRAM | **OPI/Octal 8 MB** | **OPI/Octal 8 MB** | ✅ **一致**（N16R8 正好是 Octal） |
| 调试串口 | UART0 GPIO43/44 | UART0 GPIO43/44（CH340） | ✅ **一致** |
| 板载 RGB | ST7789 LCD + LVGL | **WS2812B @ GPIO48** | LCD 驱动会找不到屏（无害），RGB 需另写驱动 |
| USB | `ESP32S3_USBSERIAL=y` | 原生 USB 在 GPIO19/20 | 可能占用该引脚 |

**结论**：这是**硬件最接近**的一份可烧录固件，适合用来
**验证「板子能启动、串口能出 NSH」**，但**不是最终固件**。

**真正的下一步**（阶段 S2）是产出 N16R8 专用配置：
- 改 `ARCH_CHIP_ESP32S3WROOM1N16R8`（自动 select `FLASH_16M` + `PSRAM_8M`）
- 去掉 LCD/LVGL/ST7789（本板没有屏）
- 基于 `esp32s3-devkit:blewifi` 叠加 OPI PSRAM，因为本项目要 **BLE + WiFi 同时**

---

## 2. 如何烧录

### 方式 A：从 WSL（需先把 USB 串口透传进来）

WSL 环境里 esptool 已装好（`~/myenv`，入口 `~/.local/bin/esptool.py`）：

```bash
# 1. 在 Windows 管理员 PowerShell 里安装并透传（只需一次）
winget install usbipd
usbipd list                                  # 找到 CH340 的 BUSID
usbipd bind --busid <BUSID>                  # 只需一次
usbipd attach --wsl --busid <BUSID>          # 每次插拔后都要

# 2. 在 WSL 里烧录
cd ~/openvela/nuttx
make flash ESPTOOL_PORT=/dev/ttyUSB0 ESPTOOL_BINDIR=./
# 或直接：
esptool.py --chip esp32s3 -p /dev/ttyUSB0 -b 921600 \
  write_flash 0x0 /path/to/nuttx-esp32s3-eye-openvela-wifi.bin
```

### 方式 B：在 Windows 侧烧录

需要 Windows 有 esptool。当前 Anaconda 是 **Python 3.8.5**，
而 esptool ≥ 5.0 要求 Python ≥ 3.10，需装 4.8.x 或新建 3.10+ 环境：

```powershell
pip install "esptool>=4.8,<5"
esptool.py --chip esp32s3 -p COM3 -b 921600 write_flash 0x0 nuttx-...bin
```

### 烧录地址

**Simple Boot 模式：烧到 `0x0`**，不需要 bootloader、不需要分区表。
（依据：NuttX `tools/esp32s3/Config.mk`；详见
[`../../docs/bringup/wsl-esp32s3-build-notes.md`](../../docs/bringup/wsl-esp32s3-build-notes.md)）

### 物理连接

必须用 **USB-ISP** 那个 Type-C 口（接 CH340 的那个），**不是 USB-OTG 口**。
板载 ISP 一键下载电路，无需手动按 BOOT。

### 看串口

115200 8N1，接上后应出现 NSH 提示符 `nsh>`。

---

## 3. 校验和（**烧录前请核对**）

| 算法 | 值 |
| --- | --- |
| MD5 | `7eea1b64af1d4126545c686fc504ac5b` |
| SHA-256 | `bdabcfca14f971d49605057271fd3abf2d69f099417994c2fe46830b61902836` |

```bash
# WSL
md5sum nuttx-esp32s3-eye-openvela-wifi.bin
# Windows
certutil -hashfile nuttx-esp32s3-eye-openvela-wifi.bin MD5
```

---

## 4. 已知缺失

| 项 | 说明 |
| --- | --- |
| `nsh` 配置的固件（207,620 B） | 更简单、无 WiFi，本该是**首烧首选**，但备份在 `/tmp` 清理时丢失。需重新构建或从其它备份找回 |
| N16R8 专用固件 | 需阶段 S2 产出 |
| BLE 固件 | `esp32s3-devkit:ble` 配置尚未完成构建验证 |

## 5. 相关文档

- 完整排错与构建记录：[`../../docs/bringup/wsl-esp32s3-build-notes.md`](../../docs/bringup/wsl-esp32s3-build-notes.md)
- 上游 bug 补丁：[`../../thirdparty/patches/README.md`](../../thirdparty/patches/README.md)
- 硬件事实与引脚：[`../../docs/hardware/README.md`](../../docs/hardware/README.md)
