# Stage 04 — 改用 NimBLE 作为 BLE Host（进行中）

- 日期：2026-10-11
- 状态：🚧 **进行中**
- 前置阶段：[stage-03-peripherals.md](stage-03-peripherals.md)
- 问题记录：[`../../HANDOFF-CURRENT-ISSUE.md`](../../HANDOFF-CURRENT-ISSUE.md)

---

## 1. 为什么必须换 host 栈

### 1.1 已确认的事实（决定性对照实验）

**同一块板、同一根线、同一个 USB 口、同一套供电**，只换固件：

| 检查项 | **ESP-IDF v5.3.1 + NimBLE** | **openvela / NuttX 原生 host** |
| --- | --- | --- |
| 控制器初始化 | ✅ `compile version [aa16a46]` | ✅ `compile version [0738a61]` |
| 蓝牙 MAC | `e0:72:a1:f2:8f:ea` | `e0:72:a1:f2:8f:ea`（同一） |
| PSRAM | ✅ 8MB, `SPI SRAM memory test OK` | ✅ 8MB |
| 广播 / 被扫到 | ✅ `nimble-bleprph` RSSI -18 | ✅ `BTSH-LIGHT` RSSI -20 |
| 建立连接 | ✅ | ✅ `le_conn_complete: status 0` |
| **GATT 服务发现** | **✅✅ 拿到 4 个服务** | **❌ 超时** |

→ **硬件与 ESP32-S3 控制器完全正常。问题在 NuttX 自带的 BLE host 栈。**

### 1.2 根因定位过程

在 VHCI 回调入口（`esp32s3_ble_recv_cb()`）插桩实测，连接全程：

```
H4_EVT (事件): 正常收到
H4_ACL (数据): 恒为 0        ← 关键
```

即：**控制器从不把 ACL 数据通过 VHCI 送上来**，
导致 HCI → L2CAP → ATT → GATT 四层全部收不到东西。

**累计排除 21 个可能**，逐段读源码确认无缺陷：

| 环节 | 文件 | 结论 |
| --- | --- | --- |
| HCI 初始化 | `bt_hcicore.c:1275+` | ✅ status 0 |
| ACL 流控使能 | `bt_hcicore.c:1443-1447` | ✅ `*enable = 1` |
| Host Buffer Size | `bt_hcicore.c:1421-1432` | ✅ mtu=68, pkts=20 |
| `le_conn_complete()` | `bt_hcicore.c:682` | ✅ 无需发命令 |
| 低功耗唤醒 | `esp32s3_ble_adapter.c:2784` | ✅ 睡眠已禁用，直接返回 |
| **VHCI 传输层** | `hci_driver_standard.c:117` | ✅ **无条件转发，无过滤** |
| 包类型映射 | `esp32s3_ble.c:133` | ✅ `H4_ACL→BT_ACL_IN` |
| 控制器 HCI 模式 | `sdkconfig.h` | ✅ `HCI_MODE_VHCI=1` |
| L2CAP / ATT / GATT 层 | `bt_l2cap.c` `bt_att.c` `bt_gatt.c` | ✅ 代码无缺陷 |

### 1.3 旁证：openvela 对 ESP32-S3 的 BLE 支持不完整

`CONFIG_ESPRESSIF_BLE` 的 Kconfig 定义**只在 RISC-V 侧存在**：

```
arch/risc-v/src/common/espressif/Kconfig:505   ← 有（ESP32-C3）
arch/xtensa/src/common/espressif/Kconfig       ← 没有 ESPRESSIF_BLE
```

而 `esp-hal` 的 `sdkconfig.h:939` 用它来开关 34 个 `CONFIG_BT_CTRL_*` 宏。
本项目只能靠 `-DCONFIG_ESPRESSIF_BLE=1` 绕过编译（见
[`build-n16r8.sh`](../../scripts/build/build-n16r8.sh)）。

**ESP32-C3 有完整的 `ESPRESSIF_BLE` Kconfig 与 `Make.defs` 接线，
ESP32-S3 侧缺失 —— 二者不是同等程度的支持。**

---

## 2. 方案：改用 NimBLE

### 2.1 为什么 NimBLE 是最优解

**NuttX 官方已支持 NimBLE**，且已接进配置系统：

```
apps/wireless/bluetooth/nimble/Kconfig:

config NIMBLE
    bool "Apache NimBLE (BLE host-layer)"
    default n
    depends on !WIRELESS_BLUETOOTH_HOST     ← 与 NuttX 原生 host 二选一
```

**外设角色（GATT Server）是现成选项**：

```
config NIMBLE_ROLE_PERIPHERAL    bool "NimBLE peripheral role"
config NIMBLE_ROLE_CENTRAL       bool "NimBLE central role"
config NIMBLE_ROLE_BROADCASTER   bool "NimBLE broadcaster role"
config NIMBLE_ROLE_OBSERVER      bool "NimBLE observer role"
```

**成功率高的理由**：
1. ESP-IDF 下已实测：**同一块板 + 同一控制器 + NimBLE = 完全正常**
   （完整枚举出 4 个 GATT 服务）
2. NuttX 这个移植用的是**同一个上游 NimBLE 源码**
   （`NIMBLE_REF = 6a5a16c7c0fab0fe7e95154493ff1fe9f0824fe3`）

### 2.2 代价（必须如实说明）

| 项 | 影响 |
| --- | --- |
| **应用层要重写** | 现有 `src/app/btsh_light_main.c`（410 行）基于 **NuttX 原生 GATT API**（`bt_gatt_register()` 等），改用 NimBLE 后**必须重写为 NimBLE API**（`ble_gatts_add_svcs()` / `ble_gap_adv_start()` 等） |
| **构建要下载源码** | NimBLE 从 GitHub 拉取，需要可用通道（本机有 relay proxy） |
| **`btsak` 不可用** | `btsak` 依赖 NuttX 原生 host；改用 NimBLE 后失去这个调试工具 |

### 2.3 保留的成果

以下**不受影响**，继续可用：
- PSRAM（8MB）、WiFi、WiFi+BLE 共存配置
- 板载 WS2812B 状态灯（`/dev/leds0`）
- 全部构建脚本、板级补丁、上游 bug 补丁
- `BT_GATT_CCC` 崩溃的修复经验（新实现要注意同样的类型陷阱）

---

## 3. 已发现的 NimBLE 配置项

| 配置项 | 说明 |
| --- | --- |
| `CONFIG_NIMBLE` | 总开关（须 `!WIRELESS_BLUETOOTH_HOST`） |
| `CONFIG_NIMBLE_REF` | 默认 `6a5a16c7c0fab0fe7e95154493ff1fe9f0824fe3` |
| `CONFIG_NIMBLE_ROLE_PERIPHERAL` | **GATT Server 必需** |
| `CONFIG_NIMBLE_ROLE_CENTRAL` | Central 角色（可选） |
| `CONFIG_NIMBLE_CALLOUT_THREAD_STACKSIZE` | 默认 `DEFAULT_TASK_STACKSIZE` |
| `CONFIG_NIMBLE_BLE_VERSION_50..53` | 默认 5.0 |
| `CONFIG_NIMBLE_TINYCRYPT` | 默认 y |
| `CONFIG_NIMBLE_DEBUG_ERROR/WARN/INFO` | 调试输出（在 `DEBUG_FEATURES` 下） |

---

## 4. 待办

- [ ] 读清 `apps/wireless/bluetooth/nimble/` 的构建机制（源码怎么下载、怎么编译）
- [ ] 新建 `defconfig.nimble`（关掉 `WIRELESS_BLUETOOTH_HOST`，开 `NIMBLE` + 外设角色）
- [ ] 构建通过
- [ ] 写最小 GATT Server 应用（NimBLE API）
- [ ] 实测：能被扫描到 + **GATT 服务发现成功**（这是关键判据）
- [ ] 把灯控逻辑接到新的 GATT 服务上

---

## 5. 判据

**成功标准**（与之前 NuttX 原生 host 的失败形成对照）：

| # | 判据 |
| --- | --- |
| 1 | 固件启动无 PANIC |
| 2 | 手机 nRF Connect 能扫到设备 |
| 3 | 能建立连接且**不崩溃** |
| 4 | **GATT 服务发现成功，列出自定义服务与特征** ← 决定性 |
| 5 | 写特征值能点亮/熄灭板载 RGB |

---

## 6. 记录

### 6.1 ✅ 里程碑一：NimBLE 在 ESP32-S3 上成功运行

**构建成功**（`defconfig.nimble`，422,144 B）：

```
Register: nimble          ← NimBLE 应用注册进 NSH
```

**实机运行成功**（串口实测）：

```
nsh> nimble
port init            ← NimBLE 协议栈初始化成功
gap init / gatt init
ans init / ias init / lls init / tps init
hci_sock task init   ← ★ HCI socket 传输层启动
ble_host task init   ← ★ host 任务启动
hci sock task
host task

PANIC: 0    复位: 0     ← 完全稳定
```

**这一步的意义**：
- NimBLE host 栈在 ESP32-S3 上**能正常运行**
- **HCI socket 传输层建立成功** —— 这正是之前 NuttX 原生 host 死掉的地方
- 证明「换 host 栈」这条路在架构上是通的

### 6.2 构建过程中解决的一个配置问题

首次构建失败：

```
os_callout.c:105: error: 'SIGEV_THREAD' undeclared
os_callout.c:107: error: 'struct sigevent' has no member named 'sigev_notify_function'
```

**原因**：NimBLE 的 NuttX 移植层（`porting/npl/nuttx/src/os_callout.c`）
用 POSIX 的 `SIGEV_THREAD` 做定时器回调，而 NuttX 需要显式开启。

**修复**：defconfig 加 `CONFIG_SIG_EVTHREAD=y`
（`sched/Kconfig:1740`，依赖 `!BUILD_KERNEL && SCHED_WORKQUEUE`，均已满足）。

> 📌 这是个好信号：**移植层代码本身没坏，只是缺一个开关**。

### 6.3 ⚠️ 里程碑二：示例应用不完整，需要自己写

**发现的问题**：NimBLE 自带的 NuttX 示例
（`porting/examples/nuttx/main.c`）是**残缺的**：

| 问题 | 说明 |
| --- | --- |
| **没有启动广播** | `ble.c` 里有完整的 `start_advertise()` / `update_ad()` / `gap_event_cb`，且**已被编入构建**（`Make.defs:37`），但 `main()` **从未调用它** —— 所以设备扫描不到 |
| **没设置 `ble_hs_cfg.sync_cb`** | 对比官方 `apps/bleprph/src/main.c:319` 有 `ble_hs_cfg.sync_cb = bleprph_on_sync`。缺少它，host 同步完成后没有回调去启动广播 |

**实验**：手工给示例补上广播调用（`btsh_start_advertise()` 包装）
→ 广播能启动，但**随即触发断言崩溃**（`Assertion failed`），
印证了「示例状态机不完整」的判断。

**结论**：**不能直接用这个示例**。必须自己写应用，
以官方 `apps/bleprph/src/main.c` + `gatt_svr.c` 为蓝本。

### 6.4 下一步（已明确）

写项目自己的 NimBLE 应用，替代残缺的示例。参照官方 `bleprph`：

| 要做的事 | 参照 |
| --- | --- |
| `ble_hs_cfg.sync_cb` 设为启动广播的函数 | `apps/bleprph/src/main.c:319` + `bleprph_on_sync()` |
| `ble_gap_adv_set_fields()` 设置广播数据 | `apps/bleprph/src/main.c:131` |
| `ble_gap_adv_start()` 启动广播 | `apps/bleprph/src/main.c:141` |
| GAP 事件回调（连接/断开/订阅） | `apps/bleprph/src/main.c` 的 `bleprph_gap_event()` |
| 自定义 GATT 服务（灯控） | `apps/bleprph/src/gatt_svr.c` |

**关键 API（NimBLE 风格，与 NuttX 原生完全不同）**：

```c
ble_gatts_add_svcs(svcs);                      // 注册服务
ble_gatts_count_cfg(svcs);
ble_gattc_notify_custom(conn_handle, val_handle, om);  // Notify
ble_gap_adv_start(own_addr_type, NULL, BLE_HS_FOREVER,
                  &adv_params, gap_event_cb, NULL);    // 启动广播
```

**判据**（与之前 NuttX 原生 host 的失败形成对照）：

| # | 判据 | 状态 |
| --- | --- | --- |
| 1 | 启动无 PANIC | ✅ 已验证（示例本身能跑） |
| 2 | 手机能扫到设备 | ⏳ |
| 3 | 连接不崩溃 | ⏳ |
| 4 | **GATT 服务发现成功** ← 决定性 | ⏳ |
| 5 | 写特征值点亮板载 RGB | ⏳ |

### 6.5 产出的配置

| 文件 | 说明 |
| --- | --- |
| [`defconfig.nimble`](../../config/boards/esp32s3-n16r8-generic/defconfig.nimble) | NimBLE 配置（关原生 host，开 NIMBLE + 外设角色 + SIG_EVTHREAD） |
| `assets/firmware/nuttx-n16r8-nimble.bin` | 422,172 B，MD5 `838da6ab…` |

### 6.6 附：示例广播补丁（验证用，非最终方案）

为验证「广播能否启动」，临时给示例打了补丁：

- `porting/examples/nuttx/main.c`：插入 `btsh_start_advertise()` 调用
- `porting/examples/nuttx/ble.c`：追加包装函数导出 `start_advertise()`

> ⚠️ 这是**临时验证手段**。NimBLE 源码目录（`mynewt-nimble`）是
> 构建时下载的、已被 `.gitignore` 忽略，补丁**不会被版本管理**。
> 正式实现应写成项目自己的 app（见 §6.4）。
> 备份文件：`main.c.btsh-orig`
