# 基线测试：完全干净的树 + 官方 ble 配置

- 日期：2026-10-11
- 目的：**排除本项目所有改动**，用官方原始配置验证 ESP32-S3 的 BLE 行为
- 状态：⚠️ 部分完成（扫描已验证，连接测试未获有效数据）

---

## 一、方法

### 1.1 完全恢复树

```bash
cd ~/openvela/nuttx  && git checkout -- .
cd ~/openvela/apps   && git checkout -- .
# 删除本项目添加的文件
rm -f  arch/xtensa/src/esp32s3/esp32s3_ble.c.btsh-orig
rm -f  boards/xtensa/esp32s3/esp32s3-devkit/src/esp32s3_btsh_ws2812.c
rm -rf apps/wireless/bluetooth/btsh_light{,_nimble,d}
```

**恢复后验证**：

```
nuttx git status:  ★ 完全干净
apps  git status:  ★ 干净（仅第三方 nist-sts 目录）
esp32s3_ble.c          无改动 ✓
esp32s3_bringup.c      无改动 ✓
esp32s3_wifi_adapter.c 无改动 ✓
```

> 📌 备份在 `~/btsh-backup-20261011-191758/`（2.2 MB）
> 含全部 diff、被改文件原文、已安装应用、固件。

### 1.2 配置来源

**直接取官方文件**，只改一处：

```bash
sed 's/CONFIG_ARCH_CHIP_ESP32S3WROOM1N4=y/CONFIG_ARCH_CHIP_ESP32S3WROOM1N16R8=y/' \
  nuttx/boards/xtensa/esp32s3/esp32s3-devkit/configs/ble/defconfig \
  > vendor/espressif/boards/esp32s3/esp32s3-devkit/configs/ble16r8/defconfig
```

**与官方差异（仅 1 行）**：

```
< CONFIG_ARCH_CHIP_ESP32S3WROOM1N4=y
> CONFIG_ARCH_CHIP_ESP32S3WROOM1N16R8=y
```

### 1.3 恢复过程中发现并修复的问题

**我们的安装脚本删掉应用目录后，`apps/wireless/bluetooth/Kconfig` 里的
`source` 行成了悬空引用**，导致 `olddefconfig` 报错：

```
apps/wireless/bluetooth/Kconfig:15:
  '.../btsh_light_nimble/Kconfig' not found
```

**已清理**（3 行悬空 source）。这提示后续所有安装脚本的 `--revert`
必须同时清理 Kconfig 引用——现有的脚本已经做了，但手工删除时容易漏。

### 1.4 构建

```bash
source ~/.openvela-proxy-env
export PATH="$HOME/.local/bin:$HOME/myenv/bin:\
$HOME/openvela/prebuilts/gcc/linux-x86_64/xtensa-esp32s3-elf/bin:$PATH"
cd ~/openvela
./build.sh vendor/espressif/boards/esp32s3/esp32s3-devkit/configs/ble16r8/ \
  -e -DCONFIG_ESPRESSIF_BLE=1
```

**产物**：`nuttx.bin` 421,588 B，
`assets/firmware/nuttx-n16r8-baseline-official.bin`
（MD5 `c6529d083dbe80346db28b8487f4ef6b`）

**生效配置**：

```
CONFIG_ESP32S3_BLE=y
CONFIG_WIRELESS_BLUETOOTH_HOST=y      ← 默认开启（Kconfig default y）
CONFIG_BTSAK=y
CONFIG_DEVICE_NAME="Apache NuttX"
```

---

## 二、实测结果

### 2.1 ✅ 扫描完全正常

```
nsh> bt bnep0 info
  BDAddr: e0:72:a1:f2:8f:ea          ← 控制器正常，读到了 BD 地址
  Free: 20 / ACL: 20 / Max ACL: 24 / ACL MTU: 70

nsh> bt bnep0 scan start
nsh> bt bnep0 scan get
  Scan result:
   1.  addr: 88:56:a6:01:2b:ba  rssi: -54
       advertiser data: 02 01 06 03 03 a1 f0 13 09 57 61 6c 6c 65 2d 38 38 35 36 41 36 30 31 3
   2.  addr: d4:43:8a:f3:2c:61  rssi: -68
   ...（共 21 行设备信息）
```

**扫描发现多个真实设备，含完整 advertiser data。**

### 2.2 ✅ 广播正常

Windows 侧（bleak）扫到：

```
✓ E0:72:A1:F2:8F:EA   rssi=-26
```

### 2.3 ⚠️ 连接测试——**未获有效数据**

**三次尝试，均无连接事件**：

```
le_conn_complete  : 0
bt_gatt_connected : 0
```

**原因分析（重要）**：

1. **前两次失败是我给的设备名错了。**
   btsak 的广播名是 **`btsak`**，不是 `BTSH-LIGHT`：
   ```c
   /* btsak_advertise.c:124-126 */
   sd[1].len  = sizeof("btsak");
   sd[1].type = BT_EIR_NAME_COMPLETE;
   strlcpy((FAR char *)sd[1].data, "btsak", sizeof(sd[1].data));
   ```
   用户按 `BTSH-LIGHT` 找，自然找不到。

2. **第三次（已告知正确名字 `btsak`）窗口内仍无连接尝试** ——
   无法判断是用户未操作、还是连接确实失败。

> ⚠️ **因此本测试对"连接"这一项没有结论。**
> 需要一次**确认有人操作**的连接测试。

### 2.4 一个尚未排除的可能：Windows 侧问题

所有"连接失败"的测试都是**用 Windows（bleak）发起**的。
**Windows 的 BLE 适配器能否正常发起连接，本身未经验证。**

**必须用手机做一次对照**（手机此前成功连过，证明手机侧正常）。

---

## 三、结论（修正后的准确描述）

| 功能 | 干净树 + 官方配置 | 结论 |
| --- | --- | --- |
| 启动 | ✅ | 正常 |
| 控制器初始化 | ✅ BDAddr 正确读出 | 正常 |
| **扫描（发现别人）** | ✅ 21 个真实设备 | **正常** |
| **广播（被别人发现）** | ✅ Windows rssi −26 | **正常** |
| 建立连接 | ⚠️ 无有效数据 | **待确认** |

**因此不能说"官方代码错了"。** 准确的说法是：

> **在这套 openvela 树上、这块 ESP32-S3 板子上，
> BLE 的扫描与广播功能正常；"建立连接"尚未取得有效测试数据。**

---

## 四、下一步：需要一个确认操作的连接测试

**步骤**（约 3 分钟）：

```bash
# 1. 板子侧（当前固件已烧录）
nsh> bt bnep0 advertise start

# 2. 手机 nRF Connect
#    ★ 扫描名为 "btsak" 的设备（不是 BTSH-LIGHT）
#    ★ 点 CONNECT

# 3. 观察串口
#    出现 le_conn_complete  -> 控制器响应了连接
#    出现 Packet for CID    -> ACL 通了（GATT 可用）
```

**判读表**：

| 现象 | 含义 | 下一步 |
| --- | --- | --- |
| 手机连上，串口出现 `le_conn_complete` + `Packet for CID` | **BLE 完全正常**，之前的失败全是我测试方法的问题 | 直接做 GATT 灯控服务 |
| 手机连上，只有 `le_conn_complete`，无 `Packet for CID` | 连接建立但 ACL 不通（原问题重现） | 继续攻 ACL |
| 手机连不上 | 控制器确实不响应连接 | 继续攻 ACL |
| 手机找不到 `btsak` 设备 | 广播有问题 | 检查广播 |

---

## 五、备份位置

```
~/btsh-backup-20261011-191758/
├── nuttx-modified/         被改文件的原文（含我的改动）
├── nuttx-full.diff         完整 diff（可 git apply 重放）
├── apps-full.diff
├── git-status.txt          git 状态快照
├── apps-installed/         三个应用目录的完整备份
│   ├── btsh_light/
│   ├── btsh_light_nimble/
│   └── btsh_lightd/
└── firmware/
    ├── nuttx.bin
    ├── dot-config
    └── Make.defs
```

**恢复项目改动**：
```bash
cd ~/openvela/nuttx && git apply ~/btsh-backup-*/nuttx-full.diff
cp -r ~/btsh-backup-*/apps-installed/* ~/openvela/apps/wireless/bluetooth/
```
