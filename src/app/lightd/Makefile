############################################################################
# apps/wireless/btsh_lightd/Makefile
#
# 远程灯控守护进程（TCP 版）
# 由 OpenvelaESP-BTSH 项目编写
#
############################################################################

include $(APPDIR)/Make.defs

PROGNAME  = $(CONFIG_BTSH_LIGHTD_PROGNAME)
PRIORITY  = $(CONFIG_BTSH_LIGHTD_PRIORITY)
STACKSIZE = $(CONFIG_BTSH_LIGHTD_STACKSIZE)

MAINSRC = btsh_lightd_main.c

include $(APPDIR)/Application.mk
