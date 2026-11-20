# Navicat 无限重置 for Linux

![Linux 终端中的 Navicat 配置快照与每日重置](assets/navicat-linux-banner.webp)

每天第一次登录桌面时，保留 Navicat Premium 18 偏好设置并重置试用时间，自动跳过同一天内重新登录或重启。

## 安装

在项目目录中，以日常使用 Navicat 的用户运行即可生效：

```bash
./reset.sh --dry-run   # 预览改动的目录
./install.sh
```

若想立即执行一次，请先关闭 Navicat：

```bash
~/.local/bin/navicat-daily-reset.sh
```

依赖 Bash、GNU coreutils、`cmp`、`grep`、`flock`、`pgrep` 和 `dconf`，需要支持 XDG Autostart 的桌面和当前用户的 D-Bus 会话。Fedora 用 `sudo dnf install dconf`，Debian/Ubuntu 用 `sudo apt install dconf-cli dconf-service`。

## 重置范围

| 目标                                                | 操作    |
| ------------------------------------------------- | ----- |
| dconf 子树 `/com/premiumsoft/navicat-premium/`      | 备份后重置 |
| `~/.config/navicat/Premium/preferences.json`      | 备份后删除 |
| `~/.config/navicat/Premium/preferences.json.lock` | 删除    |

其他文件（`Profiles/`、连接配置等）不受影响。设置了绝对路径的 `XDG_CONFIG_HOME` 时，配置目录使用其下的 `navicat/Premium/`。

重置前后各检查一次 Navicat 进程，检测到在运行就跳过。如果桌面会自动启动 Navicat，把启动项改成先重置再启动，两个程序按顺序执行：

```bash
"$HOME/.local/bin/navicat-daily-reset.sh" && exec "/实际安装路径/navicat"
```

## 备份和恢复

每天最多一份快照，保留最近 7 份，存放在 `~/.local/state/navicat-daily-reset/backups/YYYY-MM-DD/`。每份快照包含 `settings.dconf`、偏好文件（原本缺失时是 `preferences.absent`）和校验文件 `checksums.sha256`。

```bash
~/.local/bin/navicat-daily-reset.sh --dry-run              # 查看备份目录
~/.local/bin/navicat-daily-reset.sh --restore YYYY-MM-DD   # 恢复备份
```

恢复会先保存当前配置，中途出错自动回滚。恢复成功后，当天再次登录不会重置。

## 升级和卸载

再次运行 `./install.sh` 即可升级，旧文件保留为同目录的编号副本（如 `.~1~`）。

```bash
./install.sh --uninstall
```

卸载删除脚本和自启项，备份与 `run.log` 保留。

## 测试

```bash
./tests/run.sh
```

执行语法检查、安装、每日重置和恢复的回归测试，需要 `dbus-run-session`。

参考 [XDG 桌面自启动规范](https://specifications.freedesktop.org/autostart/latest/) 和 [dconf 命令手册](https://manpages.debian.org/trixie/dconf-cli/dconf.1.en.html)。

## 许可证

本项目的脚本和文档采用 [MIT 许可证](LICENSE)。
