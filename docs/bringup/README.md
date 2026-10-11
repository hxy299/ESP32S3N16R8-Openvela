# docs/bringup/ — 板级适配技术笔记

记录 **ESP32-S3-N16R8 在 openvela / NuttX 上的板级适配（board port）** 过程中的技术细节、
决策依据与踩坑记录。与 `docs/stages/` 的区别：

| | `stages/` | `bringup/` |
| --- | --- | --- |
| 视角 | 时间线（我什么时候做了什么） | 主题（这个机制是怎么运作的） |
| 更新 | 每阶段一份，写完基本不动 | 持续修订，长期有效 |
| 内容 | 过程、命令、结论 | 原理、配置项含义、决策理由 |

## 文件清单

| 文件 | 主题 | 状态 |
| --- | --- | --- |
| `README.md` | openvela 中 ESP32-S3 支持的**现状盘点** + 待查证问答（Q1–Q7） | ✅ 已完成 |
| [`wsl-esp32s3-build-notes.md`](wsl-esp32s3-build-notes.md) | **★ WSL2 下构建 ESP32-S3 的完整排错记录**（含两处上游 bug 分析、构建结果验证） | ✅ 已完成 |
| [`research-2026-10-10-ble-and-a7z.md`](research-2026-10-10-ble-and-a7z.md) | 外部调研报告存档（BLE 架构、A7Z、烧录方式） | ✅ 已归档 |
| `board-port-howto.md` | 新建一块 ESP32-S3 板子的完整步骤 | ⏳ S2 |
| `gatt-server-howto.md` | **如何写一个 GATT Server 内建应用**（本项目最大工作量） | ⏳ S5 |
| `pitfalls.md` | 踩坑合集（目前内容集中在 build-notes 里） | ⏳ 持续追加 |

### 重要发现的快速索引

| 发现 | 位置 |
| --- | --- |
| 官方声明**不支持 WSL** 编译，但实测可用（需额外处理网络与依赖） | [build-notes §0](wsl-esp32s3-build-notes.md) |
| `github.com` 被 DNS 污染 → 用本机 CONNECT 代理绕过（免 sudo） | [build-notes §2](wsl-esp32s3-build-notes.md) |
| esp-hal 必须**完整克隆**，不能用 `--filter=blob:none` | [build-notes §3](wsl-esp32s3-build-notes.md) |
| 跨架构残留 `.o` → 切换架构必须 `distclean` | [build-notes §4](wsl-esp32s3-build-notes.md) |
| **上游 bug：所有 ESP32-S3 配置都编译不过**（spinlock 初始化） | [build-notes §9](wsl-esp32s3-build-notes.md) |
| 两处构建成功的实测结果与产物合法性验证 | [build-notes §8](wsl-esp32s3-build-notes.md) |

---

## 已确认的现状盘点（2026-10，基于对 `~/openvela` 的实际探测）

### openvela 源码树结构

```
~/openvela/
├── nuttx/                  NuttX 内核（含 arch/xtensa/src/esp32s3、boards/xtensa/esp32s3）
├── apps/                   应用与示例（wireless/bluetooth 等）
├── external/               外部组件（bluelet、zblue 等）
├── frameworks/connectivity/bluetooth    蓝牙框架
├── vendor/                 厂商板级扩展（espressif/boards/esp32s3）
├── prebuilts/gcc/linux-x86_64/xtensa-esp32s3-elf    工具链（GCC 12.2.0）
├── build.sh -> nuttx/tools/build.sh
├── cmake_out/              构建输出（已有 rp2040 / luckfox-pico 等的产物）
└── .repo/                  repo 工具元数据
```

### ESP32-S3 芯片级支持：**已存在**

| 项 | 状态 | 证据 |
| --- | --- | --- |
| `arch/xtensa/src/esp32s3/` | ✅ 131 个文件 | 与上游 NuttX（115 个文件）有差异，是定制分支 |
| WiFi | ✅ `ESP32S3_WIFI` Kconfig 存在 | `arch/xtensa/src/esp32s3/Kconfig:677` |
| **BLE** | ✅ `ESP32S3_BLE` Kconfig 存在 | `arch/xtensa/src/esp32s3/Kconfig:684` |
| BLE 适配层 | ✅ `esp32s3_ble.c`(8.2 KB) / `esp32s3_ble_adapter.c`(96 KB) / `.h` | 文件已在源码树中 |
| WiFi/BT 共存 | ✅ `ESP32S3_WIFI_BT_COEXIST` | `Kconfig:879`，`default y if WIFI && BLE` |
| PSRAM | ✅ `ESP32S3_PSRAM_8M` / `ESP32S3_SPIRAM_MODE_OCT` / `ESP32S3_SPIRAM_TYPE_ESPPSRAM64` | `Kconfig:306 / 909 / 935` |
| SPI Flash | ✅ `esp32s3_spiflash_mtd` 等 | — |
| GPIO / ADC / I2S / LEDC(PWM) / RTC / TWAI / USB | ✅ 均有对应 `esp32s3_*.c` | — |

### 板级支持：**已有 9 块板子**

```
nuttx/boards/xtensa/esp32s3/
├── common/                     共用板级代码
├── esp32s3-devkit/             ★ 最接近通用开发板，配置最全（含 ble / blewifi）
├── esp32s3-box/
├── esp32s3-eye/
├── esp32s3-korvo-2/
├── esp32s3-lcd-ev/             （含 ws2812 配置，可参考 RGB 驱动）
├── esp32s3-lhcbit/
├── esp32s3-meadow/
└── lckfb-szpi-esp32s3/
```

`esp32s3-devkit/configs/` 下可用的配置（共 40+ 个），与本项目相关的：

| 配置 | 用途 |
| --- | --- |
| `nsh` | 最简 shell，板级适配第一目标 |
| **`ble`** | **BLE 基线，本项目核心** |
| `blewifi` | BLE + WiFi 共存 |
| `psram_octal` | OPI PSRAM 启用参考（N16R8 必需） |
| `psram_quad` / `psram_usrheap` | 其他 PSRAM 方案 |
| `gpio` | GPIO 驱动与 `/dev/gpio` |
| `usbnsh` | 原生 USB console |
| `mcuboot_nsh` | MCUboot 引导方案 |

### BLE 协议栈层次（已具备）

| 层 | 位置 | 内容 |
| --- | --- | --- |
| Controller（芯片侧） | `arch/xtensa/src/esp32s3/esp32s3_ble_adapter.c` | ESP32-S3 蓝牙控制器适配（96 KB，含 HCI 传输） |
| HCI | 同上 | — |
| Host 协议栈 | `nuttx/wireless/bluetooth/` | `bt_hcicore` `bt_l2cap` `bt_att` `bt_gatt` `bt_smp` `bt_keys` `bt_conn` `bt_netdev` `bt_ioctl` |
| 网络接口 | `nuttx/net/bluetooth/` | Bluetooth socket（AF_BLUETOOTH） |
| 应用侧 | `apps/wireless/bluetooth/` | 示例程序 |
| openvela 框架 | `frameworks/connectivity/bluetooth/`、`external/bluelet` | 上层蓝牙服务框架 |

> 这意味着：**BLE 的 Controller + Host 在 openvela 里是齐的**，
> 本项目的核心工作不是「从零实现 BLE」，而是
> ① 让 N16R8 这块板子的板级配置正确（Flash/PSRAM/引脚/晶振）；
> ② 在 `ble` 基线之上裁剪出适合灯控的最小配置；
> ③ 实现 GATT 灯控服务（应用层）。
>
> 这是**显著降低风险**的发现。

### openvela 与上游 NuttX 的差异（ESP32-S3 部分）

| 只在 openvela 有 | 只在上游 NuttX 有 |
| --- | --- |
| `esp32s3_adc` `esp32s3_aes` `esp32s3_i2s` `esp32s3_ledc` `esp32s3_pm` `esp32s3_rt_timer` `esp32s3_rtc` `esp32s3_ioexpander` `esp32s3_clockconfig` `esp32s3_efuse*` `esp32s3_gpio` `esp32s3_irq` `Wireless.mk` | `esp32s3_addrenv*` `esp32s3_mmu` `esp32s3_cache` `esp32s3_cam` `esp32s3_pgalloc` `esp32s3_pms` `esp32s3_isolation` `esp32s3_world1_vectors.S` `esp32s3_pagefault` `esp32s3_userfault` `esp32s3_wcl` |

**解读**：

- openvela 分支**往外设驱动方向扩展**（ADC/I2S/PWM/RTC/PMU 更全）→ 对智能家居有利。
- openvela 分支**缺少上游的内存管理/MMU/隔离特性**（addrenv、mmu、pms、isolation、
  kernel/user 分离相关）。若上游的某些 ESP32-S3 新驱动依赖 MMU，直接搬过来会编译失败。
- **结论**：以 `~/openvela` 的代码为准开发，把 `~/nuttx-upstream` 仅当**参考资料**
  （看驱动实现思路、看板级怎么写），不要直接把上游文件拷进 openvela。

### 环境缺口（阻塞项）

| 缺口 | 影响 | 解决 |
| --- | --- | --- |
| 工具链不在 PATH | 无法编译 | 加 PATH 或写脚本 |
| `kconfig-frontends` / `menuconfig` 未装 | 无法图形化配置 | `apt install kconfig-frontends` |
| `ninja` 未装 | openvela cmake 构建可能失败 | `apt install ninja-build` |
| **WSL 看不到 `/dev/ttyUSB*`** | **无法烧录 / 无法看串口** | usbipd-win 透传，或在 Windows 侧烧录 |
| 原理图 PDF 未获取 | 无法确认排针完整引出与 GPIO3 焊盘 | 请用户在商家资料页附件区下载 |

---

## 待查证事项（**已查证部分已回填，未查证的明确标注**）

| 编号 | 待查证 | 状态 | 结论 / 证据 |
| --- | --- | --- | --- |
| Q1 | ESP32-S3 的 NuttX 固件**烧录偏移量**与是否需要二级引导 | ✅ **已查证** | **默认 Simple Boot：不需要 bootloader，`nuttx.bin` 直接烧 `0x0`**。Legacy：bootloader@0x0 + 分区表@0x8000 + app@0x10000。MCUboot：mcuboot@0x0 + app@`OTA_PRIMARY_SLOT_OFFSET`。工具 = `esptool.py` ≥ 4.8.0（**非** esptool-js），`make flash ESPTOOL_PORT=... ESPTOOL_BINDIR=./`，默认 921600。依据：`nuttx/tools/esp32s3/Config.mk`、`arch/xtensa/src/esp32s3/Bootloader.mk`、NuttX 官方平台文档 |
| Q2 | N16R8 的 8 MB OPI PSRAM 在 NuttX 下的正确配置组合 | ✅ **已查证（待实测）** | `CONFIG_ARCH_CHIP_ESP32S3WROOM1N16R8=y`（自动 select `FLASH_16M` / `PSRAM_8M`）+ 参照 `psram_octal`：`SPIRAM` + `SPIRAM_MODE_OCT` + `MM_REGIONS=2` |
| Q3 | `esp32s3-devkit` 的板级定义能否直接用于本板 | ✅ **已判定：可以直接用** | 本板与 DevKitC-1 的差异仅在模拟外设（RGB 在 GPIO48、电源灯不可控），**核心引脚（UART0=43/44、USB=19/20、Flash/PSRAM=26–32）一致**。因此**不需要新建板级目录**，改 defconfig 即可。WS2812 需另写驱动 |
| Q4 | openvela 的 `build.sh` 与 NuttX 原生 `configure.sh`+`make` 哪个是官方推荐流程 | 🟡 **部分查证** | openvela 官方 ESP32-S3 教程用的是 **`./build.sh vendor/espressif/boards/.../configs/openvela/ -j8`** 再 `cd nuttx && make flash`。但该路径针对 `esp32s3-eye`/`box`；本板走 `nuttx/boards/xtensa/esp32s3/esp32s3-devkit` 时是否也适用**需实测** |
| Q5 | A7Z 侧 BLE 作为 Central 的能力 | 🔴 **用户已答复但有矛盾** | 用户称「BLE 部分正在适配，打算会师」。但调研发现 Radxa「Cubie A7Z」是全志 A733、官方系统 Debian/Android、**查不到 openvela 支持**。**需用户澄清**（见 [stage-01 §7.1](../stages/stage-01-env-and-baseline.md)） |
| Q6 | NuttX BLE host 是否支持 Peripheral 角色（GATT Server）与 Notify | ✅ **已查证：支持，但无应用层 API** | 内核 C API `bt_gatt_register()` 存在且注释标 "Server API"，**但没有 NSH 命令也没有 ioctl**。ioctl 只覆盖 client 侧（广播/扫描/GATT 读写信，`SIOCBTADVSTART`/`SIOCBTSCANSTART`/`SIOCBTGATTRD`/`SIOCBTGATTWR`）。**→ 灯控 GATT 服务必须自己写应用代码** |
| Q7 | WiFi + BLE 能否同时工作 | ✅ **已查证** | `esp32s3-devkit:blewifi` 配置已存在，配合 `ESP32S3_WIFI_BT_COEXIST`（`default y if WIFI && BLE`）。这正好满足用户「BLE 和 WiFi 都要」的需求 |

### Q1/Q6 的详细说明

**烧录（Q1）三种模式对比**：

| 模式 | 需要额外引导器？ | 烧录地址 | 本项目是否需要 |
| --- | --- | --- | --- |
| **Simple Boot（默认）** | ❌ 不需要 | `nuttx.bin` → **0x0** | ✅ **先用这个**，最省事 |
| Legacy（`ESP32S3_APP_FORMAT_LEGACY`） | ✅ `make bootloader` | bootloader→0x0、分区表→0x8000、app→0x10000 | ⏳ 需要自定义分区时考虑 |
| MCUboot（`ESP32S3_APP_FORMAT_MCUBOOT`） | ✅ `make bootloader` + `imgtool sign` | mcuboot→0x0、app→OTA primary slot | ⏳ 需要 OTA / 双槽回滚 / Flash 加密时考虑 |

> `tools/esp32s3/mcuboot_toolchain_esp32s3.cmake` 是**交叉编译 MCUboot 引导器本体**用的
> CMake toolchain 文件（被 `Bootloader.mk` 传给 `build_mcuboot.sh -d`），
> **不是应用签名工具**；应用签名用 Python `imgtool`。

**GATT Server（Q6）的含义**：

`nuttx/wireless/bluetooth/` 提供的是**协议栈实现**（`bt_gatt.c` 等），
但**没有把 GATT Server 的能力暴露成 ioctl 或 NSH 命令**。因此：

- ❌ 不能指望在 NSH 里敲几条命令就让板子变成 BLE 灯控设备
- ✅ 必须写一个**内建应用（built-in app）**，在其中调用 `bt_gatt_register()`
  注册服务、定义特征与回调，然后在 NSH 或开机自动启动

这是 S5 阶段的核心工作，也是本项目最大的工作量来源。

---

## 参考：外部调研资料

完整的第三方调研报告已归档：
[`research-2026-10-10-ble-and-a7z.md`](research-2026-10-10-ble-and-a7z.md)

> ⚠️ 该报告生成时本机 **github.com 不可达**，其 NuttX 代码事实取自 GitCode 上的
> `open-vela/nuttx` 镜像，并已与本机 `~/openvela` 的实际文件交叉验证（结论一致）。
> 报告中标注「未核实」的项目已在上表中体现。**该报告只作资料留存，不参与决策。**
