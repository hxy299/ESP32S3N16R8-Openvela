# 芯路城 ESP32S3 开发板 — 客户资料页存档

- **来源**：<https://www.xinlucity.com/?s=resourcedetail/index/id/61.html>
- **存档日期**：2026-10-10
- **说明**：本文是商家资料页正文的整理存档（去除了网页导航、广告等噪声），
  保留原始措辞以确保硬件事实不失真。**原文中的矛盾之处在文末「存档者备注」中标注。**
- 店铺信息：芯路城，河南省郑州市新郑市龙湖镇紫荆山南路与金岸路交叉口，豫 ICP 备 2026000735 号-1

---

## 【0】使用前必看

### （1）TypeC 口介绍

板上两个 Type-C：

- **USB-OTG**：直连 ESP32-S3 芯片本身的原生 USB **D+ / D−** 引脚。
  - 核心功能：
    1. 可以把 ESP32-S3 伪装成各种 USB 设备，用来开发鼠标、键盘和虚拟 U 盘
    2. 可做 USB 主机，直接接 U 盘、鼠标和键盘等 USB 从设备
    3. 给开发板供 5V 电
    4. 可以使用 USB-OTG 下载方式给板子下载程序
  - **注意：需要短接 OTG 焊盘才能使用**
- **USB-ISP**：板上直连 **CH340** USB 转串口芯片。
  - 核心能力：
    1. 程序烧录和固件下载
    2. 串口收发，串口监视器打印数据
    3. 给开发板供 5V 电
  - **注意：需要安装串口驱动才能使用**

### （2）IN-OUT 短接焊盘介绍

**5V-IN 引脚默认是不向外供电**，因为直接从核心板取电会影响 ESP32 的稳定运行，
这样设计能够保护板子和保障板子稳定运行。如果需要 5V 供电，**可以短接焊盘，可以对外输出 5V**。

> 实物图标注：`短接IN-OUT焊盘 对外输出5V`

### （3）RGB 和 GPIO3 焊盘介绍

- **RGB 焊盘**是 WS2812B 彩灯的使能焊盘，**短接上后，才能控制彩灯**。
  （出厂默认内部短接，方便使用）
- **GPIO3 焊盘**：（原文此处说明文字缺失）

### （4）LED 指示灯介绍

3 颗独立 LED：

- 电源灯（**不可控**）
- TX/RX 串口灯（对应 **GPIO43、GPIO44**）
- 板载 RGB（WS2812）：**GPIO48** 控制单总线 RGB 灯

### （5）ESP32-S3 关键注意事项

- **引脚限制**：GPIO26–GPIO32 为板载 Flash/PSRAM 专用引脚，因此**没有引出来**
- **ADC 限制**：ADC2 通道在 WiFi 开启时不可用，优先使用 ADC1（GPIO0–GPIO7、GPIO16–GPIO21）
- **Strapping 引脚**：GPIO0、GPIO45、GPIO46 为启动配置引脚，GPIO0 拉低进入下载模式
- **USB-OTG**：GPIO20 / GPIO19 为原生 USB 引脚，可直接做 USB 主机/设备，无需额外芯片
- **PSRAM 支持**：N16R8 自带 8 MB PSRAM，工具菜单 PSRAM 选择 **OPI PSRAM** 即可启用

---

## 【1】原理图尺寸图

> 注：PDF 格式需要去附件里下载（**本项目尚未获取**）

## 【2】程序和固件烧录教程

### 1. Arduino IDE 软件使用教程

1. 打开 Arduino IDE 软件
   - 下载安装包：<https://www.xinlucity.com/?s=resourcedetail/index/id/117.html>
2. 选择开发板：`工具 → 开发板 → ESP32S3 Dev Module`
   - 需先安装 ESP32 芯片支持包；离线芯片支持包：
     链接 <https://pan.baidu.com/s/1teLKfDVP9NXphiU6RN3Ecw?pwd=1234> 提取码 `1234`
3. 连接开发板
4. 选择 COM 口：选择带有 **CH340** 名字的 COM 口
   - 没有则需安装串口驱动（CH340 驱动.zip）
5. 打开示例代码 `Blink`，彩灯闪烁代码进行测试
6. 上传程序
7. 观察现象，板载的 RGB 彩灯会进行闪烁

### 2. 乐鑫官方 Flash Download Tools 工具使用教程

Flash Download Tools 保姆级图文烧录教程：
<https://www.xinlucity.com/?s=resourcedetail/index/id/108.html>

## 【3】软件工具下载

| 工具 | 链接 |
| --- | --- |
| Arduino 软件平台 | <https://www.xinlucity.com/?s=resourcedetail/index/id/117.html> |
| thonny-4.0.1 | <https://www.xinlucity.com/?s=resourcedetail/index/id/118.html> |
| 米思齐 | <https://www.xinlucity.com/?s=resourcedetail/index/id/142.html> |

## 【4】引脚定义

### 关键使用提示（原文）

- **SPI 接口占用**：GPIO26–GPIO32 为板载 Flash/PSRAM 专用引脚，**不可用作普通 IO**，否则会导致系统崩溃
- **下载模式**：GPIO0 为 Strapping 引脚，低电平进入下载模式。板载 ISP 一键下载电路，无需手动进行下载模式
- **电源注意**：3V3 为板载稳压器输出，**最大电流约 1 A**，外接外设时请勿超负载
- **通信引脚**：UART0 (GPIO43/44) 用于调试下载，**建议使用 UART1 (GPIO17/18) 连接外部模块**

## 【5】参考例程

> 注：以下为 Arduino 平台的基础例程，更多其他平台例程待整理更新

| 例程 | 主题 | 关键引脚 |
| --- | --- | --- |
| 1 | GPIO 输入输出（按键控 LED） | LED=GPIO2，KEY=GPIO0 |
| 2 | ADC 模拟输入 | ADC1_CH1 = GPIO1；量程 0–3.3 V，`ADC_11db` |
| 3 | Touch 触摸传感器 | 触摸引脚 GPIO0–GPIO19、GPIO21、GPIO45–GPIO46 |
| 4 | UART 串口通信 | UART0=43/44；UART1=17/18；UART2=19(TX)/20(RX) |
| 5 | I2C 通信（OLED SSD1306） | SDA=GPIO20，SCL=GPIO19（原文如此） |
| 6 | SPI 通信（SD 卡） | SCK=GPIO36，MISO=GPIO37，MOSI=GPIO35，CS=GPIO34 |
| 7 | WiFi + 蓝牙 BLE | BLE 服务 UUID `4fafc201-…`，特征 UUID `beb5483e-…` |
| 8 | USB-OTG（原生 USB CDC） | 需在工具菜单开启 `USB CDC On Boot` |
| 9 | OPI 模式（PSRAM 验证） | 工具菜单 PSRAM 选 OPI PSRAM |
| 10 | 更多例程 | 见商家资料页 |

### 例程 7 的 BLE 关键参数（可作为本项目 UUID 参考）

```
SERVICE_UUID        = "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
CHARACTERISTIC_UUID = "beb5483e-36e1-4688-b7f5-ea07361b26a8"
特性属性             = READ | WRITE | NOTIFY
```

---

## 存档者备注（**重要：原文内部矛盾**）

> 以下为整理者标注，**不是**商家原文。

1. **GPIO19/GPIO20 用途冲突**：
   资料页既把它们推荐给「UART2 (GPIO19 TX / GPIO20 RX)」和「I2C (SDA=GPIO20, SCL=GPIO19)」，
   又在【0】(5) 中明确说「GPIO20/GPIO19 为原生 USB 引脚」。
   同一对引脚不可能同时做 USB、UART2 和 I2C。**本项目采用：GPIO19/20 留给原生 USB，
   外部串口用 UART1 (GPIO17/18)，I2C 另选空闲引脚。**
2. **GPIO3 焊盘用途缺失**：原文该处说明为空，需结合原理图确认。
3. **例程 4 与例程 5 的 UART2/I2C 引脚分配**属于上述冲突的一部分，仅作参考，
   不可直接照搬到本项目。
4. 例程均为 **Arduino 平台**，本项目使用 **openvela / NuttX**，例程只用于
   验证硬件通路（如 RGB 是否亮、串口是否通），不作为实现参考。
