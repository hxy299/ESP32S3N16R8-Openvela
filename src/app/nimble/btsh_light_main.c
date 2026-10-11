/****************************************************************************
 * apps/wireless/bluetooth/btsh_light/btsh_light_main.c
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * 由 OpenvelaESP-BTSH 项目编写
 *
 * BLE GATT 灯控服务（NimBLE 版，下位机 = Peripheral / GATT Server）
 *
 * ## 为什么用 NimBLE 而不是 NuttX 自带 host
 *
 * 已实测确认（见 docs/stages/stage-04-nimble-host.md）：
 *   NuttX 自带的 BLE host 栈在 ESP32-S3 上**收不到 ACL 数据**
 *   （在 VHCI 回调入口插桩实测，H4_ACL 恒为 0），
 *   导致连接能建立但 GATT 服务发现必然超时。
 *
 *   而同一块板用 ESP-IDF + NimBLE 完全正常（完整枚举出 4 个 GATT 服务）。
 *   => 硬件与控制器正常，问题在 NuttX 原生 host。
 *
 * 因此改用 NimBLE：NuttX 官方支持（apps/wireless/bluetooth/nimble），
 * 且关键机制合适 —— `bt_hcicore.c` 的 `hci_rx_work()` 是编译期二选一：
 *
 *     #ifdef CONFIG_WIRELESS_BLUETOOTH_HOST
 *         ...原生 host 处理...
 *     #else
 *         g_hci_cb->received(buf, g_hci_cb->context);  // ★ RAW HCI 全交订阅者
 *     #endif
 *
 * 关掉原生 host 后，ACL 与 EVT 全部交给 NimBLE 的 HCI socket 传输层。
 *
 * ## GATT 服务定义（与原生版保持一致，便于 A7Z 侧复用）
 *
 *   128 位 UUID 基址：FF00-1234-5678-9ABC-DEF0123456xx
 *   ┌──────────────────────────────────────────────────────────────┐
 *   │ 0xFF00  灯控服务（primary）                                   │
 *   │   ├─ 0xFF01  灯控命令   WRITE          写 1 字节：0=灭 1=亮    │
 *   │   ├─ 0xFF02  灯状态     READ + NOTIFY  读 1 字节              │
 *   │   └─ 0xFF03  设备信息   READ           读 3 字节：版本/通道/保留│
 *   └──────────────────────────────────────────────────────────────┘
 *
 * ## 物理输出
 *
 * 当前阶段把"灯"映射到**板载 WS2812B (GPIO48, /dev/leds0)**，
 * 便于无外接硬件时验证 GATT 链路：
 *   开灯 -> 绿色常亮
 *   关灯 -> 熄灭
 * 接入继电器后只需替换 `btsh_light_apply()` 的实现。
 *
 * ## 用法（NSH）
 *
 *   nimble_light          启动服务并开始广播（需先运行一次 `nimble`）
 *   nimble_light state    查看当前状态
 *
 ****************************************************************************/

/****************************************************************************
 * Included Files
 ****************************************************************************/

#include <nuttx/config.h>

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <unistd.h>

#include <pthread.h>

/* NimBLE */

#include "nimble/nimble_port.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

/****************************************************************************
 * Pre-processor Definitions
 ****************************************************************************/

/* 灯控命令字节 */

#define BTSH_CMD_OFF       0x00
#define BTSH_CMD_ON        0x01

/* 设备信息内容 */

#define BTSH_PROTO_VERSION 0x01
#define BTSH_CHANNELS      0x01    /* 第一阶段：单路 */

/* 板载 WS2812 设备节点 */

#ifndef CONFIG_BTSH_LIGHT_LED_DEV
#  define CONFIG_BTSH_LIGHT_LED_DEV "/dev/leds0"
#endif

/* NuttX ws2812 驱动的字节序标记（见 drivers/leds/ws2812.c） */

#define BTSH_WS2812_MAGIC 0x0000aa55

/* 广播设备名 */

#ifndef CONFIG_BTSH_LIGHT_ADV_NAME
#  define CONFIG_BTSH_LIGHT_ADV_NAME "BTSH-LIGHT"
#endif

/****************************************************************************
 * Private Types
 ****************************************************************************/

/* NuttX ws2812 驱动接受 4 字节/LED：魔数 + r + g + b */

struct btsh_rgb_s
{
  uint32_t magic;
  uint8_t  r;
  uint8_t  g;
  uint8_t  b;
};

/****************************************************************************
 * Private Data — GATT UUID（128 位，基址 FF00-...） 
 *
 * 注意字节序：BLE_UUID128_INIT 的参数是**小端倒序**书写
 * （最后一个参数是最高字节）。这里基址为
 *   FF00-1234-5678-9ABC-DEF0123456xx
 * 因此 xx 在第一个参数位置。
 ****************************************************************************/

static const ble_uuid128_t g_svc_uuid =
  BLE_UUID128_INIT(0x00, 0x56, 0x34, 0x12, 0xf0, 0xde, 0xbc, 0x9a,
                   0x78, 0x56, 0x34, 0x12, 0x00, 0xff, 0x00, 0x00);

static const ble_uuid128_t g_cmd_uuid =
  BLE_UUID128_INIT(0x01, 0x56, 0x34, 0x12, 0xf0, 0xde, 0xbc, 0x9a,
                   0x78, 0x56, 0x34, 0x12, 0x00, 0xff, 0x00, 0x00);

static const ble_uuid128_t g_state_uuid =
  BLE_UUID128_INIT(0x02, 0x56, 0x34, 0x12, 0xf0, 0xde, 0xbc, 0x9a,
                   0x78, 0x56, 0x34, 0x12, 0x00, 0xff, 0x00, 0x00);

static const ble_uuid128_t g_info_uuid =
  BLE_UUID128_INIT(0x03, 0x56, 0x34, 0x12, 0xf0, 0xde, 0xbc, 0x9a,
                   0x78, 0x56, 0x34, 0x12, 0x00, 0xff, 0x00, 0x00);

/* 灯状态与连接状态 */

static uint8_t  g_light_state   = BTSH_CMD_OFF;
static uint16_t g_conn_handle   = BLE_HS_CONN_HANDLE_NONE;
static bool     g_state_notify  = false;   /* 客户端是否已订阅状态通知 */
static uint16_t g_state_val_handle;        /* 状态特征的值句柄（Notify 用） */
static int      g_led_fd        = -1;
static uint8_t  g_own_addr_type;

/* 设备信息内容：版本 + 通道数 + 保留 */

static const uint8_t g_dev_info[3] =
{
  BTSH_PROTO_VERSION,
  BTSH_CHANNELS,
  0x00,
};

/****************************************************************************
 * Private Function Prototypes
 ****************************************************************************/

static int  btsh_gatt_access(uint16_t conn_handle, uint16_t attr_handle,
                             struct ble_gatt_access_ctxt *ctxt, void *arg);
static void btsh_light_apply(uint8_t state);
static void btsh_advertise(void);
static int  btsh_gap_event(struct ble_gap_event *event, void *arg);
static void btsh_on_sync(void);
static void btsh_on_reset(int reason);

/* NimBLE 主机事件循环所需的外部函数（由 NimBLE 提供） */

extern void nimble_port_run(void);
extern void nimble_host_task(void *param);
extern void ble_hci_sock_ack_handler(void *param);

/****************************************************************************
 * Private Data — GATT 服务表
 ****************************************************************************/

static const struct ble_gatt_svc_def g_svcs[] =
{
  {
    /* 灯控服务 */

    .type = BLE_GATT_SVC_TYPE_PRIMARY,
    .uuid = &g_svc_uuid.u,
    .characteristics = (struct ble_gatt_chr_def[])
    {
      {
        /* 灯控命令：只写，1 字节 */

        .uuid      = &g_cmd_uuid.u,
        .access_cb = btsh_gatt_access,
        .arg       = (void *)"cmd",
        .flags     = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
      },
      {
        /* 灯状态：读 + 通知，1 字节 */

        .uuid       = &g_state_uuid.u,
        .access_cb  = btsh_gatt_access,
        .arg        = (void *)"state",
        .flags      = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
        .val_handle = &g_state_val_handle,
      },
      {
        /* 设备信息：只读，3 字节 */

        .uuid      = &g_info_uuid.u,
        .access_cb = btsh_gatt_access,
        .arg       = (void *)"info",
        .flags     = BLE_GATT_CHR_F_READ,
      },
      {
        0, /* 特征表结束标志 */
      }
    },
  },
  {
    0, /* 服务表结束标志 */
  },
};

/****************************************************************************
 * Private Functions — NimBLE 任务
 ****************************************************************************/

/****************************************************************************
 * Name: btsh_host_thread
 *
 * Description:
 *   NimBLE 主机事件循环任务。
 *
 *   为什么必须自己起这个任务：
 *   `nimble_port_init()` 只做「初始化」（含 HCI socket 传输层），
 *   它**不会**启动事件循环。事件循环是 `nimble_port_run()`，
 *   必须跑在独立任务里，否则所有 GAP/GATT 回调都不会被处理。
 *
 *   参照 NimBLE 自带的 NuttX 示例（porting/examples/nuttx/main.c）：
 *       ble_npl_task_init(&s_task_host, "ble_host", ble_host_task, ...)
 *   其中 ble_host_task() 内部就是调 nimble_host_task() → nimble_port_run()。
 *   这里用 NuttX 原生 pthread 起，效果等价。
 *
 ****************************************************************************/

static void *btsh_host_thread(void *arg)
{
  UNUSED(arg);

  syslog(LOG_INFO, "BTSH: host thread started\n");
  nimble_host_task(NULL);
  return NULL;
}

/****************************************************************************
 * Name: btsh_hci_thread
 *
 * Description:
 *   HCI socket 收包确认任务。
 *
 *   NimBLE 的 socket 传输层需要一个任务持续调用
 *   `ble_hci_sock_ack_handler()` 来处理控制器送来的数据。
 *   参照 NuttX 示例的 ble_hci_sock_task()。
 *
 ****************************************************************************/

static void *btsh_hci_thread(void *arg)
{
  UNUSED(arg);

  syslog(LOG_INFO, "BTSH: hci sock thread started\n");
  ble_hci_sock_ack_handler(NULL);
  return NULL;
}

/****************************************************************************
 * Name: btsh_light_apply
 *
 * Description:
 *   把逻辑灯状态写到物理输出（当前 = 板载 WS2812B）。
 *   接入继电器后只需改这里的实现，上层不用动。
 *
 ****************************************************************************/

static void btsh_light_apply(uint8_t state)
{
  struct btsh_rgb_s px;

  if (g_led_fd < 0)
    {
      return;
    }

  px.magic = BTSH_WS2812_MAGIC;

  if (state == BTSH_CMD_ON)
    {
      px.r = 0;
      px.g = 40;      /* 绿色：开灯 */
      px.b = 0;
    }
  else
    {
      px.r = 0;       /* 熄灭：关灯 */
      px.g = 0;
      px.b = 0;
    }

  if (lseek(g_led_fd, 0, SEEK_SET) < 0)
    {
      return;
    }

  (void)write(g_led_fd, &px, sizeof(px));
  syslog(LOG_INFO, "BTSH: light %s\n", state == BTSH_CMD_ON ? "ON" : "OFF");
}

/****************************************************************************
 * Name: btsh_gatt_access
 *
 * Description:
 *   GATT 特征读写回调。
 *   `arg` 是注册时传入的标识字符串（"cmd" / "state" / "info"），
 *   用它区分是哪个特征（比比较 UUID 更直观）。
 *
 ****************************************************************************/

static int btsh_gatt_access(uint16_t conn_handle, uint16_t attr_handle,
                            struct ble_gatt_access_ctxt *ctxt, void *arg)
{
  const char *which = (const char *)arg;
  uint8_t     cmd;
  int         rc;

  UNUSED(attr_handle);

  /* ---- 灯控命令：写入 1 字节 ---- */

  if (strcmp(which, "cmd") == 0)
    {
      if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR)
        {
          return BLE_ATT_ERR_UNLIKELY;
        }

      if (os_mbuf_len(ctxt->om) < 1)
        {
          syslog(LOG_ERR, "BTSH: cmd too short\n");
          return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }

      rc = os_mbuf_copydata(ctxt->om, 0, 1, &cmd);
      if (rc != 0)
        {
          return BLE_ATT_ERR_UNLIKELY;
        }

      if (cmd != BTSH_CMD_OFF && cmd != BTSH_CMD_ON)
        {
          syslog(LOG_ERR, "BTSH: unknown cmd 0x%02x\n", cmd);
          return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }

      if (cmd != g_light_state)
        {
          g_light_state = cmd;
          btsh_light_apply(g_light_state);

          /* 主动回报状态（需客户端已订阅） */

          if (g_state_notify && g_conn_handle != BLE_HS_CONN_HANDLE_NONE)
            {
              struct os_mbuf *om;

              om = ble_hs_mbuf_from_flat(&g_light_state,
                                         sizeof(g_light_state));
              if (om != NULL)
                {
                  (void)ble_gatts_notify_custom(g_conn_handle,
                                                g_state_val_handle, om);
                }
            }
        }

      return 0;
    }

  /* ---- 灯状态：读 1 字节 ---- */

  if (strcmp(which, "state") == 0)
    {
      if (ctxt->op != BLE_GATT_ACCESS_OP_READ_CHR)
        {
          return BLE_ATT_ERR_UNLIKELY;
        }

      rc = os_mbuf_append(ctxt->om, &g_light_state, sizeof(g_light_state));
      return rc == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }

  /* ---- 设备信息：读 3 字节 ---- */

  if (strcmp(which, "info") == 0)
    {
      if (ctxt->op != BLE_GATT_ACCESS_OP_READ_CHR)
        {
          return BLE_ATT_ERR_UNLIKELY;
        }

      rc = os_mbuf_append(ctxt->om, g_dev_info, sizeof(g_dev_info));
      return rc == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }

  syslog(LOG_ERR, "BTSH: unknown characteristic %s\n", which);
  return BLE_ATT_ERR_UNLIKELY;
}

/****************************************************************************
 * Name: btsh_advertise
 *
 * Description:
 *   设置广播数据并开始广播。
 *
 ****************************************************************************/

static void btsh_advertise(void)
{
  struct ble_gap_adv_params adv_params;
  struct ble_hs_adv_fields  fields;
  const char               *name;
  int                       rc;

  rc = ble_hs_id_infer_auto(0, &g_own_addr_type);
  if (rc != 0)
    {
      syslog(LOG_ERR, "BTSH: ble_hs_id_infer_auto failed: %d\n", rc);
      return;
    }

  memset(&fields, 0, sizeof(fields));

  /* 通用可发现 + 不支持 BR/EDR */

  fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;

  /* 让协议栈自动填 TX 功率 */

  fields.tx_pwr_lvl_is_present = 1;
  fields.tx_pwr_lvl            = BLE_HS_ADV_TX_PWR_LVL_AUTO;

  /* 设备名（完整） */

  name            = ble_svc_gap_device_name();
  fields.name     = (uint8_t *)name;
  fields.name_len = strlen(name);
  fields.name_is_complete = 1;

  /* 广播里带上 16 位服务 UUID 短标识 FF00（便于上位机快速识别） */

  fields.uuids16 = (ble_uuid16_t[])
    {
      BLE_UUID16_INIT(0xFF00)
    };
  fields.num_uuids16          = 1;
  fields.uuids16_is_complete  = 1;

  rc = ble_gap_adv_set_fields(&fields);
  if (rc != 0)
    {
      syslog(LOG_ERR, "BTSH: adv_set_fields failed: %d\n", rc);
      return;
    }

  memset(&adv_params, 0, sizeof(adv_params));
  adv_params.conn_mode = BLE_GAP_CONN_MODE_UND;    /* 可连接、非定向 */
  adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;    /* 通用可发现 */

  rc = ble_gap_adv_start(g_own_addr_type, NULL, BLE_HS_FOREVER,
                         &adv_params, btsh_gap_event, NULL);
  if (rc != 0)
    {
      syslog(LOG_ERR, "BTSH: adv_start failed: %d\n", rc);
      return;
    }

  syslog(LOG_INFO, "BTSH: advertising as \"%s\"\n", name);
}

/****************************************************************************
 * Name: btsh_gap_event
 *
 * Description:
 *   GAP 事件回调：连接/断开/订阅/MTU 等。
 *
 ****************************************************************************/

static int btsh_gap_event(struct ble_gap_event *event, void *arg)
{
  UNUSED(arg);

  switch (event->type)
    {
      case BLE_GAP_EVENT_CONNECT:

        if (event->connect.status == 0)
          {
            g_conn_handle = event->connect.conn_handle;
            syslog(LOG_INFO, "BTSH: connected (handle=%d)\n", g_conn_handle);
          }
        else
          {
            syslog(LOG_WARNING, "BTSH: connect failed status=%d, re-advertising\n",
                   event->connect.status);
            btsh_advertise();
          }

        return 0;

      case BLE_GAP_EVENT_DISCONNECT:

        syslog(LOG_INFO, "BTSH: disconnected reason=%d\n",
               event->disconnect.reason);
        g_conn_handle  = BLE_HS_CONN_HANDLE_NONE;
        g_state_notify = false;

        /* 断线后继续广播，便于重连。
         * 注意：灯保持原状态，不自动关灯（设计如此）。
         */

        btsh_advertise();
        return 0;

      case BLE_GAP_EVENT_SUBSCRIBE:

        if (event->subscribe.attr_handle == g_state_val_handle)
          {
            g_state_notify = event->subscribe.cur_notify;
            syslog(LOG_INFO, "BTSH: state notify %s\n",
                   g_state_notify ? "enabled" : "disabled");

            /* 订阅刚打开时，主动回报一次当前状态，让上位机同步 */

            if (g_state_notify)
              {
                struct os_mbuf *om;

                om = ble_hs_mbuf_from_flat(&g_light_state,
                                           sizeof(g_light_state));
                if (om != NULL)
                  {
                    (void)ble_gatts_notify_custom(event->subscribe.conn_handle,
                                                  g_state_val_handle, om);
                  }
              }
          }

        return 0;

      case BLE_GAP_EVENT_MTU:

        syslog(LOG_INFO, "BTSH: mtu updated conn=%d mtu=%d\n",
               event->mtu.conn_handle, event->mtu.value);
        return 0;

      case BLE_GAP_EVENT_ADV_COMPLETE:

        /* 广播结束（如超时）——重新开始 */

        btsh_advertise();
        return 0;

      default:
        return 0;
    }
}

/****************************************************************************
 * Name: btsh_gatt_register
 *
 * Description:
 *   注册 GATT 服务表。
 *
 * ★★ 必须在 host 与控制器**同步完成之后**调用（即从 sync_cb 里调）。★★
 *
 * 踩过的坑（2026-10-11 实测）：
 *   最初在 nimble_port_init() **之前**调 ble_gatts_add_svcs()，
 *   结果该函数**永久阻塞**，串口停在：
 *       BTSH[5] gatts_add_svcs
 *   之后毫无输出，连 NSH 也卡死（命令不返回）。
 *
 *   原因：ble_gatts_add_svcs() 内部要求 host 已就绪
 *   （需要 host 的任务/信号量已工作），而 nimble_port_init() 之前
 *   这些都还没起来，于是它一直等下去。
 *
 * 正确顺序：
 *   1. ble_hs_cfg.* 设好回调（尤其是 sync_cb）
 *   2. nimble_port_init()          —— 起 host，等同步
 *   3. host 同步完成 -> sync_cb 被调用
 *   4. 在 sync_cb 里：ble_gatts_count_cfg() + ble_gatts_add_svcs()
 *   5. 紧接着 ble_gap_adv_start()
 *
 ****************************************************************************/

static int btsh_gatt_register(void)
{
  int rc;

  printf("BTSH[G1] count_cfg\n");

  rc = ble_gatts_count_cfg(g_svcs);
  if (rc != 0)
    {
      printf("BTSH[!] count_cfg failed %d\n", rc);
      return rc;
    }

  printf("BTSH[G2] add_svcs\n");

  rc = ble_gatts_add_svcs(g_svcs);
  if (rc != 0)
    {
      printf("BTSH[!] add_svcs failed %d\n", rc);
      return rc;
    }

  printf("BTSH[G3] services registered\n");
  return 0;
}

/****************************************************************************
 * Name: btsh_on_sync
 *
 * Description:
 *   host 与控制器同步完成回调。
 *   **GATT 注册与广播都必须在这里做**（见 btsh_gatt_register 的说明）。
 *
 ****************************************************************************/

static void btsh_on_sync(void)
{
  int rc;

  printf("BTSH[S1] on_sync enter\n");

  /* 确保有可用的标识地址（优先 public） */

  rc = ble_hs_util_ensure_addr(0);
  printf("BTSH[S2] ensure_addr rc=%d\n", rc);
  if (rc != 0)
    {
      printf("BTSH[!] ensure_addr failed %d\n", rc);
      return;
    }

  /* 注册 GATT 服务（此刻 host 已就绪，不会阻塞） */

  if (btsh_gatt_register() != 0)
    {
      return;
    }

  /* 开始广播 */

  printf("BTSH[S3] advertise\n");
  btsh_advertise();
}

static void btsh_on_reset(int reason)
{
  printf("BTSH[!] host reset, reason=%d\n", reason);
}

/****************************************************************************
 * Public Functions
 ****************************************************************************/

/****************************************************************************
 * Name: btsh_light_start
 *
 * Description:
 *   注册 GATT 服务并启动广播。
 *   由 NSH 命令 `nimble_light` 调用。
 *
 ****************************************************************************/

int btsh_light_start(void)
{
  pthread_t tid_host;
  pthread_t tid_hci;
  int       rc;

  printf("BTSH[1] enter start\n");

  /* 打开板载 WS2812（没有也不影响 BLE 功能） */

  if (g_led_fd < 0)
    {
      printf("BTSH[2] opening LED %s\n", CONFIG_BTSH_LIGHT_LED_DEV);
      g_led_fd = open(CONFIG_BTSH_LIGHT_LED_DEV, O_WRONLY);
      printf("BTSH[3] open rc=%d\n", g_led_fd);
    }

  printf("BTSH[4] setting host callbacks\n");

  /* ★ 注意：**不要**在这里注册 GATT 服务。
   *
   * ble_gatts_add_svcs() 必须在 host 与控制器**同步完成之后**调用
   * （即从 sync_cb 里调），否则会永久阻塞。
   * 实测现象（2026-10-11）：串口停在 "BTSH[5] gatts_add_svcs" 之后
   * 毫无输出，连 NSH 也卡死（命令不返回）。
   * 详见 btsh_gatt_register() 的注释。
   */

  /* 设置 host 回调。
   * sync_cb 是**必须**的 —— host 与控制器同步完成后由它：
   *   1) 注册 GATT 服务
   *   2) 启动广播
   * （NimBLE 自带的 NuttX 示例漏了 sync_cb，所以它永远不广播。）
   */

  ble_hs_cfg.reset_cb = btsh_on_reset;
  ble_hs_cfg.sync_cb  = btsh_on_sync;

  printf("BTSH[5] nimble_port_init\n");

  /* 初始化 NimBLE。
   * 注意：这一步内部会调 ble_transport_ll_init() → ble_hci_sock_init()，
   * 即 HCI socket 传输层在这里建立。**不需要**外部再初始化。
   *
   * 另注：nimble_port_init() 的返回值是 void（不是 int），
   * 因此不能检查返回值。若内部失败，NimBLE 会自己打印错误。
   */

  nimble_port_init();

  printf("BTSH[8] nimble port initialized\n");

  /* 设置广播名 */

  rc = ble_svc_gap_device_name_set(CONFIG_BTSH_LIGHT_ADV_NAME);
  printf("BTSH[9] set name rc=%d\n", rc);

  printf("BTSH[10] creating hci thread\n");

  /* 启动 HCI 收包任务（控制器 → 主机） */

  rc = pthread_create(&tid_hci, NULL, btsh_hci_thread, NULL);
  if (rc != 0)
    {
      printf("BTSH[!] pthread_create(hci) failed %d\n", rc);
      return rc;
    }

  (void)pthread_setname_np(tid_hci, "btsh_hci");
  printf("BTSH[11] hci thread created\n");

  /* 启动主机事件循环任务。
   * 它内部会在同步完成后触发 btsh_on_sync() → btsh_advertise()。
   */

  printf("BTSH[12] creating host thread\n");

  rc = pthread_create(&tid_host, NULL, btsh_host_thread, NULL);
  if (rc != 0)
    {
      printf("BTSH[!] pthread_create(host) failed %d\n", rc);
      return rc;
    }

  (void)pthread_setname_np(tid_host, "btsh_host");
  printf("BTSH[13] host thread created, applying light\n");

  btsh_light_apply(g_light_state);
  printf("BTSH[14] start() returning 0\n");
  return 0;
}

/****************************************************************************
 * Name: main
 *
 * Description:
 *   NSH 命令入口：
 *     nimble_light          启动
 *     nimble_light state    查看状态
 *
 ****************************************************************************/

int main(int argc, FAR char *argv[])
{
  if (argc >= 2 && strcmp(argv[1], "state") == 0)
    {
      printf("BTSH light service (NimBLE)\n");
      printf("  service UUID : FF00-1234-5678-9ABC-DEF0123456**\n");
      printf("  cmd   UUID   : ...FF01 (write)\n");
      printf("  state UUID   : ...FF02 (read/notify)\n");
      printf("  info  UUID   : ...FF03 (read)\n");
      printf("  adv name     : %s\n", CONFIG_BTSH_LIGHT_ADV_NAME);
      printf("  LED device   : %s (fd=%d)\n",
             CONFIG_BTSH_LIGHT_LED_DEV, g_led_fd);
      printf("  light state  : %s\n",
             g_light_state == BTSH_CMD_ON ? "ON" : "OFF");
      printf("  conn handle  : %d\n", (int)g_conn_handle);
      printf("  notify sub   : %s\n", g_state_notify ? "yes" : "no");
      return 0;
    }

  if (argc >= 2 && strcmp(argv[1], "help") == 0)
    {
      printf("Usage: nimble_light [state|help]\n");
      printf("  (无参数) 启动 GATT 灯控服务并开始广播\n");
      return 0;
    }

  printf("BTSH: starting NimBLE light service...\n");
  if (btsh_light_start() != 0)
    {
      printf("BTSH: start failed\n");
      return ERROR;
    }

  printf("BTSH: started. Use 'nimble_light state' to check.\n");
  return OK;
}
