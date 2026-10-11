# 阶段五：远程灯控（TCP 版）—— 核心功能已实现

- 日期：2026-10-11
- 状态：✅ **核心目标达成**（远程点灯可用）；⚠️ 一个次要问题待解

---

## 一、成果

### 1.1 ✅ 远程点灯已实现并实测验证

**拓扑**：ESP32-S3（openvela/NuttX）← WiFi → 电脑/手机

**实测证据**（串口日志，2026-10-11）：

```
nsh> btsh_lightd &
btsh_lightd: starting (port 2323)
btsh_lightd: light OFF
btsh_lightd: listening on port 2323
btsh_lightd: ready

（电脑侧发起 TCP 连接）
btsh_lightd: client 192.168.1.190:59429 connected     ← 连接成功
btsh_lightd: recv "PING"                               ← 命令到达
btsh_lightd: recv "STATE"
btsh_lightd: recv "ON"
btsh_lightd: light ON                                  ← ★★ 灯亮了
btsh_lightd: recv "STATE"
btsh_lightd: recv "OFF"
btsh_lightd: light OFF                                 ← ★★ 灯灭了
btsh_lightd: recv "STATE"
```

**网络侧**：

```
wlan0  Link encap:Ethernet HWaddr e0:72:a1:f2:8f:e8 at RUNNING mtu 1500
       inet addr:192.168.1.228 DRaddr:192.168.1.1 Mask:255.255.255.0
```

**结论：从电脑通过 WiFi 发出 ON/OFF 命令，板子上的灯确实被点亮/熄灭。**

### 1.2 交付物

| 文件 | 说明 |
| --- | --- |
| [`src/app/lightd/btsh_lightd_main.c`](../../src/app/lightd/btsh_lightd_main.c) | TCP 灯控守护进程（约 580 行，注释详尽） |
| [`src/app/lightd/Kconfig`](../../src/app/lightd/Kconfig) | 配置项 |
| [`src/app/lightd/Makefile`](../../src/app/lightd/Makefile) | 构建 |
| [`src/app/lightd/Make.defs`](../../src/app/lightd/Make.defs) | 挂入 CONFIGURED_APPS |
| [`scripts/setup/install-btsh-lightd.sh`](../../scripts/setup/install-btsh-lightd.sh) | 幂等安装脚本（`--check` / `--revert`） |
| [`config/.../defconfig.lightd`](../../config/boards/esp32s3-n16r8-generic/defconfig.lightd) | 构建配置 |
| `assets/firmware/nuttx-n16r8-lightd.bin` | 902,372 B（MD5 见仓库） |

---

## 二、协议设计

**TCP 端口 2323**，极简文本协议，每行一条命令（`\n` 结尾）：

| 命令 | 响应 | 说明 |
| --- | --- | --- |
| `ON` | `OK ON` | 开灯 |
| `OFF` | `OK OFF` | 关灯 |
| `TOGGLE` | `OK ON` / `OK OFF` | 翻转 |
| `STATE` | `STATE 1` / `STATE 0` | 查询（1=亮） |
| `PING` | `PONG` | 存活检测 |
| `HELP` | `OK commands: ...` | 帮助 |
| `QUIT` | `OK BYE` | 断开 |
| 其他 | `ERR unknown command` | 错误 |

**为什么用文本协议**：便于用 telnet / netcat / Python 一行命令测试，
也便于接 Home Assistant、Node-RED（直接 TCP 发字符串）。

**客户端示例**：
```python
import socket
s = socket.create_connection(("192.168.1.228", 2323))
s.sendall(b"ON\n")
print(s.recv(64))          # b'OK ON\n'
```

---

## 三、使用步骤（完整）

```bash
# 板子侧（NSH）
nsh> btsh_lightd &                                    # 启动守护进程
nsh> ifup wlan0                                       # 启用 WiFi
nsh> wapi psk wlan0 <密码> 3                          # 3 = WPA2-PSK
nsh> wapi essid wlan0 <SSID> 1                        # 1 = ESSID ON
nsh> renew wlan0                                      # DHCP
nsh> ifconfig wlan0                                   # 查 IP

# 电脑侧
python -c "import socket;s=socket.create_connection(('<IP>',2323));s.sendall(b'ON\n')"
```

⚠️ **DHCP 是间歇性的**：`renew wlan0` 有时报
`netlib_obtain_ipv4addr() failed`。**重试即可**（实测第 2–3 次成功）。
脚本 `_lightd_clean_test.py` 里已内置 8 次重试逻辑，可参考。

---

## 四、⚠️ 已知未解决问题：TCP 回写失败

### 4.1 现象

**命令能收到、灯能控制，但客户端收不到任何响应文本。**

串口显示每次回写都失败：

```
btsh_lightd: client 192.168.1.190:59429 connected
btsh_lightd: send failed errno=107        ← ENOTCONN
```

### 4.2 已完成的对照实验

| 尝试 | 结果 |
| --- | --- |
| `send(fd, buf, len, 0)` | ❌ errno **107**（ENOTCONN） |
| `write(fd, buf, len)` | ❌ errno **107**（ENOTCONN） |
| `sendto(fd, buf, len, 0, &peer, peerlen)` | ❌ errno **9**（EBADF） |

**注意方向相反**：读方向（`recv()`）**完全正常**，只有写方向失败。

### 4.3 已排除

| 怀疑点 | 排除依据 |
| --- | --- |
| `send` vs `write` 选型问题 | 两者报**同一个** errno 107 |
| `CONFIG_NET_TCP_WRITE_BUFFERS` | 官方 `tcpblaster` 配置也启用它且工作正常 |
| 对端地址错误 | `sendto` 显式带 peer 反而报 EBADF（更早失败） |
| 命令解析问题 | `recv()` 收到并正确解析了所有命令 |

### 4.4 怀疑方向（供后续验证）

1. **NuttX 在 ESP32-S3 内建 WiFi 上 `accept()` 得到的 socket，
   在写方向未正确标记为已连接**
   —— 读方向有数据、写方向无状态，符合"半连接"特征。
2. 可能需要在 `accept()` 后调用 `getpeername()` / `getsockname()`
   触发 socket 层状态同步。
3. 该 WiFi 驱动的 TCP **接收**路径与 NuttX socket 层状态不同步。
4. 对照实验建议：**在 ESP32 上用官方 `sim` 或以太网跑同一个 daemon**。
   若同样失败 → NuttX socket 层问题；
   若正常 → ESP32 WiFi 驱动问题。

### 4.5 对项目的影响

**不影响核心目标**：远程点灯（开/关）已可用。
受影响的是"请求-响应"式交互（如查询状态、读回执）。

**若暂时不需要响应**，当前固件即可用于：
- 手机/电脑发 `ON` / `OFF` 控制
- 配合 Home Assistant 的 `command_line` 开关（不需要读回执）

---

## 五、物理输出与继电器接线

### 5.1 当前（第一版）

灯 = **板载 WS2812B（GPIO48）**：
- 开灯 → 绿色（G=40）
- 关灯 → 熄灭

### 5.2 换继电器时

只需改 [`btsh_light_apply()`](../../src/app/lightd/btsh_lightd_main.c) 的实现
（在文件里注释标明了位置），上层逻辑不用动。

**接线参考**：
```
ESP32-S3 GPIO  ->  继电器模块 IN
ESP32-S3 5V    ->  继电器 VCC（注意开发板 5V 供电余量）
ESP32-S3 GND   ->  继电器 GND
```

**推荐预留引脚**：GPIO 4 / 5 / 6 / 7 / 15 / 16 / 17
（避开 PSRAM/Flash 占用脚；GPIO48 已被 WS2812 占用）

**注意**：单路继电器 + 板载 5V 供电时，建议继电器模块**自带光耦隔离**
且控制端电流 < 20mA，否则需外部供电。

---

## 六、配置要点（构建时踩过的坑）

`defconfig.lightd` 里必须同时有这几项，否则构建失败或不工作：

| 配置项 | 作用 | 漏掉的后果 |
| --- | --- | --- |
| `CONFIG_ESP32S3_WIFI=y` | 启用 WiFi | 无网络 |
| `CONFIG_NET_TCP=y` | 启用 TCP | socket 创建失败 |
| `CONFIG_BTSH_LIGHTD=y` | 启用本应用 | 命令不存在 |
| `CONFIG_WS2812=y` | WS2812 驱动 | `/dev/leds0` 打不开 |
| **`CONFIG_ESP32S3_SPI2=y`** | WS2812 的时序发生器 | **编译失败**：`'ESP32S3_SPI2' undeclared` |
| **`CONFIG_ESP32S3_SPI2_MOSIPIN=48`** | WS2812 数据线引脚 | 灯不亮 |

> 📌 **WS2812 会 `select SPI`** —— 它没有 CS/RESET 线，
> 靠 SPI 时钟模拟单总线时序，因此**独占一个 SPI 外设**。
> 必须显式指定用哪个 SPI 与哪根 MOSI。
