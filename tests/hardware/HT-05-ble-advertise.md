# HT-05 — BLE 广播与中央设备发现验证

- 日期：2026-10-10
- 固件：`nuttx-n16r8-ble.bin`（421,620 B，MD5 `7eab1093dd58f0e0d4fee611f551b343`）
- 构建配置：`config/boards/esp32s3-n16r8-generic/defconfig.ble`
- 构建命令：`./build.sh <cfg> -e -DCONFIG_ESPRESSIF_BLE=1 -j16`
- 硬件：ESP32-S3-N16R8（MAC `e0:72:a1:f2:8f:e8`，BLE 地址 `e0:72:a1:f2:8f:ea`）
- 接线：USB-ISP → COM4（115200 8N1）
- 对端：Windows 侧 BLE 适配器 **Realtek Bluetooth Adapter** + Python `bleak` 0.22.3

## 步骤

1. 冷启动板子，进入 NSH
2. 执行 `bt bnep0 advertise stop`（见「发现」第 1 条：这是必要的清理步骤）
3. 执行 `bt bnep0 advertise start`
4. `bt bnep0 info` 记录 BLE 地址
5. Windows 侧用 `BleakScanner.discover(timeout=14, return_adv=True)` 扫描
6. 在结果中按地址匹配本板

## 期望结果

中央设备（Windows）能扫到本板的 BLE 广播。

## 实际结果

**① 广播启动成功（无错误输出）**

```
$ bt bnep0 advertise stop
$ bt bnep0 advertise start
nsh>
```

**② BLE 地址**

```
$ bt bnep0 info
Device: bnep0
BDAddr: e0:72:a1:f2:8f:ea
Free: 20  ACL: 20  SCO: 0
Max:  ACL: 24  SCO: 0
MTU:  ACL: 70  SCO: 70
```

**③ Windows 扫描：共 33 个设备，其中命中本板**

```
E0:72:A1:F2:8F:EA  rssi= -20  name=(无名)
```

地址与 `bt bnep0 info` 报的 `e0:72:a1:f2:8f:ea` **精确一致**；
RSSI **-20 dBm 为全场最强**（次强 -30），与"开发板就放在电脑旁"相符。

**④ 广播内容解析**

```
name         : None
local_name   : None
rssi         : -30
tx_power     : None
service_uuids: (空)
```

设备名**未被解析**（详见「发现」第 2 条）。

## 结论

**PASS** —— 核心目标达成：

> **ESP32-S3 的 BLE 广播可被中央设备发现**，证明射频、控制器、
> HCI 传输、host 协议栈、以及广播通路**整条链路可用**。
> 这是 S4（GATT Server）的前置条件，现已满足。

## 发现

### 1. `advertise start` 首次调用必失败，需要先 `stop` 一次（**重要**）

现象（可稳定复现）：

| 操作序列 | 结果 |
| --- | --- |
| 冷启动 → `advertise start` | ❌ `ioctl(SIOCBTADVSTART) failed: 5` |
| 再 `advertise start` | ❌ 同样失败 |
| **`advertise stop` → `advertise start`** | ✅ **成功** |

根因定位（读源码）：

`wireless/bluetooth/bt_hcicore.c` 的 `bt_hci_cmd_send_sync()` 末尾有：

```c
if (ret >= 0)
  {
    if (buf->u.hci.sync == NULL)
      {
        wlerr("ERROR:  Failed get return parameters\n");
        ret = -EIO;                            /* ← 就是这个 EIO(5) */
      }
```

注释说明：*"An I/O error will be declared if the response does not occur
within the timeout interval."* —— 即控制器未在超时内回复
`BT_HCI_OP_LE_SET_ADV_ENABLE`。

`bt_start_advertising()` 会**连续发 4 条 HCI 命令**：

```
LE_SET_ADV_DATA        (bt_hci_cmd_send，异步)
LE_SET_SCAN_RSP_DATA   (bt_hci_cmd_send，异步)
LE_SET_ADV_PARAMETERS  (bt_hci_cmd_send，异步)
LE_SET_ADV_ENABLE      (bt_hci_cmd_send_sync，同步等待)   ← 等这条
```

冷启动后直接发起这一串，最后一条的同步等待超时；而先做一次
`advertise stop`（发 `LE_SET_ADV_ENABLE(0)`）之后，同样的序列就成功。

**结论**：这是 NuttX host 栈与 ESP32-S3 控制器之间的时序/状态初始化问题，
**不是硬件缺陷**。实用 workaround：**启动广播前先执行一次 `advertise stop`**。
S4 自写应用时应在初始化阶段主动做这一步。

### 2. 广播名未被中央设备解析（`local_name: None`）

根因（读 `apps/wireless/bluetooth/btsak/btsak_advertise.c:120-130`）：

```c
memset(&sd, 0, 2 * sizeof(struct bt_eir_s));
sd[1].len         = sizeof("btsak");
sd[1].type        = BT_EIR_NAME_COMPLETE;
strlcpy((FAR char *)sd[1].data, "btsak", sizeof(sd[1].data));
```

`bt_eir_s` 的结构是 `{len, type, data[]}`，标准 AD 结构要求
**`len` = type 长度(1) + 数据长度**。这里把 `len` 设成了 `sizeof("btsak")` = 6
（即数据长度），少算了 type 那 1 字节；且 `strlcpy` 写入时也含结尾 `\0`。
结果是 AD 结构长度字段不自洽，中央设备解析时跳过或丢弃该项。

另外 `ad[0]`（flags）用的是 `len = 2` + `type` + `data[0]`，这个是对的 ——
所以扫描能识别出设备存在，但读不到名字。

**结论**：`btsak` 是 NuttX 的**示例/调试工具**，其广播数据构造比较粗糙。
**S4 自写 GATT 服务时必须用正确构造的 AD 结构**（`len = 1 + 数据长度`），
广播名应设为项目名（如 `BTSH-LIGHT-<MAC 后4位>`）。

## 备注

- 广播期间**同时**可以扫描（实测 `scan get` 在广播状态下仍能工作并扫到
  5 个设备），说明 ESP32-S3 控制器支持同时 peripheral + central 角色。
  这对本项目有潜在价值（下位机未来或可主动连接其他从设备）。
- `dmesg` 命令不可用（`open failed: 2`），因为配置未开 `CONFIG_SYSLOG_DMESG`
  或未挂载相应设备节点。排错时可考虑开启以看到 `wlinfo/wlerr` 内核日志。
- 原始记录：
  [`serial-ble-advertise.txt`](serial-ble-advertise.txt)、
  [`serial-ble-advertise-repro.txt`](serial-ble-advertise-repro.txt)
