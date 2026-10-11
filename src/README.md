# src/ — 项目自有源码

本目录只放 **本项目自己写的代码**。openvela / NuttX 上游代码不在此处，
对其改动以 patch 形式放在 [`../thirdparty/`](../thirdparty/README.md)。

## 子目录

| 目录 | 职责 | 典型文件 |
| --- | --- | --- |
| [`app/`](app/README.md) | 业务逻辑：智能家居灯控、BLE 事件回调、命令解析、状态机 | `smarthome_main.c` |
| [`protocol/`](protocol/README.md) | 通信契约：GATT 服务/特征注册、报文编解码（与 A7Z 的接口） | `btsh_gatt.c`, `btsh_codec.c` |
| [`platform/`](platform/README.md) | 平台抽象：GPIO/继电器/RGB 灯封装，隔离板级差异 | `bsp_relay.c`, `bsp_rgb.c` |

## 编码规范

- 语言：C（NuttX 内核与应用侧统一）。文件头写 Apache-2.0 许可声明。
- 命名：对外接口前缀 `btsh_`（Bluetooth SmartHome）；板级/平台层前缀 `bsp_`。
- 头文件放同目录，`#include` 用双引号引相对路径。
- **禁止**在应用层直接写裸 GPIO 编号，必须经 `platform/` 抽象，便于换板。
- 所有对外可配参数集中在 `config/` 下，代码里不出现魔法数字。

## 与 openvela 的集成方式

本项目代码最终需要被 NuttX 构建系统收录，两种方式（阶段 S5 时定夺）：

1. **作为 apps 包**（推荐）：在 openvela 的 `apps/` 下建一个外部包目录，
   用 `apps/external` 或 `EXTERNALDIR` 机制引入，通过 Kconfig 开关启停。
2. **作为板级源码**：直接放进 `boards/xtensa/esp32s3/<board>/src/`，随板级编译。

采用哪种、以及如何用 patch 固化，见 [`../docs/bringup/`](../docs/bringup/README.md)。

## 构建

编译入口见 [`../scripts/build/`](../scripts/build/README.md)。
