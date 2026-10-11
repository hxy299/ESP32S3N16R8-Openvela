# ⚠️ 阶段四最终状态：NimBLE 路线未走通（含完整技术依据）

- 日期：2026-10-11
- **重要：本文如实记录失败，不粉饰。** 便于后续接手判断投入产出。

---

## 一、结论

**NimBLE 路线在 openvela/ESP32-S3 上未能走通。**

具体卡点：**NimBLE host 无法与 ESP32-S3 控制器完成同步**
（`ble_hs_cfg.sync_cb` 从未被调用），
`nimble_port_init()` 之后的线程启动/同步流程卡死，导致 NSH 阻塞。

**根本障碍**：NimBLE 的 NuttX 移植层使用 **socket 传输**
（`BLE_TRANSPORT_LL: socket`，见
`mynewt-nimble/porting/targets/nuttx/syscfg.yml:20`），
它假设 NuttX 有一个 **HCI socket 设备**可以对接到控制器。
但本树里：

| 检查项 | 结果 |
| --- | --- |
| NuttX 的 HCI socket 支持（`BTPROTO_HCI` / `HCI_CHANNEL_RAW`） | ✅ 头文件与 `net/bluetooth/` 都在 |
| **谁把 ESP32 控制器的数据喂给 HCI socket** | ❌ **没有找到** |
| `arch/xtensa/src/esp32s3/` 里 NimBLE 相关代码 | ❌ 零（`ls \| grep nimble` 为空） |
| 任何架构/芯片接 NimBLE 的 `Make.defs` | ❌ 零（`grep -rln NIMBLE arch/*/src/*/Make.defs` 为空） |

**即：openvela 当前树里没有任何芯片真正对接过 NimBLE。**
`apps/wireless/bluetooth/nimble/` 只是一个**源码容器 + 残缺示例**，
不是可用的集成。

---

## 二、走过的完整路径（供后人省力）

### 2.1 已成功的部分

| 步骤 | 结果 |
| --- | --- |
| 让 NimBLE 在 ESP32-S3 上编译 | ✅ 解决 `SIGEV_THREAD` 缺开关问题（`CONFIG_SIG_EVTHREAD=y`） |
| 让 NimBLE 协议栈在板上运行 | ✅ 用自带示例：`port init` / `gap init` / `gatt init` 全部成功，`hci_sock task init` + `ble_host task init` 都打印，**复位 0 次** |
| 写出自己的 GATT 灯控应用 | ✅ `src/app/nimble/btsh_light_main.c`（约 700 行，完整） |
| 让应用编译进固件、注册名正确 | ✅ `Register: nimble_light`，无重复符号 |

> 注：运行示例时 `hci_sock task init` 能打印，是因为示例只**启动任务**、
> 不去等 host 同步；而我们的应用需要 host 真正同步才能注册 GATT 服务，
> 于是暴露出同步失败的问题。

### 2.2 逐个攻克的集成问题（都有解决方案，已固化在脚本/配置里）

| # | 问题 | 现象 | 解决 |
| --- | --- | --- | --- |
| 1 | `SIGEV_THREAD` 未开启 | `os_callout.c:105: error: 'SIGEV_THREAD' undeclared` | defconfig 加 `CONFIG_SIG_EVTHREAD=y` |
| 2 | **选错 `syscfg.h`** | `ble_hci_socket.c:60: error: expected expression before 'int'`（`_IOW` 未定义） | `INC` 里把 `porting/examples/nuttx/include` 排**最前**，让 `BLE_SOCK_USE_NUTTX=1` 生效（另一份默认给 Linux，值为 0） |
| 3 | 协议栈被编两遍 | `multiple definition of 'ble_sm_alg_s1'` | 只让**一处**掌握 `CSRCS`/`MAINSRC` |
| 4 | `CSRCS` 全局变量污染 | 同上 | 不要在两个 app 里都设 `CSRCS` |
| 5 | 应用目录被 NuttX 自动编译 | 对象重复 | 从 `CONFIGURED_APPS` 移除应用目录（`Make.defs` 留空） |
| 6 | `syslog()` 阻塞 | 第一行 `printf` 后整个 NSH 卡死 | defconfig 加 `CONFIG_SYSLOG_CONSOLE=y`（`SYSLOG_BUFFER=y` 只开缓冲、无输出通道） |
| 7 | **`ble_gatts_add_svcs()` 阻塞** | 串口停在 `BTSH[5] gatts_add_svcs`，NSH 卡死 | 必须移到 `sync_cb` 里调用（host 同步后），不能在 `nimble_port_init()` 之前 |

**经验**：`ble_gatts_add_svcs()` / `ble_gatts_count_cfg()` 必须在
host 与控制器同步完成之后调用，否则**永久阻塞**（不是返回错误）。

### 2.3 最终未能跨越的障碍

修完上述 7 项后，当前行为（`nuttx-n16r8-nimblelight.bin`，MD5 `6a11b6df…`）：

```
nsh> nimble_light
BTSH: starting NimBLE light service...
BTSH[1] enter start
BTSH[2] opening LED /dev/leds0
BTSH[3] open rc=3                    ← LED 正常
BTSH[4] setting host callbacks
BTSH[5] nimble_port_init
BTSH[8] nimble port initialized      ← 这一步返回了
BTSH[9] set name rc=0
BTSH[10] creating hci thread
BTSH[11] hci thread created
BTSH[12] creating host thread
BTSH[13] host thread created, applying light
BTSH: light OFF
BTSH[14] start() returning 0
BTSH: started. Use 'nimble_light state' to check.
                                      ← 此后完全静默
                                      ← `nimble_light state` 也无响应 = NSH 阻塞
```

**缺失的关键打印**：
- `BTSH: host thread started`（`btsh_host_thread` 内）
- `BTSH: hci sock thread started`（`btsh_hci_thread` 内）
- `BTSH[S1] on_sync enter`（**`sync_cb` 从未被调用**）

**推断**：两个 pthread 已创建但未能正常进入函数体（或进入后立刻阻塞），
且 host 从未与控制器同步。可能原因：
- `ble_hci_sock_ack_handler()` 在等 socket 数据，而 socket 那头无人送
- `nimble_port_run()` 等事件队列，而同步事件永远不会来

**这与 §1 的判断一致**：没有东西把 ESP32 控制器的 HCI 数据喂给这个 socket。

---

## 三、给后续接手者的建议（按可行性排序）

### 建议 1（推荐）：放弃 NimBLE，回头修 NuttX 原生 host 的 ACL 问题

理由：
- NuttX 原生 host **至少能跑**（广播、连接建立都成功），
  只差 ACL 数据不通（ACL=0）
- 而 NimBLE 连 host 同步都做不到，**离可用更远**
- 原生 host 的问题已被**精确锁定**在「控制器不通过 VHCI 送 ACL」
  （VHCI 回调入口插桩实测），且已排除 21 个可能
- 剩余怀疑点集中：`CONFIG_BT_CTRL_*` 静态参数与 NuttX 用法不匹配

**两条具体线索**：
1. 在 ESP32-C3（RISC-V）上跑同一套 NuttX 原生 BLE 代码。
   该芯片的 `CONFIG_ESPRESSIF_BLE` Kconfig 是**完整的**
   （`arch/risc-v/src/common/espressif/Kconfig:505`），
   而 Xtensa(ESP32-S3) 侧缺失 → 强烈暗示 S3 支持不完整。
   C3 正常而 S3 异常即可定位到 S3 特有的缺口。
2. 逐项对比 NuttX 与 ESP-IDF 的控制器初始化序列
   （ESP-IDF 用同一控制器实测**完全正常**，其 `esp_bt_controller_init`
   的参数与调用顺序可直接对照）。

### 建议 2：改用 ESP-IDF 的 NimBLE 作为 NuttX 的 host

工程量最大，但 ESP-IDF 已实测可用（拿到 4 个 GATT 服务）。
需要把 ESP-IDF 的 NimBLE + VHCI controller glue 移植到 NuttX。

### 建议 3：绕开 BLE，先用 WiFi 实现远程点灯

WiFi 已验证可用（`wapi scan` 扫到 5 个真实 AP）。
项目最终目标是「远程点灯」，WiFi/TCP 能更快达成，
BLE 可作为后续升级。

---

## 四、本次投入产出总结

**产出（都是真实、可复用的）**：

| 产出 | 价值 |
| --- | --- |
| ESP-IDF 对照实验（完整证据链） | **定性了问题归属**：硬件正常，NuttX host 栈有问题 |
| `BT_GATT_CCC` 崩溃根因 + 修复 | 修掉一个真实 bug（连接即崩溃），原生 host 路线受益 |
| 21 项排除清单 | 把原生 host 的问题压缩到极小范围 |
| 7 项 NimBLE 集成问题的解决方案 | 若将来有人走这条路，可直接复用 |
| `btsh_light_main.c`（700 行，NimBLE 版） | GATT 服务定义完整，逻辑可直接移植到别的 host |
| 完整文档与脚本 | 见下 |

**教训（已写入各处注释与文档）**：
1. 我在未验证 "NimBLE 在 NuttX 上是否真的被集成过" 的情况下就推荐了这条路线。
   正确做法：先 `grep -rln NIMBLE arch/*/src/*/Make.defs`（结果为空），
   5 秒就能发现没有任何芯片对接过 NimBLE。
2. 多次过早下结论（先说"控制器不送 ACL = 控制器缺陷"，
   后又说"ACL 缺失是崩溃导致"），都是**未做对照实验就归因**。
   有效的做法始终是：**同一变量、只改一处、实测对照**。

---

## 五、相关文件索引

| 文件 | 说明 |
| --- | --- |
| [`src/app/nimble/btsh_light_main.c`](../../src/app/nimble/btsh_light_main.c) | ✅ 完整 GATT 灯控应用（NimBLE API，700 行，注释详尽） |
| [`src/app/nimble/Kconfig`](../../src/app/nimble/Kconfig) | 应用配置项 |
| [`scripts/setup/install-btsh-light-nimble.sh`](../../scripts/setup/install-btsh-light-nimble.sh) | 安装脚本（含 `--check` / `--revert`） |
| [`config/.../defconfig.nimble`](../../config/boards/esp32s3-n16r8-generic/defconfig.nimble) | ✅ NimBLE 配置（示例模式，能跑） |
| [`config/.../defconfig.nimblelight`](../../config/boards/esp32s3-n16r8-generic/defconfig.nimblelight) | ⚠️ 目标配置（构建通过，运行卡在 host 同步） |
| [`HANDOFF-CURRENT-ISSUE.md`](../../HANDOFF-CURRENT-ISSUE.md) | NuttX 原生 host 的 ACL 问题（**建议从这里继续**） |
| `assets/firmware/nuttx-n16r8-nimblelight.bin` | 421,672 B（当前板上固件） |
| `assets/firmware/nuttx-n16r8-gattlight.bin` | NuttX 原生 host 版（含 CCC 修复，能广播能连，ACA 不通） |
