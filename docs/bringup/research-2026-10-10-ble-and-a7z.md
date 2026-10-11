> **归档说明**
>
> - 本文件是 **2026-10-10 的外部技术调研报告原文**，由 AI 子代理生成，**未经逐条人工核实**。
> - 生成环境限制：当时 **github.com 不可达**，NuttX 代码事实取自 **GitCode 上的
>   `open-vela/nuttx` 镜像**与 NuttX 官方文档站；openvela 文档取自 Gitee；Radxa 取自官网。
>   报告中凡标注「未查到 / 未核实」的部分，**不要当作结论使用**。
> - 其关键结论已与本机 `~/openvela` 的实际文件**交叉验证**，验证结果见
>   [`README.md`](README.md) 的「待查证事项」表。
> - **本文档不参与项目决策**，仅作资料留存与溯源；项目的权威结论在
>   [`README.md`](README.md) 与 [`../../docs/hardware/`](../hardware/README.md)。

---
# NuttX / openvela 下 ESP32-S3（N16R8）蓝牙（BLE）适配 与 Radxa A7Z 技术调研报告

> 调研对象：用 NuttX 系（openvela）为 ESP32-S3-N16R8（16MB Flash + 8MB OPI PSRAM）做板级适配，并通过蓝牙从一块高性能主控板（用户表述为 "Radxa A7Z"）远程控制 ESP32-S3 下位机（先做电灯开关）。
>
> 调研方式与局限：本机 **github.com 无法访问**（DNS 解析到非公网 IP），因此 GitHub 仓库正文未能直接打开；NuttX 侧代码事实全部取自 **open-vela/nuttx 的 GitCode 镜像（dev 分支，与上游同源）** 与 **NuttX 官方文档站**，openvela 文档取自 **Gitee open-vela/docs**，Radxa 取自 **官方站点**。凡仅有搜索引擎标题、未能打开正文的内容，均在文中明确标注"未核实/未查到"。

---

## 0. 结论速览（TL;DR）

| 问题 | 结论 |
|---|---|
| ESP32-S3 BLE 控制器在 NuttX 是否可用 | **可用**。`esp32s3_ble.c` + `esp32s3_ble_adapter.c` 把 Espressif 的 BLE 控制器（`esp_bt_controller_init` / `esp_vhci_host_*`）封装成 NuttX 的 `bt_driver`（H4/HCI），板级 `esp32s3_bringup()` 里调用 `esp32s3_ble_initialize()` |
| host 侧是哪种 | **NuttX 自带 BLE host：`wireless/bluetooth`**（`CONFIG_WIRELESS_BLUETOOTH` + `CONFIG_WIRELESS_BLUETOOTH_HOST`）。该栈 Kconfig 头注释写明是 **Intel/Zephyr arduino101 固件包移植而来**。**不是 NimBLE**（NimBLE 在 nuttx-apps 中作为可选 host-only 应用存在），也不是 Zephyr 原版 host |
| Controller-only 还是 Controller+Host | **两者都有**：控制器（Espressif 二进制实现）+ NuttX host 同时存在，`ble` / `blewifi` defconfig 直接可用；host 层可关（`WIRELESS_BLUETOOTH_HOST=n`），但"只用控制器 + 外部 host 走 UART"的 ESP32-S3 官方用法**未查到** |
| openvela 侧 ESP32-S3 蓝牙 | openvela/nuttx 与上游同源（有小米侧蓝牙修补提交）；openvela **官方适配的 ESP32-S3 板只有 `esp32s3-eye`、`esp32s3-box`**，且其移植文档**只写 Wi-Fi，没写蓝牙**；`bluelet` 这个名称**未查到** |
| 最接近通用 DevKitC/N16R8 的板子 | **`esp32s3-devkit`**（即 ESP32-S3-DevKitC-1 + ESP32-S3-WROOM-1 模组）。N16R8 需把芯片选项改成 `ARCH_CHIP_ESP32S3WROOM1N16R8`，PSRAM 参照 `psram_octal` |
| Radxa A7Z 是什么 | **确实存在：Radxa Cubie A7Z**，但它是 **Allwinner A733（2×A76+6×A55）+ LPDDR4x 最大 16GB + WiFi6/BT5.4** 的 Linux/Android 小板，**不是 Rockchip**。**未查到任何 openvela 支持**；openvela 的 Rockchip 支持只是一个**空壳 `vendor_rockchip` 仓库**（Gitee 上仅 4 个提交、只有 `.github/.gitee`） |
| 烧录方式 | **esptool.py（Python，≥4.8.0）**，由 `make flash` 驱动；`esptool-js` 是 Espressif 的浏览器/WebSerial 版本，**NuttX 构建体系不使用**。默认 **Simple Boot：不需要额外 bootloader，`nuttx.bin` 直接烧到 `0x0`**；Legacy 模式为 bootloader@`0x0` + 分区表@`0x8000` + app@`0x10000`；MCUboot 模式为 `mcuboot-esp32s3.bin`@`0x0` + 应用烧到 OTA primary slot |

---

## 1. NuttX 官方仓库中 ESP32-S3 的蓝牙（BLE）支持现状

### 1.1 `arch/xtensa/src/esp32s3/` 下的 BLE 相关文件是什么

经 GitCode 镜像目录 API 核实，ESP32-S3 芯片目录下与 BLE 相关的文件共有 4 个：

| 文件 | 作用（依据代码内容） |
|---|---|
| [`esp32s3_ble_adapter.c`](https://gitcode.com/open-vela/nuttx/blob/dev/arch/xtensa/src/esp32s3/esp32s3_ble_adapter.c) / [`esp32s3_ble_adapter.h`](https://gitcode.com/open-vela/nuttx/blob/dev/arch/xtensa/src/esp32s3/esp32s3_ble_adapter.h) | **控制器适配层**：把 Espressif 蓝牙控制器的 OS 依赖（信号量/队列/任务/中断/低功耗时钟/rw 共存）适配到 NuttX；实现 `esp32s3_bt_controller_init()`、`esp32s3_bt_controller_enable(ESP_BT_MODE_BLE)`、`esp32s3_vhci_register_callback()`、`esp32s3_vhci_host_send_packet()`、`esp32s3_vhci_host_check_send_available()`。文件里包含 `esp_bt.h`、`esp_private/esp_clk.h`、`private/esp_coexist_internal.h` 等，说明控制器实现来自 Espressif HAL（`esp-hal-3rdparty`），并以 Wi-Fi/BT 共存（coex）方式工作 |
| [`esp32s3_ble.c`](https://gitcode.com/open-vela/nuttx/blob/dev/arch/xtensa/src/esp32s3/esp32s3_ble.c) / `esp32s3_ble.h` | **HCI 传输 + host 侧驱动注册**：定义 `struct bt_driver_s drv`（`head_reserve = H4_HEADER_SIZE`、`open/send/close`），收发走 H4 头（`H4_CMD/H4_ACL/H4_EVT/H4_ISO`），收到控制器数据后调用 `bt_netdev_receive()` 交给 NuttX host；`esp32s3_ble_initialize()` 顺序为：`esp32s3_bt_controller_init()` → `esp32s3_bt_controller_enable(ESP_BT_MODE_BLE)` → `esp32s3_vhci_register_callback()` → **`bt_driver_register(&g_ble_priv.drv)`** |

板级初始化调用点已核实：`boards/xtensa/esp32s3/esp32s3-devkit/src/esp32s3_bringup.c` 中

```c
#ifdef CONFIG_ESP32S3_WIRELESS
#ifdef CONFIG_ESP32S3_WIFI_BT_COEXIST
  ret = esp32s3_wifi_bt_coexist_init();
#endif
#ifdef CONFIG_ESP32S3_BLE
  ret = esp32s3_ble_initialize();
#endif
#ifdef CONFIG_ESP32S3_WIFI
  ret = board_wlan_init();
#endif
#endif
```

见 [esp32s3_bringup.c](https://gitcode.com/open-vela/nuttx/blob/dev/boards/xtensa/esp32s3/esp32s3-devkit/src/esp32s3_bringup.c)。

**结论**：`esp32s3_ble_adapter.*` = "Espressif BLE 控制器 → NuttX OS 服务"的胶水层；`esp32s3_ble.c` = "控制器 VHCI ↔ NuttX BT host 的 H4/HCI 驱动"。**控制器在 NuttX 里是可用的**，并且带有 Wi-Fi/BT 共存配置（`ESP32S3_WIFI_BT_COEXIST`，源自 Espressif 的 PR，见 1.5 节的出处标注）。

### 1.2 host 侧到底是哪种栈

- NuttX 的 BLE host 在 `wireless/bluetooth/`，由 `CONFIG_WIRELESS_BLUETOOTH` 打开，且默认带 host 层 `CONFIG_WIRELESS_BLUETOOTH_HOST=y`（"BLE Host Layer"）。其 `Kconfig` 文件头写明：*"Ported from the Intel/Zephyr arduino101_firmware_source-v1.tar package"* —— 即**从 Zephyr/Intel 的 arduino101 固件包移植而来的 NuttX 自带 host**。见 [wireless/bluetooth/Kconfig](https://gitcode.com/open-vela/nuttx/blob/dev/wireless/bluetooth/Kconfig)。
- 该目录下可见完整协议组件：`bt_hcicore.c`、`bt_l2cap.c`、`bt_att.c`、`bt_gatt.c`、`bt_smp.c`、`bt_conn.c`、`bt_keys.c`、`bt_netdev.c`、`bt_ioctl.c` 等，见 [wireless/bluetooth 目录](https://gitcode.com/open-vela/nuttx/blob/dev/wireless/bluetooth)。
- **NimBLE 是另一条可选路线**：NuttX 文档有独立页面 [`nimble` Apache NimBLE (BLE host-layer) for NuttX](https://nuttx.apache.org/docs/latest/applications/wireless/nimble/index.html)（"build nimBLE stack (host-only) as a library/application in NuttX"）。但 **ESP32-S3 的 `ble` defconfig 走的是 NuttX 原生 host，不是 NimBLE**。
- Zephyr host 原版并没有作为独立组件出现在 NuttX 里；能称得上"Zephyr 血统"的只有上面这套移植版 host。

### 1.3 需要开哪些 Kconfig（以 `esp32s3-devkit:ble` 实测 defconfig 为准）

官方 `ble` 配置（[defconfig](https://gitcode.com/open-vela/nuttx/blob/dev/boards/xtensa/esp32s3/esp32s3-devkit/configs/ble/defconfig)）中与 BLE 相关的关键项：

```
CONFIG_ALLOW_BSD_COMPONENTS=y     # WIRELESS_BLUETOOTH 的依赖
CONFIG_ESP32S3_BLE=y              # 芯片侧 BLE（自动 select ESP32S3_WIRELESS）
CONFIG_WIRELESS=y
CONFIG_WIRELESS_BLUETOOTH=y       # NuttX BLE host 总开关
CONFIG_DRIVERS_BLUETOOTH=y        # 蓝牙驱动框架（bt_driver_register 需要）
CONFIG_DRIVERS_WIRELESS=y
CONFIG_DRIVERS_IEEE80211=y
CONFIG_NET_BLUETOOTH=y            # AF_BLUETOOTH / HCI socket 层
CONFIG_BTSAK=y                    # btsak 测试工具（Bluetooth Swiss Army Knife）
CONFIG_ESP32S3_RT_TIMER_TASK_STACK_SIZE=4096
CONFIG_ARCH_CHIP_ESP32S3WROOM1N4=y
```

芯片侧 Kconfig 定义（[arch/xtensa/src/esp32s3/Kconfig](https://gitcode.com/open-vela/nuttx/blob/dev/arch/xtensa/src/esp32s3/Kconfig)）：

```
config ESP32S3_BLE
	bool "BLE"
	default n
	select ESP32S3_WIRELESS          # 后者 select NET / ARCH_PHY_INTERRUPT / ESP32S3_RNG / ESP32S3_RT_TIMER / ESP32S3_TIMER0

config ESP32S3_WIFI_BT_COEXIST      # "Wi-Fi and BT coexist"
	default y if ESP32S3_WIFI && ESP32S3_BLE
	depends on ESP32S3_WIFI && ESP32S3_BLE

menu "BLE Configuration"  depends on ESP32S3_BLE
  ESP32S3_BLE_TASK_STACK_SIZE       default 4096   # 控制器任务栈
  ESP32S3_BLE_TASK_PRIORITY         default 253    # 控制器任务优先级
  ESP32S3_BLE_INTERRUPT_SAVE_STATUS default 3      # 中断现场保存深度
```

Host 侧可调项（[wireless/bluetooth/Kconfig](https://gitcode.com/open-vela/nuttx/blob/dev/wireless/bluetooth/Kconfig)）：`WIRELESS_BLUETOOTH_HOST`（默认 y）、`DEVICE_NAME`（默认 "Apache NuttX"）、`DEVICE_LOCAL_NAME`（默认 "NuttX"，广播名）、`BLUETOOTH_MAX_CONN`（**默认 1**）、`BLUETOOTH_MAX_PAIRED`（默认 1）、`BLUETOOTH_MAXSCANDATA/MAXSCANRESULT`、`BLUETOOTH_TXCMD/TXCONN` 线程参数等。

### 1.4 Controller-only 还是 Controller+Host：二者都有，但"应用层 API"很薄（重要）

- **控制器**：Espressif 的 BLE controller（经 `esp-hal-3rdparty` 提供），NuttX 侧只做适配。**Controller 是二进制/预编译实现**，与 Wi-Fi 共享 PHY 与共存调度。
- **Host**：NuttX `wireless/bluetooth`（GAP/L2CAP/ATT/GATT/SMP），并通过 `bt_netdev.c` 暴露成一个**网络设备 + ioctl** 接口。
- 可用的上层能力（据 [bt_ioctl.h](https://gitcode.com/open-vela/nuttx/blob/dev/include/nuttx/wireless/bluetooth/bt_ioctl.h)）：`SIOCBTADVSTART/STOP`（广播起停）、`SIOCBTSCANSTART/GET/STOP`（扫描）、`SIOCBTSECURITY`（安全/加密等级）、`SIOCBTEXCHANGE`、`SIOCBTDISCOVER`、`SIOCBTGATTRD`、`SIOCBTGATTWR`（**GATT client** 的 MTU/发现/读/写）、`SIOCBTCONNECT/DISCONNECT`。命令行工具 `btsak` 就是这些 ioctl 的包装，命令见 [NuttX 文档 btsak](https://nuttx.apache.org/docs/12.12.0/applications/wireless/btsak/index.html)。
- **GATT server（外设角色）只有内核级 C API，没有 ioctl/NSH 命令**：[bt_gatt.h](https://gitcode.com/open-vela/nuttx/blob/dev/include/nuttx/wireless/bluetooth/bt_gatt.h) 中有 `void bt_gatt_register(const struct bt_gatt_attr_s *attrs, size_t count)`、`bt_gatt_notify()`、`BT_GATT_PRIMARY_SERVICE/BT_GATT_CHARACTERISTIC/BT_GATT_CCC` 等宏，注释标为 "Server API"。历史上社区也确认过"没有从用户态注册 GATT server 的接口"（见 2020 年邮件列表 [defining a BLE GATT server](https://www.mail-archive.com/dev@nuttx.apache.org/msg04754.html)）。
  - 实践含义：NuttX **FLAT 构建**下应用与内核同镜像、无特权隔离，内建应用**可以直接调用 `bt_gatt_register()`** 来做一个 BLE 外设（电灯开关）；但"用 NSH 命令/IOCTL 动态定义 GATT 服务"这条路在 ESP32-S3 上目前不存在，必须自己写代码。
- **Controller-only 用法**：可以把 `CONFIG_WIRELESS_BLUETOOTH_HOST` 关掉只留控制器，但 ESP32-S3 官方/文档层面**未查到**"仅控制器 + 外部 host（如 Linux BlueZ）通过 HCI UART/网络接管"的示例或说明；NuttX 中"外部控制器接 NuttX host"方向（bth4/btuart 等）才是常见用法。

### 1.5 出处与溯源（含未能核实项）

- NuttX 官方平台文档明确列出 **Bluetooth = Yes**（ESP32-S3 外设支持表）：[Espressif ESP32-S3 — NuttX latest documentation](https://nuttx.apache.org/docs/latest/platforms/xtensa/esp32s3/index.html)。
- 功能来源（**这两条只有搜索结果的标题，未能在本环境打开 GitHub 正文，属"未核实正文"**）：
  - `Implement ESP32-S3 BLE support with Wi-Fi coexistence by tmedicci · Pull Request #10200 · apache/nuttx` → <https://github.com/apache/nuttx/pull/10200>
  - 相关 issue：`ESP32-S3: Add BLE support · Issue #9507` → <https://github.com/apache/nuttx/issues/9507>；`Add BLE support for esp32s3 · Issue #12685` → <https://github.com/apache/nuttx/issues/12685>
  - 上游 PR #14224 要求芯片打开 `CONFIG_DRIVERS_BLUETOOTH` 才能用蓝牙，这一点由 openvela 的修补提交反向证实（见第 2 节）。

---

## 2. openvela 项目中 ESP32-S3 的蓝牙支持现状

### 2.1 openvela/nuttx 里的 ESP32-S3 蓝牙代码

- openvela 的 nuttx（`dev` 分支）中 `arch/xtensa/src/esp32s3/` 同时存在 `esp32s3_ble.c/.h` 与 `esp32s3_ble_adapter.c/.h`，与上游**同源**（例如 `esp32s3_ble_adapter.c` 最近一次改动是 [commit 90712206 "arch/xtensa: fix compiler warning"](https://atomgit.com/open-vela/nuttx/blob/dev/arch/xtensa/src/esp32s3/esp32s3_ble_adapter.c)）。
- openvela 侧**有蓝牙相关修补**，例如提交 `9984d36b`：*"bluetooth: Fix the incompatibility made by https://github.com/apache/nuttx/pull/14224 … that pr requires chip turn on CONFIG_DRIVERS_BLUETOOTH to use bluetooth, but not all defconfig enable this option, so let's map bt_driver_register to bt_netdev_register in header file in this case"*（作者 xiaoxiang@xiaomi.com）→ 说明**小米/openvela 在维护 NuttX 蓝牙与新驱动注册模型的兼容**：["bluetooth: Fix the incompatibility…" 提交](https://gitcode.com/open-vela/nuttx/commits/detail/9984d36b2906346a0d4380a3d6090bcc595039b7)。
- openvela 的 `wireless/` 下只有 `bluetooth`、`ieee802154`、`pktradio`（**没有** 名为 bluelet 的目录）：[wireless 目录](https://gitcode.com/open-vela/nuttx/blob/dev/wireless)。

### 2.2 openvela 官方支持的 ESP32-S3 板子（这才是重点）

- openvela 的 vendor 仓库 `open-vela/vendor_espressif`（分支 `dev-ai-contest-2026`）下 `boards/` 只有 `esp32s3/`，其下**只有两块板**：`esp32s3-box`、`esp32s3-eye` —— 见 [vendor_espressif boards/esp32s3 目录](https://gitcode.com/open-vela/vendor_espressif/tree/dev-ai-contest-2026/boards/esp32s3)。
- openvela 官方《openvela 开发板支持列表》中，乐鑫只有 **ESP32S3EYE** 和 **ESP32S3BOX** 两款（芯片 ESP32S3）：[Development_Board.md](https://gitee.com/open-vela/docs/blob/trunk-5.2/zh-cn/dev_board/Development_Board.md)。
- 大赛（2026）硬件平台清单里，**ESP32-S3-EYE 属于"已支持开发板"**，开发指南指向 `vendor_espressif/blob/dev-ai-contest-2026/boards/esp32s3/esp32s3-eye/README_zh-cn.md`；而 **ESP32-P4X-Function-EV-Board** 属于"待适配"：[supported_hardware.md](https://gitee.com/open-vela/docs/blob/dev-ai-contest-2026/zh-cn/contest_2026/hardware_porting/supported_hardware.md)。
- **openvela 的 ESP32-S3 移植文档只写 Wi-Fi，没写蓝牙**：教程标题即《在 ESP32-S3-EYE 开发板上移植 openvela 并启用 Wi-Fi 功能》，全文围绕 `CONFIG_ESP32S3_WIFI`/`CONFIG_WIRELESS_WAPI`，**没有 BLE/蓝牙章节**；烧录用 `make -j$(nproc) flash ESPTOOL_PORT=... ESPTOOL_BINDIR=./`，工具链用 `xtensa-esp32s3-elf-12.2.0_20230208`、`pip install esptool`：[ESP32-S3-EYE.md](https://gitee.com/open-vela/docs/blob/trunk-5.2/zh-cn/quickstart/development_board/ESP32-S3-EYE.md)。

### 2.3 openvela 的蓝牙框架（是"上层框架"，不是 ESP32-S3 专用）

- 官方《蓝牙概述》写明：openvela 蓝牙已通过 **Bluetooth 5.4 认证**，支持 BR/EDR/BLE、GAP、L2CAP、GATT Client/Server、A2DP、HFP、LEA、Mesh 等；架构为 **Android Native 风格 Framework API + Service 组件 + SAL 协议栈适配层 + HAL**，可接入 **Zephyr、Bluez、Bluedroid、Barrot** 等多种协议栈；驱动模型就是 NuttX 的 `struct bt_driver_s`（`open/send/ioctl/close`）+ `bt_driver_register()`，以 BTH4 为例：[Bluetooth_Overview.md](https://gitee.com/open-vela/docs/blob/trunk-5.2/zh-cn/device_dev_guide/connection/bluetooth/Bluetooth_Overview.md)。
- 相关仓库：`open-vela/frameworks_bluetooth`（API/Service/SAL/HAL，含 `bttool`）→ <https://github.com/open-vela/frameworks_bluetooth>（GitHub，本环境未打开正文，标题/描述来自搜索结果）；`external_zblue`（源自 Zephyr 社区、openvela 增强的协议栈）、`external_fluoride`（Bluedroid）在 openvela 仓库清单中确实存在（见 [openvela 仓库列表（GitCode 组织 API）](https://api.gitcode.com/api/v5/orgs/open-vela/repos?per_page=100&page=2) 中的 `external_zblue`、`external_fluoride`、`frameworks_bluetooth`）。
- 文档目录：蓝牙开发文档集中在 `zh-cn/device_dev_guide/connection/bluetooth/`（含 `how_to_add_a_bluetooth_driver.md`、`how_to_analyze_bluetooth_issues.md`、`functionality_test/`）：[目录](https://gitcode.com/open-vela/docs/tree/dev/zh-cn/device_dev_guide/connection/bluetooth)。
- 快应用（QuickApp）蓝牙 API：openvela 文档指向 `@system.bluetooth` 系列接口：<https://doc.quickapp.cn/features/system/bluetooth.html>。
- **`bluelet`：本次检索（web_search 关键词 "openvela bluelet 协议栈" 等）未查到 openvela 中以 `bluelet` 命名的组件或文档**，openvela 蓝牙相关命名是 `frameworks_bluetooth`（Framework/SAL/HAL）、`external_zblue`、`external_fluoride`、`bttool`。若你看到的 "bluelet" 出自某篇具体文档，请提供链接，我再单独核查。

### 2.4 小结（openvela + ESP32-S3 蓝牙）

**openvela 对 ESP32-S3 的支持 = 内核侧跟随上游 NuttX（含 BLE）+ 官方只适配/认证了 `esp32s3-eye` / `esp32s3-box` 两块板，且公开文档只覆盖 Wi-Fi**。蓝牙层面**没有** openvela 特有的 ESP32-S3 适配（openvela 的蓝牙 Framework/SAL 主要面向其主力蓝牙 SoC 与自家协议栈），ESP32-S3 走的是 NuttX 原生 `wireless/bluetooth` host。

---

## 3. NuttX / openvela 的 ESP32-S3 板子清单，以及最接近 N16R8 的板子

### 3.1 板子清单

**(A) openvela/nuttx `dev` 分支实测（目录 API 核实，共 8 块板 + common）**：`esp32s3-box`、`esp32s3-devkit`、`esp32s3-eye`、`esp32s3-korvo-2`、`esp32s3-lcd-ev`、`esp32s3-lhcbit`、`esp32s3-meadow`、`lckfb-szpi-esp32s3`（另有 `common`）。
来源：[boards/xtensa/esp32s3 目录 API](https://api.gitcode.com/api/v5/repos/open-vela/nuttx/contents/boards/xtensa/esp32s3?ref=dev) ／ 网页视图 <https://gitcode.com/open-vela/nuttx/tree/dev/boards/xtensa/esp32s3>。

**(B) NuttX 官方文档（latest）"Supported Boards" 列表（11 个页面）**：ESP32S3-8048S043、ESP32S3-DevKit、ESP32-S3-EYE、ESP32-S3-Korvo-2 V3.0、ESP32-S3-LCD-EV、esp32s3-lhcbit、M5Stack Cardputer、esp32s3-touch-lcd7、ESP32S3-WS-LCD128、Seeed Studio XIAO ESP32S3、LCKFB SZPI ESP32-S3。
来源：[ESP32-S3 文档索引页](https://nuttx.apache.org/docs/latest/platforms/xtensa/esp32s3/index.html)。

> 说明：两处清单不完全一致（openvela 是 fork 快照；官方文档列表也未覆盖所有目录，例如 `esp32s3-box`、`esp32s3-meadow` 未出现在文档列表里）。若你要"上游 master 的完整目录名"，需要能访问 GitHub/Gitea 的环境再核对一次（本环境 GitHub 不可达、nuttx-forge 镜像被 Cloudflare 拦截）。

### 3.2 最接近"通用 ESP32-S3 DevKitC / N16R8 核心板"的板子：`esp32s3-devkit`

官方文档对这块板的描述就是 **ESP32-S3-DevKitC-1 + ESP32-S3-WROOM-1 模组**（含 USB-UART、BOOT/EN 按键、按型号不同容量的 SPI Flash、WS2812 在 GPIO48 或 v1.1 的 GPIO38）：
- [ESP32S3-DevKit 板级文档](https://nuttx.apache.org/docs/latest/platforms/xtensa/esp32s3/boards/esp32s3-devkit/index.html)
- 文档的烧录示例明确写 "the `nsh` defconfig for the **ESP32-S3-DevKitC-1** board"。

其 `configs/` 下共有 40+ 个配置，与本次相关的是 `nsh`、`wifi`、`ble`、`blewifi`、`psram_octal`、`psram_quad`、`mcuboot_nsh`、`sta_softap`、`knsh`、`usbnsh`、`qemu_debug` 等（目录 API：<https://api.gitcode.com/api/v5/repos/open-vela/nuttx/contents/boards/xtensa/esp32s3/esp32s3-devkit/configs?ref=dev>）。

**关键 defconfig 对比（均实测原文）**

| 配置 | 关键内容 | 链接 |
|---|---|---|
| `nsh` | 只有串口 NSH，`ARCH_CHIP_ESP32S3WROOM1N4`，无无线 | [nsh/defconfig](https://gitcode.com/open-vela/nuttx/blob/dev/boards/xtensa/esp32s3/esp32s3-devkit/configs/nsh/defconfig) |
| `wifi` | `ESP32S3_WIFI=y` + `WIRELESS_WAPI=y` + `SMP=y/SMP_NCPUS=2` + iperf/dhcpc，**无 BLE** | [wifi/defconfig](https://gitcode.com/open-vela/nuttx/blob/dev/boards/xtensa/esp32s3/esp32s3-devkit/configs/wifi/defconfig) |
| `ble` | `ESP32S3_BLE=y` + `WIRELESS_BLUETOOTH=y` + `NET_BLUETOOTH=y` + `DRIVERS_BLUETOOTH=y` + `BTSAK=y`，**无 Wi-Fi** | [ble/defconfig](https://gitcode.com/open-vela/nuttx/blob/dev/boards/xtensa/esp32s3/esp32s3-devkit/configs/ble/defconfig) |
| `blewifi` | `BLE` + `WIFI`（`ESP32S3_WIFI_STATION_SOFTAP`）+ 共存 + `BTSAK`（栈 8192）+ dhcpd/iperf/ping，`BLUETOOTH_TXCMD/TXCONN_PRIORITY=120/119` | [blewifi/defconfig](https://gitcode.com/open-vela/nuttx/blob/dev/boards/xtensa/esp32s3/esp32s3-devkit/configs/blewifi/defconfig) |
| `psram_octal` | `ESP32S3_SPIRAM=y` + `ESP32S3_SPIRAM_MODE_OCT=y` + `FLASH_FREQ_80M` + `MM_REGIONS=2`（**注意：它的芯片选项仍是 WROOM1N4**，PSRAM 是手工打开的） | [psram_octal/defconfig](https://gitcode.com/open-vela/nuttx/blob/dev/boards/xtensa/esp32s3/esp32s3-devkit/configs/psram_octal/defconfig) |

**给 ESP32-S3-N16R8 的适配建议（基于以上 Kconfig 事实）**

1. 芯片选择改成 `CONFIG_ARCH_CHIP_ESP32S3WROOM1N16R8=y`（Kconfig 帮助文本："16MB SPI Flash (quad) and 8MB PSRAM (octal)"，会自动 `select ESP32S3_FLASH_16M` 与 `ESP32S3_PSRAM_8M`）。
2. 想用 8MB OPI PSRAM 作堆：参照 `psram_octal` 加 `CONFIG_ESP32S3_SPIRAM=y`、`CONFIG_ESP32S3_SPIRAM_MODE_OCT=y`、`MM_REGIONS=2`（`SPIRAM_BOOT_INIT` 默认 y）。
3. 先跑 `nsh` 验证启动/串口，再叠加 `ble`（或 `blewifi`）配置；**不要一开始就 BLE+Wi-Fi+PSRAM 全开**（共存 + SMP + PSRAM 版本叠加最容易踩坑）。
4. 16MB Flash 的注意点：官方文档在 `toywasm` 配置里明确提示 *"To use flash larger than 4MB, you need to install a custom bootloader"*（并给了 `mkfsimg` + 指定 `0x180000` 写文件系统的例子），说明大 Flash 与自定义分区/引导相关，别默认"16MB 自动可用"。

---

## 4. Radxa A7Z 是什么，以及 Radxa/Rockchip 在 openvela 中的支持现状

### 4.1 产品确认：**存在，型号全名 Radxa Cubie A7Z**

- 官方产品页：[Radxa Cubie A7Z（radxa.com）](https://radxa.com/products/cubie/a7z/)；官方文档：[Radxa Cubie A7Z | Radxa Docs](https://docs.radxa.com/en/cubie/a7z)（中文：[docs.radxa.com/cubie/a7z](https://docs.radxa.com/cubie/a7z)）；产品简介 PDF：[radxa_cubie_a7z_product_brief.pdf](https://dl.radxa.com/cubie/a7z/docs/radxa_cubie_a7z_product_brief.pdf)。
- **SoC：Allwinner A733（全志，不是瑞芯微）** —— 2×Cortex-A76 + 6×Cortex-A55，最高 2.0GHz；GPU：Imagination PowerVR BXM-4-64 MC1（OpenGL ES 3.2 / Vulkan 1.3 / OpenCL 3.0）；NPU：**3 TOPS@INT8**（Vivante VIP9000，支持 INT8/INT16/FP16/BF16）。
- 内存/存储：LPDDR4/4x **1GB/2GB/4GB/8GB/16GB** 可选；板载 UFS 3.0 可选（文档写 up to 1TB，产品页写 up to 512GB，两处口径不同）+ microSD。
- 无线：**Wi-Fi 6 + Bluetooth 5.4（含 BLE）**，外置天线。
- 接口：Micro HDMI（4Kp60）、USB-C 3.1（DP Alt）、USB-C 2.0 OTG、4-lane MIPI CSI、**PCIe 3.0 x1 FPC**、40-pin GPIO（UART/I2C/SPI/PWM）、3-pin 风扇座；尺寸 **65 × 30 mm**；供电 USB-C 5V。
- **系统支持：Debian Linux、Android 13（文档另列 Buildroot、Tina Linux）**。也就是说：**A7Z 是跑 Linux/Android 的"主控板"，不是 openvela 设备**。
- 相近型号（便于你确认手上的板子）：Cubie 系列 [Cubie A7A](https://docs.radxa.com/en/cubie/a7a)、[Cubie A7S](https://docs.radxa.com/en/cubie/a7s)、[Cubie A5E](https://docs.radxa.com/en/cubie/a5e)（[Cubie 系列总览](https://docs.radxa.com/en/cubie)）；以及 [ZERO 3W/3E](https://docs.radxa.com/en/zero/zero3)、ROCK 5 系列等。**注意：Cubie A7A/A7S/A7Z 都是全志 A733 家族，ROCK/Zero 系列才是 Rockchip**，两族完全不同的 SoC 与 BSP。

### 4.2 Radxa 是否支持 openvela？

**未查到。** radxa.com / docs.radxa.com 的产品与系统列表中没有 openvela/Vela OS；openvela 侧的官方开发板列表（ST、乐鑫、恒玄、QEMU…）里也没有 Radxa：
- [openvela 开发板支持列表](https://gitee.com/open-vela/docs/blob/trunk-5.2/zh-cn/dev_board/Development_Board.md)（截至本报告抓取，**无 Radxa**）
- [openvela 2026 大赛硬件平台清单](https://gitee.com/open-vela/docs/blob/dev-ai-contest-2026/zh-cn/contest_2026/hardware_porting/supported_hardware.md)（**无 Radxa**）

### 4.3 openvela 的 Rockchip（瑞芯微）支持现状

- 仓库确实存在：<https://gitee.com/open-vela/vendor_rockchip>，描述为 *"Rockchip chip vendor support for openvela"*，但**基本是空壳**——只有 `dev`/`dev-ai-contest-2026`/`trunk` 三个分支、**4 次提交**，仓库根目录只看到 `.gitee`、`.github` 脚手架文件（本环境抓取到的内容如此，不排除分支内有更多内容）。
- 官方的 Rockchip 板卡动作是"**待适配**"：大赛清单里 **KICKPI-K7（RK3576）** 属于"待适配开发板"，标注 *"上游目标仓（获奖后 PR）：`vendor_rockchip`（`dev-ai-contest-2026` 分支，`boards/` 目录）"*，说明 Rockchip 适配是"刚起步/交给大赛选手做"的状态。另有第三方文章《Openvela+ 瑞芯微+DeepSeek 桌面机器人实战评测》（[CSDN](https://blog.csdn.net/interpromotion/article/details/160658280)）可佐证生态里有人在折腾 openvela+RK，但**非官方支持**。
- openvela 的**全志**支持是另一条线：`vendor_allwinnertech` 支持的是 **R528（Cortex-A7 + HiFi4 DSP）** 板卡（[润芯微 Gemini-S1](https://gitee.com/open-vela/docs/blob/dev-ai-contest-2026/zh-cn/contest_2026/hardware_porting/supported_hardware.md)、百问网 DShanPixVela-Devkit），**与 A733 完全不是同一代/同一类芯片**，不能指望直接复用。
- 上游 Linux 对 A733 的支持仍在推进中（例：`pmdomain: sunxi: Add support for A733 to Allwinner PCK600 driver` 的 LKML 补丁讨论，[LKML 链接](https://lkml.iu.edu/hypermail/linux/kernel/2603.1/13075.html)），这也侧面说明 A7Z 目前的主战场是厂商 BSP（Debian/Android），不是 RTOS 生态。

**因此对原方案的建议**：把 A7Z 当 **BLE 主机（Central）** 用 **Debian + BlueZ**（可用 `bluetoothctl`/D-Bus/`bleak` 等）与 ESP32-S3 通信是合理路线；**"A7Z 上跑 openvela"目前缺乏任何官方支持证据**，若必须全 openvela，主控应换成 openvela 已支持板卡（ST STM32H750B-DK、全志 R528 系、BES、思澈等）。

---

## 5. ESP32-S3 与 NuttX 的烧录 / 刷机方式

### 5.1 用 esptool.py，不是 esptool-js

- NuttX 的 `tools/esp32s3/Config.mk` 里，`MKIMAGE` 与 `FLASH` 规则全部调用 **`esptool.py`**：
  - `ESPTOOL_MIN_VERSION := 4.8.0`，并通过 `python3 tools/espressif/check_esptool.py -v $(ESPTOOL_MIN_VERSION)` 校验版本；
  - 生成镜像：`esptool.py -c esp32s3 elf2image ... -o nuttx.bin nuttx`；
  - 烧录：`esptool.py -c esp32s3 -p $(ESPTOOL_PORT) -b $(ESPTOOL_BAUD) write_flash $(ESPTOOL_WRITEFLASH_OPTS) $(ESPTOOL_BINS)`，`ESPTOOL_BAUD ?= 921600`；
  - 另有 `merge_bin` 生成 `nuttx.merged.bin`（QEMU 用）。
  原文：[tools/esp32s3/Config.mk](https://gitcode.com/open-vela/nuttx/blob/dev/tools/esp32s3/Config.mk)
- 官方文档：`pip install esptool>=4.8.1`，`make flash ESPTOOL_PORT=<port> ESPTOOL_BINDIR=./`，建议首次使用先 `esptool.py erase_flash`；也支持 `UF2=1` 生成 UF2，用 [ESP USB Bridge](https://github.com/espressif/esp-usb-bridge) 拖拽烧录：[ESP32-S3 平台文档](https://nuttx.apache.org/docs/latest/platforms/xtensa/esp32s3/index.html)。
- **esptool-js 是什么**：Espressif 官方的 **JavaScript/WASM 版 esptool**，面向浏览器 WebSerial（网页烧录器场景），文档在 <https://espressif.github.io/esptool-js/docs/>。**NuttX 的 Kconfig/Makefile 体系不使用它**；它只在你做"网页版烧录工具"或自定义 Web 工具链时才有意义。
- openvela 侧流程（官方 ESP32-S3-EYE 教程）：`pip install esptool`（建议 venv）→ `./build.sh vendor/espressif/boards/esp32s3/esp32s3-eye/configs/openvela/ -j8` → `cd nuttx && make -j$(nproc) flash ESPTOOL_PORT=/dev/ttyACM0 ESPTOOL_BINDIR=./`：[ESP32-S3-EYE.md](https://gitee.com/open-vela/docs/blob/trunk-5.2/zh-cn/quickstart/development_board/ESP32-S3-EYE.md)。

### 5.2 `tools/esp32s3/mcuboot_toolchain_esp32s3.cmake` 是干嘛的

它是一个 **CMake toolchain 文件（交叉编译描述）**，用来把 **MCUboot 引导程序本体**编译成 ESP32-S3 目标：

```cmake
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_C_COMPILER xtensa-esp32s3-elf-gcc)
set(CMAKE_CXX_COMPILER xtensa-esp32s3-elf-g++)
set(CMAKE_ASM_COMPILER xtensa-esp32s3-elf-gcc)
set(_CMAKE_TOOLCHAIN_PREFIX xtensa-esp32s3-elf-)
set(CMAKE_C_FLAGS "-mlongcalls" ...)
```
原文：[mcuboot_toolchain_esp32s3.cmake](https://gitcode.com/open-vela/nuttx/blob/dev/tools/esp32s3/mcuboot_toolchain_esp32s3.cmake)

它的使用者在 `arch/xtensa/src/esp32s3/Bootloader.mk`：

```
MCUBOOT_TOOLCHAIN  = $(TOPDIR)/tools/esp32s3/mcuboot_toolchain_esp32s3.cmake
...
$(TOOLSDIR)/build_mcuboot.sh -c esp32s3 -f $(BOOTLOADER_CONFIG) -p $(BOOTLOADER_DIR) -e $(HALDIR) -d $(MCUBOOT_TOOLCHAIN)
```

即：`make bootloader` 会 `git clone` [mcu-tools/mcuboot](https://github.com/mcu-tools/mcuboot)（`CONFIG_ESP32S3_MCUBOOT_VERSION` 指定提交），用这个 CMake toolchain + Espressif HAL 目录（`esp-hal-3rdparty`）+ 生成的 `bootloader.conf` 编译出 **`mcuboot-esp32s3.bin`**。原文：[Bootloader.mk](https://gitcode.com/open-vela/nuttx/blob/dev/arch/xtensa/src/esp32s3/Bootloader.mk)。**注意：这不是"给你的应用做签名/烧录"的工具，而是"把 MCUboot 引导器交叉编译出来"的工具链描述**；给应用签名用的是 Python 的 `imgtool`。

### 5.3 要不要 bootloader？烧到 0x0 还是 0x10000？

NuttX/ESP32-S3 有**三种镜像格式**，由 Kconfig 选择（见 [esp32s3/Kconfig](https://gitcode.com/open-vela/nuttx/blob/dev/arch/xtensa/src/esp32s3/Kconfig) 与 [tools/esp32s3/Config.mk](https://gitcode.com/open-vela/nuttx/blob/dev/tools/esp32s3/Config.mk)）：

| 模式 | 选择方式 | 是否需要额外 2nd-stage bootloader | 烧录地址 |
|---|---|---|---|
| **Simple Boot（默认）** | `CONFIG_ESPRESSIF_SIMPLE_BOOT=y`（无 MCUboot/legacy 时默认 y） | **不需要**（启动所需功能都编进 NuttX；2nd bootloader 被忽略） | `nuttx.bin` → **0x0000**（`APP_OFFSET := 0x0000`；官方文档示例日志亦为 `write_flash ... 0x0000 nuttx.bin`） |
| **Legacy（ESP-IDF 2nd bootloader 格式）** | `CONFIG_ESP32S3_APP_FORMAT_LEGACY=y` | **需要**：`make bootloader` 生成 `bootloader-esp32s3.bin` + `partition-table-esp32s3.bin` | bootloader → **0x0**；分区表 → **0x8000**（`ESP32S3_PARTITION_TABLE_OFFSET` 默认 0x8000）；应用 → **0x10000**（`ESP32S3_KERNEL_OFFSET` 默认 0x10000） |
| **MCUboot / OTA** | `CONFIG_ESP32S3_APP_FORMAT_MCUBOOT=y`（会自动开 `ESP32S3_HAVE_OTA_PARTITION`） | **需要**：`make bootloader` 生成 `mcuboot-esp32s3.bin`；应用用 `imgtool sign` 签名（`pip install imgtool`） | MCUboot → **0x0**；应用 → `CONFIG_ESP32S3_OTA_PRIMARY_SLOT_OFFSET`（openvela dev 分支 esp32s3 Kconfig **默认 0x10000**；NuttX 较新文档的 MCUBoot 布局示例改为 `ESPRESSIF_OTA_PRIMARY_SLOT_OFFSET` 默认 **0x20000**，并预留 E-Fuse Virtual 分区——见下方链接）；secondary slot 默认 0x110000、scratch 默认 0x210000 |

- 用法示例（官方文档）：`make bootloader` 把 bootloader/分区表放到 `nuttx/` 目录，然后 `make flash ESPTOOL_PORT=<port> ESPTOOL_BINDIR=./`（`ESPTOOL_BINDIR` 就是"外部 bootloader 与分区表所在目录"）。
- MCUboot 的 Flash 布局与 OTA 说明：[ESP32-S3 文档 · MCUBoot and OTA Update / Flash Allocation for MCUBoot](https://nuttx.apache.org/docs/latest/platforms/xtensa/esp32s3/index.html)；`mcuboot_nsh` 配置在 [esp32s3-devkit/configs](https://api.gitcode.com/api/v5/repos/open-vela/nuttx/contents/boards/xtensa/esp32s3/esp32s3-devkit/configs?ref=dev) 中确实存在。
- 什么时候必须上 bootloader/MCUboot：需要 **OTA/双槽回滚**、**Flash 加密**、**自定义分区表**（以及文档提到的**大容量 Flash**场景）时；只做"跑起来 + 蓝牙收命令点灯"，**Simple Boot 直接烧 0x0 最省事**。
- 依赖提醒：`make bootloader` 需要**联网 git clone**（`espressif/esp-nuttx-bootloader` 或 `mcu-tools/mcuboot`）并初始化 `esp-hal-3rdparty` 子模块。
- openvela 侧还提供 `tools/esp32s3/Config.mk` 与 `arch/xtensa/src/esp32s3/Bootloader.mk`（同上游），因此 `make bootloader` / `make flash` 用法一致。

---

## 6. 关键风险与结论

### 6.1 最大技术风险（按严重程度排序）

1. **主控板选型与技术路线不匹配（最大风险）**：Radxa Cubie A7Z 是 **Allwinner A733 的 Linux/Android 板**，**没有任何 openvela 官方支持**（openvela 全志侧是 R528；Rockchip 侧 `vendor_rockchip` 只是空壳仓库，RK3576 板卡在官方口径里都是"待适配"）。如果方案默认"主控跑 openvela + 下位机跑 openvela/NuttX"，**这条链路目前没有可复用的官方支持**。建议：A7Z 侧用 **Debian + BlueZ** 做 BLE Central；下位机 ESP32-S3 用 openvela/NuttX 做 BLE Peripheral。
2. **NuttX 侧"BLE 外设（GATT server）"缺应用层 API**：NuttX host 只有 **GATT client + 广播/扫描/安全** 的 ioctl（`btsak` 全套命令都是 client 侧），**GATT server 只有内核 C API `bt_gatt_register()`**，没有 NSH 命令/IOCTL。这意味着"电灯开关"作为可被手机/主控写特征值的外设，**必须自己写内建应用/驱动代码**（FLAT 构建下可直接调用），不能靠现成命令拼出来。这是本项目最容易被低估的工作量。
3. **控制器是 Espressif 二进制实现 + Wi-Fi/BT 共存 + 内存/IRAM 紧张**：BLE 与 Wi-Fi 同开必须走 `ESP32S3_WIFI_BT_COEXIST`（`blewifi` 配置就是为此存在）；控制器任务栈（默认 4096）、优先级 253、中断现场保存深度等参数在 ESP32-S3 上都需要实测调优；再叠加 PSRAM/SMP 后，**栈、IRAM、PSRAM 配置的组合问题**是最常见的"跑一会儿就崩"来源。
4. **N16R8 不是"拿来即用"的默认配置**：所有 esp32s3-devkit defconfig 默认都是 `ARCH_CHIP_ESP32S3WROOM1N4`；N16R8 需要改 `ARCH_CHIP_ESP32S3WROOM1N16R8`，OPI PSRAM 需要参照 `psram_octal`（`SPIRAM` + `SPIRAM_MODE_OCT` + `MM_REGIONS=2`），大 Flash 还有"自定义 bootloader/分区"的官方提示。
5. **openvela 对 ESP32-S3 的"官方适配面"很窄**：只认证/适配 `esp32s3-eye`、`esp32s3-box`，文档只有 Wi-Fi 教程，**没有 ESP32-S3 蓝牙教程**；openvela 的蓝牙 Framework/SAL（frameworks_bluetooth、zblue）与 NuttX 原生 host 是两套东西，**不要假设 openvela 的蓝牙 API 能直接驱动 ESP32-S3**（ESP32-S3 走的是 NuttX `bt_driver` + `wireless/bluetooth`）。
6. **蓝牙协议/体验层风险**：NuttX host 的 `BLUETOOTH_MAX_CONN` 默认 1、配对/绑定管理能力有限；与手机（iOS/Android）或 Linux BlueZ 的配对、重连、MTU、断线恢复都需要你自己兜底测试。若对 BLE 外设体验要求高，可评估在 ESP32-S3 上用 **NimBLE host**（NuttX 文档有 nimble 应用）或走 openvela 的 zblue 路线，但这都属于"换栈"，需要额外验证。
7. **工具链/网络风险**：必须使用匹配的 `xtensa-esp32s3-elf-gcc`（NuttX CI 用 14.2.0；openvela ESP32-S3 教程用 12.2.0_20230208，**两者不同，建议以你项目的构建脚本为准**）；`esptool.py ≥ 4.8.0`、`imgtool`、`make bootloader` 需要联网 clone；GitHub 在受限网络下不可达会影响拉取子模块。

### 6.2 结论与建议实施顺序

1. **先证明"能跑"**：`esp32s3-devkit:nsh`（改芯片为 N16R8）→ 串口 NSH 正常；再加 `psram_octal` 验证 8MB OPI PSRAM。
2. **再证明"BLE 能起来"**：启用 `ESP32S3_BLE` + `WIRELESS_BLUETOOTH` + `DRIVERS_BLUETOOTH` + `NET_BLUETOOTH` + `BTSAK`（等价于 `esp32s3-devkit:ble`），用手机 nRF Connect / BlueZ 扫描确认可被发现、可广播（`bt <ifname> advertise start`、`info`、`features le`）。
3. **打通"控制电灯"**：写一个内建应用，调用 `bt_gatt_register()` 注册自定义服务（例如一个可写特征值 + `bt_gatt_notify()` 上报状态），写 GPIO 控制继电器/LED；主控 A7Z 侧用 BlueZ（Python `bleak`/`dbus`）做 Central 写入特征值。
4. **性能/稳定性加固**：需要 Wi-Fi 与 BLE 并存时切到 `blewifi` 并调 COEXIST 与任务栈；需要 OTA/加密时再切 MCUboot（`make bootloader` + `imgtool`）。
5. **如果一定要"全 openvela 方案"**：把主控换成 openvela 已支持板卡（ST STM32H750B-DK / 全志 R528 系 / BES / 思澈等，见[开发板支持列表](https://gitee.com/open-vela/docs/blob/trunk-5.2/zh-cn/dev_board/Development_Board.md)）；否则 A7Z 保留 Debian + BlueZ 是当前唯一有充分文档支撑的路径。

### 6.3 明确"未查到 / 未核实"清单（避免误用）

- `openvela` 中名为 **bluelet** 的蓝牙组件/文档：**未查到**。
- openvela / NuttX 中 **ESP32-S3 仅控制器（controller-only）+ 外部 host 接管** 的官方说明或示例：**未查到**。
- **Radxa 任何产品对 openvela/Vela 的官方支持**：**未查到**。
- openvela 中 **Allwinner A733（Cubie A7Z 的 SoC）** 支持：**未查到**（openvela 全志支持为 R528）。
- GitHub 正文（PR #10200、issue #9507/#12685、`open-vela/frameworks_bluetooth`）：因本机 **github.com 不可达**，仅依据搜索引擎返回的标题/描述，**正文未核实**。
- 上游 `apache/nuttx` master 的 `boards/xtensa/esp32s3` **完整目录名**：未能访问 GitHub/Gitea 镜像核对，本报告使用"openvela dev 分支（API 实测）+ NuttX 官方文档列表"两组数据，二者不完全一致（见 3.1 说明）。
