# 文件清单与阅读顺序

> 本文件帮你在最短时间内找到需要的东西。**按 §2 的顺序读效率最高。**

---

## 1. 交接文档（先读这四份）

| 文件 | 作用 | 建议 |
| --- | --- | --- |
| [`HANDOFF-AI-ONBOARDING.md`](HANDOFF-AI-ONBOARDING.md) | 项目是什么、做到哪、坑在哪、下一步 | ★ **从这里开始** |
| [`HANDOFF-CURRENT-ISSUE.md`](HANDOFF-CURRENT-ISSUE.md) | **当前唯一阻塞问题的完整记录**（含 5 个待验证假设） | ★★ **要解决问题就读这份** |
| [`HANDOFF-REPRODUCE.md`](HANDOFF-REPRODUCE.md) | 从零复现的完整步骤 + 精确版本清单 | 需要动手时读 |
| `HANDOFF-INVENTORY.md` | 本文件，文件导航 | — |

---

## 2. 推荐阅读顺序

### 只想知道"这是个什么项目"（15 分钟）

1. [`README.md`](README.md) — 项目总览
2. [`HANDOFF-AI-ONBOARDING.md`](HANDOFF-AI-ONBOARDING.md) §0–§3 — 定位与进度
3. [`docs/stages/README.md`](docs/stages/README.md) — 阶段总表（S0→S3 一览）

### 要接手解决 GATT 问题（1–2 小时）

1. [`HANDOFF-CURRENT-ISSUE.md`](HANDOFF-CURRENT-ISSUE.md) — **完整问题记录**
2. [`tests/hardware/serial-gattdebug-connect.log`](tests/hardware/serial-gattdebug-connect.log)
   — 原始内核日志（**最有说服力的证据**）
3. [`src/app/btsh_light_main.c`](src/app/btsh_light_main.c) — 我写的 GATT 服务实现
4. `~/openvela/nuttx/wireless/bluetooth/bt_gatt.c` 的 `bt_gatt_connected()`
   — 假设 1 的验证点
5. `~/openvela/nuttx/wireless/bluetooth/bt_att.c` 的 opcode 分发表（320-370 行）
   — 假设 2 的验证点

### 要审阅代码质量

1. [`src/app/btsh_light_main.c`](src/app/btsh_light_main.c)（410 行，自写 GATT 服务）
2. [`config/boards/esp32s3-n16r8-generic/src/esp32s3_btsh_ws2812.c`](config/boards/esp32s3-n16r8-generic/src/esp32s3_btsh_ws2812.c)（板级 WS2812）
3. [`scripts/setup/install-btsh-light.sh`](scripts/setup/install-btsh-light.sh)（应用安装脚本）
4. [`scripts/setup/apply-board-ws2812.sh`](scripts/setup/apply-board-ws2812.sh)（板级补丁脚本）
5. [`scripts/build/build-n16r8.sh`](scripts/build/build-n16r8.sh)（构建入口）
6. [`thirdparty/patches/`](thirdparty/patches/)（两个上游 bug 补丁）

### 要了解踩过的坑

1. [`docs/bringup/wsl-esp32s3-build-notes.md`](docs/bringup/wsl-esp32s3-build-notes.md)
   — **踩坑全集**（含误删 nuttx 目录的事故与恢复）
2. [`thirdparty/patches/README.md`](thirdparty/patches/README.md) — 上游 bug 分析
3. [`tests/hardware/HT-05-ble-advertise.md`](tests/hardware/HT-05-ble-advertise.md)
   — 广播 EIO 的根因定位
4. [`tests/hardware/HT-07-ws2812-statusled.md`](tests/hardware/HT-07-ws2812-statusled.md)
   — WS2812 从零接入的过程

---

## 3. 按目录的文件清单

### 3.1 根目录

```
HANDOFF-AI-ONBOARDING.md     交接总览 ★
HANDOFF-CURRENT-ISSUE.md     当前阻塞问题 ★★
HANDOFF-REPRODUCE.md         从零复现指南
HANDOFF-INVENTORY.md         本文件
README.md                    项目总览
LICENSE                      Apache-2.0
.gitignore
```

### 3.2 `src/` — 源码（本项目自写部分）

```
src/app/
├── btsh_light_main.c    ★ GATT 灯控服务主实现（410 行）
├── Kconfig              应用配置项
├── Makefile             应用构建
├── Make.defs            应用注册
└── README.md

src/platform/README.md   预留（继电器/GPIO 抽象层，未实现）
src/protocol/README.md   预留（上下位机协议定义，未实现）
```

### 3.3 `config/` — 板级配置

```
config/boards/esp32s3-n16r8-generic/
├── defconfig.nsh          最小可启动基线（207,632 B）
├── defconfig.psram        + PSRAM（207,672 B）
├── defconfig.ble          + BLE（421,620 B）
├── defconfig.blewifi      + WiFi 共存（901,212 B）
├── defconfig.statusled    + WS2812 状态灯（422,904 B）
├── defconfig.gattlight    + GATT 灯控（423,816 B）
├── defconfig.gattdebug    同上 + 内核日志（437,912 B）★ 排查用
└── src/
    └── esp32s3_btsh_ws2812.c   板级 WS2812 初始化（上游没有）
```

> 每个 defconfig 头部都有**详细中文注释**，说明每一项改动及其理由。
> 这是本项目文档最密集的地方，值得一读。

### 3.4 `scripts/` — 脚本

```
scripts/build/
├── build-n16r8.sh        ★ 构建入口（自动注入必需宏）
└── build-esp32s3.sh      通用封装

scripts/setup/
├── apply-patches.sh            ★ 应用上游补丁（幂等）
├── install-btsh-light.sh       ★ 安装 GATT 应用到 apps 树
├── apply-board-ws2812.sh       ★ 安装 WS2812 板级支持
├── restore-esp-hal.sh          从缓存恢复 esp-hal
├── fetch-esp-hal-submodules.sh 获取 5 个子模块
├── setup-esptool.sh            安装 esptool
├── check-env.sh                环境自检
├── relay_proxy.py              Windows 侧代理中继
├── gh_proxy.py                 GitHub 代理辅助
└── setup-github-proxy.sh       配置代理环境变量

scripts/flash/
└── flash.sh              烧录脚本（WSL 侧，需串口可用）
```

### 3.5 `docs/` — 文档

```
docs/stages/                     ★ 分阶段开发记录
├── README.md                    阶段总表与规范
├── stage-00-project-init.md     项目初始化
├── stage-01-env-and-baseline.md 环境搭建与基线
├── stage-02-board-port.md       板级适配（含上游 bug 分析）
└── stage-03-peripherals.md      外设与无线（PSRAM/BLE/WiFi/WS2812）

docs/bringup/
├── wsl-esp32s3-build-notes.md   ★ 踩坑全集（DNS/代理/误删恢复/构建）
├── research-2026-10-10-ble-and-a7z.md  外部调研归档
└── README.md

docs/hardware/
├── README.md                    ★ 权威硬件事实（引脚/实测芯片数据）
└── schematic-notes.md           原理图解读

docs/protocol/README.md          预留（上下位机协议，未定义）
```

### 3.6 `tests/hardware/` — 实测证据（★ 最有说服力）

```
HT-05-ble-advertise.md          BLE 广播端到端验证（含 EIO 根因定位）
HT-06-wifi-ble-coexist.md       WiFi+BLE 共存验收
HT-07-ws2812-statusled.md       WS2812 状态灯（含目视确认）
HT-08-gatt-light-service.md     ★ GATT 服务（当前问题的完整记录）
README.md                       用例索引表

serial-boot-log.txt             首次启动日志
serial-nsh-commands.txt         NSH 命令验证
serial-psram-verify.txt         PSRAM 生效证据
serial-ble-verify.txt           BLE 启动与线程
serial-ble-deep.txt             BLE 扫描 5 个设备
serial-ble-advertise.txt        广播首次失败
serial-ble-advertise-repro.txt  广播 workaround 复现
serial-blewifi-verify.txt       WiFi+BLE 共存
serial-wifi-scan.txt            WiFi 扫到路由器
serial-ws2812.txt               WS2812 设备节点
serial-ws2812-run.txt           WS2812 点灯
serial-ws2812-sweep.txt         WS2812 色相扫描
serial-gattlight-start.txt      GATT 服务启动
serial-gattdebug-connect.log    ★ 连接成功的内核日志
serial-gattdebug-connect2.log   ★ 同上（复现）
```

### 3.7 `thirdparty/` — 上游补丁

```
patches/
├── 0001-esp32s3-add-missing-includes-for-wireless.patch
├── 0002-esp-hal-fix-spinlock-initializer.patch
└── README.md        ★ 补丁分析（症状/根因/基线 commit）
```

### 3.8 `assets/` — 资源

```
firmware/                      ★ 各配置的固件与符号表
├── nuttx-n16r8-{nsh,psram,ble,blewifi,statusled,gattlight,gattdebug}.bin
├── System.map-n16r8-*         符号表（调试用）
├── defconfig-n16r8-*          构建时实际生效的完整 .config
├── nuttx-esp32s3-eye-openvela-wifi.bin   官方 eye 固件（对照用，会挂死）
└── README.md

images/                        开发板照片与原理图截图（6 张 PNG）
reference/xinlucity-resource-61.md   板厂资源链接
```

> 📌 **不含 `.elf` 文件**（原始 ELF 有 9–12 MB × 7 个，约 67 MB）。
> 调试信息已由 `System.map-n16r8-*` 提供，足够定位符号地址。

### 3.9 预留但未实现的目录

```
hardware/README.md        硬件设计相关（预留）
tools/README.md           工具（预留）
tests/unit/README.md      单元测试（预留）
tests/integration/README.md  集成测试（预留）
.github/workflows/README.md  CI（预留）
```

---

## 4. 关键数字速查

| 项 | 值 |
| --- | --- |
| 芯片 MAC | `e0:72:a1:f2:8f:e8` |
| BLE 地址 | `e0:72:a1:f2:8f:ea` |
| 板载 WS2812B 数据线 | GPIO48 |
| SPI2 MOSI（WS2812 用） | GPIO48（`CONFIG_ESP32S3_SPI2_MOSIPIN=48`） |
| 串口 | COM4 / 115200 8N1 |
| PSRAM 总量 | 8,388,608 B（8 MB Octal） |
| 系统可用内存（blewifi 配置） | 8,626,992 B |
| GATT 服务 UUID | `0xFF00` |
| 灯控命令特征 | `0xFF01`（写 1 字节：0=关灯 1=开灯） |
| 灯状态特征 | `0xFF02`（读 + Notify） |
| 设备信息特征 | `0xFF03`（读 3 字节） |
| 广播名 | `BTSH-LIGHT` |
| 烧录地址 | `0x0`（Simple Boot，无 bootloader/分区表） |

---

## 5. 阅读时的几个提醒

1. **`tests/hardware/` 里的日志是原始串口输出**，含 ANSI 转义残留和
   中文乱码（Windows 控制台 GBK 所致）。这是**故意保留**的——
   它们是未经修饰的一手证据。

2. **`docs/stages/stage-03-peripherals.md` 的 §3.4 曾被修正过两次**：
   最初记为"广播失败"，后查明是时序问题。文中保留了修正痕迹，
   说明排查过程。阅读时以**最终结论**为准。

3. **`HT-08-gatt-light-service.md` 里我修正过自己的一个误判**：
   曾用 `bt bnep0 info` 的 `Free` 字段判断"连接未建立"，
   实际该字段不反映 LE 连接数。文中已明确标注。

4. **defconfig 里的注释比 defconfig 本身更有价值** ——
   每一项都写了"为什么"，包括失败的尝试。

5. **`serial-gattdebug-connect.log` 是最关键的一份证据**，
   它证明连接成功且 ATT 层无流量。要解决问题必读。
