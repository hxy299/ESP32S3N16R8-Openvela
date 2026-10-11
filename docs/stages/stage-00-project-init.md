# Stage 00 — 项目初始化

- 日期：2026-10-10
- 状态：✅ 已完成（**含若干待用户确认项**）
- 关联提交：见本阶段结束时的首次 commit
- 前置阶段：无

---

## 1. 本阶段目标

1. 建立项目目录 `Openvela-ESP32S3-Buletooth-SmartHome` / 简称 `OpenvelaESP-BTSH`
2. 创建各功能子目录（docs / src / tests / config / scripts / assets 等）
3. 每个子目录提供 `README.md` 说明用途与维护要求
4. 在 `docs/` 下建立**分阶段开发记录**机制（供后续版本管理）
5. 在项目根初始化 **git 仓库**，准备后续推送 GitHub

---

## 2. 前置条件与环境

### 2.1 执行位置

| 项 | 值 |
| --- | --- |
| Windows 工作目录 | `D:\Myprogram\DeepSeekProgram\ESP32S3N16R8-One` |
| 项目目录 | `D:\Myprogram\DeepSeekProgram\ESP32S3N16R8-One\OpenvelaESP-BTSH` |
| 参考资料目录 | `D:\Myprogram\DeepSeekProgram\ESP32S3N16R8-One\参考` |

### 2.2 WSL 环境探测结果（实际执行，非推测）

执行了三个探测脚本（`_wsl_probe.sh` / `_wsl_probe2.sh` / `_wsl_probe3.sh`），结果：

| 项 | 结果 |
| --- | --- |
| WSL 发行版 | Ubuntu 22.04，WSL2，内核 `6.18.40.1-microsoft-standard-WSL2` |
| WSL 用户 | `hxy299`，HOME=`/home/hxy299` |
| openvela 源码 | ✅ `~/openvela`（`.repo` 存在，用 repo 工具管理） |
| 上游 NuttX 参考树 | ✅ `~/nuttx-upstream`（commit `cc2edca9`） |
| 其他项目 | `~/luckfox-pico`、`~/pico-sdk`、`~/picotool`（**说明用户已有多个 openvela 适配经验**） |
| 磁盘 | 1007 G，已用 48 G，剩 909 G ✅ 充足 |

### 2.3 环境缺口（**重要，阻塞后续阶段**）

| 缺口 | 影响 | 处理 |
| --- | --- | --- |
| `xtensa-esp32s3-elf-gcc` 不在 PATH | 无法编译 | 阶段 S1 加 PATH（工具链实体在 `~/openvela/prebuilts/gcc/linux-x86_64/xtensa-esp32s3-elf/`，GCC 12.2.0） |
| `kconfig-frontends` / `menuconfig` 未安装 | 无法 `make menuconfig` | 阶段 S1 `apt install` |
| `ninja` 未安装 | openvela cmake 构建可能受影响 | 阶段 S1 `apt install` |
| **WSL 中无 `/dev/ttyUSB*`、无 `usbipd`** | **无法烧录、无法看串口日志** | 阶段 S1 解决（usbipd-win 透传，或改在 Windows 侧烧录） |
| 原理图 PDF 未获取 | 无法确认排针完整引出、GPIO3 焊盘用途 | **需用户协助下载** |

---

## 3. 实际执行过程

### 3.1 研读参考资料

| 文件 | 处理结果 |
| --- | --- |
| `参考/1775875467453325.png` | 板子实物图，标注「短接 IN-OUT 焊盘 对外输出 5V」 |
| `参考/1776506140612601.png` | 板子接口标注图：USB-OTG（原生 D+/D−）与 USB-ISP（CH340）双 Type-C 口 |
| `参考/1783913303242785.pdf` | 83 页，**ESP32-S3 系列数据手册 v2.2 中文版**（PDF 字体编码部分乱码，正文主体可读） |
| `参考/www_xinlucity.pdf` | 1 页，芯路城 ESP32S3 开发板客户资料页打印稿 |

额外：用 `pypdf` 把两份 PDF 转文本，输出到项目外的 `_pdf_dump/`（**未入库**，属临时产物）。

用户补充提供了商家资料页链接：<https://www.xinlucity.com/?s=resourcedetail/index/id/61.html>，
已抓取并整理成 [`assets/reference/xinlucity-resource-61.md`](../../assets/reference/xinlucity-resource-61.md)。

**该页面提供了本项目最关键的硬件事实**：

- GPIO26–GPIO32 被板载 Flash/PSRAM 占用，未引出
- 板载 RGB = **WS2812B @ GPIO48**，需 WS2812 焊盘短接（出厂已短接）
- 调试串口 = **UART0 @ GPIO43/44**，接 CH340
- 原生 USB = **GPIO19(D−) / GPIO20(D+)**，需短接 OTG 焊盘
- 5V-IN 默认不对外供电，短接 IN-OUT 焊盘才输出
- N16R8 的 8 MB PSRAM 需选 **OPI PSRAM** 模式
- 3V3 输出最大约 1 A
- 建议外部模块用 **UART1 @ GPIO17/18**

### 3.2 探测 WSL 中的 openvela 现状

用三个 bash 脚本对 `~/openvela` 做了只读探测（**未修改任何上游文件**）。
关键发现（完整分析见 [`../bringup/README.md`](../bringup/README.md)）：

1. **ESP32-S3 芯片级支持已存在**：`arch/xtensa/src/esp32s3/` 有 131 个文件，
   `ESP32S3_WIFI`、`ESP32S3_BLE`、`ESP32S3_WIFI_BT_COEXIST`、`ESP32S3_PSRAM_8M` 等 Kconfig 齐全。
2. **BLE 适配层已存在**：`esp32s3_ble.c`(8.2 KB)、`esp32s3_ble_adapter.c`(**96 KB**)、`esp32s3_ble.h`。
3. **BLE host 协议栈齐全**：`nuttx/wireless/bluetooth/` 下有
   `bt_hcicore` / `bt_l2cap` / `bt_att` / `bt_gatt` / `bt_smp` / `bt_keys` / `bt_conn` / `bt_netdev` / `bt_ioctl`。
4. **板级支持已有 9 块 ESP32-S3 板子**，其中 `esp32s3-devkit` 最接近通用开发板，
   且其 `configs/` 下**已有 `ble` 和 `blewifi` 配置**，另有 `psram_octal`、`gpio`、`usbnsh` 等。
5. **openvela 与上游 NuttX 的 ESP32-S3 分支有实质差异**：
   - openvela 多出：ADC / I2S / LEDC(PWM) / RTC / PMU / IO expander / clockconfig / efuse
   - openvela 缺少：addrenv / MMU / cache / pms / isolation / userfault / world1_vectors

> **结论**：本项目**不需要从零实现 BLE**，风险大幅降低。核心工作变成
> ① 板级适配（让 N16R8 正确启动）；② 在 `ble` 基线上裁剪最简配置；③ 应用层 GATT 灯控服务。

### 3.3 创建项目目录与文档

创建了 22 个目录、19 份 README 与 3 份核心文档：

```
OpenvelaESP-BTSH/
├── README.md                                   项目总览
├── LICENSE                                     Apache-2.0
├── .gitignore
├── docs/
│   ├── README.md                               文档中心总览
│   ├── stages/README.md + stage-00-*.md        ★ 分阶段开发记录机制
│   ├── hardware/README.md                      硬件事实库（引脚权威来源）
│   ├── protocol/README.md                      BLE GATT 协议契约（草案）
│   └── bringup/README.md                       板级适配技术笔记 + 现状盘点
├── src/  README + app/ protocol/ platform/     各层职责说明
├── tests/ README + unit/ integration/ hardware/
├── config/ README + boards/ defconfig/ kconfig/
├── scripts/ README + setup/ build/ flash/ debug/
├── assets/ README + images/ diagrams/ reference/
│   └── reference/xinlucity-resource-61.md      商家资料页存档
├── hardware/README.md                          硬件工程文件说明
├── thirdparty/README.md                        patch 管理规范
├── tools/README.md                             辅助工具说明
└── .github/workflows/                          预留
```

### 3.4 初始化 git 仓库

见第 4 节产出物与第 5 节验证。

---

## 4. 产出物

| 类别 | 路径 |
| --- | --- |
| 项目总览 | [`../../README.md`](../../README.md) |
| 阶段记录机制 | [`README.md`](README.md)、本文件 |
| 硬件事实库 | [`../hardware/README.md`](../hardware/README.md) |
| 板级适配笔记 | [`../bringup/README.md`](../bringup/README.md) |
| 协议契约草案 | [`../protocol/README.md`](../protocol/README.md) |
| 商家资料存档 | [`../../assets/reference/xinlucity-resource-61.md`](../../assets/reference/xinlucity-resource-61.md) |
| Git 仓库 | 本项目根 `.git/` |

临时产物（**不入库**）：`../_pdf_dump/`、`_wsl_probe*.sh`（位于项目外的工作目录根）。

---

## 5. 验证方法与结果

| 验证项 | 方法 | 结果 |
| --- | --- | --- |
| 目录结构完整 | 递归列出所有子目录 | ✅ 22 个目录全部创建 |
| README 齐全 | 统计 README.md 数量 | ✅ 19 份（每个一级子目录 + 二级子目录均有） |
| git 仓库可用 | `git status` / `git log` | ✅ 见第 6 节 |
| 硬件事实与资料一致 | 交叉核对商家资料页 PDF 与网页存档 | ✅ 一致；发现资料内部 1 处矛盾（GPIO19/20 用途），已标注 |
| openvela 现状判断 | 基于实际文件列表与 Kconfig 行号，非推测 | ✅ |

**发现的资料矛盾（已记入硬件文档）**：商家资料页同时把 GPIO19/GPIO20 推荐给
UART2 和 I2C，又声明它们是原生 USB D+/D−。三者电气互斥。

---

## 6. 结论

**项目骨架、文档体系和 git 仓库已建成。**
关键技术判断：openvela 已具备 ESP32-S3 的 BLE Controller + Host + 板级基线，
本项目的主要工作量在**板级适配**与**应用层 GATT 服务**，而非蓝牙协议栈本身。

---

## 7. 遗留问题与风险

### 7.1 待用户确认（**阻塞项，已单独提问**）

| 编号 | 问题 | 为什么必须问 |
| --- | --- | --- |
| P1 | **Radxa A7Z** 具体型号确认 + 它的 openvela 适配是否已包含可用 BLE（Central 角色） | 若 A7Z 无 BLE Central 能力，整个方案要改（例如改用 WiFi/MQTT 或 A7Z 外挂蓝牙模块） |
| P2 | **灯控硬件**：继电器模块型号、通道数、有效电平、供电方式、被控灯具电压 | 决定 `bsp_relay` 的引脚、电平逻辑与安全设计；涉及强电安全 |
| P3 | **GPIO3 焊盘**的用途 | 商家资料页此项说明缺失，需原理图 |
| P4 | **原理图 PDF** 能否提供（商家资料页附件需登录） | 排针完整引出关系无法确认 |
| P5 | 调试方式：WSL 用 **usbipd 透传 CH340**，还是**在 Windows 侧烧录/看串口**？ | 决定脚本放 `scripts/flash/` 还是 Windows 侧 |
| P6 | 断线后灯的策略：**保持**还是**关闭**？ | 安全策略，取决于用途 |
| P7 | 是否需要本地物理按键控制（板载 BOOT 键 GPIO0） | 影响应用层设计 |
| P8 | 是否要**调光**（PWM）还是仅**开关** | 若调光，需改用 LEDC/PWM 而非 GPIO 通断 |

### 7.2 技术风险

| 风险 | 等级 | 说明与对策 |
| --- | --- | --- |
| A7Z 侧 BLE Central 能力未验证 | 🔴 高 | 见 P1，**这是项目可行性的前提** |
| ESP32-S3 在 NuttX 下的**烧录偏移量/引导方式**未查证 | 🟡 中 | 阶段 S1 查 `nuttx/Documentation/platforms/xtensa/esp32s3` + 实机验证；**不靠猜** |
| `esp32s3-devkit` 板级与本板引脚不完全一致 | 🟡 中 | 阶段 S2 逐项比对，可能需要新建板级目录 |
| N16R8 的 OPI PSRAM 配置错误会导致启动失败 | 🟡 中 | 参考 `psram_octal` defconfig |
| WSL 蓝牙不可用（影响 PC 侧临时 BLE 客户端工具） | 🟢 低 | 该工具可改在 Windows 侧运行 |
| openvela 分支缺少上游 MMU 相关代码 | 🟢 低 | 不直接移植上游文件，以 openvela 为准 |

---

## 8. 下一步

**阶段 S1 — 环境与资料基线**，具体动作：

1. 解决环境缺口：工具链入 PATH、安装 `kconfig-frontends` / `ninja`、解决串口通路
2. 查证 ESP32-S3 的 NuttX 烧录方式与偏移量，写入 [`../bringup/`](../bringup/README.md)
3. 把 `esp32s3-devkit` 的 `ble` / `nsh` / `psram_octal` defconfig 快照到
   [`../../config/defconfig/`](../../config/defconfig/README.md)
4. 建立一个最小验证目标：**先让 `esp32s3-devkit:nsh` 在裸板上跑起来**（不改代码，只验证工具链与烧录通路）
5. 编写 `scripts/setup/check-env.sh`

> 在用户答复 P1–P8 之前，S1 中**不涉及继电器/灯控硬件**的部分可以先做
> （环境、工具链、编译、烧录、NSH 启动），这些不依赖上位机与灯控硬件的决策。
