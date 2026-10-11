# tests/unit/ — 单元测试（PC 端）

不依赖任何硬件与 RTOS，直接在 WSL / Windows 上跑。

## 计划覆盖对象

| 被测模块 | 用例要点 |
| --- | --- |
| `src/protocol/btsh_codec.c` | 合法报文解析；长度不符；未知操作码；边界值（空载荷、最大长度） |
| 灯控状态机 | 幂等（重复开灯）；状态迁移合法性；掉线时的默认态 |
| 协议常量 | UUID 格式合法性；操作码唯一性 |

## 运行方式（待实现）

```bash
# 在 WSL 中，项目根目录
make -C tests/unit
# 或
gcc -o /tmp/t_codec tests/unit/test_codec.c src/protocol/btsh_codec.c && /tmp/t_codec
```

## 约定

- 测试文件命名 `test_<模块名>.c`。
- 零第三方依赖（不引 Unity/CMock 也行，先用最简单的断言宏），保证一条 `gcc` 就能跑。
- 每个用例失败时打印：期望值、实际值、输入报文十六进制。
