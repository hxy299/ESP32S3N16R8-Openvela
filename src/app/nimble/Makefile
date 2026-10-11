############################################################################
# apps/wireless/bluetooth/btsh_light_nimble/Makefile
#
# BLE GATT 灯控服务（NimBLE 版）—— OpenvelaESP-BTSH 项目
#
# ## ★ 重要：本目录**不负责编译**
#
# 实际的编译发生在 NimBLE 官方容器的示例目录：
#
#     apps/wireless/bluetooth/nimble/mynewt-nimble/
#       porting/examples/nuttx/
#         ├─ main.c        <-- 已被安装脚本替换为我们的应用源码
#         └─ Make.defs     <-- CSRCS = NimBLE 协议栈全部源码
#                                MAINSRC = 上面那个 main.c
#                                PROGNAME = $(CONFIG_BTSH_LIGHT_NIMBLE_PROGNAME)
#
# 由 `scripts/setup/install-btsh-light-nimble.sh` 施加。
#
# ## 本文件的作用
#
# 只提供一个"空壳"，让 NuttX 的 context/register 目标能正常处理本目录
# （`apps/Makefile` 的 `context` 目标要求每个应用目录都有 Makefile）。
#
# **不要**在这里设置 CSRCS / MAINSRC / PROGNAME：
#   - CSRCS 是 NuttX apps 构建的全局变量，会与容器互相覆盖
#   - 设了 MAINSRC 会导致本目录也被自动编译，与容器产生重复对象
#     （曾报 multiple definition of `ble_sm_alg_s1'）
#
# 本目录的 `btsh_light_main.c` 是**源码母本**，由安装脚本复制到
# 上面的示例目录。它留在这里是为了版本管理（见项目 git 仓库）。
#
############################################################################

include $(APPDIR)/Make.defs

# 有意留空：编译交给容器的示例目录

include $(APPDIR)/Application.mk
