# config/defconfig/ — defconfig 快照库

存放本项目使用的 NuttX `defconfig` 文件及其**来源与差异说明**。

## 为什么要存快照

openvela 源码树在 `~/openvela` 里，会随 `repo sync` 变动。把 defconfig 拷进本仓库后：

1. 固件可复现 —— 任何时候都能知道 v0.3 是用哪个配置编的。
2. 便于 diff —— 与上游 `esp32s3-devkit/configs/ble` 的差异一目了然。
3. 便于评审 —— 配置改动可以像代码一样 review。

## 计划收录

| 文件 | 来源 | 说明 |
| --- | --- | --- |
| `esp32s3-devkit_ble.defconfig.upstream` | `nuttx/boards/xtensa/esp32s3/esp32s3-devkit/configs/ble/defconfig` | 只读参考基线 |
| `esp32s3-devkit_nsh.defconfig.upstream` | 同上 `nsh/` | 只读参考基线 |
| `esp32s3-devkit_psram_octal.defconfig.upstream` | 同上 `psram_octal/` | N16R8 的 OPI PSRAM 参考 |
| `btsh_nsh.defconfig` | 本项目 | 目标板 NSH 基线（阶段 S2 产出） |
| `btsh_ble.defconfig` | 本项目 | 目标板 BLE 配置（阶段 S4 产出） |

## 差异记录要求

每引入一份自定义 defconfig，在同目录写一个 `<name>.diff.md`，说明：

- 相对哪个上游配置
- 增删了哪些 CONFIG_，**每个的原因**
- 与该配置配套的 Kconfig / 源码改动（指向 `thirdparty/` 的 patch）

> 命名后缀 `.upstream` 表示「上游原始副本，不得修改」。
