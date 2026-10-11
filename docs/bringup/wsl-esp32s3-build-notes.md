# WSL2 下构建 openvela ESP32-S3 的完整排错记录

- **日期**：2026-10-10
- **环境**：WSL2 Ubuntu 22.04，openvela `dev` 分支（nuttx commit `5315a2b7f0`）
- **目标**：`vendor/espressif/boards/esp32s3/esp32s3-eye/configs/openvela/`
- **性质**：本文是**实测记录**，不是推测。所有结论都有对应的报错原文。

> ⚠️ **官方文档明确说明**：「本文仅适配 Ubuntu 22.04。**不支持在 Windows Subsystem
> for Linux (WSL) 或 Docker 容器环境中进行编译**。」
> 出处：`参考/Openvela-doc/docs/zh-cn/quickstart/openvela_ubuntu_quick_start.md` 第 9 行。
>
> 但 WSL 实际可用，只是需要额外处理下面列出的几个网络/环境问题。
> 本文就是把这些额外处理固化下来，让 WSL 路径可复现。

---

## 0. TL;DR — 正确的构建流程

```bash
cd ~/openvela

# 一次性：解决 github.com DNS 污染（ESP32 系列必需）
bash <项目>/scripts/setup/setup-github-proxy.sh

# 官方要求的清理
rm -f nuttx/.config nuttx/Make.defs

# 官方构建命令：build.sh <defconfig目录路径> [menuconfig|distclean] [-jN]
./build.sh vendor/espressif/boards/esp32s3/esp32s3-eye/configs/openvela/ -j$(nproc)
```

**不要**用 `nuttx/tools/configure.sh` + `make` 直接构建。`build.sh` 是官方入口，
它额外做了 kconfig-frontends 自建、环境变量注入等事情。

---

## 1. 关键认知：`build.sh` 才是入口，不是 `make`

我最初按 NuttX 上游习惯用：

```bash
cd nuttx && ./tools/configure.sh -e esp32s3-devkit:nsh && make -j20    # ❌ 错误路径
```

结果遇到一连串本可避免的问题。官方文档给出的正确形式是（`build.sh` 源码
`board_config=$1`，后接 make 选项）：

```bash
./build.sh <defconfig目录> [-jN]      # ✅ 官方路径
./build.sh <defconfig目录> menuconfig  # 图形配置
./build.sh <defconfig目录> distclean   # 清理
```

`build.sh` 内部做的事（源码 `~/openvela/build.sh`）：

1. `source build/envsetup.sh` — 注入各 vendor 的环境变量
2. 若 `prebuilts/kconfig-frontends/bin/kconfig-conf` 不存在且系统也没有，
   **自动从源码构建 kconfig-frontends**（`./configure && make install`）
3. 调用 `nuttx/tools/configure.sh -e <cfg>`（注意：`-e` 由 build.sh 自己传）
4. `make -C nuttx EXTRAFLAGS="-Wno-cpp -Wno-deprecated-declarations" -jN`
5. `make savedefconfig` 并回写 defconfig

**为什么 `configure.sh -e` 危险**：`-e` 表示「配置变化时执行 distclean」。
这个 distclean 会删掉 `nuttx/.config`、`Make.defs`，以及
`arch/xtensa/src/esp32s3/esp-hal-3rdparty`（Make.defs 里的
`distclean:: $(call DELDIR,chip/$(ESP_HAL_3RDPARTY_REPO))`）。
由 `build.sh` 调用时它是有预期后果的；手动裸调时容易把源码树搞坏。

---

## 2. 坑一：`github.com` 被 DNS 污染（**最关键**）

### 报错原文

```
fatal: unable to access 'https://github.com/espressif/esp-hal-3rdparty.git/':
Failed to connect to github.com port 443 after 28 ms: Connection refused
make[1]: *** [chip/Make.defs:261: chip/esp-hal-3rdparty] Error 128
```

### 根因

```
$ getent ahostsv4 github.com
127.0.0.1    github.com          ← 被劫持到回环地址
```

但真实服务是**可达**的：

| 域名 | 解析结果 | 连通性 |
| --- | --- | --- |
| `github.com` | `127.0.0.1` | ❌ Connection refused |
| `codeload.github.com` | `20.205.243.165` | ✅ HTTP 200 |
| `20.205.243.166`（github.com 真实 IP） | — | ✅ curl 带 Host 头返回 200 |

### 为什么 ESP32 系列躲不开

`arch/xtensa/src/esp32s3/Make.defs:227` 硬编码：

```make
ESP_HAL_3RDPARTY_URL = https://github.com/espressif/esp-hal-3rdparty.git
ESP_HAL_3RDPARTY_VERSION = 9fc713a95b1ff150dd0b0647e465d3c624056bb1
```

并且 `context::` 目标会在需要时 `git clone` 它，还会初始化 5 个子模块
（**也都指向 github.com**）：

| 子模块 | commit |
| --- | --- |
| `components/mbedtls/mbedtls` | `72aa687352a469044cbb946f3fdb261430e41ce1` |
| `components/esp_phy/lib` | `06e7625de197bc12797dd701d6762229bca01826` |
| `components/esp_wifi/lib` | `dffb3f92194f571c18473387ab9fac62a1f64e67` |
| `components/bt/controller/lib_esp32c3_family` | `29d5555ca1febeb132f5a13556893f3419d2d640` |
| `components/esp_coex/lib` | `94ebf43111a5889a3a97fd470b7148cd6b692b7c` |

> 这也解释了为什么用户之前适配 RP2040 / STM32F411 / Luckfox 都没遇到——
> **只有 ESP32 全系列需要从 GitHub 拉取这个第三方 HAL**。

### 尝试过但**无效**的方案

| 方案 | 结果 |
| --- | --- |
| `git -c http.curloptResolve=github.com:443:<IP>` | ❌ git 不认这个配置项（自己实现 DNS） |
| `git config url."https://<IP>/".insteadOf "https://github.com/"` | ❌ Host 头变成 IP，SSL 证书校验失败：`certificate subject name (github.com) does not match target host name` |
| `codeload.github.com` 下 tarball 代替 clone | ⚠️ 部分可行，但 tarball **不含子模块内容**，且后续 `git submodule update` 依旧失败 |

### 有效方案（免 sudo）

写一个**本机 HTTP CONNECT 代理**，收到 `CONNECT github.com:443` 时
**忽略域名、强制连到真实 IP**。TLS 由客户端与真实 github.com 端到端完成，
证书校验正常。

```bash
# 脚本已入库
bash scripts/setup/setup-github-proxy.sh

# 它做的事：
python3 scripts/setup/gh_proxy.py 8888 20.205.243.166 &
git config --global http.https://github.com/.proxy http://127.0.0.1:8888

# 验证
git ls-remote https://github.com/espressif/esp-hal-3rdparty.git HEAD
```

**为什么不用改 `/etc/hosts`**：那需要 root，且是全局改动。CONNECT 代理方案
完全在用户态，只影响显式配置了代理的 git 操作。

**IP 失效时怎么办**：`github.com` 的 IP 可能变化。用
`getent ahostsv4 codeload.github.com` 取一个新值，或
`GH_UPSTREAM_IP=<新IP> bash scripts/setup/setup-github-proxy.sh`。

---

## 3. 坑二：`esp-hal-3rdparty` 必须**完整**克隆，不能用 `--filter=blob:none`

### 报错原文

```
chip/esp-hal-3rdparty/components/esp_hw_support/clk_ctrl_os.c:39:38: error: invalid initializer
   39 | static lock_type_t periph_spinlock = LOCK_INITIALIZER_UNLOCKED;
      |                                      ^~~~~~~~~~~~~~~~~~~~~~~~~
make[1]: *** [Makefile:138: .../clk_ctrl_os.o] Error 1
```

### 根因

我为了加速用了 `git clone --filter=blob:none --no-checkout`，
导致部分 blob 未落盘，`clk_ctrl_os.c` 里的宏定义段**缺失/为空**，
于是 `LOCK_INITIALIZER_UNLOCKED` 展开异常。

**判断方法**：对比文件大小与内容。完整版 `clk_ctrl_os.c` = **4755 字节**，
且第 27 行能看到 `#define LOCK_INITIALIZER_UNLOCKED       0`。

### 正确做法

```bash
cd ~/openvela/nuttx/arch/xtensa/src/esp32s3
rm -rf esp-hal-3rdparty
git clone --depth=1 --no-checkout \
  https://github.com/espressif/esp-hal-3rdparty.git esp-hal-3rdparty
cd esp-hal-3rdparty
git fetch --depth=1 origin 9fc713a95b1ff150dd0b0647e465d3c624056bb1
git checkout 9fc713a95b1ff150dd0b0647e465d3c624056bb1
git submodule update --init --depth=1 <上面表格里的 5 个路径>
```

完整克隆后大小约 **200 MB**（含子模块）。

> 📌 **重要**：NuttX 的 `distclean` 会删除整个 `esp-hal-3rdparty` 目录
> （`Make.defs` 里的 `distclean::` 规则）。所以每次 `distclean` 后都要
> 重新克隆 + 初始化子模块（约 3–5 分钟）。因此**能不全量 distclean 就不要**。

---

## 4. 坑三：跨架构残留的 `.o` 导致链接期莫名报错

### 报错原文

```
make[1]: *** No rule to make target '/home/hxy299/openvela/nuttx/include/arch/barriers.h',
        needed by 'libxx_delete.o'.  Stop.
```

### 根因

`libxx_delete.o` 是**之前 STM32F411（ARM）构建**留下的产物（时间戳 17:57），
而当前目标是 Xtensa。ARM 架构有 `arch/arm/include/barriers.h`，
**Xtensa 架构没有这个文件**（openvela 该版本 `arch/xtensa/include/` 下确实不存在）。

切换架构时，`build.sh` 不保证清理旧 `.o`，于是 make 用陈旧的依赖关系去找
ARM 才有的头文件。

### 正确做法

官方文档给了这个用法（`STM32F411.md` 第 397–403 行）：

```bash
./build.sh <cfg> distclean    # 清理
./build.sh <cfg> -j8          # 重建
```

**切换目标架构（ARM ↔ Xtensa ↔ RISC-V）时必须 distclean。**

---

## 5. 坑四：`kconfig` 相关的两件事

### 5.1 `kconfig-tweak: command not found`

`configure.sh` 在刷新配置时会调用 `kconfig-tweak`。
`build.sh` 会自建 kconfig-frontends，但**裸调 `configure.sh` 不会**。

**不要**从 Ubuntu 的 `.deb` 里抽二进制塞进 `prebuilts/kconfig-frontends/`：
系统版是 **4.11.0.1（2016 年代码）**，解析 openvela 的 Kconfig 时会报：

```
../apps/tests/Kconfig:11: 'endmenu' in different file than 'menu'
Kconfig:2940: unexpected end statement
make: *** [tools/Unix.mk:726: olddefconfig] Error 1
```

**正确做法**：走 `build.sh`，让它自己构建匹配版本的 kconfig-frontends；
或 `sudo apt install kconfig-frontends`（但仍有版本风险）。

### 5.2 `ERROR: environment variable APPSDIR is not set`

裸调 `make` 时缺环境变量。`build.sh` 通过 `source build/envsetup.sh` 注入。
若必须手动调 kconfig，至少要设：

```bash
export APPSDIR=~/openvela/apps
export APPSBINDIR=~/openvela/apps
export BINDIR=~/openvela/nuttx
export TOPDIR=~/openvela/nuttx
export EXTERNALDIR=~/openvela/apps/external
```

---

## 6. ⚠️ 一次破坏性操作的事故记录（供后来者避坑）

**我做了什么**：在 `~/openvela/nuttx` 里执行 `make distclean`，
随后发现 **`~/openvela/nuttx` 整个目录消失**。

**为什么会这样（分析）**：`tools/Unix.mk` 的 `distclean` 目标链条包含
`subdir_distclean` 与 `clean_context`，其中大量使用
`$(call DELDIR, ...)` / `$(call DELFILE, ...)`。当 `TOPDIR` 等变量未正确设置时，
删除目标的路径可能回退到当前目录，造成远超预期的删除范围。

**如何恢复**（已实测成功）：

```bash
BARE=~/openvela/.repo/project-objects/nuttx.git
COMMIT=5315a2b7f0ab864efa34d7ee13532b34ee4e926b   # 删除前的 HEAD

git clone --no-checkout --shared "$BARE" ~/openvela/nuttx
cd ~/openvela/nuttx && git checkout "$COMMIT"
```

恢复后校验：`git ls-files | wc -l` 应为 **23988**；ESP32-S3 板级目录应有 9 个。

**预防措施**：

1. **优先用 `./build.sh <cfg> distclean`**，不要在 `nuttx/` 里裸调 `make distclean`
2. 破坏性操作前记录 `git -C nuttx rev-parse HEAD`
3. 关键 `.config` 先备份（例如 `cp nuttx/.config /tmp/nuttx_config_backup`）

---

## 7. 环境体检脚本

上述所有检查项已固化为：

```bash
bash scripts/setup/check-env.sh
```

它会逐条判定：源码树完整性、工具链版本、GitHub 可达性（含真实 git 实测）、
esp-hal 完整性与子模块、esptool、串口设备、构建依赖，并给出阻塞项汇总。

---

## 8. ✅ 构建结果（已验证）

### 8.1 两个配置都构建成功

| 配置 | `build.sh` 参数 | rc | `nuttx.bin` | text / data / bss |
| --- | --- | --- | --- | --- |
| `esp32s3-devkit:nsh`（无无线） | `nuttx/boards/xtensa/esp32s3/esp32s3-devkit/configs/nsh` | **0** | 207,620 B | 121,825 / 3,452 / 130,832 |
| `esp32s3-eye:openvela`（**含 WiFi**） | `vendor/espressif/boards/esp32s3/esp32s3-eye/configs/openvela/` | **0** | **1,363,024 B** | 1,296,194 / 13,772 / 521,244 |

无线配置的 `nuttx` ELF 为 19.5 MB（含调试符号）。

### 8.2 产物合法性验证

`esptool.py image-info nuttx.bin` 输出：

```
ESP32-S3 Image Header
Image version: 1
Entry point: 0x40374e3c
Segments: 2
Flash size: 4MB
Flash freq: 40m
Flash mode: DIO
Chip ID: 9 (ESP32-S3)
```

`nuttx.bin` 首字节 `e9`（ESP32 镜像魔术字）；`readelf` 确认
`Class: ELF32`、`Machine: Tensilica Xtensa Processor`。

→ **是合法的、可烧录的 ESP32-S3 固件。**

### 8.3 无线配置的实测 Kconfig

```
CONFIG_ESP32S3_WIFI=y
CONFIG_ESP32S3_SPIRAM=y
CONFIG_ESP32S3_SPIRAM_MODE_OCT=y     # N16R8 需要的 OPI PSRAM
CONFIG_SMP=y
CONFIG_WIRELESS_WAPI=y
```

> ⚠️ 两点必须注意：
> 1. 该官方配置的芯片型号是 `ARCH_CHIP_ESP32S3WROOM1N4`（**4 MB Flash**）。
>    我们的 N16R8 要改成 `ARCH_CHIP_ESP32S3WROOM1N16R8` —— 阶段 S2 的工作。
> 2. 该配置**不含 BLE**（没有 `CONFIG_ESP32S3_BLE`），只开了 WiFi。
>    本项目需要 BLE + WiFi，应基于 `esp32s3-devkit:blewifi` 叠加 OPI PSRAM 配置。

---

## 9. 🐞 发现的两处上游 bug（不修则编译不过）

> **本轮最重要的发现**：openvela 当前 dev 分支上，**所有 ESP32-S3 配置都无法直接编译**。
> 两处都已定位到具体文件与行号，补丁存于
> [`thirdparty/patches/`](../../thirdparty/patches/)。

### bug 1（致命）：esp-hal 的 spinlock 初始化与 NuttX 新 API 不兼容

**现象**（`nsh` 与 `openvela` 两个配置都会命中）：

```
chip/esp-hal-3rdparty/components/esp_hw_support/clk_ctrl_os.c:27:41: error: invalid initializer
   39 | static lock_type_t periph_spinlock = LOCK_INITIALIZER_UNLOCKED;
      |                                      ^~~~~~~~~~~~~~~~~~~~~~~~~
chip/.../clk_ctrl_os.c:27:42: note: (near initialization for 'periph_spinlock.lock')
   27 | #define LOCK_INITIALIZER_UNLOCKED       0
```

**根因**：

| 事实 | 出处 |
| --- | --- |
| NuttX 的 `spinlock_t` 是**结构体** `{ atomic_t lock; }` | `nuttx/include/nuttx/spinlock_type.h:93` |
| NuttX **不存在** `SPINLOCK_INITIALIZER` 宏 | 全树 grep 无结果 |
| esp-hal 却把 `LOCK_INITIALIZER_UNLOCKED` 定义为标量 `0` | `clk_ctrl_os.c:27`、`modem_clock.c:35` |

即 `struct spinlock_s = 0` → GCC 报 `invalid initializer`。
esp-hal 的 pin（`9fc713a95b1ff150dd0b0647e465d3c624056bb1`，
commit message 甚至写着 "fix compile error."）早于 NuttX 把 spinlock
改成结构体的那次改动。

**修复**：`0` → `{0}`（等价于 NuttX 的 `SP_UNLOCKED`）

```c
#define LOCK_INITIALIZER_UNLOCKED       {0}
```

**影响面**：这两个文件是**唯一**用 `= 0` 初始化 spinlock 的地方；
其它文件（`periph_ctrl.c`、`phy_init.c` 等）用 `static spinlock_t x;`
（零初始化，合法），所以只需改两处。

### bug 2：无线相关文件缺 `#include`，导致链接期符号名不匹配

**现象**（仅启用 WiFi 的配置命中）：

```
chip/esp32s3_wifi_utils.c:278: warning: implicit declaration of function 'nxsem_tickwait'
chip/esp32s3_wifi_utils.c:386: warning: implicit declaration of function 'nxsem_post'
...
xtensa-esp32s3-elf-ld: staging/libarch.a(esp32s3_wifi_utils.o):
    undefined reference to `nxsem_tickwait'
xtensa-esp32s3-elf-ld: ... undefined reference to `nxsem_post'
```

**根因**：隐式声明的函数被当作 `int f()`，Xtensa 上符号名会带上
不同的调用约定，于是链接期找不到匹配符号。真因是缺头文件。

**修复**：

| 文件 | 补的 include |
| --- | --- |
| `esp32s3_wifi_utils.c` | `<nuttx/semaphore.h>` |
| `esp32s3_wireless.c` | `<nuttx/semaphore.h>` |
| `esp32s3_wifi_adapter.c` | `<nuttx/semaphore.h>`、`<nuttx/tls_task.h>` |

### 补丁与自动化

```bash
bash scripts/setup/apply-patches.sh           # 应用（幂等）
bash scripts/setup/apply-patches.sh --check   # 只检查
bash scripts/setup/apply-patches.sh --revert  # 撤销
```

---

## 10. 环境依赖安装（esptool）——**必须**

NuttX 最后一步用 `esptool.py` 把 ELF 转成 `nuttx.bin`。
**缺 esptool 时编译和链接都会成功，但不产出可烧录的 .bin**：

```
MKIMAGE: ESP32-S3 binary
esptool.py not found. Please run: 'pip install esptool'
Run make again to create the nuttx.bin image.
```

**Ubuntu 22.04 的坑**：系统默认可能既没有 `pip` 也没有 `ensurepip`，
`python3 -m venv` 也因缺 `python3-venv` 而失败。先装：

```bash
sudo apt install python3-venv python3-pip
```

然后一步到位：

```bash
bash scripts/setup/setup-esptool.sh
```

它建 venv、装 esptool，并在 `~/.local/bin/esptool.py` 放一个包装脚本。

> **为什么需要包装脚本**：NuttX `tools/esp32s3/Config.mk` 里
> `ESPTOOL_MIN_VERSION := 4.8.0`，且调用命令名 `esptool.py`。
> 但 esptool 5.x 起不再提供名为 `esptool.py` 的可执行文件，
> 所以包装脚本把这个名字补上。

---

## 11. 一键构建

以上所有前置处理都已固化：

```bash
# 环境体检
bash scripts/setup/check-env.sh

# 应用上游 bug 补丁
bash scripts/setup/apply-patches.sh

# 构建（自动处理工具链 PATH、GitHub 代理、补丁检查）
bash scripts/build/build-esp32s3.sh
bash scripts/build/build-esp32s3.sh vendor/espressif/boards/esp32s3/esp32s3-eye/configs/openvela
```

---

## 12. 待办 / 未验证

| 项 | 状态 |
| --- | --- |
| `esp32s3-devkit:nsh` 构建 | ✅ 通过 |
| `esp32s3-eye:openvela`（WiFi）构建 | ✅ 通过 |
| 产物合法性（esptool image-info / readelf） | ✅ 通过 |
| **BLE 配置构建**（`esp32s3-devkit:ble`） | ⏳ 待验证 |
| **BLE + WiFi + OPI PSRAM 组合**（本项目实际需要的形态） | ⏳ 待验证 |
| N16R8 芯片型号（`ARCH_CHIP_ESP32S3WROOM1N16R8`） | ⏳ 阶段 S2 |
| 实机烧录（`make flash ESPTOOL_PORT=... ESPTOOL_BINDIR=./`） | ⏳ **无开发板，无法验证** |
| USB 串口透传到 WSL（usbipd-win） | ⏳ 未配置 |
| 自定义 `esp32s3-n16r8` 板级目录 | ⏳ 阶段 S2 |
