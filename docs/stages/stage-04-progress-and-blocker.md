# 阶段四进展与卡点（截至 2026-10-11 17:05）

> 本文记录 NimBLE 路线的当前真实状态，**包括未解决的问题**。
> 不夸大、不隐瞒，便于后续接手。

---

## 一、已确认的结论（这些是确定的）

### 1.1 硬件与控制器完全正常

同一块板、同一根线、同一个 USB 口、同一供电，只换固件：

| 检查项 | ESP-IDF v5.3.1 + NimBLE | openvela/NuttX 原生 host |
| --- | --- | --- |
| 控制器初始化 | ✅ `compile version [aa16a46]` | ✅ `compile version [0738a61]` |
| 蓝牙 MAC | `e0:72:a1:f2:8f:ea` | `e0:72:a1:f2:8f:ea`（同一） |
| PSRAM | ✅ 8MB 自检通过 | ✅ 8MB |
| 广播 / 被扫到 | ✅ `nimble-bleprph` RSSI −18 | ✅ `BTSH-LIGHT` RSSI −20 |
| 建立连接 | ✅ | ✅ `le_conn_complete: status 0` |
| **GATT 服务发现** | **✅✅ 拿到 4 个服务** | **❌ 超时** |

**结论：问题在 NuttX 自带的 BLE host 栈，不在硬件。**

### 1.2 NuttX 原生 host 的故障点

在 VHCI 回调入口（`esp32s3_ble_recv_cb()`）插桩实测，连接全程：
- `H4_EVT`（事件）：正常收到
- **`H4_ACL`（数据）：恒为 0** ← 关键

即控制器从不把 ACL 数据通过 VHCI 送上来。
**累计排除 21 个可能**（HCI 初始化、ACL 流控、Host Buffer Size、
`le_conn_complete`、低功耗唤醒、VHCI 传输层、包类型映射、
控制器 HCI 模式、L2CAP/ATT/GATT 各层代码），逐段读源码确认无缺陷。

### 1.3 顺带修复的两个真实 bug

| Bug | 位置 | 现象 | 状态 |
| --- | --- | --- | --- |
| **`BT_GATT_CCC` 参数类型错误** | `src/app/btsh_light_main.c` | BLE 一连上就崩溃复位（`rst:0x13`），每 2 秒一轮死循环 | ✅ 已修复并实测验证（连 3 次，复位 0） |
| `SIGEV_THREAD` 未开启 | NimBLE 移植层 | 构建报 `'SIGEV_THREAD' undeclared` | ✅ 加 `CONFIG_SIG_EVTHREAD=y` 解决 |

---

## 二、NimBLE 路线的当前状态

### 2.1 ✅ 已跑通的部分

**NimBLE 协议栈在 ESP32-S3 上成功运行**（用 `defconfig.nimble` 构建，
即使用 NimBLE 自带的 NuttX 示例）：

```
nsh> nimble
port init            ← 协议栈初始化成功
gap init / gatt init
ans init / ias init / lls init / tps init
hci_sock task init   ← ★ HCI socket 传输层建立
ble_host task init   ← ★ host 任务启动
hci sock task
host task

PANIC: 0    复位: 0     ← 完全稳定
```

**这一步的意义**：HCI socket 传输层**能建立**，
这正是 NuttX 原生 host 死掉的地方。证明「换 host 栈」在架构上可行。

### 2.2 ⚠️ 尚未完成的部分：把自己的应用接进去

**目标**：用本项目自己的 GATT 灯控应用（`btsh_light_main.c`，约 700 行，
已写完）替换 NimBLE 自带的残缺示例。

**应用代码已完成**，功能：
- 广播名 `BTSH-LIGHT`
- GATT 服务：`0xFF00`（128 位基址 `FF00-1234-5678-9ABC-DEF0123456xx`）
  - `0xFF01` 灯控命令 WRITE（1 字节：0=灭 1=亮）
  - `0xFF02` 灯状态 READ+NOTIFY
  - `0xFF03` 设备信息 READ
- 指示灯映射到板载 WS2812B（`/dev/leds0`），接继电器后换 `btsh_light_apply()` 即可
- 启动两个必要任务：`nimble_port_run()`（host 事件循环）+
  `ble_hci_sock_ack_handler()`（HCI socket 收包）
- **设置了 `ble_hs_cfg.sync_cb`**（样例漏了这个，所以它永远不广播）

### 2.3 🔴 当前的构建集成卡点（未解决）

**问题**：如何让「NimBLE 协议栈只编一遍」+「只有一个 main」+
「注册名正确」。三种尝试都失败：

| 尝试 | 做法 | 结果 |
| --- | --- | --- |
| A | 关闭 `CONFIG_NIMBLE_PORTING_EXAMPLE`，应用自带 `CSRCS := $(NIMBLE_SRC)` | ❌ 协议栈编两遍：`multiple definition of 'ble_sm_alg_s1'` |
| B | 应用把 `CSRCS` 清空，只留 `MAINSRC` | ❌ `CSRCS` 是 NuttX apps 构建的**全局变量**，容器与应用互相覆盖，无法可靠分工 |
| C | 打开 `PORTING_EXAMPLE=y`，改样例 Make.defs 的 `MAINSRC` 指向我们的代码 | ❌ 应用目录的空 `Makefile` 让 NuttX **自动编译本目录所有 `.c`**，与容器的 `MAINSRC` 重复；且 `PROGNAME` 仍是 `nimble`，注册名不对 |

**根本原因**（已查清）：
- NimBLE 容器 `apps/wireless/bluetooth/nimble/Makefile` 的
  `CSRCS`/`MAINSRC` 全部来自
  `porting/examples/nuttx/Make.defs`，该文件只在
  `CONFIG_NIMBLE_PORTING_EXAMPLE=y` 时被 `-include`
- NuttX 的 `Application.mk` 会自动把应用目录下所有 `.c` 编进来
- `CSRCS` 是全局变量，多个 app 的 Makefile 之间会互相污染

### 2.4 建议的解法（给接手者）

按可行性排序：

#### 方案 1（推荐）：把我们的 main 放进 NimBLE 的 examples 目录

既然 `porting/examples/nuttx/Make.defs` 已经把 `MAINSRC` 指向
`porting/examples/nuttx/main.c`，最干净的做法是：

1. 保留 `CONFIG_NIMBLE_PORTING_EXAMPLE=y`
2. 把我们的 `btsh_light_main.c` 复制到
   `porting/examples/nuttx/` 目录下（或替换原 `main.c` 的内容）
3. 在那里改 `MAINSRC` / `PROGNAME`
4. **删除我们的空 Makefile**（避免 NuttX 自动编译应用目录）

优点：协议栈只有一处编译，`NIMBLE_ROOT`/include 路径都是现成的。
缺点：改动了 NimBLE 源码（但该目录是构建时下载的，已被 gitignore，
     用安装脚本可重复施加）。

#### 方案 2：让应用目录完全自包含

把应用目录做成完整的 NimBLE 构建单元（复制样例的 `Make.defs`），
并**关闭容器**（`CONFIG_NIMBLE_PORTING_EXAMPLE=n` 且让容器不加入
`CONFIGURED_APPS`）。需要注意 `CSRCS` 全局污染问题，
可能要在应用 Makefile 里显式 `CSRCS := $(NIMBLE_SRC)` 并
确保没有一个空的 `Makefile`（那会导致自动编译）。

#### 方案 3：改用 ESP-IDF 的 NimBLE 作为 NuttX 的 host

工程量最大，但 ESP-IDF 已证明可用。

---

## 三、产出的文件

| 文件 | 说明 |
| --- | --- |
| [`src/app/nimble/btsh_light_main.c`](../../src/app/nimble/btsh_light_main.c) | ✅ 完整的 GATT 灯控应用（约 700 行，含详细注释） |
| [`src/app/nimble/Kconfig`](../../src/app/nimble/Kconfig) | 应用配置项 |
| [`src/app/nimble/Make.defs`](../../src/app/nimble/Make.defs) | 加入 `CONFIGURED_APPS` |
| [`src/app/nimble/Makefile`](../../src/app/nimble/Makefile) | ⚠️ 当前为空壳（见 §2.3 卡点） |
| [`scripts/setup/install-btsh-light-nimble.sh`](../../scripts/setup/install-btsh-light-nimble.sh) | 幂等安装脚本（含 `--check` / `--revert`） |
| [`config/.../defconfig.nimble`](../../config/boards/esp32s3-n16r8-generic/defconfig.nimble) | ✅ NimBLE 配置（样例模式，已跑通） |
| [`config/.../defconfig.nimblelight`](../../config/boards/esp32s3-n16r8-generic/defconfig.nimblelight) | ⚠️ 目标配置（构建通过但注册名/对象有问题） |
| `assets/firmware/nuttx-n16r8-nimble.bin` | ✅ 421,672 B（样例模式，可运行） |

---

## 四、环境记录

- ESP-IDF v5.3.1 装在 `~/esp-idf`（2.1G），工具链 `~/.espressif`（2.1G）
  - Python venv：`~/.espressif/python_env/idf5.3_py3.10_env/`
  - 示例工程：`~/esp-ble-test`（bleprph，已配 esp32s3 + 16MB flash + Octal PSRAM）
- NimBLE 源码：`apps/wireless/bluetooth/nimble/mynewt-nimble`
  （ref `6a5a16c7c0fab0fe7e95154493ff1fe9f0824fe3`，1.8 MB tarball）
- 板子当前烧的是：`nuttx-n16r8-gattlight.bin`（NuttX 原生 host，含 CCC 修复）
