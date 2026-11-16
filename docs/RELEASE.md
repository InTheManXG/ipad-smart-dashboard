# 发布流程

## 当前发布范围

当前预览版本号为 `0.1.0-beta.4`，Git 标签为 `v0.1.0-beta.4`。Mac 构建目标仅为 **Apple Silicon / arm64**，最低部署目标为 macOS 13；这不代表 macOS 13 及之后的所有版本已经验证。除本机自动化及隔离用户目录检查外，beta.3 已在独立 M1 Mac mini、macOS 27.0.1 上验证首次 GUI 安装、配对与控制权限、版本替换保留配置和退出后台。具体操作、证据与限制见 [实际验收记录](ACCEPTANCE.md)；macOS 13、实际 iPad、多播放器及真实中转站 Key 的升级仍未验收。

当前提供明确标注 `unnotarized` 的 ad-hoc 测试包，没有 Apple 颁发的开发者身份签名，也没有 Apple 公证，不能称为已通过 Gatekeeper 的正式发行包。用户按 [未公证安装说明](UNNOTARIZED_INSTALL.md) 自行核对来源、校验并决定是否仅允许该 App。GitHub 自动提供的源码归档不代表 Mac 安装包。

## 通过 GitHub 打包发布

发行附件统一由 GitHub Actions 的 `macos-15` Apple Silicon runner 从版本标签编译、打包、验证并直接上传到 GitHub Release。维护者本机只做开发和验收，不上传本机构建的安装包。beta.4 已通过这一流程发布，见[实际打包记录](https://github.com/InTheManXG/ipad-smart-dashboard/actions/runs/43840655193)。

1. 将已验证的源码提交并推送到 GitHub，为该提交创建新的预发布标签，例如 `v0.1.0-beta.5`。推送新标签会自动触发 `Release` 工作流。
2. 也可在仓库的 [Actions → Release](https://github.com/InTheManXG/ipad-smart-dashboard/actions/workflows/release.yml) 点击 `Run workflow`，选择 `main`，将 `version` 填为已推送的版本标签，`artifact` 选择 `unnotarized`。
3. 等待工作流全部通过，再从对应 Release 下载 DMG、备用 ZIP、安装说明及 `SHA256SUMS`。手动入口同样在 GitHub 构建，不需要本机预先编译或上传文件。

已有同名附件时上传会拒绝覆盖。修改源码后应使用新标签和版本，不移动已经发布的标签；未生成附件的失败任务可在修复运行环境后重试。

## 未公证测试版

`unnotarized` 路径不需要 Developer ID。打包强制使用 `BUILD_CONFIGURATION=development` 与 `SIGNING_IDENTITY=-`，只接受预发布版本号及指向当前提交的匹配标签，工作区必须干净；已有输出目录时拒绝覆盖，以免混入上一版本产物。

GitHub 工作流在 runner 内调用以下打包入口；本地仅在调试或复现打包问题时使用：

```sh
bash mac_app/package-preview.sh 0.1.0-beta.4
```

产物先写入 runner 的 `.build/previews/0.1.0-beta.4/`，随后由同一任务上传：

```text
iPad-Control-0.1.0-beta.4-unnotarized-macos-arm64.dmg
iPad-Control-0.1.0-beta.4-unnotarized-macos-arm64.zip
SHA256SUMS
UNNOTARIZED_INSTALL.md
```

DMG 为主要下载项，ZIP 保留为备用。DMG、ZIP 和安装说明均计入同一份 `SHA256SUMS`；用户仅下载其中一种安装包，按安装说明筛选对应条目校验即可。DMG 窗口提供 App、指向 `/Applications` 的快捷方式和安装说明；拖入后从“应用程序”打开 App，再推出镜像。测试包内保留项目及第三方许可证。不执行公证，也不把签名结构通过写成 Gatekeeper 通过。发布页必须醒目标明 ad-hoc、未公证、arm64，以及实际完成和未完成的验收范围。

安装说明只使用 Finder 和系统设置对单个 App 的“仍要打开”流程；不要求用户关闭全局安全保护、清除隔离属性或通过终端绕过。受管 Mac 可能拒绝运行。更新后可能重新出现钥匙串授权，但不应删除用户数据或降低整个钥匙串的保护。

## 开发构建

在 Apple Silicon Mac 上安装 Apple Command Line Tools，运行：

```sh
bash mac_app/test.sh
python3 -m unittest discover -s tests -p 'test_*.py'
for test in tests/test_*.cjs; do node "$test" || exit; done
bash mac_app/build.sh
```

构建结果在 `.build/iPad 控制台.app`。默认使用 ad-hoc 签名；设置 `SIGNING_IDENTITY` 可以指定已有开发证书。没有对应证书或私钥时构建应报错，不应静默替换身份。常规开发构建和明确标注的未公证测试包，都不能因为能启动或 `codesign --verify` 通过而宣称 Gatekeeper 接受或公证通过。

从源码构建不需要 Docker 或 Homebrew。可选订阅更新由用户配置自己的脚本和解释器，App 不自带该业务脚本及 Python 运行时。包内媒体适配器需要保留许可证和说明。

## 正式二进制的前置条件

发布者需持有有效的 **Developer ID Application** 证书及私钥，并配置 Apple 公证凭据。不要把证书私钥、P12 密码、App Store Connect API 私钥或钥匙串导出文件提交到仓库。

正式发布在 GitHub 的 `Release` 工作流中选择 `artifact=notarized`，凭据通过下文列出的仓库 Secret 提供。工作流内部的发布脚本读取：

| 变量 | 用途 |
| --- | --- |
| `SIGNING_IDENTITY` | 有效 Developer ID Application 证书名或指纹 |
| `NOTARY_KEYCHAIN_PROFILE` | 已通过 `notarytool store-credentials` 保存的钥匙串凭据名称 |
| `NOTARY_KEYCHAIN` | 可选，存放上述凭据的钥匙串路径 |
| `APP_BUILD` | 正整数构建号，默认 `1` |

发布前必须使用已验证、已提交的源码和对应版本标签。工作流 checkout 后使用干净工作区，以下为脚本内部调用方式，也可用于本地调试：

```sh
SIGNING_IDENTITY='Developer ID Application: 你的证书名称' \
NOTARY_KEYCHAIN_PROFILE='你的公证凭据名称' \
bash mac_app/release.sh 0.1.0-beta.4
```

脚本要求构建前和最终验收时 Gatekeeper 均处于启用状态；关闭或无法确认状态时直接拒绝，避免把系统跳过评估误判为通过。之后使用 hardened runtime 和时间戳签名，提交公证并要求状态为 `Accepted`，随后 staple、验证票据、执行严格签名检查和 Gatekeeper 检查。由已公证 App 生成 DMG 后，还会对 DMG 单独签名、提交公证、staple 并验证 Gatekeeper 打开评估；ZIP 保留为备用。全部通过才生成：

```text
.build/releases/0.1.0-beta.4/iPad-Control-0.1.0-beta.4-macos-arm64.dmg
.build/releases/0.1.0-beta.4/iPad-Control-0.1.0-beta.4-macos-arm64.zip
.build/releases/0.1.0-beta.4/SHA256SUMS
```

缺少凭据、证书不合适、源码未提交、标签不匹配或公证失败时，正式发行流程停止，不会静默降级上传开发包。未公证测试版是单独明确选择的路径。公证流程本身仍需用真实发行凭据完成端到端验证；媒体兼容组件是否被公证接受不能靠本机构建推断。

## GitHub Actions

`.github/workflows/checks.yml` 执行完整历史凭据扫描、服务端/网页检查、arm64 原生构建、组包后媒体组件只读加载及 DMG 挂载复制验证。`.github/workflows/release.yml` 提供三条明确的发布路径：

- 推送预发布 `v*` 标签，或手动选择 `artifact=unnotarized`：运行凭据扫描、原生、Python 和网页检查，生成上述明确命名的未公证测试包、安装说明和校验清单，创建测试版 prerelease。这是当前 beta.4 采用的路径；正式版本号不能走此路径。
- 手动选择 `artifact=source-only`：运行源码检查并创建源码预览 prerelease，不上传 `.app` 或安装包。GitHub 自动附带该标签的源码归档。
- 手动选择已有版本标签及 `artifact=notarized`：执行完整测试、签名和公证，成功后向对应发行版添加 DMG、ZIP 与 SHA-256，或在尚无发行版时创建它。该路径才需要以下仓库 Secret。

| Secret | 内容 |
| --- | --- |
| `APPLE_SIGNING_IDENTITY` | Developer ID Application 证书名或指纹 |
| `MACOS_CERTIFICATE_P12_BASE64` | 包含签名证书和私钥的 P12 文件，Base64 编码 |
| `MACOS_CERTIFICATE_PASSWORD` | P12 的导出密码 |
| `APPLE_API_KEY_P8_BASE64` | App Store Connect 公证 API 私钥，Base64 编码 |
| `APPLE_API_KEY_ID` | 该 API Key 的 ID |
| `APPLE_API_ISSUER_ID` | 该 API Key 的 Issuer ID |

工作流使用临时钥匙串导入凭据并在结束时清理，不使用明文 Apple ID 密码。正式使用前核对仓库中工作流的实际权限与 Secret 名称，并保护能够修改发布工作流和版本标签的账号。

CI 配置存在不代表已经运行成功。发布时记录实际 Actions 结果；没有凭据时可明确选择源码预览或未公证测试路径，不声称已完成自动公证。预发布版本应标记为 GitHub prerelease，附件只允许来自同一提交、同一版本且通过对应检查的产物。后续补上公证二进制时，也应更新发行说明中的验收结果，不能保留“仅源码”或“全部未公证”的过时描述。

## 每次发行需要记录

- 变更及迁移影响，尤其是旧网页默认改为只读、权限的保存和撤销行为。
- 实际测试的 macOS、CPU、播放器及浏览器；自动化检查和真机测试分开写。
- 新用户安装、升级保留配置/钥匙串/配对、后台启停与登录启动的验证结果。
- 发行证书身份、公证结果、Gatekeeper 结果和附件 SHA-256。
- 已知限制及未验证项目，包括中继信任边界和非端到端加密。

未完成的项目写明原因，不把构建成功替代运行、升级、真机或生产部署验收。

## beta.1 / beta.2 源码预览验证记录

- 本机环境：Apple Silicon，macOS 27.2.1；原生 227 项断言、服务端 Python 回归、全部 7 组网页 Node 回归通过。
- 开发包构建及严格签名结构检查通过，确认包含许可证且不含 Python 运行时、密钥文件或个人配置。媒体框架和测试客户端从锁定上游源码按 macOS 13 重建，打包后只读媒体查询返回合法 JSON；这不代表旧系统或所有播放器已经验收。开发包未作为下载附件发布。
- 真实后台二进制在隔离用户目录完成首次状态查询；默认关闭公网、局域网、音乐及登录启动，旧配置模拟升级保留文件内容与钥匙串账户归属。没有替换维护者当前安装。
- OrbStack 临时独立容器通过非 root、只读文件系统、健康检查及数据库重启持久化验证，原有容器和线上 1Panel 部署未修改。
- Git 历史及待公开源码进行了 Gitleaks 凭据扫描；个人路径、旧签名标识和不再分发的第三方图标清理后再公开。
- 当时未完成：真实 Developer ID 签名与公证、Gatekeeper 下载验收、另一台 Mac 上的完整 GUI 安装升级卸载、实际 iPad 和多播放器兼容验收。后续独立 Mac 的实际结果见下节，不能用这些历史检查替代。

## beta.3 实际发行与独立 Mac 验收

- [完整持续检查](https://github.com/InTheManXG/ipad-smart-dashboard/actions/runs/43826336640)与[打包发行检查](https://github.com/InTheManXG/ipad-smart-dashboard/actions/runs/43826336624)通过；原生 227 项断言、38 项 Python 测试及 7 组网页回归通过。
- 从 GitHub Release 重新下载的 ZIP 完成 SHA-256、严格签名结构、arm64 架构、最低构建目标、许可证及私密数据排除检查。隔离首次状态查询与媒体适配器只读查询通过。
- 独立 M1 Mac mini 验证了首次安装、双网络地址、逐端只读与控制授权、撤权、踢下线、配置保留升级、登录启动配置及完整退出。旧版来自 `v0.1.0-beta.2` 精确标签的源码构建，新版使用 beta.3 实际发布附件；这不是从历史 beta.2 二进制附件升级。
- 测试机 Gatekeeper 原本关闭，本次未改变系统安全设置，不能宣称单 App 放行或 Gatekeeper 通过。真实 Key 的钥匙串升级、实际重新登录启动、macOS 13、实际 iPad 和多播放器仍未验证；没有执行 Developer ID 签名或 Apple 公证。

详细结果及测试清理情况见 [实际验收记录](ACCEPTANCE.md)。后补的文档不替换已发布的标签、ZIP、校验清单和随包安装说明。
