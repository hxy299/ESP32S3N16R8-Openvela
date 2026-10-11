/****************************************************************************
 * boards/xtensa/esp32s3/esp32s3-devkit/src/esp32s3_btsh_ws2812.c
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * 由 OpenvelaESP-BTSH 项目添加（非上游文件）
 *
 * 目标板：ESP32-S3-N16R8（芯路城）
 *   板载 RGB 为 **WS2812B**，数据线接 **GPIO48**
 *   （依据原理图：U1 = WS2812B，DIN <- GPIO48）
 *
 * 该文件用 SPI 时钟模拟 WS2812 单总线时序：
 *   - NuttX 通用驱动：drivers/leds/ws2812.c
 *   - 注册接口：      ws2812_leds_register()
 *   - SPI 外设：      SPI2，MOSI 引脚由 defconfig 指定为 GPIO48
 *                     （CONFIG_ESP32S3_SPI2_MOSIPIN=48）
 *
 * WS2812 没有 CS/RESET 线，因此**独占** SPI2。
 *
 * 参考：boards/xtensa/esp32s3/esp32s3-lcd-ev/src/esp32s3_ws2812.c
 ****************************************************************************/

/****************************************************************************
 * Included Files
 ****************************************************************************/

#include <nuttx/config.h>

#include <debug.h>
#include <errno.h>
#include <stdio.h>

#include <nuttx/leds/ws2812.h>
#include <nuttx/spi/spi.h>

#include "esp32s3_spi.h"

#if defined(CONFIG_WS2812) && !defined(CONFIG_WS2812_NON_SPI_DRIVER)

/****************************************************************************
 * Public Functions
 ****************************************************************************/

/****************************************************************************
 * Name: board_ws2812_initialize
 *
 * Description:
 *   Initialize and register the WS2812 LED driver.
 *
 * Input Parameters:
 *   devno - The device number, used to build the device path as /dev/ledsN
 *   spino - SPI port number
 *   nleds - Number of LEDs chained
 *
 * Returned Value:
 *   Zero (OK) on success; a negated errno value on failure.
 *
 ****************************************************************************/

int board_ws2812_initialize(int devno, int spino, uint16_t nleds)
{
  FAR struct spi_dev_s *spi;
  char devpath[16];
  int ret;

  spi = esp32s3_spibus_initialize(spino);
  if (spi == NULL)
    {
      lederr("ERROR: esp32s3_spibus_initialize(%d) failed\n", spino);
      return -ENODEV;
    }

  snprintf(devpath, sizeof(devpath), "/dev/leds%d", devno);

  ret = ws2812_leds_register(devpath, spi, nleds);
  if (ret < 0)
    {
      lederr("ERROR: ws2812_leds_register(%s) failed: %d\n", devpath, ret);
      return ret;
    }

  ledinfo("BTSH: ws2812 %s registered, %u LED(s), SPI%d\n",
          devpath, (unsigned)nleds, spino);
  return OK;
}

#endif /* CONFIG_WS2812 && !CONFIG_WS2812_NON_SPI_DRIVER */
