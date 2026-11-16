# 发布流程

## 当前发布范围

当前预览版本号为 `0.1.0-beta.2`，Git 标签为 `v0.1.0-beta.2`。Mac 构建目标仅为 **Apple Silicon / arm64**，最低部署目标为 macOS 13；这不代表 macOS 13 及之后的所有版本已经验证。当前已完成本机自动化检查，以及隔离用户目录的首次运行和旧配置保留检查；这不是独立 Mac 的完整安装验收。Intel Mac、其他 macOS 版本、干净用户的完整 GUI 安装升级流程及实际 iPad 仍需分别验收。

当前没有完成 Developer ID 签名和 Apple 公证，不能把开发包称为正式可分发安装包。允许先发布开源预览的源码和兼容限制，暂不附加未公证的 `.app`、ZIP 或 DMG；GitHub 自动提供的源码归档不代表 Mac 安装包。

## 开发构建

在 Apple Silicon Mac 上安装 Apple Command Line Tools，运行：

```sh
bash mac_app/test.sh
python3 -m unittest discover -s tests -p 'test_*.py'
for test in tests/test_*.cjs; do node "$test" || exit; done
bash mac_app/build.sh
```

构建结果在 `.build/iPad 控制台.app`。默认使用 ad-hoc 签名，仅用于本机开发；设置 `SIGNING_IDENTITY` 可以指定已有开发证书。没有对应证书或私钥时构建应报错，不应静默替换身份。开发包能启动、`codesign --verify` 通过，都不等于 Gatekeeper 接受或公证通过。

从源码构建不需要 Docker 或 Homebrew。可选订阅更新由用户配置自己的脚本和解释器，App 不自带该业务脚本及 Python 运行时。包内媒体适配器需要保留许可证和说明。

## 正式二进制的前置条件

发布者需持有有效的 **Developer ID Application** 证书及私钥，并配置 Apple 公证凭据。不要把证书私钥、P12 密码、App Store Connect API 私钥或钥匙串导出文件提交到仓库。

本机发布脚本读取：

| 变量 | 用途 |
| --- | --- |
| `SIGNING_IDENTITY` | 有效 Developer ID Application 证书名或指纹 |
| `NOTARY_KEYCHAIN_PROFILE` | 已通过 `notarytool store-credentials` 保存的钥匙串凭据名称 |
| `NOTARY_KEYCHAIN` | 可选，存放上述凭据的钥匙串路径 |
| `APP_BUILD` | 正整数构建号，默认 `1` |

发布前必须使用已验证、已提交的干净工作区，并在当前提交打好同版本标签。运行示例：

```sh
SIGNING_IDENTITY='Developer ID Application: 你的证书名称' \
NOTARY_KEYCHAIN_PROFILE='你的公证凭据名称' \
bash mac_app/release.sh 0.1.0-beta.2
```

脚本要求构建前和最终验收时 Gatekeeper 均处于启用状态；关闭或无法确认状态时直接拒绝，避免把系统跳过评估误判为通过。之后使用 hardened runtime 和时间戳签名，提交公证并要求状态为 `Accepted`，随后 staple、验证票据、执行严格签名检查和 Gatekeeper 检查。全部通过才生成：

```text
.build/releases/0.1.0-beta.2/iPad-Control-0.1.0-beta.2-macos-arm64.zip
.build/releases/0.1.0-beta.2/SHA256SUMS
```

缺少凭据、证书不合适、源码未提交、标签不匹配或公证失败时，应停止发行，不上传开发包作为替代品。该流程本身仍需用真实发行凭据完成端到端验证；媒体兼容组件是否被公证接受不能靠本机构建推断。

## GitHub Actions

`.github/workflows/checks.yml` 执行完整历史凭据扫描、服务端/网页检查与 arm64 原生构建。`.github/workflows/release.yml` 提供两条明确的发布路径：

- 推送 `v*` 标签，或手动选择 `artifact=source-only`：运行源码检查并创建源码预览 prerelease，不上传 `.app` 或安装包。GitHub 自动附带该标签的源码归档。这是当前首发采用的路径。
- 手动选择已有版本标签及 `artifact=notarized`：执行完整测试、签名和公证，成功后向对应发行版添加 ZIP 与 SHA-256，或在尚无发行版时创建它。该路径才需要以下仓库 Secret。

| Secret | 内容 |
| --- | --- |
| `APPLE_SIGNING_IDENTITY` | Developer ID Application 证书名或指纹 |
| `MACOS_CERTIFICATE_P12_BASE64` | 包含签名证书和私钥的 P12 文件，Base64 编码 |
| `MACOS_CERTIFICATE_PASSWORD` | P12 的导出密码 |
| `APPLE_API_KEY_P8_BASE64` | App Store Connect 公证 API 私钥，Base64 编码 |
| `APPLE_API_KEY_ID` | 该 API Key 的 ID |
| `APPLE_API_ISSUER_ID` | 该 API Key 的 Issuer ID |

工作流使用临时钥匙串导入凭据并在结束时清理，不使用明文 Apple ID 密码。正式使用前核对仓库中工作流的实际权限与 Secret 名称，并保护能够修改发布工作流和版本标签的账号。

CI 配置存在不代表已经运行成功。首次开源时记录实际 Actions 结果；没有凭据则使用源码预览路径，不声称已完成自动公证。预发布版本应标记为 GitHub prerelease，附件只允许来自同一提交、同一版本且通过上述检查的产物。后续补上公证二进制时，也应更新发行说明中的验收结果，不能保留“仅源码”的过时描述。

## 每次发行需要记录

- 变更及迁移影响，尤其是旧网页默认改为只读、权限的保存和撤销行为。
- 实际测试的 macOS、CPU、播放器及浏览器；自动化检查和真机测试分开写。
- 新用户安装、升级保留配置/钥匙串/配对、后台启停与登录启动的验证结果。
- 发行证书身份、公证结果、Gatekeeper 结果和附件 SHA-256。
- 已知限制及未验证项目，包括中继信任边界和非端到端加密。

未完成的项目写明原因，不把构建成功替代运行、升级、真机或生产部署验收。

## 本次源码预览验证记录

- 本机环境：Apple Silicon，macOS 27.2.1；原生 227 项断言、服务端 Python 回归、全部 7 组网页 Node 回归通过。
- 开发包构建及严格签名结构检查通过，确认包含许可证且不含 Python 运行时、密钥文件或个人配置。媒体框架和测试客户端从锁定上游源码按 macOS 13 重建，打包后只读媒体查询返回合法 JSON；这不代表旧系统或所有播放器已经验收。开发包未作为下载附件发布。
- 真实后台二进制在隔离用户目录完成首次状态查询；默认关闭公网、局域网、音乐及登录启动，旧配置模拟升级保留文件内容与钥匙串账户归属。没有替换维护者当前安装。
- OrbStack 临时独立容器通过非 root、只读文件系统、健康检查及数据库重启持久化验证，原有容器和线上 1Panel 部署未修改。
- Git 历史及待公开源码进行了 Gitleaks 凭据扫描；个人路径、旧签名标识和不再分发的第三方图标清理后再公开。
- 未完成：真实 Developer ID 签名与公证、Gatekeeper 下载验收、另一台 Mac 上的完整 GUI 安装升级卸载、实际 iPad 和多播放器兼容验收。
