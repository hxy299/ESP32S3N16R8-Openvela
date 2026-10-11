# 交接说明 — 给接手的 AI / 工程师

> **请先读这一份。** 本文告诉你：项目是什么、做到哪了、当前卡在哪、
> 该从哪里继续、以及**哪些结论是实测验证过的、哪些只是推测**。

---

## 0. 一句话概括

把 **openvela**（Apache NuttX 的衍生发行版）移植到 **ESP32-S3-N16R8**
开发板上，让它作为**蓝牙 BLE 下位机**，接受 **Radxa A7Z** 上位机的控制，
实现智能家居的**远程点灯**。

**当前进度：无线部分全部打通，卡在 BLE GATT 服务发现。**

---

## 1. 项目定位与最终目标

| 角色 | 硬件 | 职责 |
| --- | --- | --- |
| 上位机 | **Radxa A7Z** | 运行用户自移植的 **native openvela**；作为 BLE **Central**（GATT Client），发起连接、下发灯控命令 |
| 下位机 | **ESP32-S3-N16R8** | 运行本项目移植的 openvela；作为 BLE **Peripheral**（GATT Server），执行点灯 |

第一阶段目标（本项目范围）：**远程开关灯**。
后续可扩展：多路、PWM 调光、WiFi 联网（MQTT/HTTP）。

> 📌 用户已明确：A7Z 上的 openvela 是**用户自己移植好的**，不需要本项目关心。
> 本项目只负责 ESP32-S3 这一侧。

---

## 2. 硬件事实（全部实测确认，不要凭型号猜）

| 项 | 值 | 来源 |
| --- | --- | --- |
| 开发板 | 芯路城 ESP32-S3-N16R8 开发板 | 实物 |
| 模组 | ESP32-S3-WROOM-1 **N16R8**（16MB Flash + 8MB Octal PSRAM） | esptool 实测 |
| 芯片 | ESP32-S3 (QFN56) revision **v0.2** | `esptool chip-id` |
| 芯片特性 | WiFi, BLE, **Embedded PSRAM 8MB (AP_3v3)** | esptool |
| 晶振 | 40 MHz | esptool |
| Flash | 16 MB，quad (4 data lines)，3.3V，DIO 模式 | esptool flash-id |
| 芯片 MAC | `e0:72:a1:f2:8f:e8` | esptool |
| **BLE 地址** | `e0:72:a1:f2:8f:ea`（= MAC + 2） | `bt bnep0 info` |
| 串口 | Windows **COM4**（CH340），115200 8N1 | 实测 |
| **板载 RGB** | **WS2812B，数据线 GPIO48** | 原理图 U1 |
| 用户负载 | **单路继电器模块，高电平有效**，低压直流（5/12/24V，**非 220V**） | 用户确认 |

> ⚠️ **不要假设 N16R8 的 PSRAM 是 Quad。** 它是 **Octal**，
> 且必须显式指定类型（见 §5.2），否则启动挂死。

详细引脚与原理图解读见：
- [`docs/hardware/README.md`](docs/hardware/README.md) — 权威硬件事实
- [`docs/hardware/schematic-notes.md`](docs/hardware/schematic-notes.md) — 原理图解读

---

## 3. 已验证可用 ✅ vs 未完成 ❌

### ✅ 已实测验证（每项都有原始串口日志）

| 能力 | 证据 | 日志/文档 |
| --- | --- | --- |
| 系统启动到 NSH | `nsh>` 提示符 | `tests/hardware/serial-boot-log.txt` |
| **8MB PSRAM** | `free` 总内存 **8,792,160 B**（基线仅 405,120 B） | `serial-psram-verify.txt` |
| **BLE 控制器 + host 栈** | `btController` / `BT_HCI_Tx` 线程；`scan get` 扫到 5 个真实设备 | `serial-ble-deep.txt` |
| **BLE 广播可被发现** | Windows 侧扫到 `E0:72:A1:F2:8F:EA`，RSSI -20（全场最强） | [`HT-05`](tests/hardware/HT-05-ble-advertise.md) |
| **WiFi 可用** | `wapi scan wlan0` 扫到 5 个真实路由器（BSSID/信号/加密/SSID） | `serial-wifi-scan.txt` |
| **WiFi + BLE 共存** | 四个无线任务并存；WiFi 活跃时 BLE 广播仍可被扫到 | [`HT-06`](tests/hardware/HT-06-wifi-ble-coexist.md) |
| **板载 WS2812B 点灯** | `/dev/leds0` 注册；**用户目视确认颜色渐变** | [`HT-07`](tests/hardware/HT-07-ws2812-statusled.md) |
| **自写 GATT 服务注册** | `btsh_light start` → `service 0xff00 registered (8 attrs)` | `serial-gattlight-start.txt` |
| **GATT 广播名可解析** | Windows 扫到 `name='BTSH-LIGHT'` | `serial-gattdebug-connect2.log` |
| **BLE 连接建立成功** | `le_conn_complete: status 0 handle 1` | `serial-gattdebug-connect.log` |

### ❌ 当前阻塞：GATT 服务发现失败

**现象**：Windows（bleak）能扫描到设备、能建立 BLE 连接，
但**服务发现（`get_services()`）超时**。

**已定位到具体环节**（有内核日志为证）：

```
le_conn_complete: status 0 handle 1 role 1 7C:FA:80:EF:CE:2B (public)
bt_conn_set_state: disconnected -> connected
conn_tx_kthread: Started for handle 1
bt_smp_connected: conn 0x3fc94d50 handle 1
bt_gatt_connected: conn 0x3fc94d50
                    ← 日志到此为止：无断开、无错误、无任何 ATT 流量
```

即：**连接层完全正常，但 ATT（属性协议）层的交互没有发生。**

**👉 请直接跳到 [`HANDOFF-CURRENT-ISSUE.md`](HANDOFF-CURRENT-ISSUE.md)**，
那里有完整的排查记录、已排除项、和 5 个待验证的假设。

---

## 4. 仓库结构导航

```
├── HANDOFF-AI-ONBOARDING.md      ← 你正在读（项目总览）
├── HANDOFF-REPRODUCE.md          ← 从零复现的完整步骤与精确版本
├── HANDOFF-CURRENT-ISSUE.md      ← ★ 当前阻塞问题的详细记录
├── HANDOFF-INVENTORY.md          ← 文件清单与阅读顺序建议
├── HANDOFF-SCRIPTS-RUNBOOK.md    ← 脚本手册与运维指南（11 个脚本 + 故障速查）
│
├── config/boards/esp32s3-n16r8-generic/
│   ├── defconfig.nsh             ← 最小可启动基线
│   ├── defconfig.psram           ← +8MB PSRAM
│   ├── defconfig.ble             ← +BLE
│   ├── defconfig.blewifi         ← +WiFi 共存
│   ├── defconfig.statusled       ← +WS2812 状态灯
│   ├── defconfig.gattlight       ← +自写 GATT 灯控服务 ★
│   ├── defconfig.gattdebug       ← 同上 + 无线内核日志 ★（排查用）
│   └── src/esp32s3_btsh_ws2812.c ← 板级 WS2812 初始化（上游没有）
│
├── src/app/                      ← ★ 本项目自写的 GATT 灯控服务
│   ├── btsh_light_main.c         ← 主实现（410 行）
│   ├── Kconfig / Makefile / Make.defs
│
├── scripts/
│   ├── build/build-n16r8.sh      ← ★ 构建入口（自动注入必需宏）
│   ├── setup/apply-btsh-*.sh     ← 幂等的"安装到 openvela 树"脚本
│   └── setup/relay_proxy.py      ← Windows 侧 GitHub 代理中继
│
├── thirdparty/patches/           ← ★ 上游 bug 补丁（必需，非可选）
│   ├── 0001-...wireless.patch
│   └── 0002-...spinlock.patch
│
├── docs/
│   ├── stages/                   ← 分阶段开发记录（S0→S3）
│   ├── bringup/wsl-esp32s3-build-notes.md  ← ★ 踩坑全集
│   └── hardware/                 ← 引脚与原理图
│
└── tests/hardware/               ← ★ 实测日志（原始串口记录，最有说服力）
    ├── HT-05/06/07/08-*.md       ← 用例记录
    └── serial-*.txt / *.log      ← 原始日志
```

---

## 5. 三个最容易踩的坑（务必先看）

### 5.1 openvela 上游有两个 bug，不修则**所有** ESP32-S3 配置都编译不过

| 补丁 | 症状 |
| --- | --- |
| `0002-esp-hal-fix-spinlock-initializer.patch` | `error: invalid initializer`（`spinlock_t` 是结构体，但被初始化为标量 `0`） |
| `0001-esp32s3-add-missing-includes-for-wireless.patch` | `undefined reference to 'nxsem_post'`（缺 `#include <nuttx/semaphore.h>`） |

**必须**先跑 `bash scripts/setup/apply-patches.sh`。

详见 [`thirdparty/patches/README.md`](thirdparty/patches/README.md)。

### 5.2 PSRAM 必须显式指定类型，不能用 `TYPE_AUTO`

```c
CONFIG_ESP32S3_SPIRAM_TYPE_ESPPSRAM64=y   /* ✅ 推导出 SPIRAM_SIZE=8388608 */
/* CONFIG_ESP32S3_SPIRAM_TYPE_AUTO=y */   /* ❌ 推导出 SPIRAM_SIZE=-1，启动挂死 */
```

依据 `arch/xtensa/src/esp32s3/Kconfig:940-948`。
如果启动日志停在 `total segments stored 6` 之后就没动静了，就是这个原因。

### 5.3 ESP32-S3 的 BLE 在 openvela 里有一处 **Kconfig 桥接缺口**

`esp-hal-3rdparty/nuttx/esp32s3/include/sdkconfig.h:939` 把 34 个
`CONFIG_BT_CTRL_*` 宏包在 `#ifdef CONFIG_ESPRESSIF_BLE` 里，
但 **`CONFIG_ESPRESSIF_BLE` 的 Kconfig 只存在于 RISC-V 侧**
（`arch/risc-v/src/common/espressif/Kconfig:505`），**Xtensa 侧完全没有**。

后果：不修则 `esp_bt.h` 直接编译失败
（`static assertion failed: "please enable bluetooth in menuconfig..."`）。

**绕过方式（无需改源码树）**：`build.sh` 的 `-e` 可透传编译宏：

```bash
./build.sh <cfg> -e -DCONFIG_ESPRESSIF_BLE=1 -e -DCONFIG_ESPRESSIF_WIFI=1
```

`scripts/build/build-n16r8.sh` **已自动做这件事**（读 defconfig 判断后注入）。

---

## 6. 构建与烧录（最短路径）

```bash
# ---- WSL2 Ubuntu 22.04 内 ----
source ~/.openvela-proxy-env          # GitHub 代理（可选，仅首次拉取需要）

# 1. 打上游补丁（幂等）
bash scripts/setup/apply-patches.sh

# 2. 安装自写应用到 openvela 的 apps 树（幂等）
bash scripts/setup/install-btsh-light.sh
bash scripts/setup/apply-board-ws2812.sh

# 3. 构建（必需宏由脚本自动注入）
bash scripts/build/build-n16r8.sh gattdebug

# ---- Windows 侧烧录（WSL 无法访问串口）----
python -m esptool --chip esp32s3 -p COM4 -b 921600 \
       --before default_reset --after hard_reset \
       write_flash 0x0 nuttx-n16r8-gattdebug.bin
```

完整版（含环境搭建、依赖安装、排错）见
**[`HANDOFF-REPRODUCE.md`](HANDOFF-REPRODUCE.md)**。

---

## 7. 重要设计决策与理由

| 决策 | 理由 |
| --- | --- |
| 用官方 `build.sh` 而非裸 `configure.sh` + `make` | 官方唯一支持的入口；`configure.sh` 会漏掉依赖 |
| defconfig 以官方 `esp32s3-devkit:nsh` 为基底做**最小改动** | 手写全新 defconfig 曾在 Kconfig 阶段失败 |
| 每个能力一个独立 defconfig，**逐步叠加** | 每步只引入一个变量，失败可立即定位 |
| 不用 `btsak` 做灯控，自己写应用 | `btsak` 是调试工具，其广播 AD 数据**有长度字段缺陷**（设备名解析不出）；且 GATT Server **没有 ioctl/NSH 接口**，必须写应用调 `bt_gatt_register()` |
| 板级改动（WS2812）放 `config/boards/.../src/`，用脚本安装 | 不污染 openvela 源码树，可 `--revert`，且改动有版本管理 |
| 物理灯先映射到板载 WS2812 | 用户继电器接线未定，先用板载 RGB 打通 GATT 链路 |
| GATT 用 **16 位 UUID** | NuttX 的 `BT_GATT_PRIMARY_SERVICE()` 宏**内部硬编码 `BT_UUID_16`**，无法声明 128 位服务 UUID |

---

## 8. 已知的上游问题清单（可直接提 issue）

1. **`ESP32S3_SPIRAM_IGNORE_NOTFOUND` 拼写 bug**
   `arch/xtensa/src/esp32s3/esp32s3_start.c:395` 判断的是
   `ESP32S3_SPIRAM_IGNORE_NOTFOUND`（**少了 `CONFIG_` 前缀**），
   导致该 Kconfig 项**永远不生效** —— PSRAM 初始化失败必然 `PANIC()`，没有兜底。

2. **`CONFIG_ESPRESSIF_BLE` Kconfig 缺失**（见 §5.3）

3. **`spinlock_t` 初始化 bug**（补丁 `0002`）

4. **无线源文件缺 include**（补丁 `0001`）

5. **`btsak` 广播 AD 长度字段错误**
   `apps/wireless/bluetooth/btsak/btsak_advertise.c:120-130`：
   `sd[1].len = sizeof("btsak")` 少了 type 那 1 字节，导致设备名解析不出。

6. **`bt bnep0 info` 的 `Free`/`ACL` 字段不反映 LE 连接数**
   排查时若用它判断"是否已连接"会得出**错误结论**（本项目就踩过这个坑）。

---

## 9. 与用户协作的注意事项

- 用户是**中文用户**，所有回复用中文。
- 用户明确要求：**"在开发过程有问题及时向我发出疑问，我给你回答；你不知道的不要自己猜，及时问我。"**
  —— 遇到不确定的事**先问**，不要臆断。
- 用户偏好**分阶段、有据可查**的记录方式（`docs/stages/` 就是为此）。
- 用户**目视确认**是某些验证的唯一手段（如 WS2812 是否真的发光）——
  串口日志无法替代，需主动请用户确认。
- 用户曾要求：**不要破坏性操作 `~/openvela`**（历史上误删过整个 `nuttx` 目录，
  已恢复；教训见 `docs/bringup/wsl-esp32s3-build-notes.md`）。

---

## 10. 下一步建议（优先级排序）

| # | 任务 | 说明 |
| --- | --- | --- |
| **1** | **攻克 GATT 服务发现** | 当前唯一阻塞项，见 [`HANDOFF-CURRENT-ISSUE.md`](HANDOFF-CURRENT-ISSUE.md) |
| 2 | 继电器接入 | 用户已确认：单路、高电平有效、低压直流。需问清**具体引脚**后实现 `bsp_relay` |
| 3 | A7Z 侧对接 | 广播名 `BTSH-LIGHT`，服务 `0xFF00`，命令 `0xFF01` 写 `0x00/0x01` |
| 4 | WiFi 联网 | 需用户提供 SSID/密码才能实测连接 |
| 5 | 多路 / PWM 调光 | 等用户明确需求 |
