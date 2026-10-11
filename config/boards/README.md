# config/boards/ — 板级定义

每块目标板一个子目录，存放**板级事实**：名称、引脚映射、时钟、Flash/PSRAM 参数、板级选项。

## 命名约定

```
config/boards/<board-slug>/
├── README.md         板级说明（硬件规格、引脚表、注意事项）
├── board.yaml        机器可读的引脚映射（供脚本生成代码）
├── defconfig.nsh     NSH 基线配置
├── defconfig.ble     BLE 基线配置
└── pins.md          引脚占用表（谁用了哪个脚，一眼可见）
```

## 当前板子

| slug | 说明 | 状态 |
| --- | --- | --- |
| `esp32s3-n16r8-generic` | 本项目目标：ESP32-S3-WROOM-1 **N16R8** 核心板 + CH340 + WS2812 + 双 Type-C | 🚧 待建立（阶段 S1） |

## 引脚占用表的维护要求

**每次新增一个外设，必须同步更新 `pins.md`。** 这是避免「两个功能抢同一个 GPIO」
这类低级但极耗时的错误的唯一有效手段。表里必须包含：GPIO 号、功能、方向、
是否被系统占用（UART/USB/Flash）、备注。
