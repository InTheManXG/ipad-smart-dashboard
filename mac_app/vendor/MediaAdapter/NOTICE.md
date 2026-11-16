# 媒体兼容组件

来源为 [mediaremote-adapter v0.7.7](https://github.com/ungive/mediaremote-adapter/tree/e3ff5021eb0875858bd05f48d2e9ba2e962d1cf6)，锁定提交为 `e3ff5021eb0875858bd05f48d2e9ba2e962d1cf6`。BSD 3-Clause 许可证原文随附于 LICENSE，保留作者及贡献者版权。

`0.1.0-beta.1` 沿用的两份二进制实际要求 macOS 27.0，与 App 的 macOS 13.0 声明不符。`0.1.0-beta.2` 从上述公开源码重新编译框架和兼容客户端，明确使用 `-target arm64-apple-macosx13.0`，未修改二进制 load command 来降低版本号。编译目标和接口检查不等于 macOS 13 真机验收；旧版 macOS、不同播放器的实际兼容性仍未验证。

复现构建需要 Apple Command Line Tools，不依赖 CMake、Homebrew 或旧安装包：

```sh
git clone https://github.com/ungive/mediaremote-adapter.git /tmp/mediaremote-adapter
git -C /tmp/mediaremote-adapter checkout e3ff5021eb0875858bd05f48d2e9ba2e962d1cf6
bash scripts/build-media-adapter.sh /tmp/mediaremote-adapter .build/media-adapter-rebuilt
```

脚本拒绝非指定提交、已修改的源码和已有输出目录；保留 Perl 脚本及完整上游许可证，并使用 ad-hoc 签名供后续 App 签名。编译器、SDK、签名时间等环境差异可能改变文件哈希，不承诺逐字节一致。

运行使用 macOS 的 `/usr/bin/perl`。框架只包含 Apple Silicon 版本；系统接口升级或播放器差异可能导致不可用。打包会把框架 install name 改为相对标识并重新签名，不修改媒体逻辑，不下载额外可执行组件。
