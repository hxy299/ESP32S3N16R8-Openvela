# docs/hardware/ — 硬件事实库

> **本文件是引脚与硬件参数的唯一权威来源。** 其他地方需要引脚号时，链接到这里，不要复述。

## 1. 板子身份

| 项 | 值 | 来源/置信度 |
| --- | --- | --- |
| 板名（商家称呼） | ESP32S3 开发板（芯路城 / xinlucity，商品资料页 id=61） | ✅ 商家资料页 |
| 模组 | ESP32-S3-WROOM-1，丝印 `ESP32-S3-N16R8` | ✅ 实物图 |
| 芯片 | ESP32-S3（Xtensa® 双核 32 位 LX7） | ✅ 数据手册 |
| **芯片封装 / 版本** | **ESP32-S3 (QFN56)，revision v0.2** | ✅✅ **实测** |
| **Flash 容量** | **16 MB**（Manufacturer `0x68`，Device `0x4018`） | ✅✅ **实测** |
| **Flash 类型 / 电压** | **quad（4 数据线）** / **3.3 V**，均由 eFuse 设定 | ✅✅ **实测** |
| **PSRAM** | **Embedded PSRAM 8MB (AP_3v3)** | ✅✅ **实测** |
| **晶振** | **40 MHz** | ✅✅ **实测** |
| **MAC** | `e0:72:a1:f2:8f:e8`（本块板子） | ✅✅ **实测** |
| **无线能力** | **WiFi + BLE**（芯片特性实测确认） | ✅✅ **实测** |
| 模组内部 Flash/PSRAM 引脚 | GPIO26–GPIO32（**未引出，不可用**） | ✅ 商家资料页 |

> ✅✅ = **esptool 实测**（2026-10-10 首次烧录时取得），比任何资料页都权威。
> 复现命令（Windows 侧，COM4 为当时的串口号）：
> ```bash
> python -m esptool --chip esp32s3 -p COM4 -b 115200 chip_id
> python -m esptool --chip esp32s3 -p COM4 -b 115200 flash_id
> ```
> 实测原始输出存档：[`../../tests/hardware/serial-boot-log.txt`](../../tests/hardware/serial-boot-log.txt)

### 关于芯片版本 v0.2

`revision v0.2` 属于**较新的芯片版本**（早期为 v0.1）。有实际影响：

- NuttX 有 `ESP32S3_CHIP_REV` 相关配置（最小/最大支持芯片版本）
- 部分外设（USB-Serial-JTAG、某些 RTC 行为）在 v0.1 / v0.2 之间有差异
- **若遇到难以解释的启动问题，芯片版本是第一批要核对的地方**

### 关于 eFuse（实测确认已烧录）

```
Flash type set in eFuse: quad (4 data lines)
Flash voltage set by eFuse to 3.3V
```

出厂已烧录 Flash 相关 eFuse。这对 PSRAM/Flash 初始化参数的选择有直接影响——
不能假设 eFuse 为空。**注意：eFuse 是不可逆的，切勿随意写。**

### 参考文件归档

| 文件 | 位置 | 说明 |
| --- | --- | --- |
| 商家资料页存档 | [`../../assets/reference/xinlucity-resource-61.md`](../../assets/reference/xinlucity-resource-61.md) | 芯路城 ESP32S3 开发板客户资料页（含注意事项、例程） |
| **原理图（全）** | [`../../assets/images/2026-10-10-schematic-full.png`](../../assets/images/2026-10-10-schematic-full.png) | **★ 权威来源**。从 `参考/www_xinlucity.pdf` 内嵌图片提取 |
| **引脚复用总图** | [`../../assets/images/2026-10-10-pinout-alternate-functions.png`](../../assets/images/2026-10-10-pinout-alternate-functions.png) | **★ 权威来源**。每个 GPIO 的第二功能 |
| 尺寸图 | [`../../assets/images/2026-10-10-dimensions.png`](../../assets/images/2026-10-10-dimensions.png) | 板宽 25.400 mm；排针跨距 27.940 mm |
| 焊盘与 LED 标注图 | [`../../assets/images/2026-10-10-board-leds-and-pads.png`](../../assets/images/2026-10-10-board-leds-and-pads.png) | LED 位置、WS2812、焊盘位置 |
| 双 Type-C 接口图 | [`../../assets/images/2026-10-10-board-interfaces.png`](../../assets/images/2026-10-10-board-interfaces.png) | USB-OTG / USB-ISP 与 CH340 说明 |
| ESP32-S3 数据手册（中文） | `参考/1783913303242785.pdf`（项目外，**未入库，版权考虑**） | 83 页，ESP32-S3 Series Datasheet v2.2 |
| 原始商家 PDF（含全部内嵌图） | `参考/www_xinlucity.pdf`（项目外） | 26 张内嵌图，已提取 4 张关键图入库 |

---

## 2. 接口与焊盘

| 接口/焊盘 | 位置 | 功能 | 默认状态 |
| --- | --- | --- | --- |
| **USB-ISP**（Type-C） | 板子一侧 | 接板载 **CH340C** USB 转串口：烧录 + 串口打印 + 给板供电 | 可用 |
| **USB-OTG**（Type-C） | 板子另一侧 | 直连 ESP32-S3 **原生 USB D+/D-**（GPIO20=D+, GPIO19=D−）：可做 USB 设备/主机、虚拟 U 盘、键鼠 | **需短接 OTG 焊盘**才可用 |
| **IN-OUT 焊盘** | 板载（见实物图箭头处） | 短接后 5V-IN 引脚才对外输出 5V | **默认不输出**（保护板子稳定性） |
| **WS2812 焊盘** | 板载 | 短接后才能控制板载 RGB 彩灯 | **出厂已内部短接** |
| **GPIO3 焊盘** | 板载 | 见下方 §3.1：**已从原理图确认**是接到 J5 跳线，经 10 kΩ 下拉到 GND | — |
| **RST 按键** | 板载 | 复位（经 C10 100 nF 到 CHIP_PU） | — |
| **BOOT 按键** | 板载 | 对应 **GPIO0**，经 C9 100 nF / R18 10 kΩ；按下拉低，上电进下载模式 | — |

---

## 3. 原理图解读（**独立成文**）

> 原理图的逐块解读、与商家网页资料的差异、GPIO3 跳线（J5）的电气分析、
> 尺寸数据，全部整理在 **[`schematic-notes.md`](schematic-notes.md)**。

**三句话结论**：

1. 主控确认为 **ESP32-S3-WROOM-1-N16R8**；串口走 **CH340C**（U2），调试串口 = **GPIO43/44**。
2. **GPIO19/20 是原生 USB D−/D+（未接 CH340）**，因此不可同时用作 UART2 或 I2C——
   商家网页资料在这点上有误，本项目以原理图为准。
3. **GPIO26–GPIO32 未引出**（模组内部接 Flash/OPI PSRAM），**绝对不可使用**。

---

## 3. 板载 LED


| LED | 控制脚 | 说明 |
| --- | --- | --- |
| 电源指示灯 | 无（不可控） | 上电即亮 |
| TX 指示灯 | GPIO43（UART0 TX） | 串口发送时闪 |
| RX 指示灯 | GPIO44（UART0 RX） | 串口接收时闪 |
| **RGB 彩灯** | **GPIO48**（WS2812B，单总线） | 可用作程序状态指示 |

> GPIO48 同时也是 ESP32-S3 的一个常规 GPIO，做 WS2812 输出需要精确时序（RMT 或 SPI 模拟）。
> NuttX 的 `esp32s3-lcd-ev` 板级有 `ws2812` 配置，可作实现参考。

---

## 4. 引脚定义

### 4.1 被系统占用 / 不可用

| GPIO | 占用者 | 说明 |
| --- | --- | --- |
| GPIO26 – GPIO32 | **板载 Flash + OPI PSRAM** | **未引出到排针，任何情况下不可当普通 IO 用**，否则系统崩溃 |
| GPIO43 | UART0 TX | 调试串口（接 CH340），板载 TX 灯 |
| GPIO44 | UART0 RX | 调试串口（接 CH340），板载 RX 灯 |
| GPIO19 / GPIO20 | 原生 USB D− / D+ | 若启用 USB OTG 则不可复用 |
| GPIO48 | 板载 WS2812 RGB | 若要控制彩灯则不可复用 |

### 4.2 Strapping（启动配置）引脚

| GPIO | 作用 | 注意 |
| --- | --- | --- |
| GPIO0 | 低电平进下载模式；板载 BOOT 按键 | 上电瞬间电平决定启动模式，用作输出需谨慎；可复用为普通按键输入 |
| GPIO45 | 启动模式配置（VDD_SPI 电压） | 上电瞬间电平敏感 |
| GPIO46 | 启动模式配置（ROM 打印 / 启动模式） | 上电瞬间电平敏感 |

> 板载有 ISP 一键下载电路，正常烧录**无需手动**拉 GPIO0。

### 4.3 ADC

| 组 | 可用引脚 | 说明 |
| --- | --- | --- |
| ADC1 | GPIO0–GPIO7、GPIO16–GPIO21 | **WiFi 开启时仍可用，优先使用** |
| ADC2 | GPIO8–GPIO15、GPIO45–GPIO46 | **WiFi 开启时不可用** |

### 4.4 各外设推荐引脚（**依据原理图 + 引脚复用总图修正**）

| 外设 | 引脚 | 依据 | 可用性 |
| --- | --- | --- | --- |
| UART0（调试/下载） | **GPIO43 TX / GPIO44 RX** | 原理图：接 CH340C；板上 U0TXD/U0RXD | ❌ 已被占用 |
| 原生 USB | **GPIO19 D− / GPIO20 D+** | 原理图：直连 USB-OTG 座（未接 CH340） | ⚠️ 用 USB 时不可复用 |
| 板载 RGB | **GPIO48** | 原理图：WS2812B DIN | ⚠️ 用 RGB 时不可复用 |
| BOOT 按键 | **GPIO0** | 原理图：SW4 → GPIO0 | ⚠️ Strapping 引脚 |
| Flash / OPI PSRAM | **GPIO26–GPIO32** | 商家资料页 + 模组规格 | ❌ 未引出，绝对不可用 |
| **UART1（推荐给外部模块）** | **GPIO17 TX / GPIO18 RX** | 引脚复用总图：GPIO17=`U1TXD`、GPIO18=`U1RXD`（经 GPIO 矩阵） | ✅ 可用，**首选** |
| UART1（硬件默认脚） | GPIO19 RXD / GPIO20 TXD | 引脚复用总图：GPIO19=`U1RXD`、GPIO20=`U1TXD` | ⚠️ **与原生 USB 冲突** |
| I2C | GPIO8=`I2C0_SCL`、GPIO9=`I2C0_SDA` | 引脚复用总图 | ✅ 可用（**待实测确认编号**） |
| SPI2/FSPI | GPIO10–GPIO14、GPIO21 | 引脚复用总图：`FSPICS0/CLK/D/MISO/MOSI`、`FSPID` | ✅ 可用 |
| Touch | GPIO1–GPIO14、GPIO0 | 引脚复用总图 | ✅ |
| ADC1 | GPIO1–GPIO10（`ADC1_0`–`ADC1_9`） | 引脚复用总图 | ✅ WiFi 开启时仍可用 |

> ⚠️ **重要修正**：商家网页资料把 **GPIO17/18 标成 "UART1"，把 GPIO19/20 标成 "UART2"**，
> 但**引脚复用总图与原理图都表明 GPIO19/20 是原生 USB D−/D+**。
> 本项目采用：**GPIO17/18 作 UART1（外部模块）**，GPIO19/20 保留给原生 USB。
> 这一修正已与该总图交叉验证。

### 4.5 引脚占用表（本项目）

> 阶段 S1 建立 `config/boards/esp32s3-n16r8-generic/pins.md` 后在此链接。
> **在此之前，任何外设接线方案都需先与用户确认。**

---

## 5. 电气注意事项

| 项 | 值/说明 |
| --- | --- |
| 3V3 输出 | 板载稳压器输出，**最大约 1 A**，外接外设勿超负载 |
| 5V 输出 | 默认不对外供电，短接 IN-OUT 焊盘后可输出 |
| 供电 | 两个 Type-C 口都给板子供 5V |
| Flash 加密 / 安全启动 | 数据手册支持；本项目暂不启用 |

### 驱动继电器模块的电气方案（已确认硬件）

**已确认的硬件方案**（用户 2026-10-10 确认）：

| 项 | 值 |
| --- | --- |
| 灯控器件 | **单路继电器模块，高电平触发**（GPIO 输出高 → 吸合 → 灯亮） |
| 被控负载 | **低压直流**（5 V / 12 V / 24 V，如 LED 灯带、直流灯泡）—— **不涉及 220 V 强电** ✅ |
| 后续可能 | 转向其他控制方式（换器件时只改 `src/platform/`） |

因为是**高电平触发 + 低压直流**，方案相对简单，但仍有下列要点：

| 问题 | 说明 | 对策 |
| --- | --- | --- |
| 5 V 供电来源 | 板上 5V-IN 默认不输出（见 §2） | **短接 IN-OUT 焊盘**，或从 USB-ISP 的 VBUS 取；板上 5V 轨由 U12(LN2220) 升压产生 |
| 上电误动作（**高电平触发的固有风险**） | ESP32-S3 的 GPIO 在复位后、程序初始化前处于**高阻输入**态，多数继电器模块会因内部上拉/悬空而**误吸合一下**，导致灯闪一下或通电即亮 | ① 软件：`bsp_relay` 尽早在 `board_late_initialize`/应用 init 里把引脚驱动为**低电平**；② 硬件：GPIO 到继电器 IN 之间加 **10 kΩ 下拉电阻到 GND**（最可靠，推荐）；③ 或改用低电平触发模块 |
| 继电器线圈电流 | 单路模块吸合电流通常 60–90 mA @5 V | 板上 5V 轨（LN2220 升压）能否承受需实测；**建议继电器模块独立 5 V 供电、与开发板共地** |
| 3V3 输出能力 | 商家称最大约 1 A，但 U11 型号丝印为 `TAR`，**无法从原理图核实** | ⚠️ 不要用 3V3 排针给继电器线圈供电，用 5 V |
| 负载侧（低压直流） | 若用继电器切换 12 V/24 V 灯带，触点侧与开发板电气隔离 | 继电器本身已隔离，注意**共地只在控制侧**，负载侧独立回地 |
| 若改 MOS 管直驱 | 低压直流场景下 MOS 直驱比继电器更安静、无寿命限制 | 需要**低边 N-MOS + 栅极下拉**；PWM 可调光 |

**继电器控制引脚：待定。** 候选（均已按 §4 排除冲突）：

| 候选 GPIO | 优点 | 缺点 |
| --- | --- | --- |
| GPIO4 / GPIO5 | 排针 J1 上有，复用功能少（ADC1_3/ADC1_4、TOUCH4/5、RTC） | 无 |
| GPIO47 | 排针上有，无 ADC/Touch 冲突 | 复用功能为 SPICLK_P |
| GPIO21 | 排针上有 | 复用 FSPID；且原为 USB-OTG 检测相关（**需确认**） |
| GPIO1 / GPIO2 | 无特殊复用 | GPIO2 在总图上兼 `ADC1_1`/`TOUCH2` |

> **建议选 GPIO4**（普通 GPIO，无 strapping、无 USB/UART/Flash 冲突），
> 但**最终引脚号等开发板到手、接线确定后再写入** `config/boards/`。

---

## 6. 参考资料链接

| 资源 | 链接 |
| --- | --- |
| 商家客户资料页（引脚/例程/注意事项） | <https://www.xinlucity.com/?s=resourcedetail/index/id/61.html> |
| **原理图 / 尺寸图 / 引脚复用总图** | ✅ **已从 `参考/www_xinlucity.pdf` 提取入库**，见 [`../../assets/images/`](../../assets/images/README.md) |
| ESP32-S3 数据手册（中文 PDF） | `参考/1783913303242785.pdf`（项目外，未入库） |
| Arduino 软件平台下载 | <https://www.xinlucity.com/?s=resourcedetail/index/id/117.html> |
| Flash Download Tools 烧录教程 | <https://www.xinlucity.com/?s=resourcedetail/index/id/108.html> |
| 乐鑫官方 ESP32-S3 文档 | <https://docs.espressif.com/projects/esp-idf/zh_CN/latest/esp32s3/> |

> ✅ **原理图已获取**（2026-10-10，用户提示 `参考/www_xinlucity.pdf` 内含）。提取方法与
> 全部 26 张内嵌图见 [`../stages/stage-01-env-and-baseline.md`](../stages/stage-01-env-and-baseline.md)。
> 排针引出关系与 GPIO3 的电气连接已确认；**GPIO3 的"用途"仍需用户在实物上确认**。
