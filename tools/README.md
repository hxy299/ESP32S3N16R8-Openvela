# tools/ — 辅助小工具

存放不属于构建流程、但开发过程中用得上的小工具与脚本。

## 计划收录

| 工具 | 用途 | 语言 |
| --- | --- | --- |
| `ble_client_test.py` | 在 PC/WSL 上当临时 BLE Central，验证 ESP32-S3 的 GATT 服务是否正常（**用于在 A7Z 联调之前先自测**） | Python + bleak |
| `make_uuid.py` | 生成随机 128 位 UUID，替换协议草案里的临时 UUID | Python |
| `decode_log.py` | 解析串口日志，提取关键事件与时间戳 | Python |
| `pins_check.py` | 读取 `config/boards/*/pins.md`，检查 GPIO 占用冲突 | Python |

## 为什么需要 `ble_client_test.py`

A7Z 联调的成本高（需要上位机在场、需要协议双方都就绪）。用 PC 上的 Python BLE
客户端先验证 ESP32-S3 侧，可以**把问题定位在单侧**，避免联调时互相甩锅。

前提：PC 或 WSL 要有可用的蓝牙适配器。WSL2 **默认不支持蓝牙**，
因此这个工具大概率要在 **Windows 侧**运行（用 Windows 的蓝牙）。

> ⚠️ 待阶段 S5 确认 WSL 蓝牙可用性后再定实现与运行位置。

## 约定

- Python 脚本用 `uv` 或系统 Python，依赖写在同目录 `requirements.txt`。
- 工具脚本不做破坏性操作，不自动改仓库文件（除显式 `--write`）。
