# 当前阻塞问题 — GATT 服务发现失败

> **这是本项目唯一未解决的技术问题。** 本文提供完整现象、已排除项、
> 和待验证的假设，供接手者直接继续，无需重复我走过的路。

---

## 1. 现象（一句话）

**ESP32-S3 能广播、能被扫描到、BLE 连接能建立成功，
但中央设备（Windows / bleak）的服务发现 `get_services()` 会超时。**

---

## 2. 分层验证结果（逐层实测）

| 层 | 状态 | 证据 |
| --- | --- | --- |
| 射频 / 控制器 | ✅ 正常 | `bt bnep0 scan get` 扫到 5 个真实 BLE 设备 |
| 广播（Advertising） | ✅ 正常 | Windows 扫到 `E0:72:A1:F2:8F:EA`，RSSI -20 |
| 广播数据（AD 结构） | ✅ 正常 | 设备名 `BTSH-LIGHT` 被**正确解析**（对比 `btsak` 解析不出） |
| GATT 服务注册 | ✅ 正常 | 板上输出 `service 0xff00 registered (8 attrs)` |
| **ACL 连接建立** | ✅ **正常** | `le_conn_complete: status 0 handle 1 role 1` |
| SMP 层 | ✅ 已连接 | `bt_smp_connected: conn 0x3fc94d50 handle 1` |
| GATT 层 | ✅ 已连接 | `bt_gatt_connected: conn 0x3fc94d50` |
| **ATT 层交互** | ❌ **无任何流量** | 日志在 `bt_gatt_connected` 后**完全静默** |
| 服务发现 | ❌ 超时 | Windows `asyncio.TimeoutError` |

---

## 3. 关键日志（原始证据）

内核日志打开方式见 §7。完整日志文件：
- `tests/hardware/serial-gattdebug-connect.log`
- `tests/hardware/serial-gattdebug-connect2.log`

### 3.1 广播阶段 —— HCI 命令全部正常

```
bt_hci_cmd_create: opcode 200a param_len 1     ← LE_SET_ADV_ENABLE
bt_hci_cmd_send_sync: opcode 200a len 4
hci_cmd_complete: opcode 200a                  ← 控制器正常回应

bt_hci_cmd_create: opcode 2008 param_len 32    ← LE_SET_ADV_DATA
bt_hci_cmd_create: opcode 2009 param_len 32    ← LE_SET_SCAN_RSP_DATA
bt_hci_cmd_create: opcode 2006 param_len 15    ← LE_SET_ADV_PARAMETERS
```

> `hci_cmd_complete: Unhandled opcode XXXX` 是**正常的** ——
> 表示该命令完成事件无需特殊处理，不是错误。

### 3.2 连接建立 —— 完全成功

```
hci_event: event 62                                     ← LE Meta 事件
bt_buf_consume: buf 0x3fc952a4 len 2
bt_buf_consume: buf 0x3fc952a4 len 1
le_conn_complete: status 0 handle 1 role 1 7C:FA:80:EF:CE:2B (public)
                  ^^^^^^^^         ^^^^^^ ^^^^^^
                  status=0 成功    句柄1   role=1 (peripheral，正确)
bt_keys_find_irk: 7C:FA:80:EF:CE:2B (public)
bt_keys_find_irk: 7C:FA:80:EF:CE:2B (public)
bt_conn_set_state: disconnected -> connected            ← 状态机已连接
bt_conn_addref: handle 1 ref 2
bt_conn_addref: handle 1 ref 3
conn_tx_kthread: Started for handle 1                   ← 连接发送线程启动
conn_tx_kthread: calling nxsem_wait_uninterruptible()
bt_smp_connected: conn 0x3fc94d50 handle 1              ← SMP 已连接
bt_gatt_connected: conn 0x3fc94d50                      ← GATT 层已连接
bt_conn_release: handle 1 ref 2
bt_buf_release: buf 0x3fc952a4 ref 1 type 1
bt_buf_release: Buffer freed: 0x3fc952a4
                        ← ★ 日志到此为止，之后再无任何输出
```

### 3.3 关键观察

- ✅ **无断开事件**（`hci_disconn_complete` 未出现）
- ✅ **无任何错误/警告**（`wlerr`/`wlwarn` 均无输出）
- ❌ **无任何 ATT 层日志** —— 尤其 `bt_att.c` 的
  `att_read_type_req()` / `att_find_info_req()` / `att_read_req()`
  **零输出**，说明服务发现请求要么没到达，要么在到达前就被丢弃

### 3.4 中央设备侧

```
✓ 发现: E0:72:A1:F2:8F:EA  name='BTSH-LIGHT'  rssi=-10
步骤 2：建立连接（不请求服务）
   ✗ 连接失败: TimeoutError
```

注意：**即使不主动请求服务列表**（`BleakClient.connect()` 内部仍会拉服务），
也在 connect 阶段就超时。说明 Windows 在链路层之上等待某个响应而未果。

---

## 4. 已排除的怀疑点（**不要重复排查**）

| # | 怀疑点 | 排查方式 | 结论 |
| --- | --- | --- | --- |
| 1 | GATT 属性句柄从 `0x0000` 开始（ATT 规定 0 为无效句柄） | 已改为从 `0x0001` 开始（参照 `bt_services.c` 的 `#define GASVC 0x0001`），重新构建烧录 | ❌ **问题依旧**，不是这个原因 |
| 2 | `CONFIG_BLUETOOTH_MAX_CONN` 太小 | 实测 `.config` 中为 `1`（Kconfig 默认值，合理） | ❌ 排除 |
| 3 | MTU 协商失败 | 已阅读 `bt_att.c:470 att_mtu_req()` 实现：正确读取客户端 MTU、校验范围、按 `bt_buf_tailroom(buf)+1` 截断、回 `BT_ATT_OP_MTU_RSP` | ❌ 逻辑正确 |
| 4 | 广播 / AD 数据格式错误 | 中央设备能**正确解析出设备名** `BTSH-LIGHT` | ❌ 排布正确 |
| 5 | 控制器或射频不工作 | `le_conn_complete: status 0` 已证明链路层正常 | ❌ 排除 |
| 6 | S3 阶段发现的 `LE_SET_ADV_ENABLE` 首次返回 `-EIO` | 已用"先 `bt_stop_advertising()` 再 `bt_start_advertising()`"规避；日志显示 `opcode 200a` 正常完成 | ❌ 已规避，且不是本问题的原因 |
| 7 | **ACL 连接未建立** | ⚠️ **这是我最初的误判**：曾用 `bt bnep0 info` 的 `Free` 字段（始终 20）判断无连接。打开内核日志后发现**连接其实成功了**。该 ioctl 字段**不反映 LE 连接数** | ❌ **误判，已在文档中更正** |
| 8 | NuttX 的 GATT Server 根本没有实现 | 已确认 `nuttx/wireless/bluetooth/bt_att.c` **就是服务端实现**（含 `att_find_info_req` / `att_find_type_req` / `att_read_type_req` / `att_read_req` / `att_write_req` 等） | ❌ 有实现 |
| 9 | 连接回调未注册导致 GATT 不工作 | `bt_gatt_connected()` 由 NuttX 内部在连接完成时调用，不依赖应用注册 `bt_conn_cb` | ❌ 无关（且内部头在 apps 中不可用，见 §8） |
| 10 | `bt_gatt_connected()` 缺少必要初始化 | 读实现：它**只**做 `bt_gatt_foreach_attr(0x0001, 0xffff, connected_cb, conn)`，即仅遍历 CCC 属性处理订阅状态。**ATT 服务端不需要连接后初始化** | ❌ 排除（原假设 1 不成立） |
| 11 | ATT 请求到了但响应没发出 | **反证**：`bt_att_receive()` 入口就有 `wlinfo("Received ATT code 0x%02x len %u")`（bt_att.c:1755），一条都没有 | ❌ 排除 |
| 12 | L2CAP 层把 ATT 包抢走了 | `btnet_l2cap_receive` 只是 L2CAP 的 **default 监听者**，仅在找不到 CID 匹配者时才被调用；ATT 已注册 CID 0x0004。且 `bt_l2cap_receive()` 入口的 `wlinfo("Packet for CID %u")` 也无输出 | ❌ 排除 |
| 13 | HCI ACL 流控没配好（控制器压着不发） | **实测反证**：`Host Buffer Size`(0c33) 已发且参数正确（`param_len=7`，`acl_mtu=68`，`acl_pkts=20`），控制器回 `hci_cmd_complete: opcode 0c33`；`Set Ctl→Host Flow`(0c31) 也已发并被接受；`le_read_buffer_size_complete: status 0` | ❌ 排除 |
| 14 | VHCI 层包类型判断错误 | 读 `esp32s3_ble.c` 的 `esp32s3_ble_recv_cb()`：`H4_EVT→BT_EVT`、`H4_ACL→BT_ACL_IN`、`H4_ISO→BT_ISO_IN`，**映射正确** | ❌ 排除 |

---

## 4.5 ★★ 精确故障点：控制器未通过 VHCI 送上来任何 ACL 数据

**这是本轮最重要的成果。** 通过在 `esp32s3_ble_recv_cb()` 入口插入日志
（`syslog("BTSH-HCI: pkt type=0x%02x len=%u")`），直接观测**控制器→主机的
每一个 HCI 包**，得到决定性数据：

```
★ BTSH-HCI 包统计（连接全程）
    H4_EVT (0x04): 15 个     ← 全部是事件
    H4_ACL (0x02):  0 个     ← ★ 一个都没有
    H4_ISO (0x03):  0 个
    未知类型:        0 个
```

即：**控制器连接建立成功（`le_conn_complete: status 0`），但此后
一个 ACL 数据包都没有通过 VHCI 送上来。**

这一条结论同时解释了为什么三层日志全空：

| 层 | 该层入口日志 | 实测 |
| --- | --- | --- |
| VHCI | `esp32s3_ble_recv_cb()` 的 `BTSH-HCI: pkt type=...` | 只有 EVT，**无 ACL** |
| HCI | `hci_acl()` 的 `wlinfo("handle %u len %u flags %u")` | 无 |
| L2CAP | `bt_l2cap_receive()` 的 `wlinfo("Packet for CID %u")` | 无 |
| ATT | `bt_att_receive()` 的 `wlinfo("Received ATT code 0x%02x")` | 无 |

**因此问题不在 NuttX host 栈（HCI/L2CAP/ATT/GATT 四层代码都是好的、
日志点都验证过能工作），而在「ESP32 控制器 → VHCI → 主机」这段。**

### 复现方法（供接手者复验）

```bash
# 1. 在 VHCI 回调入口插日志
F=~/openvela/nuttx/arch/xtensa/src/esp32s3/esp32s3_ble.c
cp "$F" "$F.bak"
# 在 esp32s3_ble_recv_cb() 的 switch (data[0]) 之前插入：
#   syslog(LOG_INFO, "BTSH-HCI: pkt type=0x%02x len=%u\n", data[0], len);
# 并在 case H4_ACL: 分支里加一条 syslog(LOG_INFO, "-> ACL to host\n");
# 记得 #include <syslog.h>

# 2. 构建烧录
bash scripts/build/build-n16r8.sh gattdebug

# 3. 连板子，观察串口
#    预期：大量 type=0x04，type=0x02 应为 0
```

> 原始日志：[`tests/hardware/serial-vhci-debug.log`](../../tests/hardware/serial-vhci-debug.log)

### 剩下的疑点（下一轮从这里继续）

问题收敛到控制器侧后，可疑方向变为：

#### ~~假设 A：控制器 HCI 传输参数不对~~ ❌ 已排除

**已核实**（读 `esp-hal-3rdparty/nuttx/esp32s3/include/sdkconfig.h`）：

```
#define CONFIG_BT_CTRL_HCI_MODE_VHCI 1     ← ★ HCI 模式 = VHCI，正确
#define CONFIG_BT_CTRL_HCI_TL        1
#define CONFIG_BT_CTRL_HCI_TL_EFF    1     ← hci_tl_type = 1 = VHCI
#define CONFIG_BT_CTRL_BLE_MAX_ACT_EFF 6
#define CONFIG_BT_CTRL_BLE_STATIC_ACL_TX_BUF_NB 0
```

`esp32s3_bt_controller_init()` 只覆盖 4 个字段
（`controller_task_stack_size` / `controller_task_prio` /
`controller_task_run_cpu` / `magic`），其余走
`BT_CONTROLLER_INIT_CONFIG_DEFAULT()`，而该宏展开后 `hci_tl_type`
取自 `CONFIG_BT_CTRL_HCI_TL_EFF` = **1（VHCI）**。

> 📌 附带发现：`components/bt/include/` 下**没有 `esp32s3` 目录**，
> 构建实际使用的是 **`esp32c3` 那套 `esp_bt.h`**（编译日志可证）。
> 这是 esp-hal 的组织方式，不一定是 bug，但值得注意。

#### ~~假设 B：低功耗 / sleep 模式导致 ACL 不转发~~ ❌ 已排除

**已核实**：`CONFIG_BT_CTRL_SLEEP_MODE_EFF = 0`
（即 `ESP_BT_SLEEP_MODE_NONE`，睡眠已禁用），
`CONFIG_BT_CTRL_SLEEP_CLOCK_EFF = 0`。
因此 `btdm_low_power_mode_init()` 不会启用低功耗路径。

#### ~~假设 C：NuttX 的 VHCI 传输层遗漏了必需步骤~~ ❌ 已排除

**已读 `hci_driver_standard.c` 全文并核对整条链路**：

```
hci_transport_acl_to_host()          hci_transport.c:92
  → hci_driver_vhci_controller_tx()  hci_driver_standard.c:29
      buf[0] = HCI_DRIVER_TYPE_ACL   （加 H4 头）
  → forward_cb(..., C2H)             hci_driver_standard.c:48
  → hci_transport_host_recv_cb()     hci_transport.c:38
  → hci_driver_vhci_host_recv_cb()   hci_driver_standard.c:111
  → host_recv_cb->notify_host_recv() hci_driver_standard.c:117
  → esp32s3_ble_recv_cb()            esp32s3_ble.c:133
  → bt_netdev_receive() = bt_receive() bt_driver.h:49
  → hci_rx_work → hci_acl()          bt_hcicore.c:1087/235
```

**关键结论**：`hci_driver_vhci_host_recv_cb()`（第 117 行）
**无条件转发所有类型** —— 对 ACL 和 EVT 一视同仁，**没有任何过滤**。
传输层是干净的。

#### 假设 D：控制器固件（lib_esp32c3_family）与该 CONFIG 组合有 bug

注意：`sdkconfig.h` 里的 `CONFIG_BT_CTRL_*` 参数来自 esp-hal 的**静态**头文件，
未必与 NuttX 的实际使用方式匹配。可尝试改几个
`CONFIG_BT_CTRL_*` 值（如 `CONFIG_BT_CTRL_HCI_TL_EFF`）看是否有变化。

#### ~~假设 E：换一个中央设备~~ ❌ 已完成，不是特例

**已用 Android + nRF Connect 实测**（3 次连接）：

| 中央设备 | 地址类型 | `le_conn_complete` | `bt_gatt_connected` | 复位 | ACL |
| --- | --- | --- | --- | --- | --- |
| Windows (bleak) | `(public)` | ✅ | ✅ | 0 | 0 |
| **Android (nRF Connect)** | `(random)` | ✅ | ✅ | 0 | 0 |

**两个平台行为完全一致** → 与中央设备无关。

#### ★ 下一步（方向 F）：用 ESP-IDF 验证同一块板 —— ✅ **已完成，结论明确**

**这是判断「硬件/控制器」与「NuttX host 栈」的分水岭。**

### 🎯 决定性对照实验（2026-10-11 完成）

**同一块板、同一根 USB 线、同一个 USB 口、同一套供电**，只换固件：

| 检查项 | **ESP-IDF v5.3.1 + NimBLE** | **openvela / NuttX** |
| --- | --- | --- |
| BLE 控制器初始化 | ✅ `BLE_INIT: BT controller compile version [aa16a46]` | ✅ `compile version [0738a61]` |
| 蓝牙 MAC | `e0:72:a1:f2:8f:ea` | `e0:72:a1:f2:8f:ea`（**同一地址**） |
| PSRAM | ✅ `Found 8MB PSRAM`, `SPI SRAM memory test OK` | ✅ 8MB |
| 广播 | ✅ | ✅ |
| 被中央设备扫描到 | ✅ `nimble-bleprph`，RSSI **-18** | ✅ `BTSH-LIGHT`，RSSI -20 |
| 建立 BLE 连接 | ✅ | ✅ `le_conn_complete: status 0` |
| **GATT 服务发现** | **✅✅ 拿到 4 个服务** | **❌ 超时** |

**ESP-IDF 下完整枚举出所有服务与特征：**

```
Service 00001800-...  (Generic Access Profile)
    Char 00002a00  [read]      Char 00002a01  [read]
Service 00001801-...  (Generic Attribute Profile)
    Char 00002a05  [indicate]  Char 00002b3a  [read]  Char 00002b29  [read,write]
Service 00001811-...  (Alert Notification Service)
    Char 00002a47  [read]      Char 00002a46  [notify]
    Char 00002a48  [read]      Char 00002a45  [notify]  Char 00002a44  [write]
Service 59462f12-9543-9999-12c8-58b459a2712d  (Unknown，示例自定义服务)
    Char 33333333-2222-2222-1111-111100000000  [read,write,notify,indicate]
```

### ★★ 结论

> **硬件与 ESP32-S3 控制器本身完全正常。**
> **问题确定在 openvela / NuttX 的 BLE host 栈（或其与 ESP32 控制器的整合层）。**

**佐证**：NuttX 与 ESP-IDF 使用的是**不同的控制器固件版本**
（NuttX 链接 `0738a61`，ESP-IDF 链接 `aa16a46`），
但**蓝牙 MAC 完全相同**，说明是同一颗芯片、同一套控制器硬件。

### 为什么 NuttX 侧会失败（现有证据支持的判断）

1. **ACL 数据从未到达主机** —— 在 VHCI 回调入口插桩实测：
   连接全程只有 `H4_EVT`，`H4_ACL` **恒为 0**。
2. **整条软件链路已逐段排除**（见上表，共 21 项）——
   从 HCI 初始化、流控配置、传输层映射到 ATT/GATT 层代码，全都没问题。
3. **`CONFIG_ESPRESSIF_BLE` 的 Kconfig 桥接缺口**（见
   [`HANDOFF-AI-ONBOARDING.md`](HANDOFF-AI-ONBOARDING.md) §5.3）——
   该选项**只在 RISC-V 侧存在**（`arch/risc-v/src/common/espressif/Kconfig:505`），
   Xtensa(ESP32-S3) 侧完全没有，本项目只能靠 `-DCONFIG_ESPRESSIF_BLE=1` 绕过编译。

   > 📌 **这强烈暗示：openvela 当前树里 ESP32-S3 的 BLE 支持本身就不完整。**
   > ESP32-C3（RISC-V）有完整的 `ESPRESSIF_BLE` Kconfig 与 `Make.defs` 接线，
   > 而 ESP32-S3 侧缺失 —— 二者很可能不是同等程度的支持。

### 建议的后续方向（按可行性排序）

| # | 方向 | 说明 |
| --- | --- | --- |
| **1** | **在 ESP32-C3 上验证同一套 NuttX BLE 代码** | 该芯片 `ESPRESSIF_BLE` Kconfig 完整。若 C3 正常而 S3 异常，即可确认是 **ESP32-S3 特有缺口**，并可直接对比两边的初始化差异 |
| **2** | **对比 NuttX 与 ESP-IDF 的控制器初始化序列** | ESP-IDF 能用同一控制器正常工作，其 `esp_bt_controller_init` 的参数与调用顺序可与 NuttX 的 `esp32s3_bt_controller_init()` 逐项对比，找出 NuttX 少做或做错的地方 |
| 3 | 改用 ESP-IDF 的 NimBLE 作为 NuttX 的 host | 工程量大，但 ESP-IDF 已证明可用；NuttX 里有 `apps/wireless/bluetooth/nimble` 的痕迹可查 |
| 4 | 向 openvela 上游反馈 | 附本文的证据链（ESP-IDF 可用 / NuttX 不可用的完整对照） |

### 复现本对照实验的方法

```bash
# ---- ESP-IDF 侧 ----
# 已装在 ~/esp-idf (v5.3.1)，工具链在 ~/.espressif
. ~/esp-idf/export.sh
cd ~/esp-ble-test          # bleprph 示例（NimBLE peripheral GATT server）
idf.py build

# Windows 侧烧录（三个文件，注意偏移）
python -m esptool --chip esp32s3 -p COM4 -b 921600 \
  --before default_reset --after hard_reset \
  write_flash --flash_mode dio --flash_freq 80m --flash_size 16MB \
  0x0     bootloader.bin \
  0x8000  partition-table.bin \
  0x10000 bleprph.bin

# 广播名为 nimble-bleprph（NimBLE 的默认名，不是 sdkconfig 里设的那个）
# 用 Windows/Python bleak 连接并 get_services() -> 成功列出 4 个服务

# ---- NuttX 侧 ----
python -m esptool --chip esp32s3 -p COM4 -b 921600 \
  --before default_reset --after hard_reset \
  write_flash 0x0 nuttx-n16r8-gattlight.bin
# 板上执行 btsh_light start，再连接 -> get_services() 超时
```

**关键产物**：
- [`serial-espidf-bleprph-boot.log`](../../tests/hardware/serial-espidf-bleprph-boot.log)
  —— ESP-IDF 启动与 BLE 初始化日志（含控制器版本、PSRAM 自检）

#### ~~原始假设 C/D/E~~（多数已被 §4 排除，保留作排查记录）

> 📌 补充排除项（本轮新增）：
> **低功耗唤醒路径不影响 ACL** —— `esp32s3_ble_adapter.c:2784`
> 的 `async_wakeup_request()` 在 `g_lp_cntl.enable == 0` 时
> **直接返回 false**，而 `CONFIG_BT_CTRL_SLEEP_MODE_EFF=0` 保证该值为 0。

---

## 5. 待验证的假设（**原始假设已部分排除，见上**）

> 📌 §4.5 已经把问题**精确锁定到 VHCI 层的 ACL 缺失**，
> 下面这些原始假设大部分已被 §4 的第 10–14 条排除。
> 保留在此仅作排查过程记录。

### 假设 1：`bt_gatt_connected()` 之后缺少必要的 ATT 初始化

**已排除** —— 见 §4 第 10 条。它的实现只有一句
`bt_gatt_foreach_attr(0x0001, 0xffff, connected_cb, conn)`，
只处理 CCC 订阅状态，ATT 服务端无需连接后初始化。

### 假设 2：入站 ATT 请求根本没到达 host

日志中 L2CAP 通道已注册（`bt_l2cap_chan_register: CID 0x0004` 为 ATT），
但没有任何 `bt_l2cap` 的入站数据日志。

**验证方法**：在 `bt_att.c` 的请求分发入口（`bt_att_recv()` 或
`att_handle_rsp()` 附近，约 320-370 行有 opcode 分发表）加一行
`wlinfo("ATT recv opcode 0x%02x\n", ...)`，重新构建后看是否被调用。

- **若被调用**：说明请求到了，问题在响应构造/发送。
- **若未被调用**：问题在 L2CAP 层或控制器到 host 的通路。

### 假设 3：L2CAP ATT 通道（CID 0x0004）未正确建立

`bt_l2cap_connected(conn)` 在 `le_conn_complete()` 中被调用
（见 `bt_hcicore.c` 该函数末尾），但需确认它是否为 ATT 固定通道
（CID 0x0004）正确设置了收发路径。

**验证方法**：阅读 `bt_l2cap_connected()` 与 `bt_l2cap_chan_register()`
对固定通道 CID 0x0004/0x0005/0x0006 的处理。

### 假设 4：连接参数导致中央设备主动放弃

NuttX 的 `bt_start_advertising()` 里设：
```c
set_param->min_interval = BT_HOST2LE16(300);   /* 300 * 0.625ms = 187.5ms */
set_param->max_interval = BT_HOST2LE16(300);
```
187.5ms 的广播间隔偏大，且连接后 Windows 期望的
连接间隔（connection interval）可能与 NuttX 给出的不匹配。

**验证方法**：改用 Android + nRF Connect 测试。若 Android 能正常发现服务，
则是 Windows/bleak 特有的协商差异。

### 假设 5：`CONFIG_BLUETOOTH_*` 有未开启的必需项

当前 `.config` 中的蓝牙相关项只有：
```
CONFIG_BLUETOOTH_DEVICE_ID=0
CONFIG_BLUETOOTH_MAX_CONN=1
CONFIG_BLUETOOTH_MAX_PAIRED=1
CONFIG_BLUETOOTH_MAXSCANDATA=64
CONFIG_BLUETOOTH_MAXSCANRESULT=8
CONFIG_BLUETOOTH_MAXDISCOVER=8
CONFIG_BLUETOOTH_BUFFER_PREALLOC=20
CONFIG_BLUETOOTH_BUFFER_IRQRESERVE=0
CONFIG_BLUETOOTH_TXCMD_STACKSIZE=4096
CONFIG_BLUETOOTH_TXCMD_PRIORITY=100
CONFIG_BLUETOOTH_TXCMD_NMSGS=16
CONFIG_BLUETOOTH_TXCONN_STACKSIZE=4096
CONFIG_BLUETOOTH_TXCONN_PRIORITY=100
CONFIG_BLUETOOTH_TXCONN_NMSGS=16
```

**验证方法**：`make menuconfig` 进 `Wireless → Bluetooth` 逐项检查，
特别关注与 **GATT Server / ATT / 可发现性** 相关的选项。

---

## 6. 涉及的源码位置（快速索引）

| 文件 | 关注点 |
| --- | --- |
| `nuttx/arch/xtensa/src/esp32s3/esp32s3_ble_adapter.c` | ESP32-S3 的 BLE 控制器适配（`esp32s3_bt_controller_init` 在 ~3017 行） |
| `nuttx/wireless/bluetooth/bt_hcicore.c` | HCI 层；`le_conn_complete()` 在 **682 行** ★ |
| `nuttx/wireless/bluetooth/bt_att.c` | **ATT 服务端**实现；`att_mtu_req()` 在 470 行；opcode 分发表在 320-370 行 |
| `nuttx/wireless/bluetooth/bt_gatt.c` | GATT 层；`bt_gatt_register()` 在 105 行；`bt_gatt_connected()` ★ |
| `nuttx/wireless/bluetooth/bt_services.c` | **上游自带的 GAP 服务范例**（243 行），是写 GATT 服务的最佳参照 |
| `nuttx/wireless/bluetooth/bt_l2cap.c` | L2CAP；`bt_l2cap_connected()` / `bt_l2cap_chan_register()` ★ |
| `nuttx/include/nuttx/wireless/bluetooth/bt_gatt.h` | GATT 宏定义（`BT_GATT_PRIMARY_SERVICE` 在 222 行） |
| **`src/app/btsh_light_main.c`** | **本项目自写的 GATT 灯控服务** |

---

## 7. 如何复现与抓日志

### 7.1 构建带内核日志的固件

```bash
bash scripts/setup/apply-patches.sh
bash scripts/setup/install-btsh-light.sh
bash scripts/setup/apply-board-ws2812.sh
bash scripts/build/build-n16r8.sh gattdebug
```

`defconfig.gattdebug` 相对 `gattlight` 只多了这些：

```
CONFIG_DEBUG_FEATURES=y          ← ★ 总开关，漏了它下面全部会被静默剔除
CONFIG_DEBUG_ERROR=y
CONFIG_DEBUG_WARN=y
CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_WIRELESS=y
CONFIG_DEBUG_WIRELESS_ERROR=y
CONFIG_DEBUG_WIRELESS_WARN=y
CONFIG_DEBUG_WIRELESS_INFO=y     ← wlinfo 生效
```

> ⚠️ **Kconfig 陷阱**：依赖链是
> `DEBUG_FEATURES` → `DEBUG_ERROR/WARN/INFO` → `DEBUG_WIRELESS_*`。
> 只写后面几项会被 **Kconfig 静默剔除**（没有任何警告！），
> 表现为构建成功但 `nuttx.bin` 大小**完全不变**。
> 判断是否真的生效：对比产物大小（应为 **437,912 B**，而非 423,816 B）。

### 7.2 烧录

```powershell
python -m esptool --chip esp32s3 -p COM4 -b 921600 `
  --before default_reset --after hard_reset `
  write_flash 0x0 nuttx-n16r8-gattdebug.bin
```

### 7.3 板上启动服务

```
nsh> btsh_light start
BTSH: GATT service 0xff00 registered (8 attrs)
BTSH: light OFF
BTSH: advertising as "BTSH-LIGHT"
```

### 7.4 Windows 侧发起连接并观察

```python
import asyncio
from bleak import BleakClient
asyncio.run(BleakClient("E0:72:A1:F2:8F:EA", timeout=15).connect())
```

同时用串口终端（115200）观察板子输出。

---

## 8. 已知的环境限制（会影响排查手段）

| 限制 | 影响 | 应对 |
| --- | --- | --- |
| `bt_conn_cb_register()` 声明在**内部头** `nuttx/wireless/bluetooth/bt_hcicore.h` | 该目录**不在 apps 的 include 路径**（`wireless/bluetooth/Make.defs:41` 的 `CFLAGS` 只作用于编译 wireless 库自身），所以**应用里无法注册连接回调** | 若要精确连接事件，需在 NuttX 内部加钩子，或改用 ioctl 轮询 |
| `dmesg` 命令不可用 | 无法事后查看内核日志 | 已改用 `CONFIG_DEBUG_WIRELESS_INFO` 实时输出 |
| WSL 无法访问串口 | 不能在 WSL 内烧录 | 从 **Windows** 侧用 esptool 烧录 |
| `github.com:443` 在本机不可达 | 无法 `git push` / `repo sync` | `ssh.github.com:443` 可达；或用 `scripts/setup/relay_proxy.py` |
| `BT_GATT_PRIMARY_SERVICE()` 硬编码 `BT_UUID_16` | **无法声明 128 位服务 UUID** | 当前用 16 位自定义 UUID（0xFF00 段） |

---

## 9. 本项目 GATT 服务定义（供对照）

```
Service  0xFF00   （自定义 16 位）
├─ 0xFF01  灯控命令   WRITE + WRITE_WITHOUT_RESP   写 1 字节：0=关灯 1=开灯
├─ 0xFF02  灯状态     READ + NOTIFY                读 1 字节：0=关 1=开
│   └─ CCC  0x2902                                 客户端使能 Notify
└─ 0xFF03  设备信息   READ                         读 3 字节：协议版本/通道数/保留
```

属性表 **8 项**，句柄 **0x0001 起**：

```c
#define BTSH_SVC_BASE          0x0001
#define BTSH_SVC_HANDLE        (BTSH_SVC_BASE + 0)  /* 主服务 */
#define BTSH_CMD_CHRC_HANDLE   (BTSH_SVC_BASE + 1)
#define BTSH_CMD_VAL_HANDLE    (BTSH_SVC_BASE + 2)
#define BTSH_STATE_CHRC_HANDLE (BTSH_SVC_BASE + 3)
#define BTSH_STATE_VAL_HANDLE  (BTSH_SVC_BASE + 4)
#define BTSH_STATE_CCC_HANDLE  (BTSH_SVC_BASE + 5)
#define BTSH_INFO_CHRC_HANDLE  (BTSH_SVC_BASE + 6)
#define BTSH_INFO_VAL_HANDLE   (BTSH_SVC_BASE + 7)
#define BTSH_ATTR_COUNT        8
```

**这部分已确认注册成功**（板上打印 `8 attrs`），所以
"服务表本身写错了"的可能性较低，重点应放在 **ATT 层为什么没有交互**。

---

## 10. 给接手者的建议起点

按投入产出比排序：

1. **先读 `bt_gatt_connected()` 的实现**（假设 1）—— 5 分钟，可能直接命中。
2. **在 ATT 分发入口加一行日志**（假设 2）—— 15 分钟，能一刀切分问题在
   "请求没到" 还是 "响应没发"。
3. 用 **Android + nRF Connect** 测一次（假设 4）—— 能排除 Windows 特有因素。
4. 检查 L2CAP 固定通道（假设 3）。
5. 逐项核对 `menuconfig` 的蓝牙选项（假设 5）。

**如果最终确认是 NuttX host 栈的缺陷**，请明确记录：
- 具体的函数与行号
- 最小复现条件
- 是否与 ESP32-S3 控制器组合特有（可用 ESP32-C3 对比，那边 `ESPRESSIF_BLE` 是完整的）
