怎么使用？使用root

运行以下【通讯服务端命令】

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Jaydooooooo/happy-code/main/install-happy.sh)
```


【你的happy 端运行以下命令】

一定要记得，初始化可以ssh，但是happy启动必须是本地，否则会报错

[安装项目地址命令](https://github.com/slopus/happy)
```bash
npm install -g happy-coder
```
指定域名
```bash
export HAPPY_SERVER_URL=https://<你的域名>
```
初始化
```bash
happy init
```

运行
```bash
happy
```


卸载命令
```bash
npm uninstall -g happy-coder
```

```bash
rm -rf ~/.happy
rm -rf ~/.config/happy
rm -rf ~/.cache/happy
rm -rf ~/.local/share/happy
```

