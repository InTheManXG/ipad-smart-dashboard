# 媒体兼容组件

来源：本机已安装的 `media-control 0.7.7` 分发包，项目 https://github.com/ungive/media-control ，适配器项目 https://github.com/ungive/mediaremote-adapter 。脚本、框架和测试客户端保持原分发内容；许可证按源文件声明的 BSD 3-Clause 附带。

2026-11-03：同一框架的 `adapter_test` 在自编译 Swift 进程返回 4，在系统 Perl 模式返回 0。用户已同意保留此兼容组件，业务后端仍为原生 Swift；不依赖 Homebrew 或用户安装的解释器。运行仅调用 macOS 自带 `/usr/bin/perl`，不下载组件、不修改系统权限。系统升级可能改变媒体接口可用性。

本目录的二进制为 Apple Silicon 版本，不宣称支持 Intel Mac。重新分发或更新时保留许可证，并重新验证播放状态和控制回执。

打包时仅将框架自身的 install name 从 Homebrew 地址改为相对标识，并重新进行本机签名；不修改其媒体实现。
