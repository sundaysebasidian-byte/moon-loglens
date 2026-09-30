# 中文验收 walkthrough

基准版本：公开仓库 `f2744fad8225b2276f1a41338ac428d312cd4d06`，Mooncakes `0.2.0`。
验收补项基于该版本，结果应同时标注实际 HEAD 和工作区差异；公开仓库的验收补项与 Mooncakes 0.2.0 发布包分别验证，不能把源码改动当成已重新发布的包。

## 复现步骤

在已有 MoonBit 原生工具链、Python 3 和 Git 的环境中，从仓库根目录执行：

```sh
python3 scripts/acceptance.py
# 单独验证发布包：
python3 scripts/acceptance.py --consumer-only
```

脚本串行执行，不安装工具。先将 `tests/registry_consumer` 的三个源文件复制到仓库外临时模块，运行 `moon update`、native check、run；只依赖官方 registry 的 `sundaysebasidian-byte/moon-loglens@0.2.0`，不引用本地源码。完整 JSON 断言验证两条构建事件 accepted=2、sum=30、mean=15，并保存解析到的包清单和源码哈希。同模块的 `examples/reuse` 是嵌入示例，独立模块验证才覆盖下游依赖路径。

随后执行 native check/build、MoonBit 测试、两组 Python CLI 测试、5 项宿主输入边界测试及三个非 HTTP 例子。每条命令记录退出码、标准输出和错误输出，失败即停止。默认结果目录位于仓库旁的 `acceptance-evidence/<UTC时间>`；可用 `--output` 指定仓库外的新目录。`manifest.json` 包含 HEAD SHA、分支、未提交状态、输入文件 SHA256、平台和工具链版本。不要覆盖旧证据目录。

CI 使用官方 Unix 脚本的位置参数固定 `0.10.14+7d59c7ec9`，安装到 runner 临时目录并检查实际 `moonc -v`，然后调用同一验收脚本并保存证据。推荐 Linux/macOS；验收时应检查目标提交对应的 workflow 结果，不能用历史 SHA 的通过记录替代。

预期示例均 accepted=3、filtered=1、invalid=0：

| 例子 | 选择的组 | count | 第一个指标 sum / mean |
| --- | --- | --- | --- |
| jobs | mail / ok | 2 | 40 / 20 ms |
| builds | compile / linux | 2 | 30 / 15 s |
| sensors | north / freezer-a | 2 | -38 / -19 °C |

这些都是构造样本，不代表生产性能或真实传感器测量。也可以按照 README 的三条 `moon run cmd/query` 命令逐条观察 JSON 输出。

## 需求到证据矩阵

| 验收项 | 实现或文档位置 | 可检查证据 |
| --- | --- | --- |
| MoonBit 实现核心能力 | `query/query.mbt`、`moon-loglens.mbt`、`cmd/` | native check/build；Python 仅做进程断言和证据归档 |
| 独立复用公共 API | `query/pkg.generated.mbti`、`tests/registry_consumer/` | 仓库外模块从 registry 导入 `Query::parse`、`Accumulator::new/push_line/report`；完整 JSON 断言 |
| 多种非 HTTP 场景 | `examples/jobs.*`、`builds.*`、`sensors.*` | 三个示例输出与断言；`test_three_non_http_examples` |
| 嵌套字段及类型过滤 | `query/query_test.mbt` | `nested objects arrays and escaped pointer tokens`、`all typed comparison operators and missing fields` |
| 分组正确性和失败原子性 | 同上 | `typed composite keys...`、`group limit and metric overflow preserve complete prior state` |
| 报告隔离与有界诊断 | 同上 | `report mutations cannot corrupt accumulator`、`invalid diagnostics are bounded and redact payloads` |
| 真实 CLI 与退出码 | `tests/cli_smoke.py`、`tests/query_cli.py` | 8+8 个测试，覆盖 stdin/文件、CRLF、UTF-8、质量门槛、超限和无部分成功报告 |
| 公开仓库与 CI | README、`.github/workflows/ci.yml` | [基准提交](https://github.com/sundaysebasidian-byte/moon-loglens/commit/f2744fad8225b2276f1a41338ac428d312cd4d06)、[已有 Linux CI](https://github.com/sundaysebasidian-byte/moon-loglens/actions/runs/36395038101)；本地结果以 manifest 为准 |
| Mooncakes 发布 | `moon.mod` 的 0.2.0 元数据 | [公开包](https://mooncakes.io/docs/sundaysebasidian-byte/moon-loglens)及独立消费者解析清单 |
| OSI 许可、归属和 AI 使用说明 | `LICENSE`、`docs/design-and-attribution.zh-CN.md` | Apache-2.0 文件、实际依赖清单和本次辅助范围 |

基准测试为 22 个 MoonBit 测试、两组各 8 个 Python 测试；脚本中的示例和消费者断言属于额外验收步骤，不将它们造数成新增单元测试。
macOS 本地通过只证明该平台；已有 Linux CI 属于固定基准 SHA。旧 Windows 结果仅对应 `91a848e`，不能证明当前版本 Windows 通过。

可另外运行 `python3 tests/platform_inputs.py`：5 项真实宿主 CLI 测试覆盖中文/空格文件路径、CRLF、无末尾换行、文件与 stdin 一致性、编码边界及退出码。Mac 上执行属于输入边界模拟，没有 mock 平台或 Windows 内核；Windows 盘符/UNC 路径、NTFS、PowerShell 参数与管道、安装和编译仍须在真实 Windows 测试。
使用无 BOM 的 UTF-8；UTF-16/旧编码会产生输入错误，UTF-8 BOM 不被自动移除，会使首条事件无效或查询配置解析失败。

本文件是技术证据，不代表主办方初审、验收或获奖结论。[正式章程](https://bxup9uklfcb.feishu.cn/wiki/Dx4Bwd6D1i3GfHkajQCcF7SznEd)应由主办方最新内容裁定。
