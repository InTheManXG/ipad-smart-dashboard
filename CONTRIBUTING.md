# 参与开发

感谢帮助改进 iPad 智能大屏。提交改动前先确认现有行为和影响范围；涉及配对、权限、持久化格式或脚本执行时，请同时说明兼容策略和验证方法。

## 开发环境

- 原生 App：Apple Silicon Mac、Apple Command Line Tools，构建目标 macOS 13；实际系统兼容性需单独验证。
- 服务端：Python 3.12，使用标准库，不需要安装私有包。
- 网页测试：Node.js 22，无前端包安装步骤。
- 公网中继容器：Docker Compose；本地 App 不依赖 Docker。

App、后台和网页分别位于 `mac_app/` 与 `web/`；`server.py` 和 `pairing.py` 用于服务器端中继，不能当作 Mac App 的运行前置条件。

## 修改与测试

代码注释使用中文，重点解释领域规则、信任边界和选择原因。保持修改范围小，不顺手清理无关代码；不要提交个人配置、运行数据、凭据或本机生成的 App。

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
for test in tests/test_*.cjs; do node "$test" || exit; done
bash mac_app/test.sh
bash mac_app/build.sh
git diff --check
```

原生检查仅能在合适的 Mac 环境运行，包含临时配置和隔离钥匙串条目测试，系统可能要求授权。不要降低真实钥匙串的访问保护来绕过失败。默认开发构建为 ad-hoc 签名，不是对外分发产物。

安全相关逻辑需要覆盖拒绝路径，例如未认证、只读会话、跨设备请求、过期、撤权、损坏文件和重复指令。脚本测试只使用临时无害文件，不自动执行个人订阅更新、真实业务脚本或发起付费请求。

界面或动画改动需要实际查看渲染和交互；静态检查通过不能证明拖动、触屏、滚动和 iPad 常亮符合预期。测试报告区分自动化、本机运行、实际 iPad 和公网部署。

## 提交与 Pull Request

在提交前检查完整 diff 和暂存区，只提交本次任务相关改动。说明触发场景、修改后的行为、兼容性和已执行的验证；未完成的验证明确列出，不写成已通过。新依赖应说明必要性、来源和再分发许可。

文档、截图、日志和测试夹具中使用虚构信息，不提交真实设备名、公开服务凭据、配对令牌、Key、任务内容或个人文件路径。安全问题通过 [私密漏洞报告流程](docs/SECURITY.md#报告漏洞) 处理，不在公开 PR 中附有效利用凭据。

发布规则见 [docs/RELEASE.md](docs/RELEASE.md)，自托管规则见 [docs/SELF_HOSTING.md](docs/SELF_HOSTING.md)。
