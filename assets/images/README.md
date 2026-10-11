# assets/images/ — 图片

存放实拍图、商家标注图、串口截图、界面截图。

## 已入库

| 文件名 | 内容 | 来源 | 状态 |
| --- | --- | --- | --- |
| `2026-10-10-schematic-full.png` | **★ 完整原理图**（主控/USB-ISP/USB-OTG/CH340/WS2812/电源/按键） | 从 `参考/www_xinlucity.pdf` 内嵌图片提取（XObject X80） | ✅ |
| `2026-10-10-pinout-alternate-functions.png` | **★ 引脚复用总图**（每个 GPIO 的第二功能，彩色分类） | 同上（XObject X93） | ✅ |
| `2026-10-10-dimensions.png` | 尺寸图（板宽 25.400 mm、排针跨距 27.940 mm） | 同上（XObject X81） | ✅ |
| `2026-10-10-board-leds-and-pads.png` | 实物标注图（LED 位置、WS2812、焊盘） | 同上（XObject X57） | ✅ |
| `2026-10-10-board-interfaces.png` | 双 Type-C 接口说明（USB-OTG / USB-ISP 与 CH340） | 用户提供 `参考/1776506140612601.png` | ✅ |
| `2026-10-10-board-pads.png` | IN-OUT 焊盘位置（5V 输出） | 用户提供 `参考/1775875467453325.png` | ✅ |

> 提取方法与全部 26 张内嵌图的辨识过程见
> [`../../docs/stages/stage-01-env-and-baseline.md`](../../docs/stages/stage-01-env-and-baseline.md)。

## 待补充

| 文件名 | 内容 | 状态 |
| --- | --- | --- |
| `2026-10-10-module-silkscreen.jpg` | 模组丝印特写（核对芯片版本号） | ⏳ **需用户拍摄**（开发板到手后） |
| `<日期>-relay-wiring.jpg` | 继电器模块接线实拍 | ⏳ **需用户拍摄**（硬件到手后） |
| `<日期>-boot-log.png` | 首次启动串口日志截图 | ⏳ 待实机 |

## 命名约定

- 前缀为 `YYYY-MM-DD-`，避免同名覆盖，也便于按时间排序。
- 英文小写 + 连字符，**不用中文文件名**（跨平台编码问题）。

## 拍摄要求（需要用户协助时）

- **模组丝印**：需要看清模组金属屏蔽罩上的型号丝印（`ESP32-S3-WROOM-1` 与
  `N16R8`），以及屏蔽罩角落的小字（芯片版本号）。**请用手机近距离补光拍摄**。
- **接线**：拍清楚继电器模块的型号丝印、VCC/GND/IN 三个端子的接线走向、
  以及独立供电部分（如果有）。
