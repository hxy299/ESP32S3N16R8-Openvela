# docs/stages/ — 分阶段开发记录

> **这是本项目的版本管理主索引。** 每个开发阶段一个 md 文件，按序号命名。

## 为什么需要它

openvela / NuttX 的板级适配会持续数月，期间会反复改 defconfig、Kconfig、板级源码、
烧录参数。没有阶段记录，三个月后没人（包括自己）能说清「为什么这个配置是这样」。
本目录就是这条时间线。

## 命名与写法

```
stage-00-project-init.md        项目初始化
stage-01-env-and-baseline.md    环境与资料基线
stage-02-board-port.md          板级适配
stage-03-peripherals.md         外设驱动（GPIO/继电器/RGB）
stage-04-ble-bringup.md         BLE 打通
stage-05-gatt-service.md        GATT 灯控服务
stage-06-a7z-integration.md     与 A7Z 联调
stage-07-stabilize-release.md   稳定性与发布
```

## 每份阶段记录的固定结构

```markdown
# Stage NN — <阶段名>

- 日期：YYYY-MM-DD
- 状态：进行中 / 已完成 / 阻塞
- 关联提交：<git commit / tag>
- 前置阶段：stage-NN-1

## 1. 本阶段目标
（可验收的、具体的）

## 2. 前置条件与环境
（WSL 路径、工具链版本、硬件接线）

## 3. 实际执行过程
（按时间顺序：做了什么 → 命令 → 关键输出。失败的尝试也要写，并写清失败原因）

## 4. 产出物
（新增/修改的文件清单，指向仓库内路径）

## 5. 验证方法与结果
（怎么证明它work了：串口日志片段、测试输出、实测现象）

## 6. 结论
（达成 / 部分达成 / 未达成，一句话）

## 7. 遗留问题与风险
（未解决的、需要用户确认的、技术债）

## 8. 下一步
（下一阶段要做的第一件事）
```

## 阶段总表

| 阶段 | 文件 | 状态 |
| --- | --- | --- |
| S0 项目初始化 | [stage-00-project-init.md](stage-00-project-init.md) | ✅ 已完成 |
| S1 资料基线与技术调研 | [stage-01-env-and-baseline.md](stage-01-env-and-baseline.md) | ✅ 已完成 |
| S2 板级适配与实机验证 | [stage-02-board-port.md](stage-02-board-port.md) | ✅ **已完成（首次启动成功）** |
| S3 外设与无线启用 | [stage-03-peripherals.md](stage-03-peripherals.md) | ✅ **全部达成**（PSRAM / BLE / WiFi+BLE 共存 / WS2812 状态灯） |
| S4 BLE 打通 | stage-04-ble-bringup.md | ⏳ 未开始 |
| S5 GATT 灯控服务 | stage-05-gatt-service.md | ⏳ 未开始 |
| S6 与 A7Z 联调 | stage-06-a7z-integration.md | ⏳ 未开始 |
| S7 稳定性与发布 | stage-07-stabilize-release.md | ⏳ 未开始 |

## 阶段调整说明

- 原 S1「环境与资料基线」合并了「技术调研」，重命名为 **S1 资料基线与技术调研**。
- **首次编译验证**在 S1 期间提前完成（构建不需要硬件，用户当时尚无开发板）。
- S2 原计划为纯「板级适配」，实际因**开发板到手**，扩展为
  **「板级适配 + 首次实机验证」**，并新增 **S3「外设与无线启用」**
  承接 PSRAM / BLE / WiFi 的逐步叠加（每步独立验证，避免多变量同时引入）。
