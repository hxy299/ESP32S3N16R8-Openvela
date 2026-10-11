# 脚本手册与运维指南

> 本项目的 11 个脚本各自解决一个**实际踩过的坑**。
> 本文说明：什么时候用哪个、按什么顺序、出故障怎么恢复。
>
> 配套文档：[`HANDOFF-REPRODUCE.md`](HANDOFF-REPRODUCE.md)（从零搭建）、
> [`HANDOFF-CURRENT-ISSUE.md`](HANDOFF-CURRENT-ISSUE.md)（当前阻塞问题）

---

## 1. 脚本全景图

```
                      ┌─────────────────────────────┐
   环境准备阶段        │  check-env.sh   环境体检     │
                      │  setup-esptool.sh  装 esptool│
                      └─────────────┬───────────────┘
                                    │
                      ┌─────────────▼───────────────┐
   源码准备阶段        │  apply-patches.sh   上游补丁 │  ← 必需
                      │  restore-esp-hal.sh 恢复依赖 │  ← 必需
                      │  fetch-esp-hal-submodules.sh │
                      └─────────────┬───────────────┘
                                    │
                      ┌─────────────▼───────────────┐
   项目组件安装        │  apply-board-ws2812.sh       │  ← 板级 WS2812
                      │  install-btsh-light.sh       │  ← GATT 应用
                      └─────────────┬───────────────┘
                                    │
                      ┌─────────────▼───────────────┐
   构建与烧录          │  build-n16r8.sh              │  ← 构建入口
                      │  flash.sh                    │  ← 烧录（需串口）
                      └─────────────────────────────┘

   故障时按需使用：
     setup-github-proxy.sh + gh_proxy.py   GitHub DNS 污染绕过
     relay_proxy.py                         Windows 代理中转（WSL 用）
```

---

## 2. 标准执行顺序（复制即用）

```bash
cd <本仓库>

# ---- 阶段 1：环境 ----
bash scripts/setup/check-env.sh              # 体检，先看有没有阻塞项
bash scripts/setup/setup-esptool.sh          # 装 esptool（没有它构建不出 .bin）

# ---- 阶段 2：源码 ----
bash scripts/setup/apply-patches.sh          # ★ 必需，不修编译不过
bash scripts/setup/restore-esp-hal.sh        # ★ 必需，恢复 esp-hal（优先用缓存）
bash scripts/setup/fetch-esp-hal-submodules.sh   # 5 个子模块

# ---- 阶段 3：项目组件 ----
bash scripts/setup/apply-board-ws2812.sh     # 板级 WS2812 支持
bash scripts/setup/install-btsh-light.sh     # 自写 GATT 应用

# ---- 阶段 4：构建 ----
bash scripts/build/build-n16r8.sh gattdebug

# ---- 阶段 5：烧录（Windows 侧）----
#   python -m esptool --chip esp32s3 -p COM4 -b 921600 \
#          write_flash 0x0 nuttx-n16r8-gattdebug.bin
```

**除 `check-env.sh` 外，所有脚本都是幂等的**，可放心重复执行。
所有"安装类"脚本都支持 `--check` 与 `--revert`。

---

## 3. 逐脚本详解

### 3.1 `scripts/setup/check-env.sh` — 环境体检

| 项 | 说明 |
| --- | --- |
| **何时用** | 动手编译前；或构建莫名失败时 |
| **输入** | `OPENVELA_ROOT`（默认 `~/openvela`） |
| **输出** | 逐项 `[ OK ]` / `[WARN]` / `[FAIL]` + 汇总 |
| **退出码** | `0` 全通过；`1` 有阻塞项 |

检查内容涵盖源码树、工具链、esp-hal 完整性、GitHub 连通性等。
**每一项都来自实际踩坑记录**，不是泛泛的检查。

```bash
bash scripts/setup/check-env.sh
OPENVELA_ROOT=/custom/path bash scripts/setup/check-env.sh
```

---

### 3.2 `scripts/setup/setup-esptool.sh` — 安装 esptool

| 项 | 说明 |
| --- | --- |
| **何时用** | 首次搭建；或构建"成功"但**没有 `nuttx.bin`** |
| **做什么** | ① 必要时 `apt install python3-venv python3-pip`<br>② 建 `~/myenv` 虚拟环境并装 esptool<br>③ 在 `~/.local/bin` 放 `esptool.py` 包装脚本 |

> ⚠️ **为什么必须装**：NuttX 构建最后一步用 esptool 把 `nuttx`(ELF)
> 转成可烧录的 `nuttx.bin`。**缺 esptool 时编译和链接都会成功**，
> 只是不生成 `.bin`，并提示
> `esptool.py not found. Please run: 'pip install esptool'`。
> 这是个很容易误判为"构建失败"的坑。

> ⚠️ NuttX 要求 esptool **≥ 4.8.0**，且调用的是**命令名 `esptool.py`**
> （不是 `esptool`），所以需要包装脚本。

**sudo 不可用时的等效手动步骤**：
```bash
python3 -m venv ~/myenv && ~/myenv/bin/pip install esptool
mkdir -p ~/.local/bin
printf '#!/bin/bash\nexec "$HOME/myenv/bin/python3" -m esptool "$@"\n' > ~/.local/bin/esptool.py
chmod +x ~/.local/bin/esptool.py
```

---

### 3.3 `scripts/setup/apply-patches.sh` — 应用上游补丁 ★ 必需

| 项 | 说明 |
| --- | --- |
| **何时用** | **首次搭建必做**；`repo sync` 之后必做 |
| **做什么** | 把 `thirdparty/patches/` 的两个补丁按序应用到 `~/openvela` |
| **参数** | 无 / `--check` / `--revert` |

**两个补丁都是必需的，不是可选项**：

| 补丁 | 症状 |
| --- | --- |
| `0002-esp-hal-fix-spinlock-initializer.patch` | `error: invalid initializer`<br>**所有** ESP32-S3 配置都编译不过 |
| `0001-esp32s3-add-missing-includes-for-wireless.patch` | `undefined reference to 'nxsem_post'`<br>启用 WiFi 时链接失败 |

```bash
bash scripts/setup/apply-patches.sh --check    # 先看状态
bash scripts/setup/apply-patches.sh            # 应用
```

**应用成功的标志**：
```bash
git -C ~/openvela/nuttx status --short
#  M arch/xtensa/src/esp32s3/esp32s3_wifi_adapter.c
#  M arch/xtensa/src/esp32s3/esp32s3_wifi_utils.c
#  M arch/xtensa/src/esp32s3/esp32s3_wireless.c

git -C ~/openvela/nuttx/arch/xtensa/src/esp32s3/esp-hal-3rdparty status --short
#  M components/esp_hw_support/clk_ctrl_os.c
#  M components/esp_hw_support/modem_clock.c
```

详细根因分析见 [`thirdparty/patches/README.md`](thirdparty/patches/README.md)。

---

### 3.4 `scripts/setup/restore-esp-hal.sh` — 恢复 esp-hal ★ 必需

| 项 | 说明 |
| --- | --- |
| **何时用** | `esp-hal-3rdparty` 目录消失时（**切换构建配置后常见**） |
| **参数** | 无 / `--refresh`（强制重取并刷新缓存）/ `--status` |
| **缓存** | `~/.cache/esp-hal-3rdparty-cache`（可用 `ESP_HAL_CACHE` 改） |

> ⚠️ **为什么会消失**：
> NuttX 的 `arch/xtensa/src/esp32s3/Make.defs` 里有 `distclean::` 规则
> **删除整个 `esp-hal-3rdparty` 目录**；而 `./build.sh <cfg>` 内部的
> `configure.sh -e` 在**配置变化时触发 distclean**。
> 所以每换一个 defconfig 构建，这个目录都可能没了。

**三级回退策略**（脚本自动选）：

| 级别 | 方式 | 说明 |
| --- | --- | --- |
| 1 | 本地缓存 | **秒级**，首选 |
| 2 | `git clone` + submodule | 标准做法，但本网络常不通（`gnutls_handshake() failed`） |
| 3 | codeload tarball | 兜底通道（配合 `fetch-esp-hal-submodules.sh`） |

```bash
bash scripts/setup/restore-esp-hal.sh --status    # 先看在不在
bash scripts/setup/restore-esp-hal.sh             # 恢复
```

**完整性判据**（脚本内部用）：
```
components/mbedtls/mbedtls/library/aes.c 存在
且 5 个子模块目录都非空
```

---

### 3.5 `scripts/setup/fetch-esp-hal-submodules.sh` — 获取 5 个子模块

| 项 | 说明 |
| --- | --- |
| **何时用** | `restore-esp-hal.sh` 之后；或构建报子模块错误时 |
| **参数** | 可选：esp-hal 路径<br>环境变量 `FORCE_TARBALL=1` 强制走 tarball |

**两种策略**（自动选择）：

| 策略 | 条件 | 做法 |
| --- | --- | --- |
| **A：真实 git 子模块**（首选） | `github.com` 可达 | `git submodule update --init --depth=1` |
| **B：codeload tarball**（兜底） | git 协议不通 | 查 commit + 下 tarball 解压 |

5 个子模块：

| 路径 | 仓库 |
| --- | --- |
| `components/mbedtls/mbedtls` | `espressif/mbedtls` |
| `components/esp_phy/lib` | `espressif/esp-phy-lib` |
| `components/esp_wifi/lib` | `espressif/esp32-wifi-lib` |
| `components/bt/controller/lib_esp32c3_family` | `espressif/esp32c3-bt-lib` |
| `components/esp_coex/lib` | `espressif/esp-coex-lib` |

> ⚠️ **两个必须避开的坑**：
>
> **坑 1：不要用伪造的 `.git` 指针。**
> 早期版本用 tarball 解压后手工写 `.git` 文件，导致构建时报
> `fatal: could not get a repository handle for submodule 'components/...'`。
> 因为 NuttX 的 `context::` 目标会执行真实的 `git submodule update`
> （见 `arch/xtensa/src/esp32s3/Make.defs:286-295`）。
> 现在策略 B **不写任何 `.git`**，宁可让 git 认为未初始化。
>
> **坑 2：不要用 `--filter=blob:none` 部分克隆。**
> 会产生不完整的源文件，报
> `clk_ctrl_os.c:39: error: invalid initializer`。
> **必须完整克隆。**

---

### 3.6 `scripts/setup/apply-board-ws2812.sh` — 板级 WS2812 支持

| 项 | 说明 |
| --- | --- |
| **何时用** | 构建 `statusled` / `gattlight` / `gattdebug` 配置之前 |
| **参数** | 无 / `--check` / `--revert` |

**为什么需要**：上游 `esp32s3-devkit` 板级**没有** WS2812 初始化代码
（只有 `esp32s3-lcd-ev` 有）。仅开 `CONFIG_WS2812=y` 不够，
还需要板级调用 `board_ws2812_initialize()` 来注册 `/dev/leds0`。

**脚本做三件事**（幂等）：
1. 拷贝 `config/boards/esp32s3-n16r8-generic/src/esp32s3_btsh_ws2812.c`
   → `nuttx/boards/xtensa/esp32s3/esp32s3-devkit/src/`
2. 在该板级 `Make.defs` 追加（带 `CONFIG_WS2812` 条件）：
   ```make
   # === BTSH-WS2812 ===
   ifeq ($(CONFIG_WS2812),y)
   CSRCS += esp32s3_btsh_ws2812.c
   endif
   ```
3. 在该板级 `esp32s3_bringup.c` 的 `return OK;` 前插入：
   ```c
   #if defined(CONFIG_WS2812) && !defined(CONFIG_WS2812_NON_SPI_DRIVER)
     ret = board_ws2812_initialize(0, ESP32S3_SPI2,
                                   CONFIG_WS2812_LED_COUNT);
   #endif
   ```

> 📌 **设计选择**：产物放在板级目录而非项目目录，是因为**上游板级的
> `Make.defs` 只收录自己目录下的源文件**。用"脚本安装 + 可 revert"
> 的方式，既不污染 openvela 源码树太久，又让改动有版本管理。

---

### 3.7 `scripts/setup/install-btsh-light.sh` — 安装 GATT 灯控应用

| 项 | 说明 |
| --- | --- |
| **何时用** | 构建 `gattlight` / `gattdebug` 配置之前 |
| **参数** | 无 / `--check` / `--revert` |

**脚本做两件事**（幂等）：
1. 拷贝 `src/app/{btsh_light_main.c,Makefile,Make.defs,Kconfig}`
   → `~/openvela/apps/wireless/bluetooth/btsh_light/`
2. 在 `apps/wireless/bluetooth/Kconfig` 末尾追加
   `source "<绝对路径>/btsh_light/Kconfig"`

> ⚠️ **两个坑（都踩过）**：
>
> **坑 1：`Make.defs` 不需要挂钩。**
> `apps/wireless/bluetooth/Make.defs` 末尾本来就有通配符：
> ```make
> include $(wildcard $(APPDIR)/wireless/bluetooth/*/Make.defs)
> ```
> 手工追加会导致重复包含，报
> `warning: overriding recipe for target '.../btsh_light_all'`。
> 当前脚本会**自动清理**这种历史遗留挂钩。
>
> **坑 2：Kconfig 的 `source` 不能用 `$APPDIR`。**
> kconfig 解析时不展开该变量，会报
> `'$APPDIR/wireless/bluetooth/btsh_light/Kconfig' not found`。
> **必须用绝对路径**（官方也是这么做的，见
> `apps/wireless/bluetooth/Kconfig` 里 btsak 的写法）。

---

### 3.8 `scripts/build/build-n16r8.sh` — 构建入口 ★

| 项 | 说明 |
| --- | --- |
| **何时用** | 每次构建 |
| **用法** | `bash scripts/build/build-n16r8.sh <配置名> [额外参数...]` |

**可用配置**：

| 配置名 | 内容 | 固件大小 | 状态 |
| --- | --- | --- | --- |
| `nsh` | 最小可启动基线 | 207,632 B | ✅ |
| `psram` | + 8MB Octal PSRAM | 207,672 B | ✅ |
| `ble` | + BLE | 421,620 B | ✅ |
| `blewifi` | + WiFi 与 BLE 共存 | 901,212 B | ✅ |
| `statusled` | + 板载 WS2812B | 422,904 B | ✅ |
| `gattlight` | + 自写 GATT 灯控服务 | 423,816 B | ⚠️ 服务发现待攻克 |
| `gattdebug` | 同上 + 无线内核日志 | **437,912 B** | ⚠️ 排查用 |

**脚本自动做的三件事**（这是它存在的价值）：

1. 把 `config/boards/esp32s3-n16r8-generic/defconfig.<名>` 与板级
   `Make.defs` 同步到 openvela 的 vendor 配置目录
   （`vendor/espressif/boards/esp32s3/esp32s3-devkit/configs/<名>/`）

2. **自动注入必需的编译宏** —— 读 defconfig，按内容决定：
   ```bash
   CONFIG_ESP32S3_BLE=y   → -e -DCONFIG_ESPRESSIF_BLE=1
   CONFIG_ESP32S3_WIFI=y  → -e -DCONFIG_ESPRESSIF_WIFI=1
   ```
   > ⚠️ **这是必需的**：`CONFIG_ESPRESSIF_BLE` 的 Kconfig 定义**只存在于
   > RISC-V 侧**（`arch/risc-v/src/common/espressif/Kconfig:505`），
   > Xtensa 侧完全缺失。不注入则 `esp_bt.h` 的静态断言直接编译失败：
   > `static assertion failed: "please enable bluetooth in menuconfig..."`

3. 写构建指纹到 vendor 目录的 `.btsh-build-info`，记录：
   构建时间 / 配置名 / 源 defconfig / **注入的宏** / nuttx commit / 主机信息

**额外参数示例**：
```bash
bash scripts/build/build-n16r8.sh gattdebug menuconfig   # 图形化调整
bash scripts/build/build-n16r8.sh nsh distclean          # 清理
```

> ⚠️⚠️ **绝对不要**在 `~/openvela/nuttx` 里直接跑 `make distclean`。
> `Make.defs` 的 `distclean::` 规则会**删除整个目录树**
> （本项目历史上因此丢失过整个 `nuttx` 目录）。
> **要清理请用 `build-n16r8.sh <cfg> distclean`。**

---

### 3.9 `scripts/flash/flash.sh` — 烧录

| 项 | 说明 |
| --- | --- |
| **何时用** | 烧录固件（**需 WSL 能看到串口**） |
| **用法** | `bash scripts/flash/flash.sh <固件.bin> [串口设备]` |
| **环境变量** | `BAUD`（默认 921600）、`FLASH_ADDR`（默认 `0x0`） |

**关键事实**：
- 固件烧到 **`0x0`** —— **Simple Boot**，无 bootloader、无分区表
- 物理连接必须用 **USB-ISP 口**（接 CH340 的那个），**不是 USB-OTG**
- 板载 ISP 一键下载电路，通常无需手动按 BOOT

> ⚠️ **WSL 大概率用不了这个脚本**。
> WSL2 的动态串口映射**只在 WSL 启动时探测一次**，之后插拔 USB 不更新，
> `/dev/ttyS*` 全部打不开（即使 `chmod 666`）。
> **本项目实际是在 Windows 侧烧录的**：
> ```powershell
> python -m esptool --chip esp32s3 -p COM4 -b 921600 `
>   --before default_reset --after hard_reset `
>   write_flash 0x0 nuttx-n16r8-gattdebug.bin
> ```
> 若确实想在 WSL 内烧录，需要 `usbipd-win` 透传（见脚本头部注释）。

---

### 3.10 `scripts/setup/setup-github-proxy.sh` + `gh_proxy.py` — 绕过 DNS 污染

| 项 | 说明 |
| --- | --- |
| **何时用** | `github.com` 被解析到 `127.0.0.1`，git 报 `Connection refused` |
| **参数** | 无 / `--stop` / `--status` |
| **端口** | `8888`（可用 `GH_PROXY_PORT` 改） |

**原理**：本机起一个极简 HTTP CONNECT 代理，收到
`CONNECT github.com:443` 时**忽略域名**，一律连到真实 IP
（`GH_UPSTREAM_IP`，默认 `20.205.243.166`）。
TLS 由客户端与真实 github.com **端到端**完成，代理只搬 TCP 字节，
**证书校验正常，无中间人风险**。

**不需要改 `/etc/hosts`，不需要 root。**

```bash
bash scripts/setup/setup-github-proxy.sh            # 启动并配置 git
bash scripts/setup/setup-github-proxy.sh --status   # 查状态
bash scripts/setup/setup-github-proxy.sh --stop     # 停止并移除 git 配置
```

**健壮性设计**（子模块克隆会并发多连接）：
- 每连接独立线程，异常被捕获，不影响其他连接
- 上游失败返回 `502` 而不是静默挂死
- accept 循环本身不因单次异常退出

---

### 3.11 `scripts/setup/relay_proxy.py` — Windows 代理中转

| 项 | 说明 |
| --- | --- |
| **何时用** | Windows 上有代理（Clash 等）但**只绑回环**，WSL 用不上 |
| **运行位置** | **Windows 侧** |
| **用法** | `python relay_proxy.py [监听端口] [上游地址]` |
| **默认** | `python relay_proxy.py 8890 127.0.0.1:7897` |

**问题**：Clash Verge / mihomo 监听 `127.0.0.1:7897`，**只绑回环**，
所以 WSL（NAT 模式）访问不到：
- WSL 里的 `127.0.0.1:7897` 是 WSL 自己的回环
- WSL 里 `<Windows IP>:7897` 连不上，因为 Clash 没监听那块网卡

开启 Clash 的 "Allow LAN" 能解决，但那要改用户配置。
本脚本是**免配置方案**：

```
客户端(WSL) --CONNECT--> 本脚本:8890 --CONNECT--> Clash:7897 --> 目标站点
```

**WSL 侧配置**：
```bash
WI=$(ip route show default | awk '{print $3}' | head -1)   # Windows 主机 IP
export https_proxy=http://$WI:8890
export http_proxy=http://$WI:8890
export all_proxy=http://$WI:8890
export no_proxy=localhost,127.0.0.1,::1
```

**已验证可用**（2026-10-11 推送 GitHub 时实测）：
```
Windows 侧 127.0.0.1:7897 -> verge-mihomo ✓
启动 relay_proxy.py 后 WSL 可达 192.168.48.1:8890 ✓
经代理访问 https://github.com -> HTTP 200 ✓
```

> ⚠️ **三个已修复的坑**（都在脚本注释里）：
> 1. **必须先回复客户端 200，再开始搬数据** —— 否则客户端等本脚本、
>    本脚本等上游，形成互等
> 2. **搬运阶段必须 `settimeout(None)`** —— 否则空闲超过超时时间会
>    静默关闭隧道，表现为 TLS 握手刚完成就
>    `ConnectionResetError [WinError 10054]`
> 3. **上游响应中 200 之后可能已附带数据** —— 要一并转给客户端，不能丢

> 🔒 **安全提示**：监听 `0.0.0.0` 意味着**同局域网其他机器也能借用这个代理**。
> 仅在可信网络下使用，用完 `Ctrl-C` 或关掉进程。

---

## 4. 故障速查表

### 4.1 按症状查

| 症状 | 根因 | 处置 |
| --- | --- | --- |
| `error: invalid initializer` | 补丁 `0002` 未应用 | `apply-patches.sh` |
| `undefined reference to 'nxsem_post'` | 补丁 `0001` 未应用 | `apply-patches.sh` |
| `static assertion failed: "please enable bluetooth..."` | 缺 `-DCONFIG_ESPRESSIF_BLE=1` | 用 `build-n16r8.sh`（已自动注入） |
| `fatal: could not get a repository handle for submodule` | 子模块是伪造的 `.git` | `fetch-esp-hal-submodules.sh` |
| `clk_ctrl_os.c:39: error: invalid initializer`（子模块相关） | 用了部分克隆 | 完整克隆；补丁 `0002` |
| **构建成功但没有 `nuttx.bin`** | 缺 esptool | `setup-esptool.sh` |
| `No rule to make target '.../include/arch/barriers.h'` | 残留**其他架构**的 `.o` | `./build.sh <cfg> distclean` |
| `File Make.defs could not be found` | vendor 配置目录缺 `Make.defs` | `build-n16r8.sh` 已处理 |
| `overriding recipe for target '..._all'` | `apps` 里手工挂钩了 `Make.defs` | `install-btsh-light.sh` 会自动清理 |
| `'$APPDIR/.../Kconfig' not found` | Kconfig 用了变量 | 改绝对路径 |
| **Kconfig 里加的项"消失"了** | **依赖不满足被静默剔除** | 见 §4.2 |
| `esp_bt.h` / `esp_eth.h` 找不到 | include 路径问题 | 见 `docs/bringup/wsl-esp32s3-build-notes.md` |
| 启动挂在 `total segments stored 6` 之后 | PSRAM 用了 `TYPE_AUTO` | 改 `TYPE_ESPPSRAM64` |
| `github.com` 解析到 `127.0.0.1` | DNS 污染 | `setup-github-proxy.sh` |
| WSL 里 `/dev/ttyS*` 打不开 | WSL 串口映射限制 | 从 Windows 烧录 |

### 4.2 ⚠️ Kconfig 静默剔除（最容易误判的坑）

**现象**：在 defconfig 里加了配置项，构建**成功**，但配置**没生效**
——`.config` 里搜不到该项，且**产物大小完全不变**。

**原因**：Kconfig 对依赖不满足的项会**静默剔除，没有任何警告**。

**本项目的实例**（加无线内核日志时踩到）：

```
CONFIG_DEBUG_WIRELESS_INFO  depends on DEBUG_INFO
CONFIG_DEBUG_INFO           depends on DEBUG_WARN
CONFIG_DEBUG_WARN           depends on DEBUG_ERROR
CONFIG_DEBUG_ERROR          包在 `if DEBUG_FEATURES` 里
                            ↑ 漏了这层，上面全部被剔除
```

只写 `DEBUG_WIRELESS_*` 时：产物 **423,816 B**（无变化），
`.config` 里一行 `DEBUG_WIRELESS` 都没有。
补齐 `CONFIG_DEBUG_FEATURES=y` 后：**437,912 B**，日志正常输出。

**排查手法**：
1. **对比产物大小** —— 最直接的判据
2. `grep '^CONFIG_XXX' ~/openvela/nuttx/.config` —— 看是否真的写进去了
3. 用 `menuconfig` 搜索该项（`/` 键），看它的依赖链

---

## 5. 已知的环境变量

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `OPENVELA_ROOT` | `~/openvela` | openvela 源码树路径 |
| `ESP_HAL_CACHE` | `~/.cache/esp-hal-3rdparty-cache` | esp-hal 本地缓存 |
| `ESP_HAL_PIN` | `9fc713a95b1ff150dd0b0647e465d3c624056bb1` | esp-hal 目标 commit |
| `FORCE_TARBALL` | `0` | 设为 `1` 强制用 tarball 取子模块 |
| `GH_PROXY_PORT` | `8888` | `gh_proxy.py` 监听端口 |
| `GH_UPSTREAM_IP` | `20.205.243.166` | github.com 真实 IP |
| `GH_PROXY_LOG` | `/tmp/gh_proxy.log` | gh_proxy 日志 |
| `BAUD` | `921600` | 烧录波特率 |
| `FLASH_ADDR` | `0x0` | 烧录地址（Simple Boot） |
| `VENV_DIR` | `~/myenv` | esptool 虚拟环境 |
| `http_proxy` / `https_proxy` / `all_proxy` | 无 | 标准代理变量 |

**本项目实际使用的代理环境文件** `~/.openvela-proxy-env`：
```bash
export WINDOWS_HOST_IP=192.168.48.1      # 用 `ip route | grep default` 查
export RELAY_PROXY=http://192.168.48.1:8890
export http_proxy=$RELAY_PROXY
export https_proxy=$RELAY_PROXY
export all_proxy=$RELAY_PROXY
export no_proxy=localhost,127.0.0.1,::1
```

---

## 6. 危险操作清单（**做之前先想清楚**）

| 操作 | 后果 | 正确做法 |
| --- | --- | --- |
| 在 `~/openvela/nuttx` 里跑 `make distclean` | ⛔ **删除整个 nuttx 目录树** | 用 `build-n16r8.sh <cfg> distclean` |
| `rm -rf ~/openvela/prebuilts/kconfig-frontends` | ⛔ 非 repo 管理，**无法用 `repo sync` 恢复** | 别动；它是构建产物目录 |
| `git clone --filter=blob:none` 取 esp-hal | ⚠️ 源文件不完整，编译报错 | 完整克隆 |
| 手工给子模块写 `.git` 指针 | ⚠️ 构建报 submodule 错误 | 用 `fetch-esp-hal-submodules.sh` |
| `git config url.insteadOf` 绕 GitHub | ⚠️ 破坏 SNI，`gnutls_handshake() failed` | 用环境变量代理 |
| 在 `~/openvela/nuttx` 里直接改源文件 | ⚠️ 改动丢失且不可追溯 | 放 `config/`、`src/`，用安装脚本 |

---

## 7. 脚本约定（自己加脚本时请遵守）

本项目所有脚本遵循以下约定，便于交接：

1. **中文注释**，文件头必须说明：为什么需要、解决什么问题、用法、坑
2. **幂等** —— 重复执行不产生副作用
3. **支持 `--check`**（只报告状态，不改动）与 **`--revert`**（可撤销）
4. **统一输出风格**：
   ```bash
   ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
   warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
   bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
   info() { printf '\033[36m%s\033[0m\n' "$1"; }
   ```
5. **`set -uo pipefail`**（注意：**不用 `-e`**，因为需要自行处理失败并给出友好提示）
6. **路径用 `SCRIPT_DIR` 推导**，不依赖调用时的 cwd
7. **改写 openvela 源码树时用标记包裹**，便于 `--revert` 精确定位：
   ```c
   /* === BTSH-WS2812-BEGIN === */
   ...
   /* === BTSH-WS2812-END === */
   ```

---

## 8. 相关文档

| 文档 | 内容 |
| --- | --- |
| [`HANDOFF-REPRODUCE.md`](HANDOFF-REPRODUCE.md) | 从零复现的完整步骤与精确版本 |
| [`HANDOFF-CURRENT-ISSUE.md`](HANDOFF-CURRENT-ISSUE.md) | 当前阻塞问题（GATT 服务发现） |
| [`HANDOFF-AI-ONBOARDING.md`](HANDOFF-AI-ONBOARDING.md) | 项目总览与 7 个上游问题清单 |
| [`docs/bringup/wsl-esp32s3-build-notes.md`](docs/bringup/wsl-esp32s3-build-notes.md) | **踩坑全集**（含误删 nuttx 的事故与恢复过程） |
| [`thirdparty/patches/README.md`](thirdparty/patches/README.md) | 两个上游 bug 的根因分析 |
| [`docs/stages/`](docs/stages/README.md) | S0→S3 分阶段开发记录 |
