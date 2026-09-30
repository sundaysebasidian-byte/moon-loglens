# AI 辅助、设计取舍与依赖归属

## 可核实的 AI 辅助角色

项目现有申报补充记录已披露 AI 辅助，不把技术材料称为参赛者独立人工撰写。本次 Codex 的具体范围是：读取固定版本和既有证据、整理独立消费者 fixture、编写可复现验收脚本与中文说明、运行命令并记录真实结果。没有为原开发过程补写虚构的人工工作、提交次数、工时或逐行作者归属。开发历史以公开 Git 记录为准；AI 自审不等于本人审查或组委会验收。

本次未修改核心查询或 HTTP 实现；只有具体测试失败且根因在项目代码时才考虑最小修复。用户负责理解核心 API、确认材料真实性和决定后续提交；本次不代做这些声明。

## 关键设计取舍

- 选择固定 JSON 配置、JSON Pointer 和 typed predicates，而不实现通用表达式语言。重点是 accepted/filtered/invalid 语义、增量分组聚合、原子失败和进程质量门槛。README 已注明 MoonJQ、MoonJSONPath 的相邻能力，不声称生态此前缺少 JSON 查询工具。
- `query` 公共包仅用 MoonBit core，不做 I/O；调用者供给字符串。native CLI 用官方 async 处理输入，因此下游既能嵌入 API，也能直接调用 CLI。
- 查询模式按行累加而不保留全部事件；内存仍受最大单行、查询大小和分组基数影响。限制分组数、有界无效行诊断和指标更新前校验用于显式失败。HTTP 模式为精确百分位保留选中事件，适用于有界日志。
- 分组键保留 JSON 标量类型；报告是独立快照。指标使用双精度浮点，存在舍入与超过 2^53 的整数精度限制；标识符宜用字符串，不用于精确财务核算。
- 三种非 HTTP schema 展示重用范围，消费者验收独立解析已发布包。只验证现有接口，不增加仪表盘、日志格式或大范围重构。

## 许可与归属

| 组件 | 使用范围 | 许可证据 |
| --- | --- | --- |
| Moon LogLens | 查询、HTTP 分析、CLI 与示例 | 仓库 `LICENSE`、`moon.mod`：Apache-2.0 |
| `moonbitlang/core` | JSON、容器及标准 API | 现有 SDK `lib/core/LICENSE`：Apache-2.0 |
| `moonbitlang/async@0.20.2` | 原生 CLI I/O；也是发布模块声明的依赖 | 下载包 `moon.mod` 与 `LICENSE`：Apache-2.0；[官方源码](https://github.com/moonbitlang/async) |
| Python 标准库 | CLI 验证及验收归档 | 不新增第三方 Python 包；Python 使用其发行版附带的 PSF 许可 |

本次未移植第三方实现、未引入新项目依赖、未打包工具链。MoonBit 工具链自身包含的其他组件以 SDK `CREDITS.md` 和发行版许可为准，不能把其全部组件笼统称为 Apache-2.0。以上是实际使用及元数据说明，不冒称已完成全依赖法律审计。
