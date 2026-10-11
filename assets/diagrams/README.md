# assets/diagrams/ — 架构图与流程图的源文件

## 格式选型

| 用途 | 推荐格式 | 理由 |
| --- | --- | --- |
| 系统架构图、框图 | **Mermaid**（`.mmd` 或直接嵌在 md 里） | GitHub 原生渲染，diff 友好，无需工具 |
| 交互时序图 | **Mermaid sequenceDiagram** | 同上，改协议时容易同步 |
| 电路/接线图 | drawio（`.drawio`）+ 导出 PNG | 需要图形化编辑 |
| 状态机 | Mermaid `stateDiagram-v2` | — |

**优先用 Mermaid**：纯文本、可 review、不会因为二进制文件冲突而丢失修改。

## 计划收录

| 文件 | 内容 |
| --- | --- |
| `system-architecture.mmd` | A7Z ↔ ESP32-S3 系统架构 |
| `ble-sequence.mmd` | BLE 连接与灯控时序 |
| `light-state-machine.mmd` | 灯控状态机 |
| `boot-flow.mmd` | ESP32-S3 启动链路（ROM → 引导 → NuttX） |

> 待相关阶段（S4/S5）确定协议后编写。
