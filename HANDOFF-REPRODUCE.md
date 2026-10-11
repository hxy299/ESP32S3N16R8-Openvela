# 从零复现指南

> 目标：在一台**全新**机器上，从零把这个项目构建出来并烧录到板子上。
> 所有版本号都是**实测确认的精确值**，不是"大约"。
>
> 📖 本文讲"按什么顺序做"；**每个脚本内部细节与故障处置见
> [`HANDOFF-SCRIPTS-RUNBOOK.md`](HANDOFF-SCRIPTS-RUNBOOK.md)**。

---

## 0. 复现难度与前置条件

| 项 | 说明 |
| --- | --- |
| 难度 | ⚠️ **较高**。openvela 官方**明确不支持 WSL**，但本项目在 WSL2 下跑通了（需若干绕过） |
| 操作系统 | **Windows 10/11 + WSL2 Ubuntu 22.04.5 LTS**（本项目实际环境）<br>纯 Linux 也可，反而更顺（官方支持） |
| 磁盘 | ≥ **80 GB**（openvela 全树 + 预编译工具链很大） |
| 内存 | ≥ 8 GB |
| 网络 | 需要能访问 `gitee.com`（manifest）与 `github.com`（esp-hal 子模块） |
| 硬件 | ESP32-S3-N16R8 开发板 + USB 线（CH340 串口） |
| 时间 | 首次全流程约 **2–4 小时**（主要是 `repo sync` 与首次编译） |

> 💡 **如果只是要审阅代码/文档，不需要完整复现。**
> 直接读 [`HANDOFF-AI-ONBOARDING.md`](HANDOFF-AI-ONBOARDING.md)
> 与 [`HANDOFF-CURRENT-ISSUE.md`](HANDOFF-CURRENT-ISSUE.md) 即可，
> 所有源码、补丁、日志都已在仓库里。

---

## 1. 精确版本清单（★ 关键）

复现失败最常见的原因是**版本漂移**。以下是本项目验证过的确切版本。

### 1.1 openvela 源码树

| 组件 | 值 |
| --- | --- |
| manifest 仓库 | `https://gitee.com/open-vela/manifests.git` |
| manifest 分支 | `default` |
| manifest commit | `94f7cacbe639465507e3b466542dde5b2b9f7cbc` |
| manifest 文件 | `openvela.xml` |
| **`nuttx` commit** | **`5315a2b7f0ab864efa34d7ee13532b34ee4e926b`** |
| `nuttx` describe | `5315a2b7f0-dirty`（dirty 来自本项目必需的补丁，见 §4） |
| **`apps` commit** | **`52a26471afa56861ee48db0c797532ada414dd23`** |
| 树根路径 | `~/openvela`（官方约定，勿改） |

### 1.2 external 依赖

| 组件 | 值 |
| --- | --- |
| `esp-hal-3rdparty` 路径 | `nuttx/arch/xtensa/src/esp32s3/esp-hal-3rdparty` |
| **commit（必须精确）** | **`9fc713a95b1ff150dd0b0647e465d3c624056bb1`** |
| 完整大小 | 约 234 MB（含子模块） |
| 子模块数 | 5 个（见 §4.3） |

### 1.3 工具链

| 组件 | 版本 | 路径 |
| --- | --- | --- |
| Xtensa GCC | **`crosstool-NG esp-12.2.0_20230208` → GCC 12.2.0** | `~/openvela/prebuilts/gcc/linux-x86_64/xtensa-esp32s3-elf/bin/` |
| GNU Make | 4.3 | 系统 |
| CMake | 3.22.1 | 系统 |
| esptool | **v5.5.0**（WSL 侧，用于构建出 bin） | `~/myenv/bin/python3 -m esptool` |
| esptool | **4.8.1**（Windows 侧，用于烧录） | Anaconda Python 3.8.5 |
| Python | 3.10.12（WSL 系统）/ 3.8.5（Windows Anaconda） | — |

> ⚠️ **`esp-hal-3rdparty` 与 `nuttx` 的 commit 必须精确匹配**，
> 否则 `thirdparty/patches/` 里的补丁会失效。

---

## 2. 步骤一：搭建 WSL 与基础环境

### 2.1 安装 WSL2 + Ubuntu 22.04

```powershell
wsl --install -d Ubuntu-22.04
```

### 2.2 安装依赖

```bash
sudo apt update
sudo apt install -y \
  git curl wget python3 python3-pip python3-venv \
  build-essential gperf flex bison libncurses-dev \
  rsync file unzip bc xxd
```

> 📌 若 `sudo` 密码不可用，可先 `su <管理员用户>` 再操作
> （本项目环境就是这样绕过 `sudo` 密码问题的）。

### 2.3 安装 `repo` 工具

```bash
mkdir -p ~/bin
curl -s https://storage.googleapis.com/git-repo-downloads/repo > ~/bin/repo
chmod a+x ~/bin/repo
export PATH="$HOME/bin:$PATH"
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
```

> 若 `storage.googleapis.com` 不可达，可用清华镜像或从
> `gitee.com/open-vela` 相关文档获取替代安装方式。

---

## 3. 步骤二：获取 openvela 源码

### 3.1 初始化并同步

```bash
mkdir -p ~/openvela && cd ~/openvela

repo init -u https://gitee.com/open-vela/manifests.git \
          -b default -m openvela.xml

repo sync -c -j8
```

**耗时较长**（视网速 30 分钟~2 小时）。

### 3.2 检出精确版本

同步完成后，**务必**把两个仓库检到本项目验证过的 commit：

```bash
cd ~/openvela

# nuttx
git -C nuttx checkout 5315a2b7f0ab864efa34d7ee13532b34ee4e926b

# apps
git -C apps checkout 52a26471afa56861ee48db0c797532ada414dd23
```

> ⚠️ 若 `repo sync` 拉到的版本已更新，**补丁可能失效**。
> 先跑 `bash scripts/setup/apply-patches.sh --check` 确认。

### 3.3 常见问题

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `github.com` 解析到 `127.0.0.1` | DNS 污染 | 见 §3.4 代理方案 |
| `fatal: unable to access ... Connection refused` | 需要代理 | 见 §3.4 |
| `gnutls_handshake() failed` | SNI 被 `url.insteadOf` 破坏 | **不要**用 `git config url.insteadOf`，用环境变量代理 |

### 3.4 GitHub 访问方案（本机实测有效）

本机的实际情况（供参考，你的环境可能不同）：

| 域名 | 直连状态 |
| --- | --- |
| `github.com:443` | ❌ 不可达 |
| `github.com:22` | ✅ 可达 |
| `ssh.github.com:443` | ✅ 可达 |
| `api.github.com` | ✅ 可达 |
| `codeload.github.com` | ✅ 可达 |
| `pypi.org` | ✅ 可达 |

**方案 A（推荐）：SSH over 443**
```bash
# ~/.ssh/config
Host github.com
  HostName ssh.github.com
  Port 443
  User git
```

**方案 B：Windows 侧中转代理**
`scripts/setup/relay_proxy.py` 在 Windows 上监听 `0.0.0.0:8890`，
转发到本机 HTTP 代理（如 Clash 的 `127.0.0.1:7897`）：

```powershell
# Windows 侧
python relay_proxy.py --listen 0.0.0.0:8890 --upstream 127.0.0.1:7897
```

```bash
# WSL 侧
cat >> ~/.openvela-proxy-env <<'EOF'
export WINDOWS_HOST_IP=192.168.48.1        # 用 `ip route | grep default` 查
export RELAY_PROXY=http://192.168.48.1:8890
export http_proxy=$RELAY_PROXY
export https_proxy=$RELAY_PROXY
export all_proxy=$RELAY_PROXY
export no_proxy=localhost,127.0.0.1,::1
EOF
source ~/.openvela-proxy-env
```

> ⚠️ `relay_proxy.py` 有个已修复的坑：socket 超时若不清空，
> 30 秒空闲会杀掉隧道（`WinError 10054`）。当前版本已处理。

---

## 4. 步骤三：应用必需的补丁（★ 不做则编译不过）

### 4.1 为什么必需

openvela 当前 dev 分支上，**所有 ESP32-S3 配置都无法直接编译**：

| 补丁 | 症状 |
| --- | --- |
| `0002-esp-hal-fix-spinlock-initializer.patch` | `error: invalid initializer`（`spinlock_t` 是结构体，被初始化成标量 `0`） |
| `0001-esp32s3-add-missing-includes-for-wireless.patch` | `undefined reference to 'nxsem_post'` / `'nxsem_tickwait'` |

### 4.2 应用

```bash
cd <本仓库>
bash scripts/setup/apply-patches.sh          # 幂等，可重复执行
bash scripts/setup/apply-patches.sh --check  # 只检查
bash scripts/setup/apply-patches.sh --revert # 撤销
```

应用后 `git -C ~/openvela/nuttx status --short` 应显示 3 个 `.c` 文件被修改，
`esp-hal-3rdparty` 显示 2 个 `.c` 文件被修改。

### 4.3 获取 `esp-hal-3rdparty` 及其 5 个子模块

```bash
bash scripts/setup/restore-esp-hal.sh              # 从缓存恢复（若有）
bash scripts/setup/fetch-esp-hal-submodules.sh     # 用真实 git submodule 获取
```

5 个子模块（**必须是真的 git submodule**）：

| 路径 | 仓库 |
| --- | --- |
| `components/mbedtls/mbedtls` | `espressif/mbedtls` |
| `components/esp_phy/lib` | `espressif/esp-phy-lib` |
| `components/esp_wifi/lib` | `espressif/esp32-wifi-lib` |
| `components/bt/controller/lib_esp32c3_family` | `espressif/esp32c3-bt-lib` |
| `components/esp_coex/lib` | `espressif/esp-coex-lib` |

> ⚠️ **踩坑**：早期版本用 tarball 解压 + 写伪造的 `.git` 指针，
> 导致构建时 `fatal: could not get a repository handle for submodule`。
> 现在的脚本走真实 `git submodule update --init --depth=1`。

> ⚠️ **另一个坑**：`git clone --filter=blob:none`（部分克隆）会导致
> 源文件不完整，报 `clk_ctrl_os.c:39: error: invalid initializer`。
> **必须完整克隆。**

---

## 5. 步骤四：安装本项目自写的组件

这两个脚本都是**幂等**的，可反复执行。

### 5.1 板级 WS2812 支持（上游没有）

```bash
bash scripts/setup/apply-board-ws2812.sh
bash scripts/setup/apply-board-ws2812.sh --check
```

做三件事：
1. 拷贝 `config/boards/esp32s3-n16r8-generic/src/esp32s3_btsh_ws2812.c`
   → `nuttx/boards/xtensa/esp32s3/esp32s3-devkit/src/`
2. 在该板级 `Make.defs` 追加 `CSRCS += esp32s3_btsh_ws2812.c`（带 `CONFIG_WS2812` 条件）
3. 在该板级 `esp32s3_bringup.c` 的 `return OK;` 前插入
   `board_ws2812_initialize(0, ESP32S3_SPI2, CONFIG_WS2812_LED_COUNT)`

### 5.2 GATT 灯控服务应用

```bash
bash scripts/setup/install-btsh-light.sh
bash scripts/setup/install-btsh-light.sh --check
```

做两件事：
1. 拷贝 `src/app/*` → `~/openvela/apps/wireless/bluetooth/btsh_light/`
2. 在 `apps/wireless/bluetooth/Kconfig` 末尾追加
   `source "<绝对路径>/btsh_light/Kconfig"`

> ⚠️ **两个坑**：
> - `apps/wireless/bluetooth/Make.defs` **本来就有通配符**
>   `include $(wildcard $(APPDIR)/wireless/bluetooth/*/Make.defs)`，
>   **不需要**手工挂钩；手工追加会导致 `overriding recipe for target` 警告。
> - Kconfig 的 `source` **不能用 `$APPDIR` 变量**（kconfig 不展开它），
>   **必须用绝对路径**（官方也是这么做的）。

---

## 6. 步骤五：构建

### 6.1 安装 esptool（WSL 侧，构建出 bin 必需）

```bash
bash scripts/setup/setup-esptool.sh
# 或手动：
python3 -m venv ~/myenv
~/myenv/bin/pip install esptool
```

> ⚠️ NuttX 要求 esptool **≥ 4.8.0**，且调用的是命令名 `esptool.py`。
> 若缺失，构建会"成功"但不产生 `nuttx.bin`，并提示
> `esptool.py not found. Please run: 'pip install esptool'`。

### 6.2 构建

```bash
cd <本仓库>
source ~/.openvela-proxy-env      # 若需要网络

# 选择配置（见下表）
bash scripts/build/build-n16r8.sh gattdebug
```

### 6.3 可用配置一览

| 配置名 | 内容 | 固件大小 | 实测状态 |
| --- | --- | --- | --- |
| `nsh` | 最小可启动基线 | 207,632 B | ✅ 启动到 NSH |
| `psram` | + 8MB Octal PSRAM | 207,672 B | ✅ `free` 显示 8.79MB |
| `ble` | + BLE | 421,620 B | ✅ 扫描/广播实测通过 |
| `blewifi` | + WiFi 共存 | 901,212 B | ✅ WiFi 扫到真实路由器 |
| `statusled` | + WS2812 状态灯 | 422,904 B | ✅ 目视确认颜色渐变 |
| `gattlight` | + 自写 GATT 灯控服务 | 423,816 B | ⚠️ 服务注册成功，连接成功，**服务发现卡住** |
| `gattdebug` | 同上 + 无线内核日志 | **437,912 B** | ⚠️ 同上（排查用） |

> `scripts/build/build-n16r8.sh` 会**自动**做这些事：
> - 把 defconfig 与 `Make.defs` 同步到 vendor 配置目录
> - 读 defconfig，检测到 `CONFIG_ESP32S3_BLE=y` / `CONFIG_ESP32S3_WIFI=y`
>   就自动注入 `-DCONFIG_ESPRESSIF_BLE=1` / `-DCONFIG_ESPRESSIF_WIFI=1`
>   （**必需**，否则 `esp_bt.h` 编译失败，原因见 `HANDOFF-AI-ONBOARDING.md` §5.3）
> - 写构建指纹到 `.btsh-build-info`

### 6.4 构建期常见错误速查

| 错误 | 原因 | 处理 |
| --- | --- | --- |
| `error: invalid initializer` | 补丁 `0002` 未应用 | `apply-patches.sh` |
| `undefined reference to 'nxsem_post'` | 补丁 `0001` 未应用 | 同上 |
| `static assertion failed: "please enable bluetooth..."` | 缺 `-DCONFIG_ESPRESSIF_BLE=1` | 用 `build-n16r8.sh`（已自动注入） |
| `fatal: could not get a repository handle for submodule` | 子模块是伪造的 | `fetch-esp-hal-submodules.sh` |
| `No rule to make target '.../include/arch/barriers.h'` | 残留了**其他架构**的 `.o` 文件 | `./build.sh <cfg> distclean` |
| `File Make.defs could not be found` | vendor 配置目录缺 `Make.defs` | `build-n16r8.sh` 已处理 |
| 构建成功但没有 `nuttx.bin` | 缺 esptool | §6.1 |
| `Kconfig` 里加的项"消失"了 | **依赖不满足被静默剔除** | 对比产物大小确认；补齐依赖链 |

> ⚠️⚠️ **极度重要的警告**：
> **绝对不要**在 `~/openvela/nuttx` 目录里直接跑 `make distclean`。
> `Make.defs` 里的 `distclean::` 规则会**删除整个目录树**
> （本项目历史上因此丢失过整个 `nuttx` 目录，后用
> `git clone --no-checkout --shared ~/openvela/.repo/project-objects/nuttx.git`
> 恢复）。要清理请用 `./build.sh <cfg> distclean`。

---

## 7. 步骤六：烧录（必须在 Windows 侧）

> ⚠️ **WSL 无法访问串口**：WSL2 的动态串口映射只在 WSL 启动时探测一次，
> 之后插拔 USB 不会更新，`/dev/ttyS*` 全部打不开（即使 `chmod 666`）。
> 因此**烧录必须在 Windows 侧做**。

### 7.1 准备工作

1. 装 CH340 驱动（板载 USB-ISP 芯片）
2. 确认端口号（设备管理器 → 端口）。本项目为 **COM4**
3. Windows 侧装 esptool：

```powershell
# 本项目实际用的版本（Python 3.8.5 兼容）
pip install --no-build-isolation esptool==4.8.1
```

> ⚠️ 坑：PyPI 上**没有任何 esptool 版本提供 wheel**（全是源码包）。
> 若 `pip install esptool` 触发源码构建失败（`Failed building wheel for bitarray`，
> 需要 MSVC），用上面的 `--no-build-isolation` 方式。

### 7.2 烧录

固件采用 **Simple Boot** 方案 —— 直接烧到 **`0x0`**，
**没有 bootloader、没有分区表**。

```powershell
python -m esptool --chip esp32s3 -p COM4 -b 921600 `
  --before default_reset --after hard_reset `
  write_flash 0x0 <固件路径>\nuttx-n16r8-gattdebug.bin
```

或用 WSL 侧脚本（若串口可用）：
```bash
bash scripts/flash/flash.sh nuttx.bin
```

### 7.3 查看串口输出

115200 8N1。可用 PuTTY / MobaXterm / Python `pyserial`。

```python
import serial, time
ser = serial.Serial("COM4", 115200, timeout=0.3)
ser.setDTR(False); ser.setRTS(True); time.sleep(0.15); ser.setRTS(False)  # 复位
while True:
    d = ser.read(4096)
    if d: print(d.decode("utf-8", "replace"), end="")
```

> ⚠️ Windows 控制台是 GBK，Python 打印中文/特殊字符会
> `UnicodeEncodeError`。设 `PYTHONIOENCODING=utf-8` 或只写文件不打印。

---

## 8. 验证复现成功

烧录 `gattdebug` 后，串口应出现：

```
*** Booting NuttX ***
dram: lma 0x00000020 vma 0x3fc95f80 len 0x2bbc
iram: lma 0x00002be4 vma 0x40374000 len 0xac6c
...
total segments stored 6
NuttShell (NSH)
nsh> 
```

板上执行：

```
nsh> free
      total       used       free    maxused    maxfree  nused  nfree name
    8741616      55560    8686056      55936    8388592    107      2 Umem
                                  ↑ 若这里只有约 40 万，说明 PSRAM 没生效

nsh> ps
  PID GROUP PRI TYPE     STATE    EVENT       STACK   COMMAND
    5     0 253 Kthread  Waiting  Semaphore   0004024 btController
    6     0 100 Kthread  Waiting  MQ empty    0004032 BT_HCI_Tx

nsh> btsh_light start
BTSH: GATT service 0xff00 registered (8 attrs)
BTSH: light OFF
BTSH: advertising as "BTSH-LIGHT"
```

Windows 侧扫描应能发现 `BTSH-LIGHT`：

```python
import asyncio
from bleak import BleakScanner
found = asyncio.run(BleakScanner.discover(timeout=10, return_adv=True))
for addr, (dev, adv) in found.items():
    if dev.name and "BTSH" in dev.name:
        print(addr, dev.name, adv.rssi)
```

**能扫到 `BTSH-LIGHT` = 复现成功**（后续 GATT 服务发现的问题见
[`HANDOFF-CURRENT-ISSUE.md`](HANDOFF-CURRENT-ISSUE.md)）。

---

## 9. Windows 侧辅助环境（可选）

用于端到端 BLE 测试（本项目就是用这套抓的证据）：

```powershell
# BLE 客户端库
pip install --only-binary=:all: bleak==0.22.3
```

> Python 3.8.5 兼容版本为 `bleak==0.22.3`（更新的版本要求 Python ≥ 3.10）。

需要的硬件：Windows 机器上要有**可用的蓝牙适配器**
（本项目用的是 Realtek Bluetooth Adapter）。

---

## 10. 复现检查清单

按顺序打勾：

- [ ] WSL2 Ubuntu 22.04.5 可用
- [ ] 依赖包安装完毕（git/curl/python3/make/gperf/flex/bison/libncurses）
- [ ] `repo` 工具可用
- [ ] `repo init -u https://gitee.com/open-vela/manifests.git -b default -m openvela.xml`
- [ ] `repo sync -c -j8` 完成
- [ ] `nuttx` 检到 `5315a2b7f0ab864efa34d7ee13532b34ee4e926b`
- [ ] `apps` 检到 `52a26471afa56861ee48db0c797532ada414dd23`
- [ ] `apply-patches.sh --check` 两项均 ✓
- [ ] `esp-hal-3rdparty` 在 `9fc713a95b1ff150dd0b0647e465d3c624056bb1` 且 5 子模块齐全
- [ ] `apply-board-ws2812.sh --check` 三项均 ✓
- [ ] `install-btsh-light.sh --check` 各项均 ✓
- [ ] esptool ≥ 4.8.0 在 WSL 侧可用
- [ ] `build-n16r8.sh gattdebug` 成功，产物 **437,912 B**
- [ ] Windows 侧 esptool 4.8.1 可用，识别到 COM 口
- [ ] 烧录到 `0x0` 成功
- [ ] 串口出现 `nsh>`，`free` 显示约 8.7 MB
- [ ] `btsh_light start` 打印 `service 0xff00 registered`
- [ ] Windows 能扫到 `BTSH-LIGHT`

---

## 11. 环境快照（本项目实测记录）

```
主机:      Linux DogKing 6.18.40.1-microsoft-standard-WSL2 x86_64
发行版:    Ubuntu 22.04.5 LTS
nuttx:     5315a2b7f0ab864efa34d7ee13532b34ee4e926b (dirty)
apps:      52a26471afa56861ee48db0c797532ada414dd23
manifest:  gitee.com/open-vela/manifests @ 94f7cacbe639465507e3b466542dde5b2b9f7cbc
esp-hal:   9fc713a95b1ff150dd0b0647e465d3c624056bb1 (234 MB)
工具链:    xtensa-esp32s3-elf-gcc (crosstool-NG esp-12.2.0_20230208) 12.2.0
make 4.3 / cmake 3.22.1
Python:    3.10.12 (WSL) / 3.8.5 (Windows Anaconda)
esptool:   5.5.0 (WSL) / 4.8.1 (Windows)
串口:      COM4 (CH340), 115200 8N1
```

完整原始文本见 `docs/bringup/wsl-esp32s3-build-notes.md`。
