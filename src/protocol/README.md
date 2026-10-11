# src/protocol/ — 蓝牙通信协议层

本目录实现 **ESP32-S3（Peripheral）与 Radxa A7Z（Central）之间的 GATT 接口契约**。

> 接口定义（UUID、报文格式）的**权威文档**在 [`../../docs/protocol/`](../../docs/protocol/README.md)。
> 本目录是它的代码实现。改协议必须先改文档，再改代码。

## 计划中的模块

| 文件 | 职责 |
| --- | --- |
| `btsh_gatt.c/.h` | GATT 服务与特征的注册、读写回调、Notify 发送 |
| `btsh_codec.c/.h` | 报文的序列化/反序列化（纯函数，便于主机端单元测试） |
| `btsh_proto.h` | 协议常量：UUID、操作码、错误码 |

## 设计原则

1. **编解码与蓝牙栈解耦**：`btsh_codec.*` 不 include 任何 NuttX 头文件，
   这样可以在 PC 上直接跑单元测试（见 [`../../tests/unit/`](../../tests/unit/README.md)）。
2. **定长/显式长度**：报文首字节为操作码，第二字节为长度，便于兼容扩展。
3. **未知操作码必须返回错误**，不得静默忽略。
