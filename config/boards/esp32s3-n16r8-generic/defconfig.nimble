#
# NuttX defconfig — ESP32-S3-N16R8（芯路城开发板）
# 配置名：nimble
#
# ## 本配置目标
#
# 用 **Apache NimBLE** 替换 NuttX 自带的 BLE host 栈。
#
# ## 为什么必须换
#
# 已实测确认（决定性对照实验，见 docs/stages/stage-04-nimble-host.md）：
#
#   | 项目             | ESP-IDF + NimBLE      | NuttX 原生 host |
#   |------------------|-----------------------|-----------------|
#   | 广播 / 被扫到    | ✅                    | ✅              |
#   | 建立连接         | ✅                    | ✅              |
#   | GATT 服务发现    | ✅✅ 拿到 4 个服务     | ❌ 超时         |
#
#   同一块板、同一根线、同一个供电口，只换固件。
#   在 VHCI 回调入口插桩实测：连接全程 ACL 包**恒为 0**。
#   => 硬件与控制器正常，问题在 NuttX 原生 host 栈。
#
# ## 关键机制（为什么换 NimBLE 有希望）
#
# `bt_hcicore.c` 的 `hci_rx_work()` 是**编译期二选一**：
#
#     #ifdef CONFIG_WIRELESS_BLUETOOTH_HOST
#         case BT_ACL_IN:  hci_acl(buf);   break;   // 原生 host 路径
#         case BT_EVT:     hci_event(buf); break;
#     #else
#         g_hci_cb->received(buf, g_hci_cb->context);  // ★ RAW HCI，全交订阅者
#     #endif
#
# **关掉 WIRELESS_BLUETOOTH_HOST 后，ACL 与 EVT 全部交给订阅者**，
# 由 NimBLE 的 HCI socket 传输层接管。
#
# 而且这解释了一个疑点：`HCI_Host_Buffer_Size` 与
# `Set_Controller_To_Host_Flow_Control` 两条流控命令是在
# `hci_initialize()` 里发的，**只在 HOST 模式下调用**。
# 非 HOST 模式下控制器可能不知道主机能收 ACL —— 这正是我们观察到的现象。
#
# ## NimBLE 接入方式（已核实）
#
#   apps/wireless/bluetooth/nimble/Kconfig:
#       config NIMBLE
#           bool "Apache NimBLE (BLE host-layer)"
#           depends on !WIRELESS_BLUETOOTH_HOST      ← 互斥，正合需要
#
#   NimBLE 的 NuttX 移植用 **socket 传输**：
#       porting/targets/nuttx/syscfg.yml:  BLE_TRANSPORT_LL: socket
#       nimble/transport/socket/src/ble_hci_socket.c
#
#   NuttX 侧已具备 HCI socket 支持：
#       include/netpacket/bluetooth.h:  BTPROTO_HCI=1, HCI_CHANNEL_RAW=0x0
#       net/bluetooth/                  完整实现
#
#   NimBLE 源码在构建时自动下载：
#       NIMBLE_REF = 6a5a16c7c0fab0fe7e95154493ff1fe9f0824fe3
#       URL = github.com/apache/mynewt-nimble/archive/<ref>.tar.gz
#       （需 GitHub 通道；本机用 scripts/setup/relay_proxy.py）
#
# ## 相对 defconfig.statusled 的改动
#
#   1. **关掉** CONFIG_WIRELESS_BLUETOOTH_HOST
#      —— NimBLE 与它互斥（`depends on !WIRELESS_BLUETOOTH_HOST`）
#      —— 同时让 hci_rx_work() 走 RAW HCI 分支
#
#   2. **关掉** CONFIG_BTSAK
#      —— btsak 依赖原生 host 的 ioctl 接口，NimBLE 下不可用
#
#   3. 打开 CONFIG_NIMBLE=y + 外设角色
#      NIMBLE_ROLE_PERIPHERAL 是 GATT Server（下位机）必需
#
#   4. 保留 CONFIG_NET_BLUETOOTH=y
#      —— HCI socket 走 PF_BLUETOOTH，必须保留
#
#   5. 保留 PSRAM / WS2812 / DEBUG_WIRELESS_*
#
# ## 构建
#
#   source ~/.openvela-proxy-env
#   bash scripts/build/build-n16r8.sh nimble
#
# ## 判据
#
#   1. 启动无 PANIC，出现 nsh>
#   2. 手机能扫到设备
#   3. 连接不崩溃
#   4. ★ GATT 服务发现成功（列出自定义服务与特征）← 决定性
#   5. 写特征值能点亮板载 RGB
#
# CONFIG_ARCH_LEDS is not set
# CONFIG_NDEBUG is not set
# CONFIG_NSH_ARGCAT is not set
# CONFIG_NSH_CMDOPT_HEXDUMP is not set
# CONFIG_WIRELESS_BLUETOOTH_HOST is not set
# CONFIG_BTSAK is not set
CONFIG_ALLOW_BSD_COMPONENTS=y
CONFIG_ARCH="xtensa"
CONFIG_ARCH_BOARD="esp32s3-devkit"
CONFIG_ARCH_BOARD_COMMON=y
CONFIG_ARCH_BOARD_ESP32S3_DEVKIT=y
CONFIG_ARCH_CHIP="esp32s3"
CONFIG_ARCH_CHIP_ESP32S3=y
CONFIG_ARCH_CHIP_ESP32S3WROOM1N16R8=y
CONFIG_ARCH_INTERRUPTSTACK=2048
CONFIG_ARCH_STACKDUMP=y
CONFIG_ARCH_XTENSA=y
CONFIG_BOARDCTL_RESET=y
CONFIG_BOARD_LOOPSPERMSEC=16717
CONFIG_BUILTIN=y
CONFIG_DEBUG_FULLOPT=y
CONFIG_DEBUG_SYMBOLS=y
CONFIG_DEFAULT_TASK_STACKSIZE=4096
CONFIG_DRIVERS_BLUETOOTH=y
CONFIG_DRIVERS_IEEE80211=y
CONFIG_DRIVERS_WIRELESS=y
CONFIG_ESP32S3_BLE=y
CONFIG_ESP32S3_RT_TIMER_TASK_STACK_SIZE=4096
CONFIG_ESP32S3_SPI2=y
CONFIG_ESP32S3_SPI2_MOSIPIN=48
CONFIG_ESP32S3_UART0=y
CONFIG_EXAMPLES_WS2812=y
CONFIG_FS_LARGEFILE=y
CONFIG_FS_PROCFS=y
CONFIG_HAVE_CXX=y
CONFIG_HAVE_CXXINITIALIZE=y
CONFIG_IDLETHREAD_STACKSIZE=3072
CONFIG_INIT_ENTRYPOINT="nsh_main"
CONFIG_INIT_STACKSIZE=8192
CONFIG_INTELHEX_BINARY=y
CONFIG_LINE_MAX=64
CONFIG_NAME_MAX=48
CONFIG_NETDEV_LATEINIT=y
CONFIG_NET_BLUETOOTH=y
CONFIG_NET_ETH_PKTSIZE=1514
CONFIG_NET_SOCKOPTS=y
CONFIG_NET_TCP=y
CONFIG_NIMBLE=y
CONFIG_NIMBLE_BLE_VERSION_50=y
CONFIG_NIMBLE_ROLE_PERIPHERAL=y
CONFIG_NIMBLE_ROLE_BROADCASTER=y
CONFIG_NIMBLE_TINYCRYPT=y
CONFIG_NSH_ARCHINIT=y
CONFIG_NSH_BUILTIN_APPS=y
CONFIG_NSH_FILEIOSIZE=512
CONFIG_NSH_READLINE=y
CONFIG_POSIX_SPAWN_DEFAULT_STACKSIZE=2048
CONFIG_PREALLOC_MQ_MSGS=32
CONFIG_PREALLOC_TIMERS=4
CONFIG_PTHREAD_MUTEX_TYPES=y
CONFIG_RAM_SIZE=114688
CONFIG_RAM_START=0x20000000
CONFIG_RR_INTERVAL=200
CONFIG_SCHED_WAITPID=y
# SIGEV_THREAD —— NimBLE 的 NuttX 移植层需要
#   porting/npl/nuttx/src/os_callout.c:105 用了 SIGEV_THREAD +
#   sigevent.sigev_notify_function / sigev_notify_attributes
#   不开启会报：'SIGEV_THREAD' undeclared
#   依赖：!BUILD_KERNEL && SCHED_WORKQUEUE（均已满足）
CONFIG_SIG_EVTHREAD=y
CONFIG_SIG_DEFAULT=y
CONFIG_SPINLOCK=y
CONFIG_START_DAY=6
CONFIG_START_MONTH=12
CONFIG_START_YEAR=2011
CONFIG_SYSLOG_BUFFER=y
CONFIG_SYSTEM_NSH=y
CONFIG_TIMER=y
CONFIG_TLS_TASK_NELEM=4
CONFIG_UART0_SERIAL_CONSOLE=y
CONFIG_WIRELESS=y
CONFIG_WIRELESS_BLUETOOTH=y
CONFIG_WS2812=y
CONFIG_WS2812_FREQUENCY=8000000
CONFIG_WS2812_LED_COUNT=1
#
# ---- PSRAM ----
#
CONFIG_ESP32S3_SPIRAM=y
CONFIG_ESP32S3_SPIRAM_MODE_OCT=y
CONFIG_ESP32S3_SPIRAM_TYPE_ESPPSRAM64=y
CONFIG_ESP32S3_SPIRAM_BOOT_INIT=y
CONFIG_ESP32S3_SPIRAM_COMMON_HEAP=y
CONFIG_ESP32S3_SPIRAM_SPEED_40M=y
CONFIG_MM_REGIONS=2
