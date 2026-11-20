#!/usr/bin/env bash
set -euo pipefail
project=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sandbox=$(mktemp -d)
trap 'rm -rf -- "$sandbox"' EXIT
cd -- "$sandbox"
fixture_home="$sandbox/home with spaces"
fixture_config="$sandbox/absolute config"
mkdir -- "$fixture_home"
ln -s -- "$project" checkout

# 从源码目录的上级以相对路径运行，检验导出的 CDPATH 不会干扰安装器。
run_install() {
    env HOME="$fixture_home" XDG_CONFIG_HOME="$fixture_config" CDPATH=. \
        bash checkout/install.sh "$@"
}

script="$fixture_home/.local/bin/navicat-daily-reset.sh"
entry="$fixture_config/autostart/navicat-daily-reset.desktop"
run_install
[[ -x $script && -f $entry ]]
cmp -- "$project/reset.sh" "$script"
cp -- "$entry" original.desktop
run_install
[[ ! -e $script.~1~ && ! -e $entry.~1~ ]]

# 升级保留旧内容，再次安装相同内容不增加编号副本。
printf 'old script\n' > "$script"
printf 'old entry\n' > "$entry"
run_install
[[ $(<"$script.~1~") == 'old script' && $(<"$entry.~1~") == 'old entry' ]]
cmp -- "$project/reset.sh" "$script"
cmp -- original.desktop "$entry"
run_install
[[ ! -e $script.~2~ && ! -e $entry.~2~ ]]

# 同内容的链接也要单独备份，不能 chmod 修改链接指向的其他文件。
mv -- "$script" external.sh
chmod 0600 external.sh
ln -s -- "$sandbox/external.sh" "$script"
run_install
[[ -x $script && ! -L $script && -L $script.~2~ && $script.~2~ -ef external.sh ]]
[[ $(stat -c %a -- external.sh) == 600 ]]
run_install --uninstall
[[ ! -e $script && ! -e $entry && -L $script.~2~ && -f $entry.~1~ ]]

# 相对的 XDG 路径使用默认值。卸载只移除带有本项目标记的文件。
fixture_config=relative-config
entry="$fixture_home/.config/autostart/navicat-daily-reset.desktop"
run_install
[[ -f $entry && ! -e relative-config ]]
printf 'user entry\n' > "$entry"
run_install --uninstall
[[ ! -e $script && $(<"$entry") == 'user entry' ]]
echo '通过：安装、重复安装、升级、卸载、符号链接和 XDG 路径。'
