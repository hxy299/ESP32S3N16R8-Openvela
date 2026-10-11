# .github/workflows/ — CI 流水线

预留目录。后续计划接入：

| 工作流 | 触发 | 动作 |
| --- | --- | --- |
| `docs-lint.yml` | push / PR | Markdown 链接检查、中英文空格规范检查 |
| `unit-test.yml` | push / PR | 在 Ubuntu runner 上编译并运行 `tests/unit/`（不依赖硬件） |
| `build-esp32s3.yml` | 手动 / tag | 拉取 openvela 源码 + 工具链，应用 `thirdparty/patches/`，编译出 `nuttx.bin` 并作为 artifact 上传 |

## 说明

- 前两个工作流成本低，建议阶段 S1 就接入。
- `build-esp32s3.yml` 需要下载完整的 openvela 源码与 Xtensa 工具链（数 GB），
  在 GitHub 上耗时较长，建议只在打 tag 时跑，或改用自建 runner。
- **本目录暂为空**，CI 在阶段 S1 之后再启用；当前阶段优先把本地构建跑通。
