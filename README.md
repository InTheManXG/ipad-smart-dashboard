# iPad Codex 工作现场

使用现有 Mac Codex 桥接器的只读快照。Python 标准库提供网页和状态代理，无需安装依赖或运行 Docker。

## 运行

在本目录运行 `python3 server.py`。需要原有 `ESP32CodexBridge` 正在本机 8787 端口提供服务，以及已有的私有 `config.json`。不复制或修改原桥接配置。

访问 `http://Mac局域网IP:18086/`，iPad 与 Mac 需位于同一可互通网络。首次运行生成 `.display-token`，用文本编辑器打开并将口令输入网页。口令只存在当前浏览器会话中，关闭后可能需要重新输入。

iPad Safari 中选择“分享 → 添加到主屏幕”即可独立打开。首次从主屏幕启动可能需要再次输入口令。此版本不提供离线缓存，断线保留的旧数据有明确标识。

状态每 2 秒轮询，额度刷新频率由原桥接器决定。上游最多提供 8 个会话，超出时显示总数，不能将列表统计当作全部任务统计。

## 限制

这是本地试用版，HTTP 不加密，仅在可信局域网使用，不映射公网。Mac 休眠、网络切换或服务退出后会断线；未安装开机启动。iPad 上非 HTTPS 地址通常不能使用网页常亮接口，可在系统“显示与亮度 → 自动锁定”中调整。锁屏和后台刷新受 iPadOS 限制。

未接入发送消息、打开对话或修改任务等控制能力。

## 验证

`python3 -m unittest discover -s tests -v`

`node --check web/app.js`

已验证真实桥接数据返回与浏览器展示，实际 iPad Safari、主屏启动和长时间常亮仍待验证。

## HTTPS 部署准备

目标域名为 `https://ipad.iamxg.com`。`deploy/compose.yaml` 使用服务器已有 Python 镜像，容器以只读文件系统运行，仅监听服务器回环地址 18086，由 1Panel OpenResty 提供 HTTPS。`deploy/install.py` 为独立站点签发 Certbot 证书并配置续期钩子，不修改 ESP 设备站点。

2026-11-02 已经用户授权部署到 https://ipad.iamxg.com 。可信证书有效至 2027-01-31，Certbot 定时器已启用，并配置本站续期后的证书复制和 OpenResty 重载。页面、脚本、清单均返回 200；无口令状态接口返回 401，有口令返回 200 和最新真实快照；HTTP 自动跳转到 HTTPS。口令仍保存在私有文件中，不可提交或公开分享。iPad 真机常亮和主屏启动仍待用户验证。

## 状态灯与本地 Docker

【业务逻辑】运行中黄色、完成绿色、错误红色、等待用户处理蓝色；离线灰色。任务列表上游只保留完成未读对话，所以列表 `done` 显示“完成未读”，总体 `done` 仍显示“已完成”。

`docker compose -f compose.local.yaml up -d` 在 OrbStack 启动本地看板，访问 http://127.0.0.1:18088/ 。复用原桥接配置的只读挂载，并从现有 HTTPS 中继读取快照，口令不写入 Compose 文件。
