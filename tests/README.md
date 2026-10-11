# tests/ — 测试

## 分层策略

| 目录 | 层次 | 运行位置 | 说明 |
| --- | --- | --- | --- |
| [`unit/`](unit/README.md) | 单元测试 | **PC（WSL/Windows）** | 纯逻辑，不依赖硬件。协议编解码、状态机 |
| [`integration/`](integration/README.md) | 集成测试 | PC 或模拟器 | 多模块协同，如「报文→命令→状态变更」 |
| [`hardware/`](hardware/README.md) | 实机测试 | ESP32-S3 开发板 + A7Z | 需真实硬件，含手工用例与记录 |

## 原则

1. **能在 PC 上测的，不要上板测**。上板一次的成本远高于跑一次单元测试。
   这也是 `src/protocol/btsh_codec.*` 要求不依赖 NuttX 头文件的原因。
2. **实机测试必须留记录**：串口日志、实测现象、日期、固件版本（git commit）。
   模板见 `hardware/` 下 README。
3. 每个阶段的验收标准要落到具体测试用例，而不是「看起来没问题」。
