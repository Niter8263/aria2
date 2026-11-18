# Aria2 完美脚本

[![LICENSE](https://img.shields.io/github/license/mashape/apistatus.svg?style=flat-square&label=License)](https://github.com/P3TERX/aria2.conf/blob/master/LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/P3TERX/aria2.conf.svg?style=flat-square&label=Stars&logo=github)](https://github.com/P3TERX/aria2.conf/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/P3TERX/aria2.conf.svg?style=flat-square&label=Forks&logo=github)](https://github.com/P3TERX/aria2.conf/fork)

一套 Aria2 配置方案，包含了配置文件、附加功能脚本等文件，用于实现 Aria2 功能的增强和扩展，提升 Aria2 的下载速度与使用体验。

## 功能特性

* BT 下载率高、速度快
* 重启后不丢失任务进度、不重复下载
* 删除正在下载的任务自动删除未完成的文件
* 下载错误自动删除未完成的文件
* 下载完成自动删除控制文件(`.aria2`后缀名文件)
* 下载完成自动删除种子文件(`.torrent`后缀名文件)
* 下载完成自动删除空目录
* 下载完成自动移动文件到指定目录
* 下载完成自动上传到 Google Drive 和 OneDrive 等网盘(RCLONE 联动功能)
* BT 下载完成自动清除垃圾文件(文件类型过滤功能)
* BT 下载完成自动清除小文件(文件大小过滤功能)
* 一键自动更新 BT tracker，进一步加速 BT 下载
* 有一定的防版权投诉、防迅雷吸血效果
* 更好的 PT 下载支持

## 部署方法
```
# 直连（可用时优先）
wget -O aria2.sh https://raw.githubusercontent.com/Niter8263/aria2/main/aria2.sh

# 若直连不通，任选一个可用的加速地址（实测 2026-09 有效）
wget -O aria2.sh https://gh-proxy.com/https://raw.githubusercontent.com/Niter8263/aria2/main/aria2.sh
wget -O aria2.sh https://ghfast.top/https://raw.githubusercontent.com/Niter8263/aria2/main/aria2.sh
wget -O aria2.sh https://ghproxy.net/https://raw.githubusercontent.com/Niter8263/aria2/main/aria2.sh

# 或者一步到位：直连失败自动改用加速地址
wget -qO aria2.sh https://raw.githubusercontent.com/Niter8263/aria2/main/aria2.sh ||
  wget -qO aria2.sh https://gh-proxy.com/https://raw.githubusercontent.com/Niter8263/aria2/main/aria2.sh
```
* 运行脚本
```
chmod +x aria2.sh && ./aria2.sh
```

> **已失效的地址**，请勿再使用：`https://goo.su/WmqPUe`（会跳转到已停用的 `github.moeyy.xyz`）、`git.io/*` 短链、`aria2c.now.sh`、`hub.gitmirror.com`、`mirror.ghproxy.com`。
> 命令里不要加 `-N`：它与 `-O` 不兼容（wget 会警告 `timestamping does nothing in combination with -O`），且本脚本首次下载时本地并无旧文件可供比对时间。

## 本地测试

改动后建议按下面三层验证，由浅入深。

**第一层：语法检查**（改完随手做，秒级）
```
for f in aria2.sh core clean.sh delete.sh move.sh upload.sh tracker.sh service/*; do
  bash -n "$f" || echo "语法错误: $f"
done
```

**第二层：钩子脚本功能测试**（不需要 root，不需要装 Aria2）
```
bash test/run_hook_tests.sh
```
`test/` 目录里的 `mock_aria2_rpc.py` 会起一个模拟的 Aria2 RPC 服务，让 `clean.sh` / `delete.sh` / `move.sh` 能像在真实环境一样被触发，从而验证：控制文件与种子文件是否按预期清理、正在下载的种子是否被正确保留、出错任务的残留文件是否删除、已完成文件是否被误删、`move.sh` 是否移动到 `dest-dir`。

这套测试是有诊断能力的：把 `core` 的种子清理逻辑还原成旧版，只有对应那一项会失败，其余照常通过。

**第三层：完整安装测试**（必须有 root，建议用容器或测试机，不要直接在生产上试）

第二层测不到的部分需要真实系统环境：iptables 规则、init 服务注册与开机自启、crontab、apt/yum 依赖安装、以及真实的 `aria2c` 二进制。用 Docker 可以快速起一个干净环境：
```
docker run -it --rm --privileged -v "$PWD":/aria2 debian:12 bash
# 容器内：
cd /aria2 && ./aria2.sh     # 选择 1 安装
```
`--privileged` 是 iptables 需要的；如果不关心防火墙，用普通容器并忽略 iptables 相关报错也可以。装完重点检查：菜单能否正常显示状态、`/etc/init.d/aria2 status` 是否正常、菜单 14 改代理后能否生效、以及在 AriaNG 里能否连上 RPC。

**上线前检查清单**
- 菜单 8「查看配置」显示的 IPv4 / RPC 端口 / 密钥是否正确
- RPC 能否从你的客户端连上（注意默认只放行内网网段，公网需改 `rpc_allow_source`）
- 下载一个普通 HTTP 文件，确认完成后 `.aria2` 文件被清理
- 下载一个多文件 BT 任务，确认完成后 `.torrent` 被清理、正在下载的种子还在
- 重启机器，确认 Aria2 自动启动



**GitHub 代理可随时更换。** 公共 GitHub 代理会不定期失效（旧版脚本写死的 `github.moeyy.xyz` 与 `aria2c.now.sh` 均已失效）。本脚本默认使用 `https://gh-proxy.com/`（实测下载速度优于 `ghproxy.net`，且支持版本查询 API），并会自动按 `你配置的代理 → 备用代理列表 → 直连 GitHub` 依次尝试，单条线路挂掉不影响使用；下载时会显示当前用的是第几条线路。需要更换时运行脚本选择菜单 `14. 设置 GitHub 代理`，可直接输入新代理并测试连通性，设置会写回脚本持久生效。

> 已知限制：`ghproxy.net` 不转发 `api.github.com`，因此查询最新版本号时会自动跳过它（raw 文件下载不受影响）。菜单 14 的测试功能会分别报告这两项的可用性。

**RPC 访问范围默认限制在内网。** 为降低风险，安装时写入的 iptables 规则只放行内网网段（`192.168.0.0/16`、`10.0.0.0/8`、`172.16.0.0/12`、`127.0.0.1/8`）访问 RPC 端口。若需要从公网访问，请修改脚本顶部的 `rpc_allow_source` 变量，改成你的固定 IP 或 `0.0.0.0/0`（后者等同于不限制，请自行评估风险，建议配合 Nginx 反代 + HTTPS）。

**选项 `7 → 0 重置/更新配置` 只刷新配置文件。** 该操作会重新下载 `aria2.conf`、`script.conf`、`rclone.env` 三个配置文件并恢复为仓库中的版本；`core`、`clean.sh`、`delete.sh`、`move.sh`、`upload.sh` 等功能脚本**不做覆盖**，以保留本地修改。如需同步脚本更新，请手动替换并重新应用本地改动。
## 其他操作

启动：`/etc/init.d/aria2 start` `|` `service aria2 start`

停止：`/etc/init.d/aria2 stop` `|` `service aria2 stop`

重启：`/etc/init.d/aria2 restart` `|` `service aria2 restart`

查看状态：`/etc/init.d/aria2 status` `|` `service aria2 status`

配置文件路径：`/root/.aria2c/aria2.conf` （配置文件有中文注释，若语言设置有问题会导致中文乱码）

默认下载目录：`/root/downloads`

RPC 密钥：随机生成，可使用选项`7. 修改 配置文件`自定义
## 文件说明

> **TIPS:** 附加功能脚本需配合配置文件使用，仅适用于 GNU/Linux ，理论上 macOS 安装 GNU 工具套件可以使用。依赖：`bash`、`curl`、`findutils`、`jq`

| 文件                    | 说明                                                                                                                                                                                                                                                                                      |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `aria2.conf`            | Aria2 配置文件。建议配合 1.35.0 及以上版本使用。内附可能比官方文档还详细的中文注释说明和修改建议，在不了解的情况下随意修改可能导致本方案的特性失效。                                                                                                                                      |
| `script.conf`           | Aria2 附加功能脚本配置文件。                                                                                                                                                                                                                                                              |
| `core`                  | Aria2 附加功能脚本核心文件。所有脚本都依赖于此文件运行。                                                                                                                                                                                                                                  |
| `clean.sh`              | 文件清理脚本。在下载完成后执行([on-download-complete](https://aria2.github.io/manual/en/html/aria2c.html#cmdoption-on-download-complete))，自动清理控制文件(`*.aria2`)、种子文件(`*.torrent`)和空目录。（默认启用）                                                                       |
| `delete.sh`             | 文件删除脚本。在下载停止后执行([on-download-stop](https://aria2.github.io/manual/en/html/aria2c.html#cmdoption-on-download-stop))，当下载错误或删除正在下载的任务后自动删除相关文件，并自动清理控制文件(`*.aria2`)、种子文件(`*.torrent`)和空目录，防止不必要的磁盘空间占用。（默认启用） |
| `upload.sh`             | 文件上传脚本。在下载完成后执行([on-download-complete](https://aria2.github.io/manual/en/html/aria2c.html#cmdoption-on-download-complete))，自动调用 RCLONE 上传(move)下载完成的文件到网盘，并自动清理控制文件(`*.aria2`)、种子文件(`*.torrent`)和空目录。（默认不启用）                   |
| `rclone.env`            | [RCLONE 环境变量](https://rclone.org/docs/#environment-variables)文件。配合`upload.sh`使用，用于配置 RCLONE 的选项参数。                                                                                                                                                                  |
| `move.sh`               | 文件移动脚本。在下载完成后执行([on-download-complete](https://aria2.github.io/manual/en/html/aria2c.html#cmdoption-on-download-complete))，自动将下载完成的文件移动到指定目录，并自动清理控制文件(`*.aria2`)、种子文件(`*.torrent`)和空目录。（默认不启用）                               |
| `tracker.sh`            | BT tracker 列表更新脚本。在 Aria2 配置文件(`aria2.conf`)所在目录执行即可获取[最新 tracker 列表](https://raw.githubusercontent.com/XIU2/TrackersListCollection/master/all.txt)并添加到配置文件中。其它使用方法详见 [tracker.md](./tracker.md)                                              |
| `dht.dat`<br>`dht6.dat` | DHT 网络节点数据文件。提升 BT 下载率和下载速度的关键之一。相关科普：《[解决 Aria2 无法下载磁力链接、BT种子和速度慢的问题](https://p3terx.com/archives/solved-aria2-cant-download-magnetic-link-bt-seed-and-slow-speed.html)》                                                             |

### 反吸血（antileech）

`antileech.sh` 轮询 `aria2.getPeers`，按 peerId 前缀识别迅雷等客户端，再从系统层封禁（aria2 本身没有 ban peer 的 RPC）。

封禁粒度由 `antileech.conf` 的 `BLOCK_MODE` 控制：

* `ip`（默认）：把来源 IP 加入 ipset，整段拦截。只有能看到真实对端 IP 时才有意义。
* `ipport`：按来源 IP + 源端口封，只断掉那一条 peer 连接。**当端口转发或网关做了源地址改写、所有 peer 都显示成同一个地址（例如路由器地址）时，必须用这个模式**，否则按 IP 封会把正常 peer 一起打死，可能连网关一起封掉导致自己失联。

`ipport` 只能止损：封的是 NAT 会话的映射端口，对方重连换端口就绕过。想根治需要让端口转发保留真实源 IP（只做 DNAT，不要叠加 SNAT / MASQUERADE）。

`EXCLUDE_IPS` 是永不封禁的地址列表（逗号分隔），用于 `ip` 模式的兜底。注意 `ipport` 模式下若把网关填进去，等于完全不封。

`MIN_DOWNLOAD_SPEED` 是活跃放行阈值（字节/秒，默认 1024）。peer 正在给我方传数据时（`downloadSpeed` 达到该值）不会被封禁——迅雷等客户端经常一边大量下载一边回传，只按 peerId 前缀一刀切会把有用的源一起封掉。设为 `0` 关闭该保护，退化为只看前缀的行为。

`RATIO_GUARD` 是"只下不上"判定，默认关闭。开启后不看客户端名，按"我方上传给它 / 它下载给我"的累计比例识别纯吸血：窗口 `RATIO_WINDOW`（默认 600 秒）内我方至少传了 `RATIO_MIN_UPLOAD`（默认 100 MB），而它回传不足 `RATIO_MIN_IN_PERCENT`（默认 5%），就封禁。评估只在我们自己还没下载完成的任务上进行——任务已完成（自己在做种）时所有 peer 都不需要回传，照样判定会把整个 swarm 封掉。`getPeers` 只有瞬时速度没有累计字节，脚本按轮询间隔把速度积分成流量，因此 `POLL_INTERVAL` 越长估算越粗。多个 peer 共用同一出口 IP 时状态会合并，与按 IP 封禁的粒度一致。

### 运维相关

安装脚本会自动写入 `/etc/logrotate.d/aria2`，对 `aria2.log`、`tracker.log`、`upload.log`、`move.log` 做每周轮转、保留 4 份。用 `copytruncate` 是因为 aria2 通过 shell 重定向持有日志文件，改名方式会让它继续写旧 inode。

`aria2.session` 保存的是错误/未完成任务的列表（任务完成后会自动移出），机器重启或进程崩溃后靠它恢复任务队列。它位于 `/root/.aria2c` 下，而 `/root` 默认是 `0700`，非 root 无法读取，不需要额外处理权限。

配置目录支持一键备份，会排除日志、DHT 数据、会话文件和 `*.aria2`，默认保留最近 7 份：

```bash
bash aria2.sh --backup-config              # 备份到 /root/aria2-backup
bash aria2.sh --backup-config /data/bak    # 指定目录
```

需要定期自动备份可以加一条 cron：

```
0 3 * * 0 /bin/bash /root/aria2.sh --backup-config >/dev/null 2>&1
```

备份包含明文 `rpc-secret`，文件权限是 `600`，别随手拷到共享目录。

IPv6 默认开启（`disable-ipv6=false`、`enable-dht6=true`）。主机有 IPv6 出口时会自动接入 v6 的 DHT 并接受 v6 的 BT 连接，没有 v6 也不影响 v4 下载。如果确认环境没有 IPv6 想彻底关掉，把这两项改回 `true` / `false` 即可。注意 v6 的 BT/DHT 端口需要 ip6tables 放行，默认策略为 ACCEPT 时无需额外配置。

## 遇到问题如何处理

遇到问题先看 [FAQ](https://p3terx.com/archives/aria2_perfect_config-faq.html) 再提问，你还可以加入 [Aria2 TG 群](https://t.me/Aria2c)和小伙伴们一起讨论。要注意提问的方式和提供有用的信息，提问前建议去学习《[提问的智慧](https://github.com/ryanhanwu/How-To-Ask-Questions-The-Smart-Way/blob/master/README-zh_CN.md)》，这能更好的帮助你去解决问题和节约时间。诸如 “为什么不能使用？”、“那你能帮帮我吗？” 之类的问题应该没有人会知道。

## 更新日志

更新推送：[Aria2 Channel](https://t.me/Aria2_Channel)

### 2021-07-04

- 新增 正则表达式文件过滤功能。感谢 @hereisderek
- 新增 支持自定义多个 tracker 列表 URL ([Aria2 Pro](https://github.com/P3TERX/Aria2-Pro-Docker))。感谢 @hereisderek
- 修复 目录名有特殊符号时导致的路径处理错误。感谢 @zzjjbb

### 2020-12-24

- 调整一些过于激进的配置选项值，提升稳定性。
  - 单个 BT 下载任务最大连接数(`bt-max-peers`)从`0`(不限制)调整为`128`，减少不必要的 CPU 和网络占用。
  - 下载进度自动保存间隔时间(`auto-save-interval`)从`1`秒调整为`20`秒，减少磁盘 I/O 。
- 补充一些说明和设置建议。

### 2020-12-09

- 优化 RCLONE 环境变量文件加载方法
- 更换 User Agent（因部分用户的滥用行为导致被某知名开源镜像站屏蔽）
- 增加一些高级选项及说明

### 2020-07-12 | V3

- 全新 附加功能脚本
- 新增 种子文件删除功能
- 新增 全局文件过滤功能
- 新增 前端自定义临时下载目录功能。免手动设定脚本中的路径。
- 新增 附加功能脚本核心文件(`core`)。强大的功能源自于强大的核心。
- 新增 附加功能脚本配置文件(`script.conf`)。独立文件持久化配置，方便更新。
- 新增 RCLONE 环境变量文件(`rclone.env`)
- 优化 文件删除机制。防止极限环境和极端使用习惯情况下误删文件。
- 更多改进请自行体验

<details>
<summary>历史记录</summary>

早期版本和其它记录已归档至 [v2 分支](https://github.com/P3TERX/aria2.conf/tree/v2)

</details>

## 声明

本项目使用 [MIT](https://github.com/P3TERX/aria2.conf/blob/master/LICENSE) 开源协议，对于本项复制、修改、发布等行为请遵守相关协议保留所有文件中的版权信息，谢谢合作！
