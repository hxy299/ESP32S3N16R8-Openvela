# AD 广播数据缺陷的修复（2026-10-11 第五轮）

> 本文记录**修掉的一个真实缺陷**，以及它揭示的信息。

---

## 一、★ 修掉的真实缺陷：`Complete Local Name` 缺字符串终止符

### 1.1 两次踩坑的完整过程

**坑 1 —— 声明长度与数据不符**（原代码）：

```c
g_scan_rsp[0].len  = 1 + strlen("BTSH-LIGHT");      /* 11 */
g_scan_rsp[0].type = BT_EIR_NAME_COMPLETE;
memcpy(g_scan_rsp[0].data, "BTSH-LIGHT",
       strlen("BTSH-LIGHT"));                        /* 只拷 10！ */
```

声明 11 字节，只填 10 字节，第 11 字节是未初始化数据。

**坑 2 —— 去掉终止符**（我"修"的第一版，反而更糟）：

```c
g_scan_rsp[0].len  = strlen("BTSH-LIGHT");           /* 10 */
memcpy(g_scan_rsp[0].data, "BTSH-LIGHT",
       strlen("BTSH-LIGHT"));                        /* 10 */
```

**实测结果：中心设备只解析到 `BTSH-LIGH`（少了末尾的 `T`）！**

```
Windows 扫描结果：名字: 'BTSH-LIGH'      ← ★ 少一个字符
```

**原因**：`BT_EIR_NAME_COMPLETE`（Complete Local Name）**要求名字以 `'\0'` 结尾**，
长度字段必须**包含**该终止符。

**正确写法**（最终版，与 `btsak` 一致）：

```c
g_scan_rsp[0].len  = strlen(CONFIG_BTSH_LIGHT_ADV_NAME) + 1;   /* 11，含 '\0' */
g_scan_rsp[0].type = BT_EIR_NAME_COMPLETE;
memcpy(g_scan_rsp[0].data, CONFIG_BTSH_LIGHT_ADV_NAME,
       strlen(CONFIG_BTSH_LIGHT_ADV_NAME) + 1);                /* 连 '\0' 一起拷 */
```

**验证结果**：

```
Windows 扫描结果：名字: 'BTSH-LIGHT'  rssi=-16     ← ★ 完整正确
```

> 📌 位置：[`src/app/btsh_light_main.c`](../../src/app/btsh_light_main.c)
> 附近 ~500 行（`btsh_advertise()` 内），已附完整注释说明两次踩坑过程。

---

## 二、★★ 用户侧的决定性观察

**用户报告：手机【设置 → 蓝牙】能看到 `BTSH-LIGHT`。**

这条信息极有价值，它证明：

| 结论 | 依据 |
| --- | --- |
| ✅ **板子的广播能被手机收到** | 系统蓝牙扫描到了 |
| ✅ 广播数据可被手机解析 | 能看到名字 |
| ❌ **`nRF Connect` 这个 App 扫不到** | 用户在 App 里找不到 |

**即：问题不在板子，在 `nRF Connect` App 侧**（可能是缓存了之前
"连不上"的记录而不再显示，或 App 的扫描参数与系统蓝牙不同）。

**这排除了我前几轮的一个猜测**（"手机收不到板子的广播"）。

---

## 三、修正后的准确状态

> **在这套 openvela 树上、这块 ESP32-S3 上：**
>
> - ✅ 控制器正常（BD_ADDR 可读、扫描发现 21 个真实设备）
> - ✅ 广播参数正常（间隔 187.5 ms、三信道全开、`BT_LE_ADV_IND` 可连接类型）
> - ✅ **广播数据现在完全正确**（名字 `BTSH-LIGHT`、RSSI −16）
> - ✅ 手机系统蓝牙能收到并正确显示名字
> - ❓ **建立连接**：Windows 超时；手机上是否有连接尝试**待确认**
>   （本轮监控窗口内无连接事件，但不确定用户是否发起了连接）

---

## 四、为什么"连接"这一项仍无定论

**问题在于我无法确认用户是否真的发起了连接。**

本轮 10 分钟监控窗口内 `le_conn_complete` = 0，但这有**三种可能**：

1. 用户没发起连接（在看消息/做别的）
2. 用户发起了，但手机拒绝连接（不显示它 / 配对失败）
3. 用户发起了，但控制器不响应（原问题）

**无法从串口区分这三种情况。**

### 4.1 一个历史上成功的对照

`HT-11` 记录（CCC 修复后）手机上**成功建立过 3 次连接**：

```
>> 连接: le_conn_complete: status 0 handle 1 role 1 7C:53:C7:63:31:64 (random)
[120s] 复位=0 连接=3 GATT=3
```

**这说明控制器能够响应连接请求。** 只是那次的 ACL 数据不通。

---

## 五、下一步（需要用户配合确认）

### 5.1 优先：确认连接到底有没有发生

**方法**：用户发起连接后**立即告诉我**，我同步看串口。

**或者更简单**：用户可以看手机上发生了什么：

| 手机上看到 | 含义 |
| --- | --- |
| 显示"已连接"或"配对请求"弹窗 | **连接成功**，问题在 ACL（数据面） |
| 显示"连接失败"/"无法通信" | 连接被拒 |
| 点了没反应 / 设备消失 | 控制器不响应 |

### 5.2 备选：换一个 BLE 调试 App

既然系统蓝牙能看到、`nRF Connect` 看不到，
建议试 **LightBlue** 或 **BLE Scanner**（都是免费的 BLE 调试 App）。
若它们能看到并连接 → 纯属 `nRF Connect` 的 App 问题。

### 5.3 若确认是 ACL 问题

回到 [`stage-04b-ble-acl-findings.md`](stage-04b-ble-acl-findings.md)
的排查线索（30 项已排除，剩余怀疑方向已列出）。

---

## 六、本轮产出

| 项 | 内容 |
| --- | --- |
| 修复 | `Complete Local Name` 缺终止符（[`btsh_light_main.c`](../../src/app/btsh_light_main.c)） |
| 新固件 | `assets/firmware/nuttx-n16r8-gattlight.bin`（423,892 B） |
| 验证 | Windows 扫描名字 `BTSH-LIGHT` 完整、RSSI −16 |
| 日志 | `tests/hardware/serial-gattlight-connect-watch.log` |
