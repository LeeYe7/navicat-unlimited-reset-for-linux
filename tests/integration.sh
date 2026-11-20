#!/usr/bin/env bash
# 在私有 D-Bus 会话、dconf 数据库和 XDG 目录中验证真实的读写行为。
set -euo pipefail
project=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [[ ${1:-} != --private-session ]]; then
    sandbox=$(mktemp -d)
    trap 'rm -rf -- "$sandbox"' EXIT
    mkdir -m 700 "$sandbox/runtime" "$sandbox/home" "$sandbox/home/.config" "$sandbox/state"
    printf 'user-db:navicat_test\n' > "$sandbox/profile"
    HOME="$sandbox/home" XDG_RUNTIME_DIR="$sandbox/runtime" XDG_CONFIG_HOME="$sandbox/home/.config" \
        XDG_STATE_HOME="$sandbox/state" DCONF_PROFILE="$sandbox/profile" \
        dbus-run-session -- bash "$0" --private-session
    exit
fi

# 防止误把内部参数传给真实桌面会话。
[[ ${DCONF_PROFILE:-} == /*/profile && -f $DCONF_PROFILE && $(<"$DCONF_PROFILE") == user-db:navicat_test ]]
sandbox=${DCONF_PROFILE%/*}
[[ $HOME == "$sandbox/home" && $XDG_CONFIG_HOME == "$sandbox/home/.config" ]]
[[ $XDG_STATE_HOME == "$sandbox/state" && $XDG_RUNTIME_DIR == "$sandbox/runtime" ]]
script="$project/reset.sh"
dir="$XDG_CONFIG_HOME/navicat/Premium"
state="$XDG_STATE_HOME/navicat-daily-reset"
today=$(date +%F)
key=/com/premiumsoft/navicat-premium/
snap="$state/backups/$today"

mkdir -p "$dir/Profiles" "$XDG_RUNTIME_DIR/bin"
# 测试不依赖宿主机是否开着 Navicat，仅隔离进程查询。
cat > "$XDG_RUNTIME_DIR/bin/pgrep" <<'MOCK'
#!/bin/sh
if [ -n "${TEST_LAUNCH_MARKER:-}" ]; then
    [ ! -e "$TEST_LAUNCH_MARKER" ] || exit 0
    touch "$TEST_LAUNCH_MARKER"
fi
exit "${TEST_PGREP_STATUS:-1}"
MOCK
chmod +x "$XDG_RUNTIME_DIR/bin/pgrep"
export PATH="$XDG_RUNTIME_DIR/bin:$PATH"

printf 'original' > "$dir/preferences.json"
touch "$dir/preferences.json.lock" "$dir/Profiles/keep"
dconf write "${key}ui/theme" "'test'"
dconf write /com/premiumsoft/unrelated/keep 'true'
"$script" --dry-run
[[ ! -e $state && -f $dir/preferences.json.lock ]]
TEST_PGREP_STATUS=0 "$script"
[[ ! -e $state/last-success-date && ! -d $snap && -f $dir/preferences.json.lock ]]

# 在 dconf 清理成功、删除文件之前模拟一次磁盘错误。
cat > "$XDG_RUNTIME_DIR/bin/rm" <<'MOCK'
#!/bin/sh
exit 71
MOCK
chmod +x "$XDG_RUNTIME_DIR/bin/rm"
if "$script"; then exit 1; fi
[[ ! -e $state/last-success-date && -s $snap/settings.dconf ]]
[[ -z $(dconf read "${key}ui/theme") ]]
/usr/bin/rm "$XDG_RUNTIME_DIR/bin/rm"

printf 'new settings' > "$dir/preferences.json"
if "$script"; then exit 1; fi
[[ $(<"$dir/preferences.json") == 'new settings' && ! -e $state/last-success-date ]]
printf 'original' > "$dir/preferences.json"
dconf write "${key}later" 'true'
if "$script"; then exit 1; fi
[[ $(dconf read "${key}later") == true && $(<"$snap/preferences.json") == original ]]
dconf reset "${key}later"

"$script" & first=$!
"$script" & second=$!
wait "$first"; wait "$second"
[[ $(<"$state/last-success-date") == "$today" ]]
[[ ! -e $dir/preferences.json && ! -e $dir/preferences.json.lock && -f $dir/Profiles/keep ]]
[[ $(grep -c '已重置' "$state/run.log") == 1 && $(<"$snap/preferences.json") == original ]]
printf 'recreated' > "$dir/preferences.json"
dconf write "${key}new-entry" 'true'
"$script"
[[ $(<"$dir/preferences.json") == recreated && $(dconf read "${key}new-entry") == true ]]
"$script" --restore "$today"
[[ $(<"$dir/preferences.json") == original ]]
[[ $(dconf read "${key}ui/theme") == "'test'" && -z $(dconf read "${key}new-entry") ]]
[[ $(dconf read /com/premiumsoft/unrelated/keep) == true ]]

# 历史快照之间隔了数月；复制顺序和修改时间不能决定保留顺序。
backups="$state/backups"
history=(2019-08-01 2019-03-04 2019-05-23 2019-01-20 2019-06-14 2019-11-30)
for day in "${history[@]}"; do cp -r "$snap" "$backups/$day"; done
cp -r "$snap" "$backups/2000-01-01"
touch "$backups/2000-01-01/.keep"
ln -s "$backups/2019-08-01" "$backups/2020-01-02"
"$script"
for day in "${history[@]}"; do [[ -f $backups/$day/preferences.json ]]; done

oldest=2018-12-24
cp -r "$snap" "$backups/$oldest"
"$script" --dry-run
"$script" --restore "$oldest"
[[ $(<"$dir/preferences.json") == original && -f $backups/$oldest/preferences.json ]]

# 模拟长期未登录后创建第八份快照；新备份记录偏好文件和 dconf 子树原本均不存在。
rm -r "$snap"
printf '%s\n' 2019-11-30 > "$state/last-success-date"
rm "$dir/preferences.json"
dconf reset -f "$key"
"$script"
[[ -f $snap/preferences.absent && ! -s $snap/settings.dconf ]]
[[ ! -e $backups/$oldest ]]
for day in "${history[@]}"; do [[ -f $backups/$day/preferences.json ]]; done
[[ -f $backups/2000-01-01/.keep && -L $backups/2020-01-02 ]]

# 升级时一次清理多份超额快照，同日重复运行不影响重新生成的偏好。
cp -r "$snap" "$backups/$oldest"
cp -r "$snap" "$backups/2015-01-01"
printf 'later' > "$dir/preferences.json"
"$script"
[[ ! -e $backups/$oldest && ! -e $backups/2015-01-01 && $(<"$dir/preferences.json") == later ]]
for day in "${history[@]}"; do [[ -f $backups/$day/preferences.json ]]; done
dconf write "${key}later" 'true'
"$script" --restore "$today"
[[ ! -e $dir/preferences.json && -z $(dconf dump "$key") && -f $dir/Profiles/keep ]]
if "$script" --restore 1999-01-01; then exit 1; fi

# 在清理命令即将执行时加入用户文件，复现扫描目录和删除之间的竞态。
cp -r "$snap" "$backups/$oldest"
cat > "$XDG_RUNTIME_DIR/bin/rm" <<'MOCK'
#!/bin/sh
printf 'user note' > "$QA_OLD_SNAPSHOT/.keep"
exec /usr/bin/rm "$@"
MOCK
chmod +x "$XDG_RUNTIME_DIR/bin/rm"
QA_OLD_SNAPSHOT="$backups/$oldest" "$script"
/usr/bin/rm "$XDG_RUNTIME_DIR/bin/rm"
[[ $(<"$backups/$oldest/.keep") == 'user note' ]]
[[ ! -e $backups/$oldest/settings.dconf && ! -e $backups/$oldest/preferences.absent ]]

# 模拟系统从未来回拨到今天。七份未来快照已有记录，今天需要新建第八份。
future=()
for offset in {1..7}; do
    day=$(date -d "$today +$offset days" +%F)
    future+=("$day")
    cp -r "$snap" "$backups/$day"
done
rm -r -- "$snap"
"$script"  # 今天已有成功记录，但没有当天快照，七个名额都留给历史备份。
for day in "${future[@]}"; do [[ -f $backups/$day/settings.dconf ]]; done
printf '%s\n' "${future[6]}" > "$state/last-success-date"
printf 'before rollback reset' > "$dir/preferences.json"
"$script"
[[ ! -e $dir/preferences.json && -f $snap/preferences.json && ! -e $backups/${future[0]} ]]
for day in "${future[@]:1}"; do [[ -f $backups/$day/settings.dconf ]]; done
for day in "${history[@]}"; do [[ ! -e $backups/$day ]]; done
"$script"
"$script" --restore "$today"
[[ $(<"$dir/preferences.json") == 'before rollback reset' ]]
echo '通过：每日去重、失败重试、七份备份轮换、并发写入保护、日期回拨及恢复。'

# 用受控日期走真实的 A → B → A，保留两天的成功记录和快照。
cat > "$XDG_RUNTIME_DIR/bin/date" <<'MOCK'
#!/bin/sh
if [ "$1" = +%F ]; then echo "$TEST_DAY"; else exec /usr/bin/date "$@"; fi
MOCK
chmod +x "$XDG_RUNTIME_DIR/bin/date"
export TEST_DAY=2040-04-10
printf 'first visit' > "$dir/preferences.json"
"$script"
export TEST_DAY=2040-04-11
"$script"
export TEST_DAY=2040-04-10
printf 'after clock change' > "$dir/preferences.json"
dconf write "${key}later" 'true'
"$script"
[[ $(<"$dir/preferences.json") == 'after clock change' && $(dconf read "${key}later") == true ]]
[[ $(<"$backups/$TEST_DAY/preferences.json") == 'first visit' ]]

# 升级前的旧快照缺乏逐日成功标记；遇到它时也要保护现状。
export TEST_DAY=2039-01-01
mkdir -- "$backups/$TEST_DAY"
touch "$backups/$TEST_DAY/settings.dconf" "$backups/$TEST_DAY/preferences.absent"
"$script"
[[ $(<"$dir/preferences.json") == 'after clock change' && $(dconf read "${key}later") == true ]]

# 模拟 Navicat 在第一次检查和最终写入之间启动；退出后重新捕获最新设置。
export TEST_DAY=2040-04-12
marker="$XDG_RUNTIME_DIR/launch"
TEST_LAUNCH_MARKER="$marker" "$script"
[[ -e $marker && ! -d $backups/$TEST_DAY && $(<"$dir/preferences.json") == 'after clock change' ]]
[[ $(dconf read "${key}later") == true && $(<"$state/last-success-date") == 2040-04-11 ]]
printf 'changed while running' > "$dir/preferences.json"
"$script"
[[ $(<"$backups/$TEST_DAY/preferences.json") == 'changed while running' && ! -e $dir/preferences.json ]]
rm -- "$marker"
printf 'live' > "$dir/preferences.json"
dconf write "${key}live" 'true'
if TEST_LAUNCH_MARKER="$marker" "$script" --restore "$TEST_DAY"; then exit 1; fi
[[ $(<"$dir/preferences.json") == live && $(dconf read "${key}live") == true ]]
[[ -z $(dconf read "${key}later") ]]

# 不同工作目录中给出相对 XDG 值，应共用 HOME 中的配置、备份、锁和成功日期。
mkdir -- "$XDG_RUNTIME_DIR/one" "$XDG_RUNTIME_DIR/two"
(
    export XDG_CONFIG_HOME=relative-config XDG_STATE_HOME=relative-state
    cd -- "$XDG_RUNTIME_DIR/one"
    "$script"
    printf 'keep' > "$dir/preferences.json"
    cd -- "$XDG_RUNTIME_DIR/two"
    "$script"
)
[[ $(<"$HOME/.local/state/navicat-daily-reset/backups/$TEST_DAY/preferences.json") == live ]]
[[ $(<"$dir/preferences.json") == keep && -z $(dconf read "${key}live") ]]
[[ ! -e $XDG_RUNTIME_DIR/one/relative-state && ! -e $XDG_RUNTIME_DIR/two/relative-state ]]
echo '通过：已有快照日期回访、升级兼容、启动竞态及相对 XDG 路径。'
