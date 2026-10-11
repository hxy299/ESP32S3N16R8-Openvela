# Stage 02 — 板级适配与实机验证

- 日期：2026-10-10
- 状态：✅ **已完成**（首次实机验证通过）
- 关联提交：见本阶段结束时的 commit
- 前置阶段：[stage-01-env-and-baseline.md](stage-01-env-and-baseline.md)

---

## 1. 本阶段目标

1. 拿到开发板后，让它**真正跑起来**（首次实机烧录验证）
2. 建立 **N16R8 专用配置**（官方配置只覆盖 eye/box，且用 WROOM1N4）
3. 打通「编译 → 烧录 → 看串口 → 交互」的完整闭环
4. 固化过程中发现的所有环境/工具链坑

**验收标准**：串口出现 `nsh>` 提示符，且能执行命令得到正确输出。

---

## 2. 前置条件

| 项 | 值 |
| --- | --- |
| 开发板 | ESP32-S3-N16R8（芯路城），**本阶段首次到手** |
| 串口 | CH340 → Windows `COM4` |
| Windows Python | Anaconda 3.8.5（`C:\Users\hxy299\anaconda3\python.exe`） |
| 用户提供 | **GitHub 加速器**（Clash Verge / mihomo）监听 `127.0.0.1:7897` |
| 提权 | `su dshuser`（密码可用；注意 `hxy299` 自己的 sudo 密码不可用） |

---

## 3. 实际执行过程

### 3.1 芯片实测（**硬件事实库的关键数据来源**）

板子接上 COM4 后，用 esptool 读取芯片与 Flash 信息：

```
Chip is ESP32-S3 (QFN56) (revision v0.2)
Features: WiFi, BLE, Embedded PSRAM 8MB (AP_3v3)
Crystal is 40MHz
MAC: e0:72:a1:f2:8f:e8
```

```
Manufacturer: 68
Device: 4018
Detected flash size: 16MB
Flash type set in eFuse: quad (4 data lines)
Flash voltage set by eFuse to 3.3V
```

**由此确认（比任何资料页都权威）**：
- 芯片是 **rev v0.2**（较新版本）
- **BLE 与 WiFi 都存在**（对本项目的 BLE 方案是决定性确认）
- **PSRAM 8MB**、**Flash 16MB（quad）**
- 晶振 40 MHz，与模组标准一致
- **eFuse 出厂已烧录**（Flash 类型与电压）——这影响初始化参数选择，且 eFuse 不可逆

### 3.2 第一次烧录：官方 ESP32-S3-EYE 固件 → **挂死**

用阶段 S1 构建的 `nuttx-esp32s3-eye-openvela-wifi.bin`（1,363,024 B，
按 `ARCH_CHIP_ESP32S3WROOM1N4` + OPI PSRAM 构建）烧到 `0x0`：

**烧录成功**（`Hash of data verified.`），但启动后：

```
ESP-ROM:esp32s3-20210327
rst:0x1 (POWERON),boot:0x8 (SPI_FAST_FLASH_BOOT)
entry 0x40374fa0
*** Booting NuttX ***
dram: lma 0x00000020 vma 0x3fca9940 len 0x35cc   (13772)
iram: lma 0x000035f4 vma 0x40374000 len 0xbbc0   (48064)
padd: lma 0x0000f1c8 vma 0x00000000 len 0xe30    (3632)
imap: lma 0x00010000 vma 0x42070000 len 0xe3f34  (933684)
padd: lma 0x000f3f3c vma 0x00000000 len 0xc0bc   (49340)
dmap: lma 0x00100000 vma 0x3c010000 len 0x4cc50  (314448)
total segments stored 6
                    ← 到此为止，无 NSH
```

**判定实验**（重要：区分「挂死」与「重启循环」）：

| 实验 | 结果 | 结论 |
| --- | --- | --- |
| 不加复位静默观察 25 秒 | 0 字节 | **不是重启循环**（无周期性输出） |
| RTS 复位后再观察 | 0 字节 | — |
| 复位 + 等 10 秒发回车 | 814 字节后无响应 | **挂死**，且不接收输入 |

**初步归因**：`dmap` 段被放到 `0x3c010000`（PSRAM 映射区），而该固件的
PSRAM 配置是 `SPIRAM_TYPE_AUTO` + `MODE_OCT`——AUTO 自动探测在 Octal 模式下
可能不可靠。**但这只是怀疑，S2 并未去修它**，而是走下面的「最小基线」路线。

### 3.3 策略调整：先做最小可启动基线

不在有问题的配置上继续调试，而是**先建立能启动的最小基线**，
再逐步叠加（PSRAM → WiFi → BLE）。这样每加一项都能定位问题。

为此建立 `config/boards/esp32s3-n16r8-generic/defconfig.nsh`。

### 3.4 坑一：`configure.sh` 报 `File Make.defs could not be found`

第一次尝试用 vendor 路径构建，失败：

```
Build command line:
  .../tools/configure.sh -e .../vendor/espressif/boards/esp32s3/esp32s3-devkit/configs/nsh/
File Make.defs could not be found
Error: ############# config ... fail ##############
```

**根因**（读 `nuttx/tools/configure.sh:174-194`）：它按此顺序找 `Make.defs`：

```
1. ${TOPDIR}/boards/*/*/${boarddir}/configs/${configdir}/Make.defs   （in-tree 板级）
2. ${TOPDIR}/boards/*/*/${boarddir}/scripts/Make.defs               （in-tree 板级 scripts）
3. ${configpath}/Make.defs
4. ${configpath}/../../scripts/Make.defs
5. ${configpath}/../../../common/scripts/Make.defs
```

走 `vendor/` 路径时 (1)(2) 落空。官方 `esp32s3-eye` 的 vendor 配置目录里
**只有 defconfig**，靠 (5) 命中 `vendor/espressif/boards/esp32s3/common/scripts/`
—— 但**该目录在 `vendor/espressif` 里并不存在**（只有 `boards/*/scripts`）。

**修复**：把 in-tree 板级的 `scripts/Make.defs` 一并复制到 vendor 配置目录：

```bash
SRC_MAKEDEFS="$OPENVELA_ROOT/nuttx/boards/xtensa/esp32s3/esp32s3-devkit/scripts/Make.defs"
cp "$SRC_MAKEDEFS" "$BOARD_DIR_VENDOR/$CFGNAME/Make.defs"
```

已固化进 [`scripts/build/build-n16r8.sh`](../../scripts/build/build-n16r8.sh)。

> 📌 说明：官方 eye 配置**没有**这个问题，因为走的是「in-tree 板级」路径分支。
> 我们用 vendor 路径是**为了不污染 nuttx 源码树**（便于 patch 管理），
> 代价就是要手动带上 Make.defs。

### 3.5 坑二：手写 defconfig 反而失败，改用「最小改动」策略

我最初手写了一份完整 defconfig（含 `ESP32S3_FLASH_16M`、`FLASH_DETECT`、
`STACK_COLORATION` 等），同样报 `File Make.defs could not be found`。

**教训**：`Make.defs` 缺失会把 Kconfig 阶段的**任何**失败都伪装成同一个报错，
排查时容易被误导——**先补 Make.defs，再看真实错误**。

**策略修正**：以**官方 `esp32s3-devkit:nsh`（已验证可构建）为基底**，
只改 `ARCH_CHIP_ESP32S3WROOM1N4` → `ARCH_CHIP_ESP32S3WROOM1N16R8` 一项。
该选项会自动 `select ESP32S3_FLASH_16M` 与 `ESP32S3_PSRAM_8M`，
**因此不要再手工写 `FLASH_16M`，否则可能 Kconfig 冲突**。

### 3.6 打通 GitHub 通道（用户提供加速器）

用户提供了 Windows 侧 GitHub 加速器：**Clash Verge（`verge-mihomo`）监听
`127.0.0.1:7897`**。但有两个障碍：

| 障碍 | 现象 | 解法 |
| --- | --- | --- |
| Clash 只绑回环 | WSL（NAT 模式）访问不到 `127.0.0.1:7897`，也访问不到 `<Windows IP>:7897` | 写 `scripts/setup/relay_proxy.py` 在 Windows 侧再起一层转发，绑 `0.0.0.0:8890` 转给 `127.0.0.1:7897` |
| WSL 里 git 用 GnuTLS | `curl` 经代理正常，但 `git` 报 `gnutls_handshake() failed` | 用**环境变量** `https_proxy`（而非 `-c http.proxy` 的临时写法） |

**`relay_proxy.py` 的一个关键 bug（已修，值得记录）**：

第一版把上游返回的 `200 Connection Established` 转发给客户端后，
**没有清除 socket 超时**，导致空闲超过 30 秒就静默断开隧道：

```
TLS/HTTP 失败: ConnectionResetError: [WinError 10054] 远程主机强迫关闭了一个现有的连接
```

**修复**：数据搬运阶段必须 `settimeout(None)`。同时确保
「先回复客户端 200 再搬数据」（否则双向互等）与
「上游响应中 200 之后的剩余字节不能丢」。

验证结果：`github.com` / git 端点 / `api.github.com` / `codeload` 全部连通，
`git ls-remote` 返回 `09ebe1b0b817433ed5084b4e1aadbc3530ca0a87  HEAD`。

代理配置固化在 `~/.openvela-proxy-env`，构建脚本会自动 source。

### 3.7 在 Windows 侧安装 esptool（**踩了三个坑**）

WSL 看不到 Windows 的 USB 串口（`/dev/ttyS*` 全部打不开，因为 WSL2 的动态
串口映射只在启动时探测），所以改为**在 Windows 侧烧录**。

| 坑 | 现象 | 解法 |
| --- | --- | --- |
| ① 本地代理不可用 | `pip install esptool` 直连 PyPI，下到源码包要编译 | 用 `--proxy http://127.0.0.1:7897` 走加速器 |
| ② 缺 MSVC 编译器 | `ERROR: Failed building wheel for bitarray`（`bitarray` 是 C 扩展） | 先用 `--only-binary=:all:` **单独装依赖**（都有 cp38 win_amd64 wheel），再装 esptool |
| ③ esptool 无 wheel | esptool 所有版本在 PyPI 上**只有 sdist**（`5.5.0`/`4.9.0`/`4.8.1`/`4.8.0`/`4.7.0`… 均 wheel 数 = 0） | 依赖就绪后 `pip install --no-build-isolation esptool==4.8.1`（纯 Python，不需编译） |

**版本选择依据**：NuttX `tools/esp32s3/Config.mk` 要求 `ESPTOOL_MIN_VERSION := 4.8.0`。
Windows 侧 Python 是 3.8.5，而 esptool 5.x 要求 `>=3.10`，
**4.8.1 的 `requires_python` 是 `>=3.7`，正好匹配**。

**另注意命令名差异**：
- esptool **4.x** 用 `chip_id`（下划线）、`image_info`
- esptool **5.x** 改为 `chip-id`（连字符）、`image-info`

### 3.8 烧录与实机验证（**成功**）

构建产物（N16R8 专用、无 PSRAM/WiFi/BLE）：

| 产物 | 大小 |
| --- | --- |
| `nuttx` (ELF) | 6,126,124 B |
| `nuttx.bin` | **207,632 B** |
| text / data / bss | 121,837 / 3,452 / 130,844 |

镜像头：`Entry point: 0x40374e3c`、**`Flash size: 16MB`**、`Flash mode: DIO`。

烧录到 `0x0`（Simple Boot，无需 bootloader/分区表）：

```
Wrote 207632 bytes (83759 compressed) at 0x00000000 in 1.6 seconds
Hash of data verified.
```

**启动日志（完整成功）**：

```
ESP-ROM:esp32s3-20210327
rst:0x1 (POWERON),boot:0x8 (SPI_FAST_FLASH_BOOT)
SPIWP:0xee
mode:DIO, clock div:2
entry 0x40374e3c
*** Booting NuttX ***
dram: lma 0x00000020 vma 0x3fc8b230 len 0xd7c    (3452)
iram: lma 0x00000da4 vma 0x40374000 len 0x5140   (20800)
padd: lma 0x00005ef8 vma 0x00000000 len 0xa100   (41216)
imap: lma 0x00010000 vma 0x42030000 len 0x15fa0  (90016)
padd: lma 0x00025fa8 vma 0x00000000 len 0xa050   (41040)
dmap: lma 0x00030000 vma 0x3c010000 len 0x2b10   (11024)
total segments stored 6

NuttShell (NSH)
nsh> 
```

**NSH 命令实测**（全部正常响应）：

| 命令 | 输出 |
| --- | --- |
| `uname -a` | `NuttX 0.0.0 5315a2b7f0-dirty Oct 10 2026 21:53:59 xtensa esp32s3-devkit` |
| `free` | Umem 总 405,120 B，空闲 397,344 B |
| `ps` | PID 0 `CPU0 IDLE` (Kthread) + PID 1 `nsh_main` (Task, Running) |
| `ls /dev` | `console` `null` `ttyS0` `zero` |
| `cat /proc/version` | 显示构建路径 = 我们的 n16r8 配置 |
| `uptime` | `00:00:13 up 0:00, load average: 0.00, 0.00, 0.00` |
| `help` | 列出全部内建命令；Builtin Apps 为 `nsh` `sh` |

---

## 4. 产出物

| 类别 | 路径 | 说明 |
| --- | --- | --- |
| N16R8 板级配置 | [`config/boards/esp32s3-n16r8-generic/defconfig.nsh`](../../config/boards/esp32s3-n16r8-generic/defconfig.nsh) | 最小可启动配置，逐条注明改动与理由 |
| 一键构建脚本 | [`scripts/build/build-n16r8.sh`](../../scripts/build/build-n16r8.sh) | 自动同步 defconfig+Make.defs、检查代理/工具链/补丁 |
| 中转代理 | [`scripts/setup/relay_proxy.py`](../../scripts/setup/relay_proxy.py) | 让 WSL 用上 Windows 本地代理 |
| **固件（已验机）** | [`assets/firmware/nuttx-n16r8-nsh.bin`](../../assets/firmware/nuttx-n16r8-nsh.bin) | 207,632 B，**实测能启动到 NSH** |
| 固件符号表与配置 | `assets/firmware/System.map-n16r8-nsh`、`defconfig-n16r8-nsh` | 便于回溯与 GDB |
| 启动日志存档 | [`tests/hardware/serial-nsh-commands.txt`](../../tests/hardware/serial-nsh-commands.txt) | 含 NSH 全部命令对话原文 |
| 硬件实测数据 | [`docs/hardware/README.md`](../hardware/README.md) | 芯片 rev/Flash/PSRAM/MAC 等实测值 |

---

## 5. 验证方法与结果

| 验证项 | 方法 | 结果 |
| --- | --- | --- |
| 芯片身份 | esptool `chip_id` | ✅ ESP32-S3 QFN56 rev v0.2，WiFi+BLE+8MB PSRAM |
| Flash 容量 | esptool `flash_id` | ✅ 16MB，quad，eFuse 已设 |
| 固件合法性 | esptool `image-info` | ✅ 首字节 `0xE9`，Chip ID 9，Flash size 16MB |
| 烧录完整性 | esptool 写入校验 | ✅ `Hash of data verified.` |
| **系统启动** | 串口日志 | ✅ **出现 `nsh>` 提示符** |
| **Shell 可用** | 执行 7 条命令 | ✅ 全部正确响应 |
| 内存管理 | `free` | ✅ Umem 405,120 B 可用 |
| 任务调度 | `ps` | ✅ IDLE + nsh_main 正常 |
| 文件系统 | `ls /dev` | ✅ devtmpfs 节点正常 |

---

## 6. 结论

**阶段目标全部达成。**

1. **ESP32-S3-N16R8 上 openvela 首次实机启动成功**，NSH 可正常交互。
2. 建立了不污染 nuttx 源码树的 **N16R8 专用板级配置**方案（vendor 路径 +
   显式 Make.defs）。
3. 打通了「编译 → 烧录 → 串口 → 交互」完整闭环，且**每一步都脚本化**。
4. 排除了一大片变量：**Flash、串口、时钟、基本内存管理都是好的**。

**关于第一份（eye）固件挂死的结论**：暂未定位到确切原因（怀疑 PSRAM 相关
`SPIRAM_TYPE_AUTO` + Octal 的组合），但**已不影响主线**——我们用最小基线
绕过它，后续按需叠加 PSRAM/WiFi/BLE 时再单独验证。

---

## 7. 遗留问题与风险

### 7.1 待验证（下一步）

| 项 | 说明 | 优先级 |
| --- | --- | --- |
| **PSRAM 启用** | N16R8 的 8MB Octal PSRAM。eye 固件疑似在此挂死，需单独验证组合（`SPIRAM` + `MODE_OCT` + 明确 `TYPE_ESPPSRAM64` 而非 AUTO） | 🔴 高 |
| **BLE 启用** | 本项目核心。芯片已确认支持 BLE，但固件尚未开启 | 🔴 高 |
| **WiFi 启用** | 用户要求 BLE + WiFi 并存，需 `ESP32S3_WIFI_BT_COEXIST` | 🟡 中 |
| 板载 WS2812B (GPIO48) | 驱动未实现 | 🟡 中 |
| 继电器控制 | 硬件型号未定 | 🟡 中 |

### 7.2 环境风险

| 风险 | 说明 |
| --- | --- |
| **代理依赖** | 构建强依赖用户的 Clash 加速器 + `relay_proxy.py`。代理停掉则无法重新获取 esp-hal（但有本地缓存 155MB 兜底） |
| Windows esptool 环境脆弱 | Anaconda Python 3.8.5 + esptool 4.8.1（无 wheel，靠 `--no-build-isolation` 装成）。重装环境需重复 3.7 的步骤 |
| WSL 串口不可用 | `/dev/ttyS*` 打不开，烧录必须在 Windows 侧。若以后要在 WSL 烧录需装 usbipd（需管理员） |
| 芯片 rev v0.2 | 较新版本，若遇到诡异问题，芯片版本是第一批要核对的地方 |

### 7.3 待用户确认

| 编号 | 问题 |
| --- | --- |
| P9 | 继电器模块型号 / 接线 / 供电（影响 `bsp_relay`） |
| P10 | 灯的路数、是否需要 PWM 调光 |

---

## 8. 下一步

**建议顺序**（每步独立验证，避免多变量同时引入）：

1. **S3-a：启用 PSRAM**（`SPIRAM` + `MODE_OCT` + 显式 `TYPE_ESPPSRAM64`）
   → 烧录 → 确认启动 + `free` 看到 PSRAM 容量
2. **S3-b：启用 BLE**（基于 `esp32s3-devkit:ble`）
   → 烧录 → 确认启动 + BLE 可被扫描
3. **S3-c：BLE + WiFi 共存**（加 `ESP32S3_WIFI_BT_COEXIST`）
4. **S4：GATT 灯控服务**（自写内建应用调 `bt_gatt_register()`）
5. 并行：接继电器做 GPIO 点灯（不依赖无线）

> ⚠️ **提醒**：`ARCH_CHIP_ESP32S3WROOM1N16R8` 会自动 select `ESP32S3_PSRAM_8M`，
> 但**不等于启用了 PSRAM**——真正启用要单独开 `CONFIG_ESP32S3_SPIRAM=y`。
> 当前 nsh 配置刻意没开，这是它能稳定启动的原因之一。
