# HT-10 — BLE GATT 灯控服务（阶段性）

- 日期：2026-10-11
- 固件：`nuttx-n16r8-gattlight.bin`（423,816 B，MD5 `d90f16c95a88f10e316bb0e2af02de21`）
- 构建配置：`config/boards/esp32s3-n16r8-generic/defconfig.gattlight`
- 源码：[`src/app/btsh_light_main.c`](../../src/app/btsh_light_main.c)
- 安装脚本：`scripts/setup/install-btsh-light.sh`
- 硬件：ESP32-S3-N16R8；Windows 侧 BLE Central（Realtek + bleak 0.22.3）

## 目标

A7Z 上位机（BLE Central）通过自定义 GATT 服务远程控制下位机的灯。

## 设计的 GATT 服务

```
Service 0xFF00
├─ 0xFF01  灯控命令   WRITE          写 1 字节：0=关灯 1=开灯
├─ 0xFF02  灯状态     READ + NOTIFY  读 1 字节：0=关 1=开
└─ 0xFF03  设备信息   READ           读 3 字节：版本/通道数/保留
```

属性表共 8 项（含 CCC），句柄从 **0x0001** 开始。

## 已完成并验证的部分

### ① 应用编译并链接成功

```
CONFIG_BTSH_LIGHT=y
CONFIG_BTSH_LIGHT_ADV_NAME="BTSH-LIGHT"
nuttx.bin  423,816 B
```

### ② GATT 服务在板上注册成功

```
$ btsh_light start
BTSH: GATT service 0xff00 registered (8 attrs)
BTSH: light OFF
BTSH: advertising as "BTSH-LIGHT"
```

### ③ 广播数据正确 —— 设备名可被中央设备解析（★ 修正了 btsak 的缺陷）

```
✓ 发现: E0:72:A1:F2:8F:EA  name='BTSH-LIGHT'  rssi=-10
```

对比 S3 阶段 `btsak` 的广播：**名字解析不出来**（`local_name: None`）。
本实现用正确的 AD 结构（`len = 1 + 数据长度`）后，**名字被正确解析**——
证明 S3 阶段对该缺陷的分析是对的。

### ④ `btsh_light state` 命令可用

```
BTSH light service
  service UUID : 0xff00
  cmd   UUID   : 0xff01 (write)
  state UUID   : 0xff02 (read/notify)
  info  UUID   : 0xff03 (read)
  adv name     : BTSH-LIGHT
  LED device   : /dev/leds0 (fd=3)
  light state  : OFF
```

## ⚠️ 未通过：连接后服务发现失败（已定位到具体环节）

### 现象

Windows（bleak）侧：

```
✓ 发现: E0:72:A1:F2:8F:EA  name='BTSH-LIGHT'  rssi=-10
步骤 2：连接 ...
asyncio.exceptions.TimeoutError        ← get_services() 阶段超时
```

### ★ 重要修正：ACL 连接**确实建立成功了**

最初用 `bt bnep0 info` 的 `Free` 字段（始终 20）判断"连接未建立"——
**这个指标是错的**，该 ioctl 不反映 LE 连接数。

打开内核日志（见下）后，实测到完整成功的连接建立过程：

```
hci_event: event 62                                    ← LE Meta 事件
le_conn_complete: status 0 handle 1 role 1 7C:FA:80:EF:CE:2B (public)
                                                       ↑ status 0 = 成功
bt_keys_find_irk: 7C:FA:80:EF:CE:2B (public)
bt_conn_set_state: disconnected -> connected           ← 状态机已连接
bt_conn_addref: handle 1 ref 2
bt_conn_addref: handle 1 ref 3
conn_tx_kthread: Started for handle 1                  ← 连接专属发送线程启动
conn_tx_kthread: calling nxsem_wait_uninterruptible()
bt_smp_connected: conn 0x3fc94d50 handle 1             ← SMP 已连接
bt_gatt_connected: conn 0x3fc94d50                     ← GATT 层已连接
bt_conn_release: handle 1 ref 2
bt_buf_release: Buffer freed: 0x3fc952a4
                        ← 日志到此为止，再无任何输出
```

| 检查项 | 结果 |
| --- | --- |
| 控制器上报 LE Connection Complete | ✅ `event 62` |
| 连接状态码 | ✅ `status 0`（成功） |
| 连接句柄 | ✅ `handle 1` |
| 角色 | `role 1`（peripheral，正确） |
| 状态机 | ✅ `disconnected -> connected` |
| 连接发送线程 | ✅ `conn_tx_kthread` 已启动 |
| SMP / GATT 层 | ✅ 均已 connected |
| **断开事件** | **无** |
| **任何错误/警告** | **无** |
| **连接后的 ATT/L2CAP 流量** | **无（日志完全静默）** |

### 结论：卡在「连接已建立 → 服务发现」之间

板子侧连接**完全正常建立且未报错**，但**此后没有任何 ATT 流量**。
Windows 端因此等不到 GATT 服务列表而超时。

### 已排查并排除

| 怀疑点 | 排查结果 |
| --- | --- |
| GATT 属性句柄从 0 开始（0x0000 无效） | ❌ 已改为从 1 开始，问题依旧 |
| `BLUETOOTH_MAX_CONN` 太小 | ❌ 实为 1（默认，合理） |
| MTU 协商逻辑 | ❌ 已读 `att_mtu_req`（bt_att.c:470）实现，正确 |
| 广播/AD 数据格式 | ❌ 名字已被正确解析 |
| 控制器或射频不工作 | ❌ 连接事件 `status 0` 已证明正常 |
| S3 阶段发现的 `LE_SET_ADV_ENABLE` 首次 EIO | ❌ 已用"先 stop 再 start"规避，日志显示 200a 正常 |
| **ACL 连接未建立** | ❌ **错误判断，实为已建立**（见上） |

### 下一步排查方向（已具备完整日志条件）

现在内核日志已可正常工作（`defconfig.gattdebug`），可直接看到 ATT 层行为：

1. **`bt_gatt_connected()` 之后的流程**。查看
   `wireless/bluetooth/bt_gatt.c` 的 `bt_gatt_connected()`，
   确认它是否/何时把 GATT 服务变更通知发给对端。
   若它只是初始化内部状态而不主动响应
   `ATT_READ_BY_TYPE_REQ`（服务发现请求），客户端就会超时。

2. **确认入站 ATT 请求是否到达**。当前日志里
   `bt_att.c` 的 `att_read_type_req()` / `att_find_info_req()` 没有任何输出，
   说明**请求可能根本没到达 ATT 层**，或到达时日志级别未覆盖。
   可在这些函数入口加 `wlinfo` 确认。

3. **L2CAP 通道**。日志显示已注册 CID `0x0004`（ATT）/`0x0005`（LE 信令）/
   `0x0006`（SMP）。需确认 ATT 通道（0x0004）是否能正确收到数据帧。

4. **检查 `bt_gatt_connected` 的实现**是否有依赖
   `CONFIG_BLUETOOTH_DISCOVERABLE` 或类似开关。

5. **对照 Android/nRF Connect** 测试，排除 Windows 特有的
   服务发现流程差异（Windows 会先做 ATT MTU 交换再发现服务）。

### 已就绪的调试配置

新增 `config/boards/esp32s3-n16r8-generic/defconfig.gattdebug`，
在 `gattlight` 基础上打开：

```
CONFIG_DEBUG_FEATURES=y          ← ★ 总开关（漏了它所有子项会被静默剔除）
CONFIG_DEBUG_ERROR=y
CONFIG_DEBUG_WARN=y
CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_WIRELESS=y
CONFIG_DEBUG_WIRELESS_ERROR=y
CONFIG_DEBUG_WIRELESS_WARN=y
CONFIG_DEBUG_WIRELESS_INFO=y     ← wlinfo 生效
```

> 📌 **踩坑记录**：依赖链是
> `DEBUG_FEATURES` → `DEBUG_ERROR/WARN/INFO` → `DEBUG_WIRELESS_*`。
> 只写后面几项会被 Kconfig **静默剔除**，表现为构建成功但
> `nuttx.bin` 大小完全不变（423,816 B），`.config` 里搜不到任何
> `DEBUG_WIRELESS`。补齐后二进制 423,816 → **437,912 B**。

原始日志：[`serial-gattdebug-connect.log`](serial-gattdebug-connect.log)、
[`serial-gattdebug-connect2.log`](serial-gattdebug-connect2.log)

## 结论

| 环节 | 状态 |
| --- | --- |
| 应用编译链接 | ✅ |
| GATT 服务注册（板上） | ✅ 0xFF00 / 8 属性 |
| 广播 + 设备名解析 | ✅ 中央设备能扫到 `BTSH-LIGHT` |
| **BLE 连接建立** | ✅ **成功**（`le_conn_complete status 0`） |
| **连接后服务发现** | ❌ **卡住**（无 ATT 流量，客户端超时） |
| 写命令控制灯 | ⏳ 依赖上一项 |
| Notify 上报 | ⏳ 依赖上一项 |

**当前状态**：连接链路已打通，卡在**服务发现（ATT 交互）** 这一层。
调试基础设施（内核日志）已就绪，下一步可直接定位 ATT 层。

## 备注：过程中踩到的坑（供后续参考）

1. **apps 里不能用 `ledinfo/wlerr` 等 NuttX 内部日志宏** —— 它们依赖
   源码树内的 `CONFIG_DEBUG_*`。改用标准 `syslog()`。

2. **`apps/wireless/bluetooth/Make.defs` 已有通配符**
   `include $(wildcard $(APPDIR)/wireless/bluetooth/*/Make.defs)`，
   所以**不需要手工挂钩**；手工追加会导致
   `overriding recipe for target` 重复定义警告。

3. **Kconfig 的 `source` 不能用 `$APPDIR` 变量**（kconfig 不展开），
   必须用**绝对路径**（官方也是这么做的）。

4. **连接状态回调 `bt_conn_cb_register()` 声明在内部头**
   `nuttx/wireless/bluetooth/bt_hcicore.h`，而该目录**不在 apps 的
   include 路径**里。因此本应用未注册连接回调，
   用 `btsh_light state` 命令查询状态代替。

5. **NuttX 的 `BT_GATT_PRIMARY_SERVICE()` 宏内部把服务 UUID 类型
   硬编码为 `BT_UUID_16`**，因此**无法声明 128 位服务 UUID**。
   本实现采用 16 位自定义 UUID。参照实现：
   `nuttx/wireless/bluetooth/bt_services.c`（自带 GAP 服务）。

## 原始记录

- [`serial-gattlight-start.txt`](serial-gattlight-start.txt)（服务启动与状态）
