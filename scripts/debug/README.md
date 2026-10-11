# scripts/debug/ — 调试与日志

## 计划中的脚本

| 脚本 | 用途 |
| --- | --- |
| `monitor.sh` | 串口监视（picocom/minicom），带时间戳落盘 |
| `capture.sh` | 后台抓串口日志到 `*.log`，用于长时间跑稳定性 |
| `gdb.sh` | 用 `xtensa-esp32s3-elf-gdb` + `nuttx` ELF 调试 |
| `nsh-cheatsheet.md` | NSH 常用命令备忘 |

## 串口监视

```bash
# 需要先完成 usbipd 透传，或改用 Windows 侧串口工具
picocom -b 115200 /dev/ttyUSB0
```

## GDB（若走 JTAG / 内置 USB-JTAG）

ESP32-S3 内置 USB-Serial-JTAG，理论上可免外接调试器。但注意：
**本板上 GPIO19/GPIO20 同时是原生 USB-OTG 引脚**，且需短接 OTG 焊盘才可用，
因此 USB-JTAG 是否可用取决于硬件跳线，**待实测确认**。

工具链自带 GDB：

```
~/openvela/prebuilts/gcc/linux-x86_64/xtensa-esp32s3-elf/bin/xtensa-esp32s3-elf-gdb
```

## 日志落盘约定

`tests/hardware/` 里的测试记录引用的日志文件，统一放在项目根的 `logs/`
（该目录已在 `.gitignore` 中忽略），命名 `YYYYMMDD-HHMMSS-<场景>.log`。
关键片段应**粘贴进测试记录**，避免日志丢失后无法追溯。
