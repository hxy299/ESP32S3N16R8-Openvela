# config/kconfig/ — 自定义 Kconfig 片段

存放本项目新增的板级/应用配置项定义（`Kconfig` 片段），以及它们应被放到
openvela 源码树哪个位置的说明。

## 典型新增配置项

```kconfig
config BTSH_RELAY_CHANNELS
	int "SmartHome relay channel count"
	default 1
	range 1 8
	---help---
		Number of relay channels driven by the board.
```

## 收录要求

每个片段一份文件，并在同目录 `PLACEMENT.md` 中记录：

| 片段文件 | 安装到 openvela 的路径 | 挂载点（被谁 source） |
| --- | --- | --- |
| `Kconfig.btsh` | `nuttx/boards/xtensa/esp32s3/<board>/Kconfig` | 板级 Kconfig |

> 目的：这些片段最终会以 patch 形式进 [`../../thirdparty/`](../../thirdparty/README.md)，
> 此处保留人类可读的副本与落位说明。
