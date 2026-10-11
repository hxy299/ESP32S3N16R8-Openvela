> **当前状态（2026-10-11）**：**远程点灯已实现**（WiFi/TCP 版）。
>
> 🎉 `nsh> btsh_lightd &` 启动后，从电脑/手机 TCP 发 `ON` / `OFF`
> 即可控制板子上的灯 —— 已实测验证。
>
> 详见 [阶段五文档](docs/stages/stage-05-tcp-remote-light.md)。
>
> ⚠️ BLE 路线**未走通**（openvela/NuttX 在 ESP32-S3 上的 BLE host 栈
> 收不到 ACL 数据）。已用 ESP-IDF 对照实验证明**硬件完全正常**，
> 问题在 NuttX 侧。完整分析见
> [阶段四结论](docs/stages/stage-04-FINAL-nimble-not-viable.md) 与
> [HANDOFF-CURRENT-ISSUE.md](HANDOFF-CURRENT-ISSUE.md)。

---

# Openvela ESP32-S3 Bluetooth SmartHome

> 用 **openvela（Apache NuttX）** 系统，把下位机 **ESP32-S3-N16R8** 开发板改造成一块可由
> **Radxa A7Z 主控板通过蓝牙（BLE）远程操控**的智能家居从节点。第一阶段目标：**远程控制电灯**。

- 项目名：`Openvela-ESP32S3-Buletooth-SmartHome`
- 文件夹简称：`OpenvelaESP-BTSH`
- 目标硬件：ESP32-S3-N16R8（16 MB Flash + 8 MB **Octal** PSRAM，CH340 + 原生 USB-OTG 双 Type-C）
- 上位机：Radxa A7Z（已完成 openvela 适配）
- 系统：openvela（基于 Apache NuttX）
- 下位机开发环境：WSL2 Ubuntu 22.04，`~/openvela`
- 文档语言：中文

---

## 📦 交接文档（接手请先读这里）

本项目已整理为**可交接、可复现**的完整包。四份交接文档：

| 文档 | 内容 |
| --- | --- |
| **[HANDOFF-AI-ONBOARDING.md](HANDOFF-AI-ONBOARDING.md)** | **项目总览** —— 是什么、做到哪、踩过哪些坑、下一步该干什么 |
| **[HANDOFF-CURRENT-ISSUE.md](HANDOFF-CURRENT-ISSUE.md)** | **当前唯一阻塞问题的完整记录** —— GATT 服务发现失败，含 5 个待验证假设 |
| **[HANDOFF-REPRODUCE.md](HANDOFF-REPRODUCE.md)** | **从零复现指南** —— 精确版本清单、完整步骤、错误速查 |
| **[HANDOFF-INVENTORY.md](HANDOFF-INVENTORY.md)** | **文件清单与阅读顺序** |
| **[HANDOFF-SCRIPTS-RUNBOOK.md](HANDOFF-SCRIPTS-RUNBOOK.md)** | **脚本手册与运维指南** —— 11 个脚本各自解决什么坑、执行顺序、故障速查、危险操作清单 |

### 一句话进度

> ✅ **无线部分全部打通**（PSRAM 8MB / BLE / WiFi / WiFi+BLE 共存 / WS2812 状态灯 / GATT 服务注册 / BLE 连接建立）
> ❌ **卡在 GATT 服务发现**（连接成功，但 ATT 层无交互，中央设备超时）

---

## 1. 项目定位

```
┌──────────────────────────┐        BLE (GATT)        ┌────────────────────────┐
│   Radxa A7Z 主控板        │  ──────────────────────▶ │  ESP32-S3-N16R8 下位机  │
│   （已适配 openvela）      │  ◀────────────────────── │  （本项目适配目标）      │
│   角色：BLE Central       │      状态/属性通知         │  角色：BLE Peripheral   │
│   上位业务：智能家居网关    │                          │  执行：继电器→电灯       │
└──────────────────────────┘                          └────────────────────────┘
```

**数据流（第一阶段）**

| 方向 | 内容 | 说明 |
| --- | --- | --- |
| A7Z → ESP32-S3 | `LIGHT SET <ch> <on/off>` | 写 GATT 特征值，控制灯 |
| ESP32-S3 → A7Z | `LIGHT STATE <ch> <on/off>` | Notify 回报实际状态 |
| ESP32-S3 → A7Z | 心跳 / 上电事件 | Notify |

---

## 2. 目录结构

```
OpenvelaESP-BTSH/
├── README.md              项目总览（本文件）
├── LICENSE                开源协议
├── .gitignore             Git 忽略规则
│
├── docs/                  文档中心
│   ├── README.md
│   ├── stages/            ★ 分阶段开发记录（版本管理主索引）
│   ├── hardware/          硬件资料整理：引脚、原理图、注意事项
│   ├── protocol/          蓝牙 GATT 协议定义（与 A7Z 对接的接口契约）
│   └── bringup/           板级适配（board port）技术笔记
│
├── src/                   本项目自有源码
│   ├── README.md
│   ├── app/               业务应用：智能家居灯控、命令解析
│   ├── protocol/          BLE GATT 服务/特征实现、报文编解码
│   └── platform/          平台抽象层（GPIO/继电器/RGB 封装）
│
├── tests/                 测试
│   ├── README.md
│   ├── unit/              主机端单元测试（协议编解码等）
│   ├── integration/       跨模块集成测试
│   └── hardware/          实机测试用例与记录（含 A7Z 联调）
│
├── config/                板级/系统配置
│   ├── README.md
│   ├── boards/            板级定义：引脚映射、dts、板级说明
│   ├── defconfig/         NuttX defconfig 快照与差异说明
│   └── kconfig/           自定义 Kconfig 片段
│
├── scripts/               自动化脚本
│   ├── README.md
│   ├── setup/             环境准备（工具链、esptool、串口权限）
│   ├── build/             编译脚本
│   ├── flash/             烧录脚本
│   └── debug/             调试脚本（串口监视、GDB）
│
├── assets/                静态资源
│   ├── README.md
│   ├── images/            实拍图、界面截图
│   ├── diagrams/          架构图、流程图（源文件）
│   └── reference/         原厂参考资料（数据手册、商家资料页存档）
│
├── hardware/              硬件工程文件（原理图、PCB、接线图）
├── thirdparty/            第三方代码引入说明与补丁（openvela/nuttx 改动 patch）
├── tools/                 辅助小工具
└── .github/workflows/     CI（后续接入）
```

---

## 3. 关键硬件事实（来自**原理图**，权威）

> 原理图从 `参考/www_xinlucity.pdf` 内嵌图片提取，完整解读见
> [`docs/hardware/schematic-notes.md`](docs/hardware/schematic-notes.md)。

| 项目 | 值 | 备注 |
| --- | --- | --- |
| 模组 | **ESP32-S3-WROOM-1 N16R8** | 16 MB Flash + 8 MB PSRAM（**OPI/Octal**） |
| USB 转串口 | **CH340C**（U2） | 接 USB-ISP Type-C，**自动下载电路**（SS8050 ×2） |
| 调试串口 | UART0：**GPIO43 (TX) / GPIO44 (RX)** | 115200 8N1；板载 TX/RX 指示灯 |
| 原生 USB | **GPIO19 (D−) / GPIO20 (D+)**（USB-OTG Type-C） | **未接 CH340**，需短接 OTG 焊盘 |
| 板载 RGB | **WS2812B @ GPIO48** | 5 V 供电；WS2812 焊盘出厂已短接 |
| 电源指示灯 | 接 **5V 轨**（不可控） | |
| 5V 轨 | **U12 = 南麟 LN2220** 升压 | 5V-IN 默认不对外供电，需短接 IN-OUT 焊盘 |
| 3V3 轨 | U11（丝印 `TAR`，型号未标） | 商家称 ~1 A，**原理图无法核实** |
| 按键 | EN + **BOOT → GPIO0** | R18=10 kΩ，C9/C10=100 nF |
| **不可用引脚** | **GPIO26–GPIO32 被板载 Flash/PSRAM 占用，未引出** | 严禁当普通 IO 用 |
| GPIO3 | 经 R19(10 kΩ) 下拉，接 **J5 跳线** | ⚠️ **用途待确认，本项目不用** |
| ADC 限制 | ADC2 在 WiFi 开启时不可用，优先 ADC1 | |
| Strapping | GPIO0 / GPIO45 / GPIO46 | GPIO0 拉低进下载模式 |
| 外部串口（推荐） | **UART1：GPIO17 (TX) / GPIO18 (RX)** | ⚠️ 商家网页误标为 GPIO19/20，**已按引脚复用总图修正** |
| 板子尺寸 | 板宽 **25.400 mm**，排针跨距 **27.940 mm** | |

---

## 3.1 已确认的设计前提（用户 2026-10-10 答复）

| 项 | 决定 |
| --- | --- |
| 灯控器件 | **单路继电器模块，高电平触发**（后续可能更换，平台层做成可替换） |
| 被控负载 | **低压直流 5 V / 12 V / 24 V** —— 不涉及 220 V 强电 ✅ |
| 无线需求 | **BLE 与 WiFi 都要支持** → 采用 `blewifi` 配置 + `ESP32S3_WIFI_BT_COEXIST` |
| 开发板 | ✅ **已到手**（2026-10-10），**openvela 已实测启动到 NSH** |
| 上位机 A7Z | ✅ 用户自主移植的原生 openvela（按用户说明，不再质疑） |

---

## 3.2 实机验证状态（截至 2026-10-11）

> 全部结论均来自**实机实测**，原始日志存于 [`tests/hardware/`](tests/hardware/README.md)。

| 项 | 状态 | 证据 |
| --- | --- | --- |
| 芯片识别 | ✅ ESP32-S3 QFN56 **rev v0.2**，**WiFi + BLE**，8MB PSRAM | `esptool chip-id` |
| Flash | ✅ **16 MB**，quad，3.3V（eFuse 已烧录） | `esptool flash-id` |
| 晶振 / MAC | ✅ 40 MHz / `e0:72:a1:f2:8f:e8` | esptool |
| BLE 地址 | ✅ `e0:72:a1:f2:8f:ea` | `bt bnep0 info` |
| 烧录 | ✅ 烧到 `0x0`（Simple Boot，无 bootloader/分区表） | — |
| **启动** | ✅ **NSH 提示符 `nsh>`** | `serial-boot-log.txt` |
| **NSH 命令** | ✅ `uname`/`free`/`ps`/`ls`/`cat`/`uptime`/`help`/`ifconfig`/`wapi`/`bt` | `serial-nsh-commands.txt` |
| **8MB PSRAM** | ✅ 总内存 405,120 B → **8,792,160 B** | `serial-psram-verify.txt` |
| **BLE 控制器 + host** | ✅ `btController`/`BT_HCI_Tx` 线程；扫描到 5 个真实设备 | `serial-ble-deep.txt` |
| **BLE 广播** | ✅ Windows 扫到本板（RSSI -20，全场最强） | [HT-05](tests/hardware/HT-05-ble-advertise.md) |
| **WiFi** | ✅ `wapi scan` 扫到 5 个真实路由器 | `serial-wifi-scan.txt` |
| **WiFi + BLE 共存** | ✅ 四任务并存，互不干扰 | [HT-06](tests/hardware/HT-06-wifi-ble-coexist.md) |
| **板载 WS2812B** | ✅ `/dev/leds0` + **用户目视确认颜色渐变** | [HT-07](tests/hardware/HT-07-ws2812-statusled.md) |
| **自写 GATT 服务** | ✅ `service 0xff00 registered (8 attrs)`，广播名 `BTSH-LIGHT` 可解析 | `serial-gattlight-start.txt` |
| **BLE 连接建立** | ✅ `le_conn_complete: status 0 handle 1` | `serial-gattdebug-connect.log` |
| **GATT 服务发现** | ❌ **卡住**（连接成功但 ATT 层无交互，中央设备超时） | [HT-08](tests/hardware/HT-08-gatt-light-service.md) |

> ⚠️ 关于最后一项：**这是当前唯一的阻塞问题**，
> 完整排查记录与待验证假设见
> **[HANDOFF-CURRENT-ISSUE.md](HANDOFF-CURRENT-ISSUE.md)**。

验证细节：[`docs/stages/stage-03-peripherals.md`](docs/stages/stage-03-peripherals.md)

---

## 4. 开发环境（已探测确认）

| 项 | 现状 |
| --- | --- |
| WSL 发行版 | Ubuntu 22.04.5（WSL2，内核 6.18） |
| openvela 源码 | `~/openvela`（repo 工具管理），`nuttx` @ `5315a2b7…`，`apps` @ `52a26471…` |
| Xtensa 工具链 | `~/openvela/prebuilts/gcc/linux-x86_64/xtensa-esp32s3-elf/`（**GCC 12.2.0**） |
| esptool | v5.5.0（WSL，构建用）/ 4.8.1（Windows，烧录用） |
| **BLE 支持** | ⚠️ 需绕过 `CONFIG_ESPRESSIF_BLE` Kconfig 缺口（见 [HANDOFF-AI-ONBOARDING.md](HANDOFF-AI-ONBOARDING.md) §5.3） |
| BLE host 协议栈 | `nuttx/wireless/bluetooth/`（HCI/L2CAP/SMP/ATT/GATT 齐全） |
| 串口 | Windows **COM4**（CH340）—— **WSL 无法访问，必须从 Windows 烧录** |

环境搭建与排错全集：[`docs/bringup/wsl-esp32s3-build-notes.md`](docs/bringup/wsl-esp32s3-build-notes.md)

---

## 5. 分阶段计划与进度

| 阶段 | 名称 | 目标 | 状态 | 记录 |
| --- | --- | --- | --- | --- |
| S0 | 项目初始化 | 目录、文档、Git 仓库 | ✅ 已完成 | [stage-00](docs/stages/stage-00-project-init.md) |
| S1 | 资料基线与技术调研 | 原理图提取入库、硬件事实固化、BLE 路线调研 | ✅ 已完成 | [stage-01](docs/stages/stage-01-env-and-baseline.md) |
| S2 | 板级适配（Board Port） | 板级目录 + defconfig 裁剪 + **首次编译并启动到 NSH** | ✅ 已完成 | [stage-02](docs/stages/stage-02-board-port.md) |
| S3 | 外设与无线启用 | PSRAM / BLE / WiFi+BLE 共存 / WS2812 状态灯 | ✅ **全部完成** | [stage-03](docs/stages/stage-03-peripherals.md) |
| S4 | BLE GATT 灯控服务 | 自写 `bt_gatt_register()` 应用，A7Z 可读写 | 🚧 **服务端就绪，服务发现待攻克** | [HT-08](tests/hardware/HT-08-gatt-light-service.md) |
| S5 | 继电器接入 | GPIO 驱动单路继电器（高电平有效） | ⏳ 等用户确认引脚 | — |
| S6 | A7Z 联调 | 端到端远程点灯 + 状态回报 | ⏳ | — |
| S7 | 稳定性与发布 | 掉线重连、看门狗、压力测试、v1.0 | ⏳ | — |

**阶段记录规范**：每完成一个阶段，在 `docs/stages/` 新增 `stage-NN-<slug>.md`，
并在上表补链接。每份记录必须包含：目标 → 做了什么 → 命令与输出 → 结论 → 遗留问题 → 下一步。

---

## 6. 版本管理

- 本仓库：`git init` 于项目根目录，稍后推送 GitHub。
- **不把 openvela 源码树纳入本仓库**（体积过大）。对 openvela / NuttX 的所有改动，
  以 **patch 文件**形式存放在 [`thirdparty/`](thirdparty/README.md)，并保持可复现。
- 分支约定：`main` 稳定；`feat/*` 功能；`board/*` 板级适配。

---

## 7. 待确认问题（阻塞项）

| 编号 | 问题 | 阻塞什么 | 详情 |
| --- | --- | --- | --- |
| **P1'** | **A7Z 的准确型号与技术路线** —— 调研显示 Radxa「Cubie A7Z」是**全志 A733**（非 Rockchip），官方系统为 Debian/Android，**查不到任何 openvela 支持**；而你说主控已完成 openvela 适配。**两者矛盾，需澄清** | 上位机侧的全部实现方式 | [stage-01 §7.1](docs/stages/stage-01-env-and-baseline.md) |
| P3' | **GPIO3 / J5 跳线的用途** —— 电气关系已确认，但短接不改变电平，不像使能焊盘 | 是否可用 GPIO3 | [schematic-notes §3](docs/hardware/schematic-notes.md) |
| P9 | 继电器**具体型号**与接线（供电取自开发板还是独立电源） | `bsp_relay` 最终引脚与电气设计 | [hardware §5](docs/hardware/README.md) |
| P10 | 灯的路数、是否需要 PWM 调光 | 平台层实现方式 | — |

其余已确认项见上方 §3.1。

---

## 8. 技术风险提示

| 风险 | 等级 | 说明 |
| --- | --- | --- |
| **NuttX 没有 GATT Server 的应用层 API** | 🔴 高 | ioctl 只覆盖 client 侧；灯控服务必须**自己写应用**调用内核 C API `bt_gatt_register()`。没有现成 NSH 命令可用 —— 这是本项目最容易被低估的工作量 |
| A7Z 侧技术路线未确认 | 🔴 高 | 见 P1' |
| 无开发板，无法实机验证 | 🟡 中 | 先完成可编译、可单元测试的纯软件部分 |
| N16R8 非默认配置 | 🟡 中 | 所有 devkit defconfig 默认 WROOM1N4，需改 `ARCH_CHIP_ESP32S3WROOM1N16R8` |
| 高电平继电器上电误吸合 | 🟡 中 | 硬件加 10 kΩ 下拉 + 软件尽早驱动低电平 |
| BLE + WiFi 共存的内存压力 | 🟡 中 | 需实测控制器任务栈与 IRAM 占用 |

完整风险表见 [stage-01 §7.2](docs/stages/stage-01-env-and-baseline.md)。
