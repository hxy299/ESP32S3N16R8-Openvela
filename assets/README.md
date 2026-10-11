# assets/ — 静态资源

| 目录 | 内容 |
| --- | --- |
| [`images/`](images/README.md) | 实拍图、标注图、界面截图 |
| [`diagrams/`](diagrams/README.md) | 架构图、流程图、时序图的**源文件**（非导出图片） |
| [`reference/`](reference/README.md) | 原厂参考资料：商家资料页存档、数据手册索引 |

## 约定

1. **图片加日期前缀**，如 `2026-10-10-board-top.jpg`，避免同名覆盖。
2. 架构图的源文件（drawio / PlantUML / Mermaid）必须入库，导出的 PNG 也入库。
3. 大体积 PDF 若超过 ~20 MB，考虑只保留链接与校验和（`reference/` 里说明）。
4. 图片文件名用英文小写 + 连字符，避免中文文件名带来的跨平台编码问题。
