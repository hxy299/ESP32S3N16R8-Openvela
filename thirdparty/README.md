# thirdparty/ — 第三方代码与补丁

## 原则

**openvela / NuttX 源码树不纳入本仓库。** 对它的所有改动以 patch 形式存在这里，
保证任何一台机器都能从干净的 openvela 源码复现出我们的固件。

## 目录结构

```
thirdparty/
├── README.md               本文件
├── patches/                实际的 patch 文件（按应用顺序编号）
│   ├── 0001-...patch
│   └── 0002-...patch
├── upstream-notes/         对上游代码的阅读笔记（不改代码，只记录发现）
└── apply-patches.sh        一键把 patches/ 应用到 ~/openvela
```

## patch 规范

1. 用 `git format-patch` 或 `git diff` 生成，**统一 diff 格式**。
2. 文件名带序号，按依赖顺序排列：`0001-board-add-esp32s3-n16r8.patch`。
3. 每个 patch 的 commit message 写清楚：**为什么改**，而不只是改了什么。
4. patch 必须能对**指定的 openvela commit** 干净应用。
   目标基线记录在 `patches/BASELINE.md`：

```markdown
# 补丁基线
- openvela 仓库：<repo url>
- 同步日期：YYYY-MM-DD
- 各子仓库 commit：
  - nuttx: <hash>
  - apps:  <hash>
  - vendor: <hash>
```

## 变更清单（持续更新）

| 编号 | 文件 | 目标仓库 | 说明 | 状态 |
| --- | --- | --- | --- | --- |
| — | — | — | 暂无（阶段 S2 开始产生） | — |

## upstream-notes/

存放**不改代码**时的调研笔记，例如：

- NuttX 上游 ESP32-S3 驱动实现思路（`~/nuttx-upstream` 里读到的）
- openvela 分支与上游的差异分析（见 [`../docs/bringup/README.md`](../docs/bringup/README.md)）
- 上游已有的板级实现可借鉴之处

这样做的价值：避免同一个坑踩两次，也避免「三个月后忘了当初为什么没直接抄上游」。
