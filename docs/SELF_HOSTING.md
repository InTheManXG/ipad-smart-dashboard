# 自托管公网中继

Mac 本地看板直接由 App 提供，不需要 Docker、Python 或这份部署流程。本文只部署供 Mac 与网页配对的公网中继。

## 部署前确认

准备自己的域名、HTTPS 反向代理、支持 Compose 的 Docker 服务，以及项目源码。镜像通过公开的 `golang:1.27.4-alpine` 编译，再放入 `alpine:3.23` 运行，不包含 Python 或 Go 工具链，没有私有镜像仓库依赖。域名解析、证书和宿主机安全维护由部署者负责。

如果服务器通过 **1Panel** 管理，请先查看现有编排的实际目录、项目名、环境文件、端口和数据挂载。更新必须沿用这些设置；不能仅复制新 Compose 文件并启动第二个项目。Compose 项目名变化会改变默认命名卷名称，让原配对看起来丢失。旧版使用绑定目录挂载时，也不能直接换成空的命名卷。

对于全新安装，先确定部署目录，再放置源码。下面命令在该源码目录中执行；已运行的旧实例应先按后文备份并评估迁移，不直接套用首次安装命令。

从 Python 版升级到 Go 版时，保留现有 Compose 项目名、端口和数据挂载即可继续读取原 `pairing.sqlite`，设备凭据、网页配对及已授予的控制权限保持兼容。未记录控制权限的更早期数据库会补充权限字段，并将这些历史屏幕设为只读。服务重启后的实时快照仍由 Mac 重新上传。

## 首次启动

```sh
cp deploy/.env.example deploy/.env
docker compose --env-file deploy/.env -f deploy/compose.yaml up -d --build
docker compose --env-file deploy/.env -f deploy/compose.yaml ps
curl --fail http://127.0.0.1:18086/api/mode
```

最后一条应返回 `{"mode":"pairing"}`。如修改 `DASHBOARD_PORT`，检查时使用相同端口。

当前 Compose 的行为：

| 配置 | 默认值与作用 |
| --- | --- |
| `DASHBOARD_PORT` | `18086`；仅发布在宿主机 `127.0.0.1` |
| `DISPLAY_MODE` | 固定为 `pairing`，不使用旧共享管理口令 |
| `RELAY_DATA_DIR` | 容器内 `/relay-data`，保存到 `relay-data` 命名卷 |
| `PAIRING_TRUST_PROXY` | `0`；不信任客户端提交的转发地址 |
| 运行身份 | UID/GID `10001`，无额外 capabilities，根文件系统只读 |

`deploy/.env` 不需要填写 Mac 的中转站 Key、设备令牌或配对码。不要将这些数据移到服务器。健康检查只验证进程及配对模式，不代表已有 Mac 在线或任务已同步。

### 旧版共享口令模式的站点配置

此项仅适用于显式运行 `DISPLAY_MODE=legacy` 的历史安装，Go 版保留该兼容模式，默认配对中继不使用它。新 App 仍在自己的「中转站 Key」界面管理站点和钥匙串；不要为配对模式复制 Mac 的 Key 到服务器。

旧模式中继不内置任何运营者地址，并沿用原 `keys.json` 和 `station.json`。需要继续查询旧服务器 Key 时，在该实例的 `RELAY_DATA_DIR` 中保存 `station.json`，沿用原生站点的字段格式：

```json
{"type":"sub2api","name":"我的中转站","url":"https://relay.example.com"}
```

地址只允许 HTTPS 根地址或以 `/v1` 结尾的地址，不接受账号密码、查询参数、片段及其他路径；未配置或无效时拒绝查询，不会回退到其他站点。`/v1/usage` 由程序拼接，携带旧 Key 的请求不跟随重定向。修改地址会把旧实例保存的 Key 用于新站点，因此必须先确认目的地址；缓存按站点和 Key 隔离。该文件与旧 `keys.json` 都应仅允许服务账号读写。

## HTTPS 与 1Panel

在 1Panel 的网站功能中创建反向代理站点，为域名配置有效证书，强制 HTTP 跳转 HTTPS。反代目标应是**代理进程可达的地址**，指向本服务的 18086 端口。

若代理使用宿主机网络，可使用宿主机 `127.0.0.1:18086`；若 OpenResty 运行在独立容器中，其 `127.0.0.1` 指向自身，不能直接使用这个地址。应按现有 1Panel 网络方式配置受限的容器互通或宿主机访问，确认目标可达后再保存，不要为省事把后端 HTTP 端口开放到公网。现有站点更新时保留原反代与证书管理方式。

入口需转发完整路径、请求方法和认证头，不应缓存 `/api/`，也不应记录认证头或请求体。请求体上限至少 4 MiB，以容纳图标快照；响应超时可设为 30 秒，以支持短时长轮询。站点必须使用根地址，不部署到额外 URL 子路径。

默认 Compose 使用 bridge 网络，保持 `PAIRING_TRUST_PROXY=0`。该模式下中继可能把反代后的多个浏览器视为同一个来源并共享部分限流。只有确认中继看到的直接对端是受信任的回环反代，而且代理**覆盖** `X-Real-IP` 时，才可启用 `1`；单纯添加该头或把值改为 `1` 不会让容器网桥变成受信任回环连接。

## Mac 配对与验收

1. 从公网访问 `https://你的域名/api/mode`，确认返回配对模式；首页和静态资源应正常加载。
2. 在 Mac App「连接与配对」中填写同一 HTTPS 根地址。App 会验证服务模式，不需要手工复制设备凭据。
3. 打开网页，输入 App 显示的一次性配对码。新网页默认为只读，应能看到所属 Mac 的任务和已配置内容。
4. 确认未配对请求 `/api/status` 返回 `401`，只读网页的控制请求被拒绝；确实需要控制时，再在 App 中授权该网页并测试。
5. 用另一个独立浏览器会话测试踢下线：被踢会话失效，其他会话继续可用。不要用同一浏览器中共享存储的两个标签页冒充两个独立会话。

任务或音乐快照存于中继内存。容器重启后，Mac 重新上传前网页短暂离线是预期行为；持久化配对不应因此丢失。实际 iPad、跨网络连接和长时间运行仍需在自己的环境中验收。

## 备份、更新与回滚

至少保留当前源码版本、Compose、环境文件和 `/relay-data`。数据库备份包含仍有效的配对信息，应当按私密资料保护。

以下是**使用本文同一 Compose 路径的安装**的一种停机备份方式；1Panel 现有编排使用自己的原路径和项目名执行等价操作。先停止写入再复制数据库，避免直接复制运行中的 SQLite 得到不一致的文件。

从 GitHub 下载的源码 ZIP 不含 `.git`。这种安装请先填写当前下载版本对应的标签；示例中的 `v0.1.0-beta.2` 仅适用于该版本。通过 Git 克隆的安装会自动记录当前提交。版本检查在停止服务之前完成。

```sh
umask 077
source_tag="v0.1.0-beta.2"
if git rev-parse --show-toplevel >/dev/null 2>&1; then
  source_version="$(git rev-parse HEAD)"
else
  test -n "$source_tag" || { echo "请先填写当前源码的版本标签" >&2; exit 1; }
  source_version="$source_tag (GitHub source archive)"
fi
backup_dir="./backup/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup_dir"
cp deploy/compose.yaml "$backup_dir/compose.yaml"
cp deploy/.env "$backup_dir/.env"
printf '%s\n' "$source_version" > "$backup_dir/source-version.txt"
docker compose --env-file deploy/.env -f deploy/compose.yaml stop ipad-dashboard
docker compose --env-file deploy/.env -f deploy/compose.yaml cp ipad-dashboard:/relay-data "$backup_dir/relay-data"
docker compose --env-file deploy/.env -f deploy/compose.yaml start ipad-dashboard
```

确认备份完成后再更新源码，从原 Compose 目录执行 `up -d --build`，并重复前述验收。不要执行 `down -v`；它会删除该项目的数据卷。

回滚通常先恢复原代码和 Compose，保留当前数据卷。若版本发生了不向后兼容的数据库迁移，应停服后使用匹配版本的一致性备份；恢复旧数据库会同时恢复当时的会话和权限，并丢失备份后的配对变更。发布说明必须明确这种兼容限制，不能盲目覆盖数据库。

信任中继意味着允许其读取快照并提供网页代码；权限及隐私限制见 [SECURITY.md](SECURITY.md) 与 [PRIVACY.md](PRIVACY.md)。
