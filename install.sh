#!/usr/bin/env bash
set -euo pipefail
umask 077

bin_dir="$HOME/.local/bin"
config_home=${XDG_CONFIG_HOME:-}
[[ $config_home == /* ]] || config_home="$HOME/.config"
autostart_dir="$config_home/autostart"
script="$bin_dir/navicat-daily-reset.sh"
entry="$autostart_dir/navicat-daily-reset.desktop"
marker='# Managed by navicat-daily-reset'

if [[ $# == 1 && $1 == --uninstall ]]; then
    for target in "$entry" "$script"; do
        if [[ -f $target ]] && grep -Fxq "$marker" "$target"; then rm -- "$target"; fi
    done
    echo "已卸载项目管理的自启项和脚本。备份与运行记录仍在状态目录。"
    exit 0
fi
if [[ $# != 0 ]]; then
    echo "用法: $0 [--uninstall]" >&2; exit 2
fi
for tool in bash dconf flock pgrep; do
    command -v "$tool" >/dev/null || { echo "缺少依赖: $tool" >&2; exit 1; }
done

source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p -- "$bin_dir" "$autostart_dir"
install_file() {
    local source=$1 target=$2 permissions=$3
    if [[ ! -L $target && -f $target ]] && cmp -s -- "$source" "$target"; then
        chmod "$permissions" -- "$target"; return
    fi
    # GNU install 的编号备份保留旧版脚本和自启项。
    install -T --backup=numbered -m "$permissions" -- "$source" "$target"
}

# cd 默认切换到当前用户的家目录，支持路径中的空格，无需向 Exec 插入用户名。
desktop=$(mktemp)
trap 'rm -f -- "$desktop"' EXIT
cat > "$desktop" <<'DESKTOP'
[Desktop Entry]
# Managed by navicat-daily-reset
Type=Application
Name=Navicat Daily Preference Reset
Name[zh_CN]=Navicat 每日偏好重置
Comment=Reset Navicat preferences once per day at desktop login
Exec=sh -c "cd && exec ./.local/bin/navicat-daily-reset.sh"
Terminal=false
DESKTOP
install_file "$source_dir/reset.sh" "$script" 0755
install_file "$desktop" "$entry" 0644
echo "已安装。下次登录桌面时生效。预览命令：\"$script\" --dry-run"
