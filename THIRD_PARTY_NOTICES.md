# 第三方组件与素材

## MediaRemote Adapter

- 来源：https://github.com/ungive/mediaremote-adapter ，固定版本 v0.7.7（提交 `e3ff5021eb0875858bd05f48d2e9ba2e962d1cf6`）。
- 作者：Jonas van den Berg and contributors。
- 许可证：BSD 3-Clause，全文见 `mac_app/vendor/MediaAdapter/LICENSE`。
- 分发内容：媒体框架、Perl 脚本和兼容测试客户端。现有二进制仅支持 Apple Silicon。
- 框架与测试客户端从上述源码按 `arm64-apple-macosx13.0` 重建，脚本保持原样；打包按所选身份签名。不宣称苹果官方支持此接口。复现步骤见组件 NOTICE。

## Sparkle

- 来源：https://github.com/sparkle-project/Sparkle ，固定版本 2.10.1。
- 许可证：MIT 及其所包含组件的许可证，全文见 `mac_app/vendor/Sparkle-LICENSE`；安装包同时包含 `Resources/Sparkle-LICENSE`。
- 构建时从官方发行包下载并校验固定 SHA-256，更新框架及其辅助程序随 App 内置，不要求用户安装额外工具。

## 本项目图标

`mac_app/assets/app-icon.png` 与 `web/app-icon.png` 是本项目创作的应用图标，随项目按 MIT 许可提供。`web/music-note.svg` 与 `web/icon.svg` 为项目内图形。

网页不再分发从 Codex 或网易云音乐 App 提取的图标。用户自己配置的应用图标在运行时由系统读取，并只展示给该用户配对的网页；这些第三方图标与商标不受本项目 MIT 许可覆盖。

Apple、Codex、OpenAI 和网易云音乐名称仅用于说明兼容功能，不代表官方背书。
