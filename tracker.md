## tracker.sh

> 说明：原文档使用的 `git.io` 短链服务已于 2022 年停止，以下命令已改为直接引用本仓库的 `tracker.sh`。
> 若下载受阻，可把 URL 换成 jsDelivr 镜像：`https://cdn.jsdelivr.net/gh/Niter8263/aria2@main/tracker.sh`

- 执行以下命令可直接获取 Aria2 可用格式的 BT tracker 列表。
```
bash <(curl -fsSL https://raw.githubusercontent.com/Niter8263/aria2/main/tracker.sh) cat
```

- 在 Aria2 配置文件(`aria2.conf`)所在目录执行以下命令即可获取最新 BT tracker 列表并自动添加到配置文件中。
```
bash <(curl -fsSL https://raw.githubusercontent.com/Niter8263/aria2/main/tracker.sh)
```

- 指定 Aria2 配置文件路径，比如配置文件在`/root/.aria2c/aria2.conf`：
```
bash <(curl -fsSL https://raw.githubusercontent.com/Niter8263/aria2/main/tracker.sh) "/root/.aria2c/aria2.conf"
```

- 通过 RPC 方式给远程 Aria2 更新 BT tracker 列表。
```
bash <(curl -fsSL https://raw.githubusercontent.com/Niter8263/aria2/main/tracker.sh) RPC '233.233.233.233:6800' 'Secret123'
```

- 通过 RPC 方式给本地 Aria2 更新 BT tracker 列表，并写入到 Aria2 配置文件中。
```
bash <(curl -fsSL https://raw.githubusercontent.com/Niter8263/aria2/main/tracker.sh) "/root/.aria2c/aria2.conf" RPC
```
