# 未公证版安装说明

适用于 `0.1.0`，仅支持 Apple Silicon（arm64）Mac。最低构建目标为 macOS 13；beta.3 已在独立 M1 Mac mini、macOS 27.0.1 上验证首次图形界面安装、版本替换保留配置与退出后台，详见 [实际验收记录](ACCEPTANCE.md)。旧版系统兼容性仍未验证。测试机原本关闭了 Gatekeeper，本次验收不证明以下单 App 放行步骤已经通过。

这个安装包使用固定的 **Apple Development 证书签名**，用于保持更新时的签名身份。它不是 Developer ID 发行签名，没有 Apple 公证，GitHub 普通 Release 标记不代表通过 Gatekeeper 验收。签名和 SHA-256 校验不能替代 Apple 公证或恶意软件审查；是否信任并运行，由你自行决定。

## 下载与校验

只从 [本项目 v0.1.0 发行页](https://github.com/InTheManXG/ipad-smart-dashboard/releases/tag/v0.1.0) 下载以下三个附件，并放在同一文件夹：

- `iPad-Control-0.1.0-unnotarized-macos-arm64.dmg`（推荐；也可选择同名 `.zip`，无需两者都下载）
- `SHA256SUMS`
- `UNNOTARIZED_INSTALL.md`

发行页自动提供的 `Source code` 是源码，不是 App 安装包。不要从聊天转发或不明镜像获得安装包。

在终端进入下载文件所在文件夹后运行：

```sh
(
  set -e
  package='iPad-Control-0.1.0-unnotarized-macos-arm64.dmg'
  for file in "$package" UNNOTARIZED_INSTALL.md; do
    checksum_line="$(awk -v file="$file" '$2 == file { print; count++ } END { if (count != 1) exit 1 }' SHA256SUMS)"
    printf '%s\n' "$checksum_line" | shasum -a 256 -c -
  done
)
```

如果下载 ZIP，将上面 `package` 末尾的 `.dmg` 改为 `.zip`。选中的安装包和安装说明都应显示 `OK`；清单缺少对应记录、记录重复、文件缺失或校验不匹配时，命令会失败，停止安装并从同一发行页重新下载。校验用于确认文件与这份清单一致，不能证明被入侵的下载源可信；清单和附件来自同一来源。

## 安装与首次打开

1. 如果已经运行旧版，从 App 菜单选择“退出 iPad 控制台（停止后台服务）”。只关闭窗口不会退出后台。
2. 在 Finder 中双击 DMG，将窗口中的 `iPad 控制台.app` 拖到右侧“Applications（应用程序）”快捷方式。ZIP 用户先解压，再将完整 App 拖入“应用程序”。升级时替换原来同一位置的 App，不要只复制里面的可执行文件。
3. 从“应用程序”文件夹打开 App，再在 Finder 中推出安装镜像；不要直接运行 DMG 里的 App。macOS 可能提示无法验证开发者或无法确认没有恶意软件；先关闭该提示。
4. 如果你已经校验下载来源并决定信任此版本，打开“系统设置 → 隐私与安全性”，找到刚才针对 `iPad 控制台` 的阻止提示，选择“仍要打开”（Open Anyway），随后仅为该 App 确认打开。系统可能要求在本机验证管理员身份。

必须先尝试打开 App，系统才可能显示上述例外入口；这不是保证所有 Mac 都能运行的安装方法。步骤依据 [Apple 的“在 Mac 上安全地打开 App”说明](https://support.apple.com/zh-cn/102445)，具体按钮及可用性以你的 macOS 和管理策略为准。

不要关闭全局 Gatekeeper，不要修改全局安全策略，也不要通过删除隔离属性或终端绕过系统判断。受组织管理的 Mac 可能不提供“仍要打开”或禁止运行此类 App；这时联系管理员或停止安装。若提示文件已损坏、证书撤销、检测到恶意软件，或找不到只针对该 App 的允许入口，请停止并记录系统提示，不要继续绕过。

系统可能另行要求 `iPadService` 访问钥匙串。先核对来源确实是刚安装 App 的 `Contents/MacOS/iPadService`，再自行决定是否允许；密码只在系统界面输入，不要发送给项目维护者。从旧 ad-hoc 版本首次升级到本版可能需要重新授权。后续版本保持同一证书、Bundle ID 和后台服务标识；证书到期、撤销或更换时仍需重新验证，不能保证系统以后不再询问。不要通过放宽整个钥匙串的访问权限解决。

## 使用、升级与退出

已知后台在额度采集时曾发生异常退出，本版仍可能短暂掉线；本次常规发行未宣称修复该问题。

首次安装默认不连接公网，不启用局域网看板、音乐同步或登录启动。在 App 里启用需要的功能后，按 [README 的配对步骤](https://github.com/InTheManXG/ipad-smart-dashboard/blob/v0.1.0/README.md#配对和使用) 连接浏览器；新配对默认只读。

同一 Mac 的配置、配对和 Key 保存在 App 包之外。升级时保留 `~/Library/Application Support/iPadControl/` 和该 App 的钥匙串条目，先退出旧版再替换完整 App；不要为了处理授权提示删除这些数据。跨 Mac 复制会隔离旧配对及控制授权，需要重新配对。

退出请使用菜单中的“退出 iPad 控制台（停止后台服务）”。只关窗口后可从菜单栏重新打开。卸载前先关闭 App 内两个登录启动选项，再退出并移走 App；移走 App 不会自动清理已保存的配置和钥匙串。

数据去向和中继信任限制见 [隐私说明](https://github.com/InTheManXG/ipad-smart-dashboard/blob/v0.1.0/docs/PRIVACY.md) 与 [安全说明](https://github.com/InTheManXG/ipad-smart-dashboard/blob/v0.1.0/docs/SECURITY.md)。
