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
