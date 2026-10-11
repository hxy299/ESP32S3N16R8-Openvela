# 基线对照的完整结论（2026-10-11 第三轮）

> 本文修正前几轮的若干错误结论，给出**经过对照实验验证**的准确描述。

---

## 一、本轮做对的两件事（前几轮我搞错了）

### 1.1 ✅ 完全干净的树 + 官方配置，建立了基线

按用户要求执行：备份 → `git checkout` 完全恢复 → 用官方配置重试。

**恢复后验证**：

```
nuttx git status:  ★ 完全干净
apps  git status:  ★ 干净
esp32s3_ble.c / esp32s3_bringup.c / esp32s3_wifi_adapter.c  均无改动
```

**配置与官方只差 1 行**（芯片型号 N4 → N16R8）。

> 备份：`~/btsh-backup-20261011-191758/`（含完整 diff、应用目录、固件）

### 1.2 ✅ 发现之前一直搞错的设备名

**基线固件（btsak）的广播名是 `btsak`**：

```c
/* apps/wireless/bluetooth/btsak/btsak_advertise.c:124-126 */
sd[1].len  = sizeof("btsak");
sd[1].type = BT_EIR_NAME_COMPLETE;
strlcpy((FAR char *)sd[1].data, "btsak", sizeof(sd[1].data));
```

**我前几轮一直让用户找 `BTSH-LIGHT`** —— 那是我们自写应用的广播名，
在官方配置的固件上根本不存在。**用户"找不到设备"是我的指令错误，不是板子问题。**

---

## 二、★★ 关键对照实验结果

### 2.1 实验矩阵

| # | 固件 | 广播数据 | 扫描 | 广播 | Windows 连接 |
| --- | --- | --- | --- | --- | --- |
| A | **官方配置**（btsak） | ❌ **几乎为空** | ✅ 21 个设备 | ✅ 但名字空 | ❌ 超时 |
| B | **本项目 btsh_light** | ✅ **完整** | ✅ | ✅ `BTSH-LIGHT` | ❌ 超时 |

### 2.2 详细数据

**A：官方配置（btsak 广播）**

```
Windows 扫描结果：
  地址: E0:72:A1:F2:8F:EA
  名字: None                      ← ★ 没有名字！
  服务UUID: []
  制造商数据: 0 项
  RSSI: -24
```

**B：本项目 btsh_light（我写的应用）**

```
Windows 扫描结果：
  地址: E0:72:A1:F2:8F:EA
  名字: 'BTSH-LIGHT'              ← ★ 名字完整
  local_name: 'BTSH-LIGHT'
  RSSI: -20
```

**连接测试（两个固件都做了）**：

```
>>> 调用 connect()...
❌ 连接失败（46.8 / 48.9 秒后）: TimeoutError
```

板子侧串口：`le_conn_complete` = **0**（连连接完成事件都没有）

### 2.3 两个重要结论

#### 结论 1：`btsak` 的广播数据构造有缺陷

官方 `btsak advertise` 广播出来的包**几乎是空的**：
- 没有名字（名字在 scan response 里，但收不到）
- 没有服务 UUID
- 没有制造商数据

而**我们自己写的 `btsh_light` 广播数据是完整的**（名字、flags 都有）。

> 📌 这说明：**问题不在控制器** —— 控制器能正确发送我们构造的完整广播包。
> `btsak` 的广播数据构造（或其 ioctl 传参）有问题。

（此前在 `HANDOFF-AI-ONBOARDING.md` 记录过 `btsak` 的 AD 长度字段 bug，
这里可能是同一类问题的另一处表现。）

#### 结论 2：连接失败与广播数据质量**无关**

| 广播数据 | 连接结果 |
| --- | --- |
| 不完整（btsak） | ❌ 超时 |
| 完整（btsh_light） | ❌ 超时 |

**两种固件连接结果一致** → 连接失败**不是**广播数据的问题。

---

## 三、准确的问题描述（修正版）

> **在这套 openvela 树上、这块 ESP32-S3 板子上：**
>
> - ✅ BLE 控制器工作正常（能读 BD_ADDR、能扫描、能广播）
> - ✅ 扫描功能正常（发现 21 个真实设备）
> - ✅ 广播功能正常（Windows 能扫到，RSSI −20）
> - ❌ **建立连接失败**：中央设备发起连接后，
>   控制器**不产生 `LE Connection Complete` 事件**
>
> 该现象在**官方原始配置**（零改动）上同样存在，
> 因此**不是本项目的代码或配置引入的**。

---

## 四、尚未排除的可能（诚实清单）

| # | 可能 | 状态 | 如何排除 |
| --- | --- | --- | --- |
| 1 | **Windows/手机的 BLE 适配器问题** | ⚠️ **未排除** | Windows 侧从未验证过能连**任何** BLE 设备。需用一个已知正常的 BLE 设备做对照 |
| 2 | 用户未实际发起连接 | ⚠️ 未确认 | 需一次**确认有人操作**的测试 |
| 3 | 控制器确实不响应连接请求 | ⚠️ 待验证 | 上面两条排除后即可确认 |
| 4 | 手机上曾成功连接（CCC 修复后 3 次 `le_conn_complete`） | 📌 **重要反证** | 见下 |

### 4.1 ⚠️ 关键反证：手机上曾经**成功过**

在 `HT-11` 记录的测试中（CCC 修复后）：

```
>> 连接: le_conn_complete: status 0 handle 1 role 1 7C:53:C7:63:31:64 (random)
>> 连接: le_conn_complete: status 0 handle 1 role 1 7C:53:C7:63:31:64 (random)
>> 连接: le_conn_complete: status 0 handle 1 role 1 7C:53:C7:63:31:64 (random)
[ 60s] 复位=0 连接=1 GATT=1
[ 90s] 复位=0 连接=2 GATT=2
[120s] 复位=0 连接=3 GATT=3
```

**手机（Android nRF Connect）成功建立了 3 次连接**，
`le_conn_complete: status 0` + `bt_gatt_connected`。

**这说明控制器能够响应连接请求！**

**唯一的差别**：那时连接**能建立**，但 **ACL 数据（ATT 请求）到不了**。

### 4.2 因此，最可能的解释

**问题不在"连接建立"，而在"连接建立之后"** ——
即控制器建立了链路、送来了 `LE Connection Complete`，
但**之后不再送 ACL 数据**。

而 Windows 侧连接超时，可能是因为 bleak 要求连接后**立即完成服务发现**，
拿不到 ATT 响应就报超时（表现为"连接失败"）。

**这两件事是同一个根因的两种表现：ACL 数据不通。**

---

## 五、下一步（成本最低、最可能一击命中）

### 方案 A：确认 ACL 是否真的不通（必做）

用**手机**连接（此前成功过），观察串口是否出现：

```
le_conn_complete: status 0    ← 应有（此前有过）
Packet for CID 或 Received ATT code   ← 关键：ACL 是否到达
```

| 结果 | 含义 |
| --- | --- |
| 有 `le_conn_complete` 但无 `Packet for CID` | **确认 ACL 不通**（原问题重现），继续攻 ACL |
| 两者都有 | **BLE 完全正常**！之前的失败是 Windows 侧问题 |
| 都没有 | 控制器确实不响应连接（需重新审视） |

### 方案 B：验证 Windows 侧适配器是否正常

用 Windows 连一个**已知正常的 BLE 设备**（如蓝牙耳机、手环）。
若也连不上 → **Windows 测试环境有问题，之前所有结论都要重估**。

### 方案 C：继续攻 ACL（若方案 A 确认 ACL 不通）

已有的最强线索（见 `stage-04b-ble-acl-findings.md`）：
- `esp32s3_ble_send_ready()` 是空实现（但 VHCI 模式下可能是有意的）
- NuttX host 与 ESP-IDF 的控制器配置差异

---

## 六、给 A7Z 对接的现实建议

用户的最终需求：**A7Z（openvela）通过 BLE 控制 ESP32-S3 点灯**。

| 方案 | 状态 | 说明 |
| --- | --- | --- |
| **WiFi/TCP** | ✅ **已跑通** | A7Z 侧只需 TCP socket，最快达成目标 |
| BLE（A7Z 直连 ESP32-S3） | ❌ 未通 | 需先解决 ACL 问题 |
| BLE 用于手机↔A7Z，TCP 用于 A7Z↔ESP32-S3 | ⚠️ 混合 | 交互侧满足 BLE 需求，执行侧用已验证的 TCP |

**建议：先按方案 A 确认 ACL 状态**（3 分钟，用手机），
再决定是继续攻 ACL 还是走混合方案。

---

## 七、相关文件

| 文件 | 内容 |
| --- | --- |
| [`stage-04c-baseline-official-config.md`](stage-04c-baseline-official-config.md) | 干净树 + 官方配置的构建与测试方法 |
| [`stage-04b-ble-acl-findings.md`](stage-04b-ble-acl-findings.md) | ACL 问题的排查记录（30 项排除） |
| [`stage-04-FINAL-nimble-not-viable.md`](stage-04-FINAL-nimble-not-viable.md) | NimBLE 路线失败分析 |
| [`HANDOFF-CURRENT-ISSUE.md`](../../HANDOFF-CURRENT-ISSUE.md) | BLE 问题汇总 |
| `tests/hardware/serial-baseline-*.log` | 基线测试原始日志 |
| `tests/hardware/serial-gattlight-connect-watch.log` | 本项目固件的连接监听日志 |
