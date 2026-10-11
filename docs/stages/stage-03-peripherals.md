# Stage 03 — 外设与无线启用（进行中）

- 日期：2026-10-10
- 状态：🚧 **进行中**（PSRAM ✅ / BLE ✅ 但广播待解决 / WiFi ⏳）
- 前置阶段：[stage-02-board-port.md](stage-02-board-port.md)
- 关联提交：见本阶段结束时的 commit

> **策略**：每步只引入**一个变量**，独立验证后再叠加。
> 这样任何一步失败都能立刻定位到是哪一项引入的。

---

## 1. 本阶段目标

在 S2 已验证的「最小可启动基线」之上，按序叠加：

| 子阶段 | 目标 | 状态 |
| --- | --- | --- |
| **S3-a** | 启用 8MB Octal PSRAM | ✅ **完成** |
| **S3-b** | 启用 BLE | ✅ **控制器可用**（广播待解决） |
| S3-c | 启用 WiFi + BLE 共存 | ⏳ 未开始 |
| S3-d | 板载 WS2812B (GPIO48) 状态灯 | ✅ **完成**（目视确认颜色渐变） |

---

## 2. S3-a：启用 PSRAM ✅

### 2.1 配置改动（`config/boards/esp32s3-n16r8-generic/defconfig.psram`）

以 `defconfig.nsh` 为基底，只加 7 项：

| 配置项 | 值 | 理由 |
| --- | --- | --- |
| `CONFIG_ESP32S3_SPIRAM` | y | 顶层开关 |
| `CONFIG_ESP32S3_SPIRAM_MODE_OCT` | y | N16R8 是 **Octal**（8 线）PSRAM |
| **`CONFIG_ESP32S3_SPIRAM_TYPE_ESPPSRAM64`** | y | ★ **关键：不用 `TYPE_AUTO`** |
| `CONFIG_ESP32S3_SPIRAM_BOOT_INIT` | y | 启动时初始化 |
| `CONFIG_ESP32S3_SPIRAM_COMMON_HEAP` | y | 追加到内核堆，便于 `free` 验证 |
| `CONFIG_ESP32S3_SPIRAM_SPEED_40M` | y | 先保守，跑通再提速 |
| `CONFIG_MM_REGIONS` | 2 | 内存区域数 1→2（内部 SRAM + PSRAM） |

### 2.2 为什么坚持不用 `SPIRAM_TYPE_AUTO`

依据 `arch/xtensa/src/esp32s3/Kconfig:940-948`，`SPIRAM_SIZE` 由类型推导：

```
TYPE_AUTO       -> SPIRAM_SIZE = -1        （未定，靠运行时探测）
TYPE_ESPPSRAM64 -> SPIRAM_SIZE = 8388608   （8MB）
```

**而 S2 中那份挂死的官方 eye 固件正是 `TYPE_AUTO` + `MODE_OCT` 的组合。**
显式声明类型后，配置里出现 `CONFIG_ESP32S3_SPIRAM_SIZE=8388608`，
构建与启动一次通过。**S2 的怀疑由此得到印证。**

### 2.3 验证结果

```
$ free
      total       used       free    maxused    maxfree  nused  nfree name
    8792160       7808    8784352       8184    8388592     26      2 Umem
```

| 指标 | nsh 基线 | 启用 PSRAM | 变化 |
| --- | --- | --- | --- |
| 总内存 | 405,120 B | **8,792,160 B** | **+8,387,040 B ≈ +8 MB** ✅ |
| 内存区域数 | 1 | **2** | ✅ |
| 启动 | nsh> | nsh>，无 PANIC | ✅ |

产物：`assets/firmware/nuttx-n16r8-psram.bin`（207,672 B，
MD5 `668a6abbce22f763f2ff82af038c804b`）

---

## 3. S3-b：启用 BLE ✅（控制器可用，广播待解决）

### 3.1 遇到的阻塞：`CONFIG_ESPRESSIF_BLE` 缺失

构建报错：

```
esp_bt.h:261: error: static assertion failed: "please enable bluetooth in menuconfig to use esp_bt.h"
esp32s3_ble_adapter.c:3057: error: 'BT_CTRL_BLE_MAX_ACT_LIMIT' undeclared
esp32s3_ble_adapter.c:3082: error: 'CONFIG_BT_CTRL_PINNED_TO_CORE' undeclared
```

**根因链**（逐层查到）：

1. esp-hal 为 NuttX 提供了静态配置头
   `esp-hal-3rdparty/nuttx/esp32s3/include/sdkconfig.h`，
   且 `hal.mk` 已把它加入 include 路径（`nuttx/$(CHIP_SERIES)/include`，
   `CHIP_SERIES` 实测解析为 `esp32s3`）✅
2. `esp_bt.h:13` 确实 `#include "sdkconfig.h"` ✅
3. 但 `sdkconfig.h:939` 把 BLE 相关宏包在条件里：
   ```c
   #ifdef CONFIG_ESPRESSIF_BLE
   #define CONFIG_BT_ENABLED 1
   #define CONFIG_BT_CTRL_PINNED_TO_CORE 0
   ...（共 34 个 CONFIG_BT_CTRL_* 宏）
   #endif
   ```
4. **`CONFIG_ESPRESSIF_BLE` 的 Kconfig 定义只存在于 RISC-V 侧**
   （`arch/risc-v/src/common/espressif/Kconfig:505`，且
   `depends on ESPRESSIF_ESP32C3`）。
   **Xtensa 的 `arch/xtensa/src/common/espressif/Kconfig` 里完全没有它** ——
   该文件有 `ESPRESSIF_WIFI`（多处），但没有 `ESPRESSIF_BLE`。
5. `config ESP32S3_BLE`（`arch/xtensa/src/esp32s3/Kconfig:684`）
   只 `select ESP32S3_WIRELESS`，**没有 select ESPRESSIF_BLE**。

**结论**：这是 openvela 当前树里 **ESP32-S3 BLE 支持的一处缺口** ——
Kconfig 桥接没接通。

### 3.2 绕过方案（**不改源码树**）

`build.sh` 的 `-e` 参数可以透传额外编译选项，因此直接注入宏即可：

```bash
./build.sh vendor/espressif/boards/esp32s3/esp32s3-devkit/configs/ble/ \
  -e -DCONFIG_ESPRESSIF_BLE=1 -j16
```

**结果：`rc=0`，编译通过。** 比 patch 源码树干净得多。

> 📌 这说明缺口其实很小 —— `sdkconfig.h` 里那 34 个 `CONFIG_BT_CTRL_*`
> 宏本来就齐备，只是被一个 `#ifdef` 挡住了。
> **后续应把 `-DCONFIG_ESPRESSIF_BLE=1` 固化进 `build-n16r8.sh`**（待办）。

产物：`assets/firmware/nuttx-n16r8-ble.bin`（**421,620 B**，比 PSRAM 版
207KB 大一倍，BLE 协议栈进来了；MD5 `7eab1093dd58f0e0d4fee611f551b343`）

### 3.3 验证结果

**① 启动正常、PSRAM 仍在**

```
$ free
      total       used       free    maxused    maxfree  nused  nfree name
    8741616      55560    8686056      55936    8388592    107      2 Umem
```

**② 蓝牙内核线程已创建**（`ps` 输出，决定性证据）

```
PID GROUP PRI TYPE     STATE    EVENT       STACK   COMMAND
  5     0 253 Kthread  Waiting  Semaphore   0004024 btController     ← 控制器任务
  6     0 100 Kthread  Waiting  MQ empty    0004032 BT_HCI_Tx        ← HCI 传输线程
```

`btController` 优先级 **253**，与 `CONFIG_ESP32S3_BLE_TASK_PRIORITY` 默认值一致 ✅

**③ 控制器信息可读**

```
$ bt bnep0 info
Device: bnep0
BDAddr: e0:72:a1:f2:8f:ea      ← 比芯片 MAC (…:e8) 大 2，是 BLE 专用地址
Free: 20  ACL: 20  SCO: 0
Max:  ACL: 24  SCO: 0
MTU:  ACL: 70

$ bt bnep0 features le
Page 0:  ff f9 01 08  00 00 00 00    ← LE 特性位图
```

**④ 扫描真实可用**（★ 最强证据）

```
$ bt bnep0 scan start
$ bt bnep0 scan get
Scan result:
 1. addr: 38:a1:4e:0e:b8:e3  rssi: -62
 2. addr: 57:f7:23:62:7d:59  rssi: -69
 3. addr: 28:45:ac:0e:34:ba  rssi: -84
 4. addr: 28:45:ac:0e:34:ba  rssi: -83
 5. addr: 88:56:a6:01:2b:ba  rssi: -53
```

**扫到了 5 个周边真实 BLE 设备**，带回 RSSI 与 advertiser data
（其中 #5 的广播数据里能读出设备名 `Walle-8856A6012BB8`）。

→ **射频、控制器、HCI 传输、host 协议栈整条链路都已打通。**

### 3.4 ✅ 广播问题已解决 — 端到端验证通过

> **重要**：本节最初判定"广播失败"，后续排查发现**不是失败，而是时序/状态问题**。
> 完整实测记录见 [`tests/hardware/HT-05-ble-advertise.md`](../../tests/hardware/HT-05-ble-advertise.md)。

#### 3.4.1 现象与 workaround

| 操作序列 | 结果 |
| --- | --- |
| 冷启动 → `bt bnep0 advertise start` | ❌ `ioctl(SIOCBTADVSTART) failed: 5` |
| 再 `advertise start` | ❌ 同样失败 |
| **`advertise stop` → `advertise start`** | ✅ **成功** |

**根因定位**（读 `wireless/bluetooth/bt_hcicore.c`）：

`bt_hci_cmd_send_sync()` 内部：

```c
ret = nxsem_tickwait_uninterruptible(&sync_sem, MSEC2TICK(TIMEOUT_MSEC));
if (ret >= 0)
  {
    if (buf->u.hci.sync == NULL)
      {
        wlerr("ERROR:  Failed get return parameters\n");
        ret = -EIO;                          /* ← 就是这个 EIO(5) */
      }
```

注释原文：*"An I/O error will be declared if the response does not occur
within the timeout interval."*

而 `bt_start_advertising()` 会**连发 4 条 HCI 命令**，只有最后一条是同步等待：

```
LE_SET_ADV_DATA        (异步 bt_hci_cmd_send)
LE_SET_SCAN_RSP_DATA   (异步)
LE_SET_ADV_PARAMETERS  (异步)
LE_SET_ADV_ENABLE      (同步 bt_hci_cmd_send_sync)  ← 等这条，超时→EIO
```

冷启动后直接发起这一串会超时；先做一次 `advertise stop`（发
`LE_SET_ADV_ENABLE(0)`）之后同样序列就成功。

**结论**：这是 NuttX host 栈与 ESP32-S3 控制器之间的**时序/状态初始化问题**，
不是硬件缺陷。**实用 workaround：启动广播前先执行一次 `advertise stop`。**
S4 自写应用时应在初始化阶段主动做这一步。

#### 3.4.2 端到端验证（★ 决定性证据）

板上广播开启后，用 **Windows 侧 BLE 适配器（Realtek）+ Python `bleak`** 扫描：

```
扫描到 33 个设备，其中：
  E0:72:A1:F2:8F:EA  rssi= -20  name=(无名)
```

| 证据 | 说明 |
| --- | --- |
| **地址精确匹配** | `E0:72:A1:F2:8F:EA` ≡ 板上 `bt bnep0 info` 的 `BDAddr` |
| **RSSI = -20 dBm** | 全场最强（次强 -30），符合"板子就在电脑旁" |

→ **ESP32-S3 的 BLE 广播可被中央设备发现**，射频/控制器/HCI/host/广播通路
**整条链路验证通过**。**S4（GATT Server）的前置条件已满足。**

#### 3.4.3 附带发现：广播名未被解析（S4 需修正）

`name`/`local_name` 均为 `None`。根因在
`apps/wireless/bluetooth/btsak/btsak_advertise.c:120-130`：

```c
sd[1].len         = sizeof("btsak");     /* = 6，但标准 AD 的 len 应为
                                            type(1) + 数据长度 = 1 + 5 */
sd[1].type        = BT_EIR_NAME_COMPLETE;
strlcpy((FAR char *)sd[1].data, "btsak", sizeof(sd[1].data));
```

长度字段不自洽，中央设备解析时跳过该项。对比 `ad[0]`（flags）用的是
`len = 2` + type + data，**那个是对的** —— 所以能扫到设备存在但读不到名字。

**结论**：`btsak` 是 NuttX 的**调试示例**，AD 构造粗糙。
**S4 自写 GATT 服务时必须用正确的 AD 结构**（`len = 1 + 数据长度`），
广播名用项目名（如 `BTSH-LIGHT-<MAC 后4位>`）。

#### 3.4.4 附带发现：可同时广播与扫描

实测在广播状态下 `scan get` 仍能工作并扫到 5 个设备
→ ESP32-S3 控制器支持同时充当 peripheral + central 角色。
对本项目有潜在价值（下位机未来或可主动连接其他从设备）。

> 📌 `dmesg` 命令不可用（`open failed: 2`），排错时若需看 `wlinfo/wlerr`
> 内核日志，需开启对应配置。

---

## 3.5 S3-c：WiFi + BLE 共存 ✅ 完全达成

> 完整实测记录见 [`tests/hardware/HT-06-wifi-ble-coexist.md`](../../tests/hardware/HT-06-wifi-ble-coexist.md)

### 3.5.1 配置

新增 `config/boards/esp32s3-n16r8-generic/defconfig.blewifi`，
在 `defconfig.ble` 基础上加 WiFi 相关项（取自官方 `blewifi` 与 `ble` 的差异）：
`ESP32S3_WIFI`、`ESP32S3_WIFI_STATION_SOFTAP`、`WIRELESS_WAPI(+CMDTOOL)`、
`NETINIT_DHCPC`、`NETDEV_WIRELESS_IOCTL`、`NET_ICMP_SOCKET`、`SYSTEM_PING`、
`NET_UDP(_WRITE_BUFFERS)`、`NET_TCP_DELAYED_ACK/WRITE_BUFFERS`、
`IOB_NBUFFERS=124`、`IOB_THROTTLE=24`、`PREALLOC_MQ_MSGS=64`，以及
**共存关键的蓝牙任务优先级** `BLUETOOTH_TXCMD_PRIORITY=120` /
`BLUETOOTH_TXCONN_PRIORITY=119`（低于 WiFi，确保 WiFi 优先）。

**共存开关无需手写**：`Kconfig:879-884` 的 `ESP32S3_WIFI_BT_COEXIST`
在 `ESP32S3_WIFI && ESP32S3_BLE` 时**默认 y**，实测 `.config` 里确实为 `y`。

### 3.5.2 构建必须同时注入两个宏

`sdkconfig.h:1029`：

```c
#if defined(CONFIG_ESPRESSIF_BLE) && defined(CONFIG_ESPRESSIF_WIFI)
#define CONFIG_ESP_COEX_SW_COEXIST_ENABLE 1
#endif
```

**两个都要**才能启用软件共存。因此构建命令是：

```bash
./build.sh <cfg> -e -DCONFIG_ESPRESSIF_BLE=1 -e -DCONFIG_ESPRESSIF_WIFI=1 -j16
```

**这一步已自动化**：`build-n16r8.sh` 现在会读 defconfig，检测到
`CONFIG_ESP32S3_BLE=y` / `CONFIG_ESP32S3_WIFI=y` 就自动注入对应宏，
并写进 `.btsh-build-info` 指纹。**不再需要手敲。**

### 3.5.3 实测结果

**① 四个无线内核任务同时运行（核心证据）**

```
$ ps
  PID GROUP PRI TYPE     STATE    EVENT       STACK   COMMAND
    5     0 253 Kthread  Waiting  Semaphore   0004016 btController
    6     0 120 Kthread  Waiting  MQ empty    0004008 BT_HCI_Tx
    7     0 253 Kthread  Waiting  MQ empty    0006592 wifi
```

**② 内存与网络接口**

```
$ free
      total       used       free    maxfree  nused  nfree name
    8626992      90640    8536352    8388592    166      4 Umem

$ ifconfig
bnep0  UNSPEC  at DOWN  mtu -9
wlan0  Ethernet HWaddr e0:72:a1:f2:8f:e8  at UP    mtu 1500   ← WiFi STA
wlan1  Ethernet HWaddr e0:72:a1:f2:8f:e9  at DOWN  mtu 1500   ← SoftAP
```

**③ WiFi 实测扫描（扫到真实路由器）**

```
$ wapi scan wlan0
50:9a:88:c0:e3:e0  2437  -75  0800  Jin-innovalley
3c:86:9a:9f:6d:d4  2437  -74  0800  ZBCK-E
3e:86:9a:9f:33:50  2437  -55  0800  ZBCK-E_Wi-Fi5
3c:86:9a:9f:33:4c  2437  -52  0800  ZBCK-E
3e:86:9a:a0:d0:b0  2437  -79  0800  ZBCK-E_Wi-Fi5
```

**④ ★ 共存验收**

| 步骤 | 结果 |
| --- | --- |
| 开 BLE 广播 | OK，无错误 |
| `wapi scan wlan0`（WiFi 射频活跃） | 扫到 **5 个**网络 |
| Windows 扫 BLE（WiFi 仍活跃） | 33 个设备中命中 `E0:72:A1:F2:8F:EA`，**rssi=-22** |

→ **WiFi 与 BLE 同时工作、互不干扰。用户需求完整达成。**

产物：`assets/firmware/nuttx-n16r8-blewifi.bin`（**901,212 B**，
MD5 `caadcc819eaa7a0946da28f6be5a13d1`）

### 3.5.4 未做（需用户凭据）

**实际连接路由器并获取 IP** 未做 —— 需要 WiFi SSID/密码，用户未提供。
链路已就绪（`wapi psk` / `essid` / `ip` 等命令确认存在），
如后续要测 MQTT/HTTP 联网，提供凭据即可继续。

---

## 3.6 S3-d：板载 WS2812B 状态灯（GPIO48）✅ 完全验证（含目视确认）

> 完整记录见 [`tests/hardware/HT-07-ws2812-statusled.md`](../../tests/hardware/HT-07-ws2812-statusled.md)

### 3.6.1 上游没有现成支持，需要自己补

`esp32s3-devkit` 板级**没有** WS2812 初始化代码（只有 `esp32s3-lcd-ev` 有）。
仅开 `CONFIG_WS2812=y` 不够 —— 还需要板级调用 `board_ws2812_initialize()`。

NuttX 的既有设施（都可用）：

| 组件 | 路径 |
| --- | --- |
| 通用驱动 | `drivers/leds/ws2812.c`（SPI 模式模拟单总线时序） |
| 注册接口 | `ws2812_leds_register(devpath, spi, nleds)` |
| ESP32 适配 | `arch/xtensa/src/common/espressif/esp_ws2812.c` |
| 官方参考实现 | `boards/xtensa/esp32s3/esp32s3-lcd-ev/src/esp32s3_ws2812.c` |

### 3.6.2 本项目提供的补充

1. **源文件** [`config/boards/esp32s3-n16r8-generic/src/esp32s3_btsh_ws2812.c`](../../config/boards/esp32s3-n16r8-generic/src/esp32s3_btsh_ws2812.c)
   —— 逻辑等价于官方 LCD-EV 版，去掉 LCD 依赖。

2. **安装脚本** [`scripts/setup/apply-board-ws2812.sh`](../../scripts/setup/apply-board-ws2812.sh)（幂等，支持 `--check`/`--revert`）：
   - 拷贝源文件到 `nuttx/boards/xtensa/esp32s3/esp32s3-devkit/src/`
   - 在该板级 `Make.defs` 追加 `CSRCS += esp32s3_btsh_ws2812.c`（带 `CONFIG_WS2812` 条件）
   - 在该板级 `esp32s3_bringup.c` 的 `return OK;` 前插入初始化调用

### 3.6.3 配置

`config/boards/esp32s3-n16r8-generic/defconfig.statusled`，在 `defconfig.ble` 基础上加：

```
CONFIG_WS2812=y
CONFIG_WS2812_LED_COUNT=1
CONFIG_WS2812_FREQUENCY=8000000
CONFIG_ESP32S3_SPI2=y
CONFIG_ESP32S3_SPI2_MOSIPIN=48      ← 关键：数据线 GPIO48
CONFIG_EXAMPLES_WS2812=y            ← 官方测试应用，提供 ws2812 命令
```

> ⚠️ WS2812 **无 CS/RESET 线**，靠 SPI 时钟模拟时序，因此**独占 SPI2**，
> 该总线不能再用于其它 SPI 设备。

### 3.6.4 实测结果

```
$ ls /dev
/dev:
 console
 leds0        ← ★ 驱动注册成功
 null
 random
 timer0
 ttyS0
 zero

$ ws2812 -h
Usage: ws2812 [OPTIONS]
  [-p path] selects the ws2812 device.  Default: /dev/leds0
  [-l leds] selects number of ws2812s in the chain.  Default: 1
  [-r repeat] selects the number change cycles.  Default: 4
  [-d delay] selects delay between updates.  Default: 20000 us

$ ws2812 -p /dev/leds0 -r 3 -d 800000
$ ws2812 -p /dev/leds0 -r 2 -d 500000
（均无错误输出）
```

| 环节 | 状态 |
| --- | --- |
| 驱动编译进内核 | ✅ |
| SPI2 MOSI → GPIO48 | ✅ |
| 板级注册函数被调用 | ✅ `/dev/leds0` 出现 |
| 测试命令可执行 | ✅ 无报错 |
| **RGB 实际发光** | ✅ **用户目视确认「颜色在渐变」** |

> 📌 `ws2812` 命令**不接颜色参数**，它自己跑配色循环，只有 `-p/-l/-r/-d`
> 四个选项。最初按 `ws2812 <r> <g> <b>` 使用会报 `Invalid options format`。

产物：`assets/firmware/nuttx-n16r8-statusled.bin`（422,904 B，
MD5 `330818583ae39b0f3863e6ffdaacdbc8`）

---

## 4. 产出物

| 类别 | 路径 |
| --- | --- |
| PSRAM 配置 | [`config/boards/esp32s3-n16r8-generic/defconfig.psram`](../../config/boards/esp32s3-n16r8-generic/defconfig.psram) |
| BLE 配置 | [`config/boards/esp32s3-n16r8-generic/defconfig.ble`](../../config/boards/esp32s3-n16r8-generic/defconfig.ble) |
| WiFi+BLE 配置 | [`config/boards/esp32s3-n16r8-generic/defconfig.blewifi`](../../config/boards/esp32s3-n16r8-generic/defconfig.blewifi) |
| 固件 | `assets/firmware/nuttx-n16r8-{psram,ble,blewifi}.bin` |
| 用例记录 | [`HT-05-ble-advertise.md`](../../tests/hardware/HT-05-ble-advertise.md)、[`HT-06-wifi-ble-coexist.md`](../../tests/hardware/HT-06-wifi-ble-coexist.md) |
| 串口证据 | `tests/hardware/serial-{psram-verify,ble-verify,ble-deep,ble-advertise,ble-advertise-repro,blewifi-verify,wifi-scan}.txt` |
| 构建脚本增强 | [`scripts/build/build-n16r8.sh`](../../scripts/build/build-n16r8.sh) 自动注入 `CONFIG_ESPRESSIF_BLE/WIFI` |

---

## 5. 结论

| 子阶段 | 结论 |
| --- | --- |
| S3-a PSRAM | ✅ **完全达成** —— 8MB 可用，无 PANIC |
| S3-b BLE | ✅ **完全达成** —— 控制器+host 打通，scan 有效，**广播经 Windows 中央设备端到端验证** |
| S3-c WiFi+BLE 共存 | ✅ **完全达成** —— WiFi 扫到真实路由器，**且 WiFi 活跃时 BLE 广播仍可被发现** |
| S3-d WS2812B 状态灯 | ✅ **完全达成** —— `/dev/leds0` 注册成功，**用户目视确认颜色渐变** |

**重要收获**：
1. ESP32-S3 的 **BLE 与 WiFi 硬件在本板都完全可用**，不必担心芯片能力。
2. 用户的核心无线需求（BLE + WiFi 并存）**已验证达成**。
3. `btsak` 的广播 AD 构造有缺陷（名字解析不出），**S4 必须自己写正确的 AD**。

---

## 6. 下一步

1. **S3-d**：WS2812B (GPIO48) 状态灯驱动
2. **S4**：自写 GATT 灯控服务（`bt_gatt_register`）
   - 必须用**正确的 AD 结构**（`len = 1 + 数据长度`），
     广播名用 `BTSH-LIGHT-<MAC 后4位>`
   - 初始化阶段**主动先做一次 `advertise stop`** 再 `start`
     （规避 S3-b 发现的时序问题）
3. 继电器到位后并行做 GPIO 点灯（不依赖无线）

---

## 7. 待用户确认（不阻塞）

- 继电器模块型号 / 接线 / 供电（`bsp_relay` 定引脚用）
- 灯的路数、是否需要 PWM 调光
- 是否需要实际联网（需提供 WiFi SSID/密码）
