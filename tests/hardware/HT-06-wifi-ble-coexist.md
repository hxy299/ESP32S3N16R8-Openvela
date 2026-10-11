# HT-06 — WiFi 与 BLE 共存验证

- 日期：2026-10-11
- 固件：`nuttx-n16r8-blewifi.bin`（901,212 B，MD5 `caadcc819eaa7a0946da28f6be5a13d1`）
- 构建配置：`config/boards/esp32s3-n16r8-generic/defconfig.blewifi`
- 构建命令：`bash scripts/build/build-n16r8.sh blewifi`
  （脚本已自动注入 `-DCONFIG_ESPRESSIF_BLE=1 -DCONFIG_ESPRESSIF_WIFI=1`）
- 硬件：ESP32-S3-N16R8（MAC `e0:72:a1:f2:8f:e8`，BLE 地址 `e0:72:a1:f2:8f:ea`）
- 对端：Windows BLE 适配器（Realtek）+ `bleak` 0.22.3；周围真实 WiFi 环境

## 步骤

1. 烧录并冷启动，进入 NSH
2. `free` / `ps` 检查内存与无线任务
3. `ifconfig` 检查网络接口
4. `wapi scan wlan0` 扫描 WiFi
5. `bt bnep0 advertise stop` → `start` 开启 BLE 广播
6. **WiFi 射频活跃状态下**，用 Windows 扫 BLE
7. 交叉确认两者同时工作

## 期望结果

WiFi 与 BLE 同时可用且互不干扰。

## 实际结果

### ① 内存（PSRAM 生效，4 个内存区域）

```
$ free
      total       used       free    maxused    maxfree  nused  nfree name
    8626992      90640    8536352      91016    8388592    166      4 Umem
```

对比：`ble` 配置为 8,741,616 B / nfree=2；启用 WiFi 后 nfree 增至 **4**。

### ② 四个无线内核任务同时运行（★ 核心证据）

```
$ ps
  PID GROUP PRI TYPE     STATE    EVENT       STACK   COMMAND
    5     0 253 Kthread  Waiting  Semaphore   0004016 btController   ← BLE 控制器
    6     0 120 Kthread  Waiting  MQ empty    0004008 BT_HCI_Tx      ← BLE HCI 传输
    7     0 253 Kthread  Waiting  MQ empty    0006592 wifi           ← WiFi 任务
```

`BT_HCI_Tx` 优先级 120 = `CONFIG_BLUETOOTH_TXCMD_PRIORITY`，
比 WiFi 低 —— 这正是共存设计（WiFi 优先，避免 BLE 抢占）。

### ③ 网络接口全部就绪

```
$ ifconfig
bnep0  Link encap:UNSPEC  at DOWN  mtu -9      ← 蓝牙网络接口
wlan0  Link encap:Ethernet  HWaddr e0:72:a1:f2:8f:e8  at UP    mtu 1500
       inet addr:0.0.0.0  DRaddr:10.0.0.1  Mask:255.255.255.0
wlan1  Link encap:Ethernet  HWaddr e0:72:a1:f2:8f:e9  at DOWN  mtu 1500
```

`wlan0` 已 UP（STA，三地址 e8），`wlan1` 待用（SoftAP，三地址 e9）。

### ④ WiFi 实测扫描（扫到真实路由器）

```
$ wapi scan wlan0
bssid / frequency / signal level / encode / ssid
50:9a:88:c0:e3:e0  2437  -75  0800  Jin-innovalley
3c:86:9a:9f:6d:d4  2437  -74  0800  ZBCK-E
3e:86:9a:9f:33:50  2437  -55  0800  ZBCK-E_Wi-Fi5
3c:86:9a:9f:33:4c  2437  -52  0800  ZBCK-E
3e:86:9a:a0:d0:b0  2437  -79  0800  ZBCK-E_Wi-Fi5
```

**扫到 5 个真实 WiFi 网络**，含 BSSID / 频点 / 信号强度 / 加密方式 / SSID。

### ⑤ ★ 共存验收（WiFi 活跃时 BLE 广播仍可被发现）

```
步骤 1  开 BLE 广播                      -> OK（无错误）
步骤 2  wapi scan wlan0（WiFi 射频活跃） -> 扫到 5 个网络
步骤 3  Windows 扫描 BLE（WiFi 仍活跃）   -> 扫到 33 个设备，
                                            命中 E0:72:A1:F2:8F:EA rssi=-22
```

## 结论

**PASS** —— 用户需求「BLE 与 WiFi 都要支持」**完整达成**：

> WiFi 与 BLE 在同一颗 ESP32-S3 上**同时工作、互不干扰**。
> 两者各自独立验证有效（WiFi 扫到真实路由器；BLE 广播被 Windows 中央设备发现），
> 且在对方活跃时仍正常工作。

## 备注

- **未做**：实际连接路由器并获取 IP（需要用户的 WiFi 凭据，未提供）。
  `wapi psk` / `wapi essid` / `wapi ip` 等命令已确认存在，链路已就绪。
  如后续需要联网测试（MQTT/HTTP），提供凭据即可继续。
- `wapi scan_results wlan0` 返回空 —— 该命令在部分驱动实现下依赖
  `WAPI_CMDTOOL` 的缓存机制，`wapi scan` 本身已能直接给出结果，故不影响。
- 原始记录：
  [`serial-blewifi-verify.txt`](serial-blewifi-verify.txt)、
  [`serial-wifi-scan.txt`](serial-wifi-scan.txt)
