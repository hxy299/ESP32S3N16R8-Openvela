# Stage 01 — 环境探测、资料基线固化与技术调研

- 日期：2026-10-10
- 状态：✅ 已完成
- 关联提交：本阶段结束时提交
- 前置阶段：[stage-00-project-init.md](stage-00-project-init.md)

> **注**：本阶段最初规划为「环境与资料基线 + 首次编译」。由于用户补充提供了
> 关键资料（商家 PDF 内含原理图）并答复了硬件选型，且外部技术调研返回，
> 本阶段实际完成的是**资料固化 + 技术路线确认**。**首次编译被推迟到 S2 之前**
> （原因见 §7：开发板尚未到手，无法验证烧录，编译可在 S2 一并做）。

---

## 1. 本阶段目标

1. 从 `参考/www_xinlucity.pdf` 中**提取原理图与尺寸图**（用户指出的资料位置）
2. 固化硬件事实：引脚、复用功能、供电、限制
3. 完成 ESP32-S3 + BLE + A7Z 的**技术路线调研**，验证项目可行性
4. 根据用户答复修订硬件与协议设计的前提

---

## 2. 前置条件与环境

| 项 | 值 |
| --- | --- |
| Windows 工具 | Anaconda Python 3（`C:\Users\hxy299\anaconda3\python.exe`） |
| 新增依赖 | `pypdf` 5.9.0（`pip install pypdf`，用于 PDF 文本与内嵌图片提取） |
| 输入文件 | `参考/www_xinlucity.pdf`（4.0 MB，1 页，页面尺寸 1074×15690 pt） |
| 输入文件 | `参考/1783913303242785.pdf`（1.6 MB，83 页，ESP32-S3 数据手册 v2.2 中文） |

---

## 3. 实际执行过程

### 3.1 PDF 文本提取（先做，发现字体编码问题）

**命令**（Python + pypdf，输出重定向到 UTF-8 文件避免 Windows GBK 报错）：

```python
import pypdf, io, os
for name in ['1783913303242785','www_xinlucity']:
    f = r'D:\Myprogram\DeepSeekProgram\ESP32S3N16R8-One\参考\%s.pdf' % name
    r = pypdf.PdfReader(f)
    buf = []
    for i,p in enumerate(r.pages):
        buf.append('===== PAGE %d =====' % (i+1))
        buf.append(p.extract_text() or '')
    with io.open(r'...\_pdf_dump\%s.txt' % name, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(buf))
```

**遇到的第一个坑**：直接 `print` 到控制台时抛
`UnicodeEncodeError: 'gbk' codec can't encode character '\u0f22'`。
原因：Windows 控制台默认 GBK 编码，PDF 里混入了藏文/私用区字符。

**解决**：
1. 先设 `$env:PYTHONIOENCODING='utf-8'`；
2. 更根本的做法是**写入 UTF-8 文件再用 read 工具读**，绕开控制台编码。

**结果**：

| 文件 | 结果 |
| --- | --- |
| `www_xinlucity.pdf` 文本 | 仅 328 行，内容是**商家资料页的正文文字**，**没有原理图** |
| `1783913303242785.pdf` 文本 | 3250 行，中文数据手册正文（部分字体乱码如 `༢ਙྉோ`，正文主体可读） |

### 3.2 关键转折：原理图是**内嵌图片**，不是文字

用户提示「原理图和尺寸图在这个 PDF 文件里面」。文本提取只有正文文字 →
**推断原理图以图片形式内嵌**。于是改为**提取内嵌图像**：

```python
r = pypdf.PdfReader(PDF)
for pi, page in enumerate(r.pages):
    for im in page.images:
        open(out, 'wb').write(im.data)
```

**结果：从 1 页 PDF 中提取出 26 张内嵌图片**（页面尺寸 1074×15690 pt，
说明这是把长网页打印成 PDF）。XObject 清单显示尺寸从 16×16（图标）到 1920×1004。

**逐张辨识**（用 read_image 工具查看）：

| 序号 | 尺寸 | 内容 | 是否入库 |
| --- | --- | --- | --- |
| X80 | 1119×753 | ★ **完整原理图**（主控 / USB-ISP / USB-OTG / CH340 / WS2812 / 电源 / 按键） | ✅ |
| X93 | 1113×796 | ★ **引脚复用总图**（每个 GPIO 的第二功能，彩色分类） | ✅ |
| X81 | 938×595 | ★ **尺寸图**（板宽 25.400 mm、排针跨距 27.940 mm） | ✅ |
| X57 | 651×819 | ★ 实物标注图（LED 位置、WS2812、焊盘） | ✅ |
| X47 | 770×805 | 双 Type-C 接口说明图 | ✅（S0 已入） |
| X101 | 420×259 | IN-OUT 焊盘图 | ✅（S0 已入） |
| X85/X86/X88/X89/X90/X92/X98/X100 | — | Arduino IDE 教程截图（选板子、选端口等） | ❌ |
| 其余 | — | 网页图标、装饰图、logo | ❌ |

**入库命名**（`assets/images/`）：

| 原文件 | 入库名 |
| --- | --- |
| `p1_012_X80.png.png` | `2026-10-10-schematic-full.png` |
| `p1_021_X93.png.png` | `2026-10-10-pinout-alternate-functions.png` |
| `p1_013_X81.png.png` | `2026-10-10-dimensions.png` |
| `p1_008_X57.png.png` | `2026-10-10-board-leds-and-pads.png` |

### 3.3 原理图解读（**本阶段最重要的产出**）

逐块识读原理图，得到以下**权威事实**（完整版见
[`../hardware/schematic-notes.md`](../hardware/schematic-notes.md)）：

| 电路块 | 确认内容 |
| --- | --- |
| 主控 | U3 = **ESP32-S3-WROOM-1-N16R8** |
| USB-ISP | Type-C（USB2）→ D3(B5819W) → 板上 5V；**不接 ESP32 的 D+/D−**，只走 CH340 |
| USB 转 TTL | U2 = **CH340C**；TXD→GPIO44，RXD→GPIO43；DTR/RTS 经 R5/R6 引出 |
| 自动下载 | D1/D2 = **SS8050**，DTR/RTS 交叉驱动 EN 与 GPIO0（即「一键下载电路」） |
| USB-OTG | Type-C（USB1）直连 **GPIO20(D+) / GPIO19(D−)** |
| 5V 稳压 | U12 = **南麟 LN2220**（丝印 VUOT）升压 |
| 3V3 稳压 | U11 = 丝印 `TAR`（**型号未标，1 A 说法无法核实**） |
| 电源灯 | R25(1 kΩ) + LED3，接 **5V 轨**，不可控 |
| TX/RX 灯 | R1/R2(470 Ω) + LED1/LED2，接 **GPIO43 / GPIO44** |
| 板载 RGB | U1 = **WS2812B**，DIN ← **GPIO48** |
| 按键 | K1=EN、K2=SW4(BOOT)→**GPIO0**；R18=10 kΩ、C9/C10=100 nF |
| GPIO3 | **GPIO3 → J5 跳线**，并经 **R19 = 10 kΩ 下拉到 GND** |
| 排针 | J1 / J2 = X6511WV-22H-C30D00，各 22 pin |

**由此修正了商家网页的一处错误**：

> 商家网页把 GPIO19/20 同时推荐给 UART2、I2C 和原生 USB（三者电气互斥）。
> **原理图明确：GPIO19/20 直连 USB-OTG 座，是原生 USB D−/D+。**
> 本项目结论：GPIO19/20 保留给 USB；外部串口用 **GPIO17/18**（引脚复用总图上
> GPIO17=`U1TXD`、GPIO18=`U1RXD`）。

### 3.4 技术路线调研（子代理完成，含外部查证）

调研了 5 个问题，关键结论（完整报告见项目外
`NuttX_openvela_ESP32S3_BLE_与_Radxa_A7Z_调研报告.md`）：

| 问题 | 结论 |
| --- | --- |
| NuttX 的 ESP32-S3 BLE 是否可用 | ✅ **Controller + Host 都有**。`esp32s3_ble_adapter.c` = 控制器适配（调 Espressif `esp_bt_controller_*` + `esp_vhci_host_*`）；`esp32s3_ble.c` = H4/HCI 驱动，最终 `bt_driver_register()` |
| Host 是哪种 | **NuttX 自带 `wireless/bluetooth`**（Zephyr/Intel arduino101 血统），**不是 NimBLE**（NimBLE 是可选的 host-only 应用） |
| 必开配置 | `ALLOW_BSD_COMPONENTS`、`ESP32S3_BLE`、`WIRELESS`、`WIRELESS_BLUETOOTH`、`DRIVERS_BLUETOOTH`、`DRIVERS_WIRELESS`、`NET_BLUETOOTH`、`BTSAK`；共存需 `ESP32S3_WIFI_BT_COEXIST` |
| **🔴 重大限制** | **ioctl 只有 client 侧能力**（广播/扫描/GATT 读写信）。**GATT Server 只有内核 C API `bt_gatt_register()`，没有 NSH 命令也没有 ioctl** → 必须自己写应用代码 |
| N16R8 适配要点 | 所有 devkit defconfig 默认 `WROOM1N4`，**需改 `ARCH_CHIP_ESP32S3WROOM1N16R8`**；PSRAM 参照 `psram_octal`（`SPIRAM` + `SPIRAM_MODE_OCT` + `MM_REGIONS=2`） |
| 烧录方式 | **`esptool.py` ≥ 4.8.0**（不是 esptool-js）；**默认 Simple Boot 不需要 bootloader，`nuttx.bin` 直接烧 `0x0`**；波特率默认 921600 |
| `mcuboot_toolchain_esp32s3.cmake` | 是**交叉编译 MCUboot 引导器本体**用的 CMake toolchain 文件（生成 `mcuboot-esp32s3.bin`），**不是应用签名工具**；签名用 Python `imgtool` |
| WiFi + BLE 同时 | ✅ 用 `esp32s3-devkit:blewifi` 配置 + `ESP32S3_WIFI_BT_COEXIST`（已实测该 defconfig 存在） |

### 3.5 用户答复与设计前提修订

用户 2026-10-10 答复：

| 问题 | 答复 | 对设计的影响 |
| --- | --- | --- |
| A7Z 蓝牙能力 | 「A7Z 正在开发，**网络部分已完美完成，BLE 部分正在适配**，打算两者在 BLE 部分**会师**。ESP32 项目**可以同时支持 BLE 和 WiFi 最好**」 | ✅ 方案成立。**要求同时支持 BLE + WiFi** → 采用 `blewifi` + COEXIST 路线 |
| 灯控器件 | 「**先单路继电器模块（高电平）**，之后可能转向其他控制」 | 平台层需做成可替换；高电平触发有**上电误吸合**风险，需下拉电阻 |
| 被控负载 | **低压直流（5 V / 12 V / 24 V）** | ✅ **不涉及 220 V 强电**，安全风险大幅降低 |
| 开发板 | 「**现在手上还没有开发板**，你先开发，之后 ESP32 到了再烧录测试」 | ⚠️ 无法做任何实机验证；**编译与烧录验证推迟**，先做纯软件工作 |
| 原理图 | 指出在 `参考/www_xinlucity.pdf` 里 | ✅ 已提取（见 §3.2） |

---

## 4. 产出物

| 类别 | 路径 | 说明 |
| --- | --- | --- |
| 原理图全图 | [`assets/images/2026-10-10-schematic-full.png`](../../assets/images/2026-10-10-schematic-full.png) | 从 PDF 提取 |
| 引脚复用总图 | [`assets/images/2026-10-10-pinout-alternate-functions.png`](../../assets/images/2026-10-10-pinout-alternate-functions.png) | 从 PDF 提取 |
| 尺寸图 | [`assets/images/2026-10-10-dimensions.png`](../../assets/images/2026-10-10-dimensions.png) | 从 PDF 提取 |
| LED/焊盘标注图 | [`assets/images/2026-10-10-board-leds-and-pads.png`](../../assets/images/2026-10-10-board-leds-and-pads.png) | 从 PDF 提取 |
| 原理图解读文档 | [`docs/hardware/schematic-notes.md`](../hardware/schematic-notes.md) | **新建**，逐块解读 + 差异分析 |
| 硬件事实库（更新） | [`docs/hardware/README.md`](../hardware/README.md) | 修正引脚表、继电器方案 |
| 本阶段记录 | 本文件 | — |

临时产物（**不入库**，在项目外 `_pdf_dump/`）：
`www_xinlucity.txt`、`1783913303242785.txt`、`extract_images.py`、26 张原始提取图。

---

## 5. 验证方法与结果

| 验证项 | 方法 | 结果 |
| --- | --- | --- |
| PDF 内嵌图片数量 | pypdf `page.images` + XObject 清单 | ✅ 26 张，清单含尺寸/滤镜/色彩空间 |
| 原理图确实存在 | read_image 逐张查看 X80 | ✅ 确认为完整原理图 |
| 原理图解读正确性 | 交叉验证：① 与商家网页文字对比 ② 与引脚复用总图对比 ③ 与实物标注图对比 | ✅ 三处一致（差异已记录） |
| 模组型号 | 原理图 U3 标注 + 实物丝印图 | ✅ **ESP32-S3-WROOM-1-N16R8** |
| openvela 已有 BLE 支持 | 直接读 `~/openvela` 文件列表与 Kconfig 行号 | ✅ 非推测 |
| `blewifi` 配置存在 | `ls ~/openvela/nuttx/boards/xtensa/esp32s3/esp32s3-devkit/configs/` | ✅ 存在 |

**未能验证（因无开发板）**：一切实机行为 —— 编译、烧录、启动、BLE 广播、继电器动作。

---

## 6. 结论

1. **原理图、引脚复用总图、尺寸图全部拿到并入库**，硬件事实从「商家网页文字」
   升级为「原理图级依据」。S0 遗留的 P3（GPIO3 用途）、P4（原理图）两项：
   - P4 **已解决** ✅
   - P3 **电气关系已确认，用途仍需实物确认**（见 §7）
2. **项目技术可行性确认**：openvela 的 ESP32-S3 BLE Controller + Host + `blewifi`
   配置齐全，且**能用 `blewifi` 同时满足 BLE + WiFi 的需求**。
3. **识别出最大的工作量风险**：NuttX **没有 GATT Server 的应用层 API**，
   灯控服务必须手写内建应用调用 `bt_gatt_register()`。这把项目重心从
   「配置调通」推向了「写应用代码」。
4. 硬件前提已按用户答复更新：单路高电平继电器 + 低压直流 + 平台层可替换。

---

## 7. 遗留问题与风险

### 7.1 待用户确认

| 编号 | 问题 | 说明 |
| --- | --- | --- |
| P1' | **A7Z 的准确型号与技术路线** | 调研显示：Radxa 名为 **Cubie A7Z** 的产品是**全志 A733**（不是 Rockchip），官方系统是 Debian/Android，**未查到任何 openvela 支持**。而你说「主控已完成 openvela 适配」——**两者矛盾，需要你澄清**：是官方 openvela 适配？自研移植？还是其实跑的是 Debian + BlueZ？这直接影响上位的实现方式（见 §8） |
| P3' | **GPIO3 / J5 跳线的用途** | 电气关系已从原理图确认（GPIO3 → J5，R19 10 kΩ 下拉到 GND）。但**短接 J5 不改变电平**，所以它不像 WS2812 那种使能焊盘。请你在实物上确认 J5 的位置与设计意图。**在确认前本项目不使用 GPIO3。** |
| P9 | 继电器**具体型号**与接线 | 已知「单路、高电平触发、低压直流」。仍需：模块型号、是否自带光耦、供电取自开发板 5V 还是独立电源 |
| P10 | 灯的路数与是否要调光 | 目前按 1 路开关设计；若以后要 PWM 调光，`bsp_relay` 要改成 LEDC |

### 7.2 技术风险（更新）

| 风险 | 等级 | 说明与对策 |
| --- | --- | --- |
| **NuttX 无 GATT Server 应用层 API** | 🔴 高 | 必须自己写 `bt_gatt_register()` 调用代码。对策：参考 `apps/wireless/bluetooth/` 现有示例，尽早做一个最小 GATT 服务原型 |
| **A7Z 侧技术路线未确认** | 🔴 高 | 见 P1'。若 A7Z 实际跑 Debian + BlueZ，上位应用是 Python/C + D-Bus，与 openvela 无关；若真是自研 openvela 移植，则需确认其 BLE host 栈可用性 |
| 无开发板，无法验证 | 🟡 中 | 对策：先把**纯软件部分**（协议编解码、状态机、板级配置文件、构建脚本）做到可编译、可单元测试；实机验证统一推迟 |
| N16R8 非默认芯片配置 | 🟡 中 | 必须改 `ARCH_CHIP_ESP32S3WROOM1N16R8`，PSRAM 按 `psram_octal` 配 |
| 高电平继电器上电误吸合 | 🟡 中 | 硬件加 10 kΩ 下拉 + 软件尽早驱动低电平 |
| BLE + WiFi 共存的内存/IRAM 压力 | 🟡 中 | 控制器任务栈 4096、优先级 253；叠加 PSRAM/SMP 后需实测 |
| 上游 openvela 与当前 HEAD 漂移 | 🟢 低 | 所有改动走 `thirdparty/patches/`，记录 BASELINE.md |

---

## 8. 下一步

**在开发板到手之前，可以并行推进的软件工作**（不依赖硬件）：

1. **S2-a：板级定义文档化**（不写代码）
   - 建立 `config/boards/esp32s3-n16r8-generic/`，写 `README.md` + `pins.md`
   - 把原理图结论填入引脚占用表

2. **S2-b：defconfig 快照与裁剪方案**
   - 从 `~/openvela` 拷贝 `esp32s3-devkit` 的 `nsh` / `ble` / `blewifi` / `psram_octal`
     defconfig 到 `config/defconfig/`（加 `.upstream` 后缀）
   - 设计本项目 `btsh_blewifi` 的配置差异（改 N16R8、开 COEXIST、裁剪不需要的）
   - **在这一步可以尝试编译**（不需要开发板，只需工具链）

3. **S4-a：协议层与状态机的纯软件实现 + 单元测试**
   - `src/protocol/btsh_codec.c`（不依赖 NuttX 头文件，可在 PC 上跑测试）
   - `tests/unit/test_codec.c`
   - 灯控状态机

4. **S1-a：编写 `scripts/setup/check-env.sh`**，把环境体检自动化

**需要用户答复后才能做的**：

- 上位（A7Z）侧的任何实现 —— 等 P1' 澄清
- 继电器引脚最终定号 —— 等 P9 硬件到手

> **给用户的建议**：如果开发板短期到不了，可以先买一块**通用 ESP32-S3-DevKitC-1**
> 或任意 ESP32-S3 模块做**编译与启动验证**（不接继电器），这能提前暴露
> 工具链、烧录、PSRAM 配置的问题，避免开发板到手后一次性踩一堆坑。
