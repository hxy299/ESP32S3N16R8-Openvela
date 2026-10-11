# scripts/flash/ — 烧录

## 脚本

| 脚本 | 用途 | 状态 |
| --- | --- | --- |
| [`flash.sh`](flash.sh) | 烧录固件到 ESP32-S3（自动探测串口、校验和、权限检查、失败诊断） | ✅ 已实现 |
| `erase.sh` | 全片擦除 | ⏳ 待实现（可临时用 `ERASE_FIRST=1 bash flash.sh ...`） |
| `flash-monitor.sh` | 烧录后立即打开串口监视 | ⏳ 待实现 |

## 快速用法

```bash
# 烧录项目里预编译好的固件
bash scripts/flash/flash.sh assets/firmware/nuttx-esp32s3-eye-openvela-wifi.bin

# 指定串口
bash scripts/flash/flash.sh /tmp/nuttx.bin /dev/ttyUSB0

# 先整片擦除再烧（换固件发现启动异常时用）
ERASE_FIRST=1 bash scripts/flash/flash.sh assets/firmware/*.bin

# 降波特率（干扰大或线材差时）
BAUD=460800 bash scripts/flash/flash.sh assets/firmware/*.bin

# 看帮助（会列出 assets/firmware/ 下所有可用固件）
bash scripts/flash/flash.sh --help
```

## 烧录地址：`0x0`

**Simple Boot 模式直接烧 `0x0`**，不需要 bootloader、不需要分区表。
依据 NuttX `tools/esp32s3/Config.mk`；详见
[`../../docs/bringup/wsl-esp32s3-build-notes.md`](../../docs/bringup/wsl-esp32s3-build-notes.md)。

| 模式 | 需要引导器？ | 地址 |
| --- | --- | --- |
| **Simple Boot（默认，本项目用）** | ❌ | `nuttx.bin` → `0x0` |
| Legacy | ✅ `make bootloader` | bootloader→0x0、分区表→0x8000、app→0x10000 |
| MCUboot | ✅ + `imgtool sign` | mcuboot→0x0、app→OTA slot |

## 物理连接：必须用 USB-ISP 口

板上两个 Type-C：

| 口 | 芯片 | 用途 |
| --- | --- | --- |
| **USB-ISP** | **CH340C** | ✅ **烧录 + 串口日志都走这个** |
| USB-OTG | 原生 USB（GPIO19/20） | 需短接 OTG 焊盘才可用；不用于烧录 |

板载 ISP 一键下载电路（D1/D2 SS8050），**通常无需手动按 BOOT**。

## WSL 串口前置条件（必读）

WSL2 **默认看不到** Windows 的 USB 串口。需要 `usbipd-win` 透传：

```powershell
# Windows 管理员 PowerShell
winget install usbipd
usbipd list                            # 找到 CH340 的 BUSID
usbipd bind --busid <BUSID>            # 只需执行一次
usbipd attach --wsl --busid <BUSID>    # 每次插拔后都要重新执行
```

之后 WSL 里出现 `/dev/ttyUSB0`，`flash.sh` 就能自动探测到。

> 实测：本机**尚未安装 usbipd**，所以当前 WSL 看不到串口。
> 备选方案是在 Windows 侧烧录（需 Windows 有 esptool ≥ 4.8；
> 注意本机 Anaconda 是 Python 3.8.5，需 `pip install "esptool>=4.8,<5"`
> 或新建 Python 3.10+ 环境）。

## 硬件事实（影响烧录参数）

| 项 | 值 | 来源 |
| --- | --- | --- |
| 晶振 | 40 MHz（ESP32-S3 模组标准） | 数据手册 |
| Flash 容量 | **16 MB**（N16R8） | 模组丝印 |
| PSRAM | **8 MB，OPI/Octal**（N16R8） | 模组丝印；defconfig 需选 `ESP32S3_PSRAM_8M` + Octal 模式 |
| 烧录接口 | CH340（USB-ISP Type-C）；或原生 USB-OTG（需短接 OTG 焊盘） | 商家资料 |
| 下载模式 | 板载 ISP 一键下载电路，通常无需手动拉 GPIO0 | 商家资料 |
| 调试串口 | UART0 GPIO43/44，115200 8N1 | 商家资料 |

## 预期命令形态（**待实测**）

```bash
# 需要 esptool；是否用 --chip esp32s3 与烧录偏移量需按 NuttX 的 ESP32-S3 文档确认
esptool.py --chip esp32s3 -p /dev/ttyUSB0 -b 921600 write_flash <offset> nuttx.bin
```

> ⚠️ **烧录偏移量与是否需要 bootloader 尚未确认**。NuttX 对 ESP32-S3 的烧录方式
> （直接烧到 flash 起始，还是需要 MCUboot 之类的二级引导）必须查证后再固化，
> 不能猜。相关结论会在阶段 S1 写入 [`../../docs/bringup/`](../../docs/bringup/README.md)。

## WSL 串口前置条件

WSL2 默认**看不到 Windows 的 USB 串口设备**。当前 `/dev/ttyUSB*` 不存在。
需要 `usbipd-win` 把 CH340 透传进 WSL，见 [`../setup/README.md`](../setup/README.md)。
备选方案：在 Windows 侧用 esptool 直接烧录（不走 WSL）。
