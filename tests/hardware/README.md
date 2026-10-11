# tests/hardware/ — 实机测试记录

> 本目录保存**真实硬件上跑出来的证据**。所有结论都必须能在这里找到原始输出。

## 已完成的实机验证

| 编号 | 日期 | 内容 | 结论 | 证据 |
| --- | --- | --- | --- | --- |
| HT-01 | 2026-10-10 | 芯片识别（esptool `chip_id` / `flash_id`） | ✅ ESP32-S3 QFN56 rev v0.2；WiFi+BLE；8MB PSRAM；16MB Flash | [stage-02 §3.1](../../docs/stages/stage-02-board-port.md) |
| HT-02 | 2026-10-10 | 烧录官方 eye 固件 | ⚠️ 烧录成功但**启动挂死**（`dmap` 段后无输出，不接收输入） | [stage-02 §3.2](../../docs/stages/stage-02-board-port.md) |
| HT-03 | 2026-10-10 | **N16R8 专用固件烧录 + 启动** | ✅ **出现 `nsh>` 提示符** | [`serial-boot-log.txt`](serial-boot-log.txt) |
| HT-04 | 2026-10-10 | **NSH 命令交互** | ✅ `uname`/`free`/`ps`/`ls`/`cat`/`uptime`/`help` 全部正常 | [`serial-nsh-commands.txt`](serial-nsh-commands.txt) |
| HT-05 | 2026-10-10 | **PSRAM 启用** | ✅ 内存 405KB → **8.79MB**（+8MB），区域数 1→2 | [`serial-psram-verify.txt`](serial-psram-verify.txt) |
| HT-06 | 2026-10-10 | **BLE 控制器与 host** | ✅ btController/BT_HCI_Tx 线程就绪，scan 扫到 5 个设备 | [`serial-ble-deep.txt`](serial-ble-deep.txt) |
| HT-07 | 2026-10-10 | **BLE 广播端到端** | ✅ **Windows 中央设备扫到本板**（RSSI -20，全场最强） | [`HT-05-ble-advertise.md`](HT-05-ble-advertise.md) |
| HT-08 | 2026-10-11 | **WiFi + BLE 共存** | ✅ WiFi 扫到 5 个真实路由器；**WiFi 活跃时 BLE 广播仍被 Windows 发现**（rssi -22） | [`HT-06-wifi-ble-coexist.md`](HT-06-wifi-ble-coexist.md) |
| HT-09 | 2026-10-11 | **板载 WS2812B 状态灯 (GPIO48)** | ✅ /dev/leds0 注册成功；**用户目视确认颜色渐变** | [`HT-07-ws2812-statusled.md`](HT-07-ws2812-statusled.md) |

## 关键实测数据

| 项 | 值 |
| --- | --- |
| MAC 地址 | `e0:72:a1:f2:8f:e8` |
| 芯片 | ESP32-S3 (QFN56) revision **v0.2** |
| Flash | **16 MB**，Manufacturer `0x68`，Device `0x4018`，quad，3.3V（eFuse 设定） |
| PSRAM | Embedded **8MB** (AP_3v3) |
| 晶振 | 40 MHz |
| 串口 | CH340 → Windows `COM4`，115200 8N1 |
| 可用内存 | Umem 405,120 B（N16R8 nsh 配置，**未启 PSRAM**） |

## 复现命令

```powershell
# Windows 侧（需 esptool 4.8.x；安装步骤见 stage-02 §3.7）
python -m esptool --chip esp32s3 -p COM4 -b 115200 chip_id
python -m esptool --chip esp32s3 -p COM4 -b 115200 flash_id
python -m esptool --chip esp32s3 -p COM4 -b 921600 write_flash 0x0 <固件.bin>
```

```bash
# WSL 侧（构建；需先 source ~/.openvela-proxy-env）
bash scripts/build/build-n16r8.sh nsh
```

## 记录模板

新增用例时按此格式，文件名 `HT-<编号>-<描述>.md`：

```markdown
# HT-NN — <标题>

- 日期：
- 固件：<文件名> / <git commit>
- 构建配置：
- 硬件：ESP32-S3-N16R8（MAC e0:72:a1:f2:8f:e8）
- 接线：USB-ISP → COM4
- 工具与命令：

## 步骤
1. …
## 期望结果
…
## 实际结果
（原始串口输出）
## 结论
PASS / FAIL / 部分
## 备注
```

## 必备前置检查清单

- [ ] 用 **USB-ISP** 口（CH340），不是 USB-OTG
- [ ] USB 线**能传数据**（不是只充电线）
- [ ] 插上后 Windows 设备管理器出现 `USB-SERIAL CH340 (COMx)`
- [ ] 5V-IN 焊盘：驱动继电器时才需短接
- [ ] WS2812 焊盘：用板载 RGB 时才需短接（出厂已短接）
- [ ] OTG 焊盘：用原生 USB 时才需短接
- [ ] 烧录地址 **0x0**（Simple Boot，无需 bootloader/分区表）

## 已知环境限制

| 限制 | 影响 | 绕法 |
| --- | --- | --- |
| **WSL 看不到 USB 串口** | `/dev/ttyS*` 全部打不开（WSL2 动态串口映射只在启动时探测） | 在 **Windows 侧**烧录（已装 esptool 4.8.1） |
| usbipd 未安装 | 无法把 COM 口透传进 WSL | 需管理员执行 `winget install usbipd` |
| 构建需 GitHub 代理 | 重新获取 esp-hal 依赖 | 启动 Windows 侧 `relay_proxy.py`，WSL 走 `https_proxy` |
