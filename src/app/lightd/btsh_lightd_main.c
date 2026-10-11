/****************************************************************************
 * apps/wireless/btsh_lightd/btsh_lightd_main.c
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * 由 OpenvelaESP-BTSH 项目编写
 *
 * 远程灯控守护进程（TCP 版）
 *
 * ## 为什么有这一版
 *
 * 原计划用 BLE（GATT）做控制通道。但经过完整排查确认：
 *   openvela / NuttX 在 ESP32-S3 上的 BLE host 栈**无法正常工作** ——
 *   广播、连接建立都成功，但**控制器连接后不送 ACL 数据**
 *   （VHCI 回调入口插桩实测，H4_ACL 恒为 0），
 *   导致 ATT/GATT 层永远收不到东西，服务发现必然超时。
 *
 *   同一块板用 ESP-IDF + NimBLE 则**完全正常**（完整枚举 4 个 GATT 服务），
 *   证明硬件与控制器无问题。详见：
 *     docs/stages/stage-04-FINAL-nimble-not-viable.md
 *     HANDOFF-CURRENT-ISSUE.md
 *
 * 因此先用 **WiFi/TCP** 实现"远程点灯"这一核心目标（WiFi 已验证可用），
 * BLE 作为后续升级项。
 *
 * ## 协议（极简文本协议，便于任何客户端接入）
 *
 *   TCP 端口 2323（可通过 Kconfig 改）
 *
 *   客户端 -> 设备:
 *     "ON\n"            开灯
 *     "OFF\n"           关灯
 *     "TOGGLE\n"        翻转
 *     "STATE\n"         查询状态
 *     "PING\n"          存活检测
 *     "HELP\n"          帮助
 *
 *   设备 -> 客户端:
 *     "OK ON\n" / "OK OFF\n"           命令执行成功
 *     "STATE 1\n" / "STATE 0\n"        状态（1=亮 0=灭）
 *     "PONG\n"                         存活
 *     "ERR <reason>\n"                 错误
 *
 * ## 为什么用文本协议
 *
 * 便于用 telnet / netcat / Python 一行命令测试，
 * 也便于接 Home Assistant、Node-RED 等（直接 TCP 发字符串）。
 *
 * ## 物理输出
 *
 * 当前映射到**板载 WS2812B（/dev/leds0）**：
 *   开灯 -> 绿色常亮
 *   关灯 -> 熄灭
 * 接继电器后只需改 btsh_light_apply()。
 *
 * ## 用法
 *
 *   nsh> btsh_lightd              启动（前台，占一个 NSH 任务）
 *   nsh> btsh_lightd &            后台启动
 *
 * 然后从电脑：
 *   python -c "import socket;s=socket.create_connection(('<板子IP>',2323));s.sendall(b'ON\n');print(s.recv(64))"
 *
 ****************************************************************************/

/****************************************************************************
 * Included Files
 ****************************************************************************/

#include <nuttx/config.h>

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <syslog.h>
#include <unistd.h>

/****************************************************************************
 * Pre-processor Definitions
 ****************************************************************************/

#define BTSH_CMD_OFF       0x00
#define BTSH_CMD_ON        0x01

#ifndef CONFIG_BTSH_LIGHTD_PORT
#  define CONFIG_BTSH_LIGHTD_PORT 2323
#endif

#ifndef CONFIG_BTSH_LIGHTD_LED_DEV
#  define CONFIG_BTSH_LIGHTD_LED_DEV "/dev/leds0"
#endif

#ifndef CONFIG_BTSH_LIGHTD_BACKLOG
#  define CONFIG_BTSH_LIGHTD_BACKLOG 4
#endif

#ifndef CONFIG_BTSH_LIGHTD_BUFSIZE
#  define CONFIG_BTSH_LIGHTD_BUFSIZE 256
#endif

/* NuttX ws2812 驱动：4 字节/LED（魔数 + r + g + b） */

#define BTSH_WS2812_MAGIC 0x0000aa55

#define BTSH_LINE_MAX     64

/****************************************************************************
 * Private Types
 ****************************************************************************/

struct btsh_rgb_s
{
  uint32_t magic;
  uint8_t  r;
  uint8_t  g;
  uint8_t  b;
};

/****************************************************************************
 * Private Data
 ****************************************************************************/

static uint8_t g_light_state = BTSH_CMD_OFF;
static int     g_led_fd      = -1;

/****************************************************************************
 * Private Functions
 ****************************************************************************/

/****************************************************************************
 * Name: btsh_light_apply
 *
 * Description:
 *   把逻辑灯状态写到物理输出。
 *   当前 = 板载 WS2812B。接继电器后改这里即可（例如操作 GPIO）。
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
  px.r = 0;
  px.g = (state == BTSH_CMD_ON) ? 40 : 0;   /* 亮=绿，灭=熄 */
  px.b = 0;

  if (lseek(g_led_fd, 0, SEEK_SET) < 0)
    {
      return;
    }

  (void)write(g_led_fd, &px, sizeof(px));

  printf("btsh_lightd: light %s\n", state == BTSH_CMD_ON ? "ON" : "OFF");
}

/****************************************************************************
 * Name: btsh_send
 *
 * Description:
 *   发送一行响应（自动加 \n）。
 *
 * ★ 为什么用 sendto() 而不是 send()/write()
 *
 *   实测踩坑（2026-10-11）：
 *     - send()  -> 每次都失败，errno=107 (ENOTCONN)
 *     - write() -> 同样 errno=107
 *   但 accept() 明明返回了有效连接，且 recv() 能正常收到客户端数据。
 *
 *   NuttX 对 "已 accept 的 TCP socket" 在做**写**操作时会检查连接状态；
 *   这里显式用 sendto() 带上对端地址，走不依赖该状态的路径。
 *   （这是经过实测对比后确定的写法，不是猜测。）
 *
 ****************************************************************************/

static FAR struct sockaddr_in *g_peer;
static socklen_t               g_peerlen;

static int btsh_write_all(int fd, FAR const char *buf, size_t len)
{
  size_t done = 0;

  while (done < len)
    {
      ssize_t n;

      if (g_peer != NULL)
        {
          n = sendto(fd, buf + done, len - done, 0,
                     (FAR struct sockaddr *)g_peer, g_peerlen);
        }
      else
        {
          n = write(fd, buf + done, len - done);
        }

      if (n < 0)
        {
          if (errno == EINTR)
            {
              continue;
            }

          printf("btsh_lightd: write failed errno=%d\n", errno);
          return -1;
        }

      if (n == 0)
        {
          printf("btsh_lightd: write returned 0\n");
          return -1;
        }

      done += (size_t)n;
    }

  return 0;
}

static void btsh_send(int fd, FAR const char *fmt, ...)
{
  char    buf[BTSH_LINE_MAX + 8];
  va_list ap;
  int     n;

  va_start(ap, fmt);
  n = vsnprintf(buf, sizeof(buf) - 2, fmt, ap);
  va_end(ap);

  if (n < 0)
    {
      printf("btsh_lightd: vsnprintf failed\n");
      return;
    }

  if (n > (int)sizeof(buf) - 2)
    {
      n = sizeof(buf) - 2;
    }

  buf[n]     = '\n';
  buf[n + 1] = '\0';

  (void)btsh_write_all(fd, buf, (size_t)n + 1);
}

/****************************************************************************
 * Name: btsh_handle_line
 *
 * Description:
 *   处理一条命令（已去掉换行符）。
 *
 * Returned Value:
 *   true  = 继续保持连接
 *   false = 客户端要求断开
 *
 ****************************************************************************/

static bool btsh_handle_line(int fd, FAR char *line)
{
  /* 去掉首尾空白 */

  while (*line == ' ' || *line == '\t')
    {
      line++;
    }

  size_t len = strlen(line);
  while (len > 0 &&
         (line[len - 1] == ' ' || line[len - 1] == '\t' ||
          line[len - 1] == '\r'))
    {
      line[--len] = '\0';
    }

  if (len == 0)
    {
      return true;
    }

  /* 统一转大写，便于容错 */

  for (size_t i = 0; i < len; i++)
    {
      if (line[i] >= 'a' && line[i] <= 'z')
        {
          line[i] = line[i] - 'a' + 'A';
        }
    }

  printf("btsh_lightd: recv \"%s\"\n", line);

  if (strcmp(line, "ON") == 0)
    {
      if (g_light_state != BTSH_CMD_ON)
        {
          g_light_state = BTSH_CMD_ON;
          btsh_light_apply(g_light_state);
        }

      btsh_send(fd, "OK ON");
      return true;
    }

  if (strcmp(line, "OFF") == 0)
    {
      if (g_light_state != BTSH_CMD_OFF)
        {
          g_light_state = BTSH_CMD_OFF;
          btsh_light_apply(g_light_state);
        }

      btsh_send(fd, "OK OFF");
      return true;
    }

  if (strcmp(line, "TOGGLE") == 0)
    {
      g_light_state = (g_light_state == BTSH_CMD_ON) ?
                      BTSH_CMD_OFF : BTSH_CMD_ON;
      btsh_light_apply(g_light_state);
      btsh_send(fd, "OK %s", g_light_state == BTSH_CMD_ON ? "ON" : "OFF");
      return true;
    }

  if (strcmp(line, "STATE") == 0 || strcmp(line, "?") == 0)
    {
      btsh_send(fd, "STATE %d", g_light_state);
      return true;
    }

  if (strcmp(line, "PING") == 0)
    {
      btsh_send(fd, "PONG");
      return true;
    }

  if (strcmp(line, "HELP") == 0)
    {
      btsh_send(fd, "OK commands: ON OFF TOGGLE STATE PING HELP QUIT");
      return true;
    }

  if (strcmp(line, "QUIT") == 0 || strcmp(line, "EXIT") == 0)
    {
      btsh_send(fd, "OK BYE");
      return false;
    }

  btsh_send(fd, "ERR unknown command");
  return true;
}

/****************************************************************************
 * Name: btsh_serve
 *
 * Description:
 *   服务一个客户端连接，直到其断开。
 *
 ****************************************************************************/

static void btsh_serve(int fd)
{
  char  buf[BTSH_LINE_MAX * 2];
  char  line[BTSH_LINE_MAX];
  int   linelen = 0;
  bool  alive   = true;

  /* 简洁的欢迎语，便于人类用 telnet 直接试 */

  btsh_send(fd, "BTSH LIGHT READY");
  btsh_send(fd, "STATE %d", g_light_state);

  while (alive)
    {
      ssize_t n = recv(fd, buf, sizeof(buf), 0);

      if (n == 0)
        {
          printf("btsh_lightd: client closed\n");
          break;
        }

      if (n < 0)
        {
          if (errno == EINTR)
            {
              continue;
            }

          printf("btsh_lightd: recv error %d\n", errno);
          break;
        }

      for (ssize_t i = 0; i < n; i++)
        {
          char c = buf[i];

          if (c == '\n')
            {
              line[linelen] = '\0';

              if (!btsh_handle_line(fd, line))
                {
                  alive = false;
                  break;
                }

              linelen = 0;
            }
          else if (c != '\r')
            {
              if (linelen < (int)sizeof(line) - 1)
                {
                  line[linelen++] = c;
                }
              else
                {
                  /* 行太长：丢弃并报错 */

                  linelen = 0;
                  btsh_send(fd, "ERR line too long");
                }
            }
        }
    }
}

/****************************************************************************
 * Public Functions
 ****************************************************************************/

/****************************************************************************
 * Name: main
 *
 * Description:
 *   NSH 入口：启动 TCP 灯控服务。
 *
 ****************************************************************************/

int main(int argc, FAR char *argv[])
{
  struct sockaddr_in addr;
  int                listensd;
  int                optval = 1;
  int                port   = CONFIG_BTSH_LIGHTD_PORT;

  if (argc >= 2)
    {
      if (strcmp(argv[1], "help") == 0)
        {
          printf("Usage: btsh_lightd [port]\n");
          printf("  TCP 灯控服务，默认端口 %d\n", CONFIG_BTSH_LIGHTD_PORT);
          printf("  命令: ON / OFF / TOGGLE / STATE / PING / HELP / QUIT\n");
          return OK;
        }

      if (strcmp(argv[1], "state") == 0)
        {
          printf("btsh_lightd state:\n");
          printf("  port     : %d\n", port);
          printf("  led dev  : %s (fd=%d)\n",
                 CONFIG_BTSH_LIGHTD_LED_DEV, g_led_fd);
          printf("  light    : %s\n",
                 g_light_state == BTSH_CMD_ON ? "ON" : "OFF");
          return OK;
        }

      port = atoi(argv[1]);
      if (port <= 0 || port > 65535)
        {
          printf("btsh_lightd: invalid port\n");
          return ERROR;
        }
    }

  printf("btsh_lightd: starting (port %d)\n", port);

  /* 打开状态灯 */

  g_led_fd = open(CONFIG_BTSH_LIGHTD_LED_DEV, O_WRONLY);
  if (g_led_fd < 0)
    {
      printf("btsh_lightd: open %s failed: %d "
             "(继续运行，仅无指示灯)\n",
             CONFIG_BTSH_LIGHTD_LED_DEV, errno);
    }

  btsh_light_apply(g_light_state);

  /* 创建监听 socket */

  listensd = socket(AF_INET, SOCK_STREAM, 0);
  if (listensd < 0)
    {
      printf("btsh_lightd: socket failed: %d\n", errno);
      return ERROR;
    }

  (void)setsockopt(listensd, SOL_SOCKET, SO_REUSEADDR,
                   &optval, sizeof(optval));

  memset(&addr, 0, sizeof(addr));
  addr.sin_family      = AF_INET;
  addr.sin_port        = htons(port);
  addr.sin_addr.s_addr = htonl(INADDR_ANY);

  if (bind(listensd, (FAR struct sockaddr *)&addr, sizeof(addr)) < 0)
    {
      printf("btsh_lightd: bind(%d) failed: %d\n", port, errno);
      close(listensd);
      return ERROR;
    }

  if (listen(listensd, CONFIG_BTSH_LIGHTD_BACKLOG) < 0)
    {
      printf("btsh_lightd: listen failed: %d\n", errno);
      close(listensd);
      return ERROR;
    }

  printf("btsh_lightd: listening on port %d\n", port);
  printf("btsh_lightd: ready\n");

  /* 主循环：一次服务一个客户端 */

  for (; ; )
    {
      struct sockaddr_in peer;
      socklen_t          peerlen = sizeof(peer);
      int                fd;

      fd = accept(listensd, (FAR struct sockaddr *)&peer, &peerlen);
      if (fd < 0)
        {
          if (errno == EINTR)
            {
              continue;
            }

          printf("btsh_lightd: accept failed: %d\n", errno);
          continue;
        }

      printf("btsh_lightd: client %s:%d connected\n",
             inet_ntoa(peer.sin_addr), ntohs(peer.sin_port));

      /* 记住对端地址，供 sendto() 使用（见 btsh_write_all 的说明） */

      g_peer    = &peer;
      g_peerlen = peerlen;

      btsh_serve(fd);

      g_peer = NULL;
      close(fd);
      printf("btsh_lightd: client disconnected\n");
    }

  /* 不会到达 */

  close(listensd);
  return OK;
}
