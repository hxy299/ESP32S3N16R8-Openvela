# HT-11 — BLE 连接触发固件崩溃复位（★ 根因发现）

- 日期：2026-10-11
- 固件：`nuttx-n16r8-gattlight.bin`（423,816 B）/ `gattdebug`（437,984 B）
- 硬件：ESP32-S3-N16R8 + Windows COM4 + Android 手机（nRF Connect）
- **本文推翻了 `HT-08` 的结论**，请以本文为准

---

## 1. 一句话结论

> **BLE 连接一建立，固件就崩溃复位（`GLITCH_RTC_RST`），
> 复位后重启、重新广播、又被连、又崩 —— 形成 2 秒一轮的死循环。**
>
> 之前观测到的「连接成功但 ACL 数据为 0」，**不是控制器不送数据，
> 而是板子在收到数据之前就已经崩了**。

---

## 2. 关键证据链

### 2.1 现象：崩溃与手机连接尝试严格同步

| 条件 | 观察窗口 | 复位次数 |
| --- | --- | --- |
| 手机蓝牙**开着**、nRF Connect 在尝试连接 | 30 s | **10 次**（每 2 秒一次） |
| 手机蓝牙**开着**、持续尝试 | 40 s | **21 次** |
| **手机蓝牙关闭** | **150 s** | **0 次** ✅ |

**手机一关蓝牙，复位立刻消失。** 这是最直接的因果证据。

### 2.2 现象：崩溃前的日志内容

循环中反复出现的序列：

```
le_conn_complete: status 0 handle 1 role 1 59:B3:DF:13:EE:38 (random)
bt_conn_set_state: disconnected -> connected
conn_tx_kthread: Started for handle 1
bt_smp_connected: conn 0x3fc94d50 handle 1
bt_gatt_connected: conn 0x3fc94d50
                    ← 日志到此为止
ESP-ROM:esp32s3-20210327
rst:0x13 (GLITCH_RTC_RST),boot:0x8 (SPI_FAST_FLASH_BOOT)
                    ← 复位重启
```

即：**链路层连接成功 → GATT 层就绪 → 随即崩溃**。
没有任何 PANIC / Assertion / Backtrace 输出（复位太快，来不及打印）。

### 2.3 对照实验：定位到"哪个固件"会崩

用**同一块板、同一根线、同一个供电口**，只换固件：

| 固件 | 含 BLE | 含 `btsh_light` | 复位 |
| --- | --- | --- | --- |
| `nsh` (207,632 B) | ❌ | ❌ | **0** ✅ |
| `psram` (207,672 B) | ❌ | ❌ | **0** ✅ |
| `statusled` (422,904 B) | ✅ | ❌ | **0** ✅ |
| `gattlight` (423,816 B) | ✅ | ✅ | **频繁崩溃** ❌ |
| `gattdebug` (437,984 B) | ✅ | ✅ | **频繁崩溃** ❌ |

**关键推论 1**：不是供电问题。
`statusled` 同样含 BLE 协议栈，且实测**开着 BLE 广播（射频发射态）
30 秒零复位**，扫描（接收态）也零复位。所以射频功耗不是原因。

**关键推论 2**：不是调试日志问题。
`gattlight` **没有**任何 `CONFIG_DEBUG_WIRELESS_*`，
与 `statusled` 相比**唯一的配置差异**是：

```
diff defconfig.statusled defconfig.gattlight
> CONFIG_BTSH_LIGHT=y
> CONFIG_BTSH_LIGHT_ADV_NAME="BTSH-LIGHT"
> CONFIG_BTSH_LIGHT_LED_DEV="/dev/leds0"
> CONFIG_BTSH_LIGHT_PRIORITY=100
> CONFIG_BTSH_LIGHT_PROGNAME="btsh_light"
> CONFIG_BTSH_LIGHT_STACKSIZE=4096
```

**即：崩溃由本项目自写的 `btsh_light` 应用引入。**

### 2.4 排除：不是 `btsak` 广播路径的问题

在 `statusled` 上用 `bt bnep0 advertise start` 走 NuttX 自带路径广播，
**30 秒零复位**。说明 NuttX 的广播路径本身没问题，
问题出在 `btsh_light` 自己的实现（GATT 服务注册 + 自定义广播数据）。

---

## 3. 因此，`HT-08` 的哪些结论要作废

| `HT-08` / `HANDOFF-CURRENT-ISSUE` 的说法 | 更正 |
| --- | --- |
| 「控制器未通过 VHCI 送上来任何 ACL 数据」 | ⚠️ **观测正确，但归因错误**。ACL 为 0 是因为**板子已崩溃复位**，不是控制器不发 |
| 「问题不在 NuttX host 栈，而在 ESP32 控制器 → VHCI 段」 | ❌ **错误**。真因在 `btsh_light` 应用触发崩溃 |
| 「需要换 Android 测试以排除 Windows 特有问题」 | ✅ 已完成：**Android 同样崩溃**，与中央设备无关 |
| 「gattdebug 的调试日志导致复位」 | ❌ 已排除：`gattlight`（无调试日志）同样崩溃 |

**仍然有效的结论**：
- BLE 控制器、host 栈（HCI/L2CAP/ATT/GATT）四层代码本身是好的
- 广播、扫描、连接建立（`le_conn_complete: status 0`）都正常
- 排除项 1–9、11–14（句柄、MAX_CONN、MTU、AD 格式、流控等）仍然成立

---

## 4. ★★ 崩溃根因（已定位并修复）

### 4.1 根因：`BT_GATT_CCC` 的第 3 个参数类型错误

**问题代码**（`src/app/btsh_light_main.c` 修改前）：

```c
static uint16_t g_state_ccc;                    /* ← 只有 2 字节 */

BT_GATT_CCC(BTSH_STATE_CCC_HANDLE, BTSH_STATE_VAL_HANDLE,
            &g_state_ccc, NULL),                /* ← 传了标量地址 */
```

**为什么必崩**——看 `bt_gatt.h:316-330` 的宏展开：

```c
#define BT_GATT_CCC(_handle, _value_handle, _cfg, _cfg_changed) \
{ \
  ... \
  .read      = bt_gatt_attr_read_ccc, \
  .write     = bt_gatt_attr_write_ccc, \
  .user_data = (&(struct _bt_gatt_ccc_s) \
               { \
                 .cfg          = _cfg,           /* ← 当成指针数组用 */ \
                 .cfg_len      = nitems(_cfg),   /* ← 当成数组取元素数 */ \
                 ...
```

而 `struct _bt_gatt_ccc_s`（`bt_gatt.h:588`）是：

```c
struct _bt_gatt_ccc_s
{
  FAR struct bt_gatt_ccc_cfg_s *cfg;   /* 8 字节指针 */
  size_t cfg_len;                      /* 8 字节 */
  uint16_t value;
  uint16_t value_handle;
  CODE void (*cfg_changed)(uint16_t);
};
```

`bt_gatt_attr_read_ccc()`（`bt_gatt.c:230`）**第一件事**就是：

```c
FAR struct _bt_gatt_ccc_s *ccc = attr->user_data;
for (i = 0; i < ccc->cfg_len; i++)          /* 读 size_t */
  {
    if (bt_addr_le_cmp(&ccc->cfg[i].peer, &conn->dst))   /* 解引用指针 */
```

把 2 字节的 `uint16_t` 当成含指针的结构体解引用 →
`cfg` 里是垃圾值（实际是相邻静态变量）→ 访问非法地址 → **复位**。

**时机完全吻合**：客户端连接后第一次读/写 CCC（即订阅 Notify、
或 Windows/Android 在服务发现时读取 CCC 描述符）时触发。

### 4.2 修复

```c
/* 正确写法：给一个配置项数组（对应"每个对端一份订阅配置"） */
static struct bt_gatt_ccc_cfg_s g_state_ccc_cfg[CONFIG_BLUETOOTH_MAX_PAIRED];

/* 属性表里传数组，不传 &标量 */
BT_GATT_CCC(BTSH_STATE_CCC_HANDLE, BTSH_STATE_VAL_HANDLE,
            g_state_ccc_cfg, NULL),
```

> 📌 **注意**：NuttX 全树**没有任何 `BT_GATT_CCC` 的使用范例**
> （`grep -rn "BT_GATT_CCC(" nuttx/ --include=*.c` 无结果，
> 上游 `bt_services.c` 的 GAP 服务只有只读特征，不含 CCC）。
> 上面的宏展开是**唯一的权威依据**。这也是本项目踩到这个坑的原因 ——
> 没有可参照的正确用法。

### 4.3 修复验证（✅ 已通过）

修复后重新构建烧录（`nuttx-n16r8-gattdebug.bin`，437,984 B），
用 **Android nRF Connect 连了 3 次**，日志：

```
  >> 连接: le_conn_complete: status 0 handle 1 role 1 7C:53:C7:63:31:64 (random)
  >> GATT 就绪
  [ 60s] 复位=0 连接=1 GATT=1 ACL包=0 L2CAP=0 ATT=0
  >> 连接: le_conn_complete: status 0 handle 1 role 1 7C:53:C7:63:31:64 (random)
  >> GATT 就绪
  [ 90s] 复位=0 连接=2 GATT=2 ACL包=0 L2CAP=0 ATT=0
  >> 连接: le_conn_complete: status 0 handle 1 role 1 7C:53:C7:63:31:64 (random)
  >> GATT 就绪
  [120s] 复位=0 连接=3 GATT=3 ACL包=0 L2CAP=0 ATT=0
```

| 指标 | 修复前 | 修复后 |
| --- | --- | --- |
| 连接时的复位 | **每 2 秒一次**（GLITCH_RTC_RST 循环） | **0** ✅ |
| `le_conn_complete` | 有，但随即崩溃 | ✅ 正常，且可重复 |
| `bt_gatt_connected` | 有，随即崩溃 | ✅ 正常 |
| 用户观测（nRF Connect） | 点 CONNECT 后板子反复重启 | 能连上（但仍会断开） |

**结论：CCC 类型错误确实是崩溃根因，修复有效。**

---

## 4.4 ⚠️ 崩溃修好后，ACL 缺失问题依然存在

修掉崩溃之后，**`ACL包=0 / L2CAP=0 / ATT=0` 依然成立**。

也就是说：**下一节（§4.5）描述的「控制器不通过 VHCI 送 ACL 数据」
是一个独立于崩溃的真实问题**，不是崩溃的副产品。

> 📌 我在本轮中途曾误判为「ACL 缺失完全由崩溃导致」，
> 现已更正：**两个问题是独立的，崩溃已修复，ACL 问题待解**。

### 已排除的 ACL 相关怀疑点（新增）

| # | 怀疑点 | 排除依据 |
| --- | --- | --- |
| 15 | 控制器→主机流控被禁用 | `# CONFIG_BLUETOOTH_CNTRL_HOST_FLOW_DISABLE is not set`（未禁用）；源码 `bt_hcicore.c:1443-1447` 展开为 `*enable = 1`（**已启用**） |
| 16 | `Set Ctl→Host Flow Control` 的参数值错 | 同上，值为 1 ✓ |
| 17 | `Host Buffer Size` 参数不合理 | `acl_pkts=20`、`acl_mtu=68`，均为合理值，控制器回 `cmd_complete` ✓ |
| 18 | `le_conn_complete()` 之后漏发 HCI 命令 | 读实现：它只更新连接对象状态并调用 `bt_l2cap_connected()` / `bt_connected()`，**本就不需要发命令** ✓ |
| 19 | 崩溃导致 ACL 收不到 | 崩溃已修复，ACL 仍为 0 —— **两问题独立** ✓ |

### 用户侧观测（重要线索）

Android nRF Connect 显示：**能看到 `BTSH-LIGHT`，点 CONNECT 后立即断开**。

即链路层能建立（`le_conn_complete: status 0`），但**服务发现无法完成**，
与「无 ATT 流量」一致。

### 剩余方向

| # | 方向 | 说明 |
| --- | --- | --- |
| C | 对照 ESP-IDF 的 `hci_driver_standard.c` | 本机 esp-hal 里有该文件（`components/bt/porting/transport/driver/vhci/`），检查 VHCI 传输层是否还有必需步骤 |
| D | 调 `CONFIG_BT_CTRL_*` 静态参数 | 这些值来自 esp-hal 的静态 `sdkconfig.h`（如 `CONFIG_BT_CTRL_HCI_TL_EFF=1`），未必匹配 NuttX 的用法 |
| E | 换 ESP32-C3 等平台对比 | 该芯片的 `ESPRESSIF_BLE` Kconfig 是完整的（见 `HANDOFF-AI-ONBOARDING.md` §5.3），可判断是否 ESP32-S3 特有 |
| F | 用 ESP-IDF 烧同一块板验证硬件 | 若 ESP-IDF 下 BLE 正常，则确认是 NuttX 侧问题 |

---

## 5. 崩溃原因排查过程（备查）

崩溃发生在**连接建立之后极短的时间内**，且无 PANIC 输出。
按可能性排序的怀疑方向，以及最终结论：

| # | 怀疑方向 | 结论 |
| --- | --- | --- |
| 1 | 广播数据/服务表越界 | ❌ 排除（数据构造正确） |
| **2** | **GATT 属性表 `user_data` 类型不匹配** | ✅ **命中 —— CCC 参数类型错误** |
| 3 | 栈溢出（`STACKSIZE=4096`） | ❌ 未触发（真因已找到） |
| 4 | `bt_gatt_notify()` 在无 CCC 配置时调用 | ❌ 是同一根因的表象 |

**为什么能定位到方向 2**：CCC 的读写正好发生在
「连接建立 → 服务发现 / 订阅」阶段，与崩溃时机严格吻合；
且 `BT_GATT_CCC` 的第 3 参数是**唯一一处**由宏做隐式类型转换
（`_cfg` → 指针）而我传了标量地址的地方。

---

## 5. 复现方法

```bash
# 1. 烧 gattlight
python -m esptool --chip esp32s3 -p COM4 -b 921600 \
       --before default_reset --after hard_reset \
       write_flash 0x0 nuttx-n16r8-gattlight.bin

# 2. 板上启动服务（★ 必须做，否则不广播）
nsh> btsh_light start

# 3. 用手机 nRF Connect 连接 BTSH-LIGHT
#    预期：连接后 2 秒内板子复位，串口出现
#      rst:0x13 (GLITCH_RTC_RST)

# 4. 对照：关掉手机蓝牙，复位立即停止
```

**判定标准**：串口 30 秒内出现 ≥10 次 `rst:0x13` 即为复现。

---

## 6. 原始日志

- [`serial-crash-on-connect.log`](serial-crash-on-connect.log)
- [`serial-android-connect.log`](serial-android-connect.log)
- [`serial-android-reset-check.log`](serial-android-reset-check.log)
- [`serial-power-isolation.log`](serial-power-isolation.log)
- [`serial-gattlight-reset-check.log`](serial-gattlight-reset-check.log)
- [`serial-vhci-debug.log`](serial-vhci-debug.log)
