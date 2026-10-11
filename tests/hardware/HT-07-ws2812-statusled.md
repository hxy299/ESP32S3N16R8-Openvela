# HT-09 — 板载 WS2812B 状态灯（GPIO48）

- 日期：2026-10-11
- 固件：`nuttx-n16r8-statusled.bin`（422,904 B，MD5 `330818583ae39b0f3863e6ffdaacdbc8`）
- 构建配置：`config/boards/esp32s3-n16r8-generic/defconfig.statusled`
- 硬件：ESP32-S3-N16R8，板载 **WS2812B @ GPIO48**（原理图 U1）
- 接线：USB-ISP → COM4

## 步骤

1. 安装板级 WS2812 支持：`bash scripts/setup/apply-board-ws2812.sh`
2. 构建：`bash scripts/build/build-n16r8.sh statusled`
3. 烧录并启动
4. `ls /dev` 检查设备节点
5. `ws2812 -p /dev/leds0 -r 3 -d 800000` 点灯
6. **目视确认**板载 RGB 是否亮

## 期望结果

`/dev/leds0` 存在，`ws2812` 命令能驱动板载 RGB。

## 实际结果

### ① 构建成功

```
rc=0
nuttx.bin  422,904 B
text/data/bss  351,914 / 11,244 / 162,708
```

配置项确认：

```
CONFIG_WS2812=y
CONFIG_WS2812_LED_COUNT=1
CONFIG_WS2812_FREQUENCY=8000000
CONFIG_ESP32S3_SPI2=y
CONFIG_ESP32S3_SPI2_MOSIPIN=48     ← 数据线 GPIO48
```

### ② 设备节点已注册（软件层面确认）

```
$ ls /dev
/dev:
 console
 leds0          ← ★ WS2812 驱动注册成功
 null
 random
 timer0
 ttyS0
 zero
```

### ③ `ws2812` 命令可用

```
$ ws2812 -h
Usage: ws2812 [OPTIONS]
Arguments are "sticky".  For example, once the device path is
specified, that path will be re-used until it is changed.
  [-p path] selects the ws2812 device.  Default: /dev/leds0 Current: /dev/leds0
  [-l leds] selects number of ws2812s in the chain.  Default: 1 Current: 1
  [-r repeat] selects the number change cycles.  Default: 4 Current: 4
  [-d delay] selects delay between updates.  Default: 20000 us Current: 20000 us
```

### ④ 点灯命令执行（无报错）

```
$ ws2812 -p /dev/leds0 -r 3 -d 800000
$ ws2812 -p /dev/leds0 -r 2 -d 500000
$ ls /dev
（均无错误输出）
```

### ⑤ ★ 目视确认（用户实测）

| 阶段 | 用户反馈 |
| --- | --- |
| 首次运行（`-d 800000`） | **看到绿灯** |
| 色相扫描测试（`-r 3 -d 50000`，一轮约 13 秒） | **「颜色在渐变」** |

**「颜色在渐变」是决定性的**：`ws2812` 命令做的是 HSV 色相扫描
（每轮 256 步 `ws2812_hsv_to_rgb((j+k)&0xff, 0xff, 0xff)`），
能看到连续渐变说明**每一步都被正确写入并显示** ——
即 SPI 时序、GPIO48 数据线、WS2812B 器件**全部正常工作**。

> 说明：首次看到"绿灯"并非故障，而是扫描停在绿色那一帧。
> `-d 800000`（0.8 秒/步）× 256 步 ≈ **205 秒一轮**，所以看到的是途中一帧。
> 改用 `-d 50000`（50 ms/步）后一轮约 13 秒，就能连续看到整圈色相变化。

## 结论

**PASS —— 完全验证通过（含目视确认）**

| 环节 | 状态 |
| --- | --- |
| 驱动编译进内核 | ✅ `CONFIG_WS2812=y` |
| SPI2 MOSI 配到 GPIO48 | ✅ |
| 板级注册函数调用 | ✅ `/dev/leds0` 出现 |
| `ws2812` 测试命令可执行 | ✅ 无报错 |
| **RGB 实际发光且颜色连续变化** | ✅ **用户目视确认「颜色在渐变」** |

→ **板载 WS2812B 状态灯可用于后续 GATT 服务的状态指示。**

## 备注

### 实现方式与所需改动

上游 `esp32s3-devkit` **没有** WS2812 板级代码，因此本项目补充：

1. **源文件**：`config/boards/esp32s3-n16r8-generic/src/esp32s3_btsh_ws2812.c`
   逻辑等价于官方 `esp32s3-lcd-ev/src/esp32s3_ws2812.c`，去掉 LCD 依赖。
2. **安装脚本**（幂等）：`scripts/setup/apply-board-ws2812.sh`
   做三件事：
   - 拷贝源文件到 `nuttx/boards/xtensa/esp32s3/esp32s3-devkit/src/`
   - 在该板级 `Make.defs` 追加 `CSRCS += esp32s3_btsh_ws2812.c`（带 `CONFIG_WS2812` 条件）
   - 在该板级 `esp32s3_bringup.c` 的 `return OK;` 前插入
     `board_ws2812_initialize(0, ESP32S3_SPI2, CONFIG_WS2812_LED_COUNT)`
   支持 `--check` / `--revert`。

### 技术要点

- WS2812 **无 CS/RESET 线**，靠 SPI 时钟模拟单总线时序，因此**独占 SPI2**。
- 该总线不能再用于其他 SPI 设备。
- `ws2812` 命令**不接颜色参数**，它自己跑配色循环；
  只有 `-p/-l/-r/-d` 四个选项（`-r` 循环次数，`-d` 每步延迟微秒）。
  最初我按 `ws2812 <r> <g> <b>` 去用，报 `Invalid options format` —— 记录备查。

### 原始记录

- [`serial-ws2812.txt`](serial-ws2812.txt)（设备节点与用法）
- [`serial-ws2812-run.txt`](serial-ws2812-run.txt)（点灯命令执行）
