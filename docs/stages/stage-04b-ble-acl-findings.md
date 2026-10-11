# BLE 攻关：补充发现（2026-10-11 第二轮）

> 本文补充 `HANDOFF-CURRENT-ISSUE.md`，记录继续排查后的新发现。

---

## 一、本轮新排除的项（累计 25 → 30）

| # | 怀疑点 | 排除依据 | 结论 |
| --- | --- | --- | --- |
| 26 | **HCI 包类型映射错误**（ACL 被当成未知类型丢弃） | 读 `esp32s3_ble.c:148-164`：`case H4_EVT → BT_EVT`、`case H4_ACL → BT_ACL_IN`、默认 `valid=false` 并报错。映射**完全正确**，且正确剥掉 `H4_HEADER_SIZE` 头 | ❌ 排除 |
| 27 | `hw_target_code` 取错值（把 S3 当 C3） | 预处理确认实际使用的是 `esp-hal-3rdparty/nuttx/esp32s3/include/sdkconfig.h`，其中 `CONFIG_IDF_TARGET_ESP32S3 1` 已定义 → 取 **0x02010000**（S3 正确值） | ❌ 排除 |
| 28 | 链接了 C3 的控制器库 | `Wireless.mk:27` 的库路径末尾是 **`lib_esp32c3_family/esp32s3/`** —— `lib_esp32c3_family` 只是**通用控制器库的名字**，实际链接其 `esp32s3` 子目录 | ❌ 排除 |
| 29 | NuttX 控制器初始化顺序与 ESP-IDF 不同 | 读 `bt_hcicore.c:1281-1441`：Reset → Read Local Features/Version/BD_ADDR → LE Read Local Features/Buffer Size → Set Event Mask → LE Set Event Mask → Host Buffer Size → Set Ctl→Host Flow。**与 ESP-IDF 标准顺序一致** | ❌ 排除 |
| 30 | NuttX 控制器初始化参数被改错 | 只覆盖 4 个字段（`controller_task_stack_size` / `prio` / `run_cpu` / `magic`），其余全部来自 `BT_CONTROLLER_INIT_CONFIG_DEFAULT()`。结构体 36 个字段已逐一核对 | ❌ 排除 |

---

## 二、★ 发现一个真实的代码缺陷

### 2.1 `esp32s3_ble_send_ready()` 是空函数

[`esp32s3_ble.c:115`](../../../nuttx/arch/xtensa/src/esp32s3/esp32s3_ble.c)
（注：openvela 树内路径）：

```c
static esp_vhci_host_callback_t vhci_host_cb =
{
  .notify_host_send_available = esp32s3_ble_send_ready,   /* ← 空实现 */
  .notify_host_recv           = esp32s3_ble_recv_cb
};

static void esp32s3_ble_send_ready(void)
{
}                                    /* ★ 函数体是空的 */
```

**这个回调的语义**（见函数上方的英文注释）：
> *If the controller could send HCI command will callback this function.*
> （控制器**可以接收 HCI 命令**时会回调此函数）

即：**控制器通过它通知主机"我现在能收包了"**。
NuttX 把它实现成空函数 —— 通知被**静默丢弃**，没有任何机制记录或转发。

### 2.2 与之配套的检查函数存在但用途可疑

同一文件 `esp32s3_ble.c:231` 调用了：

```c
if (esp32s3_vhci_host_check_send_available())
```

而该函数的 esp-hal 实现（`hci_driver_standard.c:146`）是：

```c
bool
esp_vhci_host_check_send_available(void)
{
    return true;                     /* ← 永远返回 true，形同虚设 */
}
```

**即：ESP32 的 VHCI 传输层里，"主机能否发包"这个信息实际上是空的** ——
`check_send_available()` 恒真，`notify_host_send_available()` 空实现。

### 2.3 为什么这可能导致 ACL 不通

主机→控制器的命令**都被接受了**（日志证明每条命令都有 `cmd_complete`），
所以问题不在命令方向。

但**控制器→主机的 ACL 数据流**可能依赖另一套信用机制：
- 控制器需要确信主机有**可用的 ACL 接收缓冲**
- 这套信息本应由 `notify_host_send_available` / `check_send_available` 维护
- 两者都是空的 → 控制器侧可能认为主机缓冲不可用 → **不发 ACL**

**这与观察到的现象吻合**：事件（EVT）能发（不需要信用），
**ACL 数据不发**（需要信用）。

> 📌 注意：这只是**当前最有力的假设**，尚未经实验验证。
> 验证方法见 §4。

---

## 三、另一个未追完的线索：控制器固件版本不同

| | 控制器编译版本 |
| --- | --- |
| **NuttX / openvela** | `0738a61` |
| **ESP-IDF v5.3.1** | `aa16a46` |

同一块板、同一颗芯片，**两份控制器固件**：

- NuttX 链接 `esp-hal-3rdparty/components/bt/controller/lib_esp32c3_family/esp32s3/`
  （由 `Make.defs:292` 用 git submodule 固定到 esp-hal 的某个 commit）
- ESP-IDF 用自带的控制器库

**ESP-IDF 那份实测完全正常**（枚举出 4 个 GATT 服务），
**NuttX 这份 ACL 不通**。

**这指向一个可能：openvela 固定的那个控制器库 commit 在 ESP32-S3 上有问题。**

验证方法：更新 `lib_esp32c3_family` 子模块到较新 commit，重新构建测试。

---

## 四、实际执行的实验与结果（2026-10-11 第二轮补充）

### 4.1 ✅ 已执行：更新控制器库（方案 B）—— **失败，已回退**

**动机（证据链扎实）**：

控制器库 `lib_esp32c3_family` 的 git 历史里，**每个提交都是一次控制器固件升级**：

```
29d5555  fix(bt): Update bt lib for ESP32-C3 and ESP32-S3(0738a61)   ← openvela 固定的版本
7e73ebf  ... (bc853c5)
58d499b  ... (2f683593)
   ...
0a08c4b  ... (51d9dfde)                                              ← 最新
```

而串口实测 NuttX 的控制器编译版本正是 **`0738a61`**，
ESP-IDF v5.3.1 用的是 **`aa16a46`**（更新，且实测 BLE 完全正常）。

**执行**：

```bash
cd ~/openvela/nuttx/arch/xtensa/src/esp32s3/esp-hal-3rdparty
git -C components/bt/controller/lib_esp32c3_family checkout 0a08c4b
# libbtdm_app.a: 590,010 B -> 1,543,778 B
# 重新构建 gattlight -> 423,892 B -> 烧录
```

**结果：❌ 反而更差**

| 指标 | 旧控制器库 (`0738a61`) | 新控制器库 (`51d9dfde`) |
| --- | --- | --- |
| 广播 | ✅ 能被扫到 | ✅ 能被扫到（RSSI −26） |
| **建立连接** | ✅ `le_conn_complete` | **❌ 完全无法建立**（`le_conn_complete` = 0） |
| 崩溃 | 0 | 0 |
| ACL | 0 | 0 |

**结论**：新控制器库与 NuttX 的调用约定**不兼容**（体积从 590 KB 增至 1.5 MB，
API/结构体很可能已变更）。

**已回退**到 `29d5555`（`libbtdm_app.a` 恢复为 590,010 B），并重建烧录。

> 📌 **这条假设已排除。** 固件 `nuttx-n16r8-gattlight.bin`
> （423,892 B，MD5 `f276f0c25e4eb348eb5d2b6f99e44504`）为回退后的正常版本。

### 4.2 ⏳ 尚未执行：验证信用机制假设（方案 A）

§2 发现的 `esp32s3_ble_send_ready()` 空函数问题**尚未做实验验证**。
验证方法（成本最低，建议下一步优先做）：

在 `esp32s3_ble.c` 里把该空函数改为打印：

```c
static void esp32s3_ble_send_ready(void)
{
  syslog(LOG_INFO, "BTSH: send_ready called\n");
}
```

**判读**：

| 观察 | 含义 | 下一步 |
| --- | --- | --- |
| **从不被调用** | 控制器确实没拿到"主机可收"的信用 | 需在主机侧主动喂信用（或在 open 时显式通知） |
| **被调用但无动作** | 需在该回调里做实际的事（唤醒 bt_hcdriver 的 tx 队列） | 实现真正的发送就绪通知 |

### 4.3 其他未执行方案

- **方案 C**：ESP32-C3 对照实验（需一块 C3 板子）
- **方案 D**：改用 UART HCI 模式（`CONFIG_BT_CTRL_HCI_TL_EFF`）

---


## 五、已确认可用的成果（不受此问题影响）

- ✅ **WiFi/TCP 远程点灯**（见 [`stage-05-tcp-remote-light.md`](stage-05-tcp-remote-light.md)）
- ✅ PSRAM、WiFi、板载 WS2812B、全部构建脚本与板级补丁
- ✅ `BT_GATT_CCC` 崩溃 bug 的修复（一旦 BLE 通，这个修复就生效）
- ✅ 完整的 ESP-IDF 对照环境（`~/esp-idf`、`~/esp-ble-test`）

---

## 六、给 A7Z 对接的建议

用户需求：**A7Z（跑 openvela）通过 BLE 控制 ESP32-S3 点灯**。

### 目前的现实

| 方案 | 状态 | A7Z 侧工作量 |
| --- | --- | --- |
| **WiFi/TCP** | ✅ **已可用** | 小 —— A7Z 侧只需 TCP socket + 发文本命令 |
| BLE (GATT) | ❌ ESP32-S3 侧不通 | 大 —— 且 ESP32 侧未解决 |

### 如果坚持要 BLE

**A7Z 侧是 openvela，其 BLE host 栈可能是可用的**（问题出在 ESP32-S3
的控制器整合层，不一定在 NuttX 的 host 栈本身）。

因此有个**务实的中间方案**：

> **A7Z 作为 BLE Central，ESP32-S3 侧暂不用 BLE，
> 而是让 A7Z 通过 WiFi/TCP 控制 ESP32-S3 点灯。**

即：**BLE 用于 A7Z 与用户手机之间，WiFi 用于 A7Z 与 ESP32-S3 之间。**
这样既满足"用 BLE"的交互需求，又能立刻跑通端到端。

**若必须 A7Z↔ESP32-S3 全程 BLE**，需先按 §4 的方案 A/B 攻克
ESP32-S3 侧的 ACL 问题。
