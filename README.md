# iPad 控制台

把 iPad 或其他浏览器变成 Mac 的任务看板：查看 Codex 工作状态、额度和音乐，并按需控制已配置的应用与脚本。Mac 端使用 SwiftUI 和 Swift 原生服务，本地核心功能不需要 Docker、Python 或 Homebrew。

项目目前为 **0.1.0-beta.2 源码预览版**。源码采用 MIT 许可证；媒体适配器单独遵循 BSD 3-Clause。当前没有经过 Apple 公证的正式安装包，不应把开发构建当成已通过 Gatekeeper 的发行版。

## 支持范围

- Apple Silicon Mac；构建目标 macOS 13+，目前仅在维护者当前系统上验证，旧版系统与其他 Mac 尚未完成验收。
- iPad Safari、添加到主屏幕的网页，以及现代桌面浏览器。
- Codex 任务采集依赖本机 Codex App 的数据格式，后续版本变化可能需要适配。
- 音乐采集使用随包附带的 MediaRemote 兼容组件与系统 Perl。它依赖系统接口，不能保证所有 macOS 版本、播放器或歌曲都有歌词。
- 可选订阅更新由用户配置自己的脚本及解释器，沿用 `script sync [--id ID]` 协议，不内置任何订阅提供商。

## 从源码运行

安装 Apple Command Line Tools 后，在仓库目录执行：

```sh
bash mac_app/test.sh
bash mac_app/build.sh
open '.build/iPad 控制台.app'
```

默认是显式的 ad-hoc 开发构建，不需要维护者的签名证书。它只适合本机开发，下载到其他电脑可能被系统拦截。不要关闭系统安全保护来部署给他人；正式发行按 [发行说明](docs/RELEASE.md) 使用 Developer ID 和 Apple 公证。

首次运行默认不连接公网、不启用局域网看板、不启用音乐同步或登录启动。数据保存在 `~/Library/Application Support/iPadControl`；Key 和设备凭据保存在该用户钥匙串中。

## 配对和使用

1. 选择连接方式：在“服务管理”主动启用局域网看板，或在“连接与配对”填写自己信任的 HTTPS 服务根地址。
2. 在浏览器打开该地址，输入 Mac 显示的一次性配对码。
3. 新配对默认为只读。配对后在 Mac 的“连接与配对”中点击“刷新连接状态与地址”，需要远程操作时，在对应网页卡片开启“允许控制此 Mac”。
4. 在“快捷控制台”配置应用、Shell 脚本、命令或订阅脚本。网页仅提交项目 ID，路径和命令保留在 Mac；脚本以当前用户权限执行。
5. 可给多个网页添加备注，查看浏览器简介，或踢下线。撤销控制权限会阻止后续控制请求。

公网服务器可以读取任务标题、额度、音乐等同步信息，并传递控制指令。它不是端到端加密的盲中继。即使 Mac 还会检查本地授权，也必须信任所使用的服务器与其网页代码。详见 [隐私说明](docs/PRIVACY.md) 和 [安全边界](docs/SECURITY.md)。

局域网地址使用 HTTP，仅供可信网络。未知无线网络优先使用自己部署的 HTTPS 服务。

## 自托管

服务端使用 Python 标准库，可独立容器化部署，不需要维护者原有的服务、镜像或配置。见 [自托管说明](docs/SELF_HOSTING.md)，包含 Docker Compose、HTTPS 和 1Panel 的设置方式。

```sh
cp deploy/.env.example deploy/.env
docker compose -f deploy/compose.yaml up -d --build
```

Mac 端不使用 Docker。服务端容器数据卷保存配对记录，升级时不要删除数据卷。

## 测试

```sh
bash mac_app/test.sh
python3 -m unittest discover -s tests -p 'test_*.py'
for test in tests/test_*.cjs; do node "$test"; done
```

Swift 测试包括隔离的配置和钥匙串条目，使用后清理；不会执行用户配置的快捷项目。CI 在 Linux 运行服务器/网页测试，在 Apple Silicon macOS 运行原生测试与开发构建。

## 更新与卸载

先退出 App，再用新版本替换旧 `.app`。同机升级保留配置和配对；检测到配置复制到了另一台 Mac 后，会保留设置、Key 和快捷项目，并隔离旧配对和授权，要求重新配对。安装绑定只在本机保存硬件标识的 SHA-256 摘要，不上传硬件标识。

首次升级到本版本之前已复制的两份旧安装缺少绑定基线，无法自动分辨，应先停止旧电脑服务，再使用独立配对。不要手工复制别人的配置和钥匙串。旧订阅更新项目会保留名称和顺序，需要在 App 中补选自己的脚本及解释器后才能执行。

退出 App 会停止后台。若曾启用登录启动，卸载前关闭两个登录启动选项，再退出并移走 App。配置和钥匙串不会随移走 App 自动删除；如需彻底清除，先备份配置，再移除 `~/Library/Application Support/iPadControl` 和该 App 的钥匙串条目。不要删除其他应用的钥匙串或整个登录钥匙串。

## 发布与贡献

- [发行流程与未完成验收](docs/RELEASE.md)
- [变更记录](CHANGELOG.md)
- [贡献说明](CONTRIBUTING.md)
- [第三方组件和素材](THIRD_PARTY_NOTICES.md)

本项目与 Apple、OpenAI/Codex、网易云音乐或任何中转站均无官方隶属关系。
