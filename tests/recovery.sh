#!/usr/bin/env bash
# 在隔离的用户目录和 D-Bus 会话中验证写入失败、系统策略和恢复。
set -euo pipefail
project=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [[ $# == 0 ]]; then
    sandbox=$(mktemp -d)
    trap 'rm -rf -- "$sandbox"' EXIT
    status=0
    for scenario in full checksum legacy late managed missing; do
        root="$sandbox/$scenario"
        mkdir -p -m 700 -- "$root"/{home,runtime,config,state,bin}
        printf 'user-db:navicat_recovery_test\n' > "$root/user.profile"
        cp -- "$root/user.profile" "$root/profile"
        if [[ $scenario == managed ]]; then
            mkdir -p -- "$root/policy/locks"
            printf '[com/premiumsoft/navicat-premium/ui]\nlocked=true\ninherited=true\n' > "$root/policy/values"
            printf '/com/premiumsoft/navicat-premium/ui/locked\n' > "$root/policy/locks/values"
            dconf compile "$root/system.db" "$root/policy"
            printf 'file-db:%s/system.db\n' "$root" >> "$root/profile"
        fi
        printf '#!/bin/sh\nexit 1\n' > "$root/bin/pgrep"
        chmod +x -- "$root/bin/pgrep"
        if ! env -i HOME="$root/home" PATH="$root/bin:$PATH" \
                XDG_CONFIG_HOME="$root/config" XDG_STATE_HOME="$root/state" \
                XDG_RUNTIME_DIR="$root/runtime" DCONF_PROFILE="$root/profile" \
                dbus-run-session -- bash "$project/tests/recovery.sh" --private "$root" "$scenario"; then
            status=1
        fi
    done
    exit "$status"
fi

[[ $# == 3 && $1 == --private ]]
root=$2
scenario=$3
[[ $HOME == "$root/home" && $XDG_CONFIG_HOME == "$root/config" && $XDG_STATE_HOME == "$root/state" ]]
[[ $XDG_RUNTIME_DIR == "$root/runtime" && $DCONF_PROFILE == "$root/profile" ]]
[[ $(<"$root/user.profile") == user-db:navicat_recovery_test ]]
set -E
trap 'echo "失败：$scenario，第 $LINENO 行，$BASH_COMMAND" >&2' ERR
script="$project/reset.sh"
state="$XDG_STATE_HOME/navicat-daily-reset"
dir="$XDG_CONFIG_HOME/navicat/Premium"
prefs="$dir/preferences.json"
key=/com/premiumsoft/navicat-premium/ui/
mkdir -p -- "$dir"
original='{"theme":"original"}'
current='{"theme":"current"}'
printf '%s' "$original" > "$prefs"
dconf write "${key}saved" "'before reset'"

expect_failure() {
    if "$@"; then
        echo "失败：$scenario 本应返回非零" >&2
        return 1
    fi
}

if [[ $scenario == full ]]; then
    # 子进程的单文件上限模拟部分写入后 ENOSPC 的效果，不限制 dconf 服务。
    # 忽略 SIGXFSZ，让写入者收到 EFBIG，覆盖 dconf dump 忽略 stdout 错误的情况。
    data=$(head -c 32768 /dev/zero | tr '\0' x)
    dconf write "${key}large" "'$data'"
    limited_reset() (trap '' XFSZ; ulimit -f 8; exec "$script")
    expect_failure limited_reset
    [[ $(dconf read "${key}large") == "'$data'" && $(<"$prefs") == "$original" ]]
    shopt -s nullglob
    published=("$state/backups"/????-??-??)
    [[ ${#published[@]} == 0 && ! -e $state/last-success-date ]]
else
    "$script"
    snapshots=("$state/backups"/????-??-??)
    [[ ${#snapshots[@]} == 1 && -d ${snapshots[0]} ]]
    snapshot=${snapshots[0]}
    day=${snapshot##*/}
    dconf write "${key}later" "'keep on failure'"
    printf '%s' "$current" > "$prefs"
    printf '2001-01-01\n' > "$state/last-success-date"
    case $scenario in
        checksum)
            # 更换为较短的合法 JSON，检查能否识别已发布快照的内容发生变化。
            printf '{}' > "$snapshot/preferences.json"
            ;;
        legacy)
            day=2001-02-03
            old="$state/backups/$day"
            mkdir -- "$old"
            printf 'this is not a dconf keyfile\n' > "$old/settings.dconf"
            printf '%s' "$original" > "$old/preferences.json"
            ;;
        late)
            # 成功日期在 dconf 和文件写入之后提交。仅这一次重命名失败，允许回滚。
            export TEST_SUCCESS_STAMP="$state/last-success-date" TEST_REAL_MV
            TEST_REAL_MV=$(command -v mv)
            cat > "$root/bin/mv" <<'MOCK'
#!/usr/bin/env bash
if [[ ${!#} == "$TEST_SUCCESS_STAMP" && ! -e $XDG_RUNTIME_DIR/failed-once ]]; then
    touch -- "$XDG_RUNTIME_DIR/failed-once"
    exit 71
fi
exec "$TEST_REAL_MV" "$@"
MOCK
            chmod +x -- "$root/bin/mv"
            ;;
        missing)
            rm -- "$prefs"
            rmdir -- "$dir"
            ;;
        managed)
            [[ $(dconf read "${key}locked") == true && $(dconf read "${key}inherited") == true ]]
            ;;
        *) exit 2 ;;
    esac
    if [[ $scenario == managed || $scenario == missing ]]; then
        "$script" --restore "$day"
        [[ $(<"$prefs") == "$original" && $(dconf read "${key}saved") == "'before reset'" ]]
        [[ -z $(dconf read "${key}later") ]]
        if [[ $scenario == managed ]]; then
            # 仅查看用户数据库，确认可覆盖的系统默认值也没有被固化。
            [[ -z $(DCONF_PROFILE="$root/user.profile" dconf read "${key}inherited") ]]
            [[ -z $(DCONF_PROFILE="$root/user.profile" dconf read "${key}locked") ]]
        fi
    else
        expect_failure "$script" --restore "$day"
        if [[ $scenario == late ]]; then [[ -f $XDG_RUNTIME_DIR/failed-once ]]; fi
        [[ $(<"$prefs") == "$current" && $(dconf read "${key}later") == "'keep on failure'" ]]
        [[ -z $(dconf read "${key}saved") && $(<"$state/last-success-date") == 2001-01-01 ]]
        if [[ $scenario == legacy ]]; then
            cp -- "$snapshot/settings.dconf" "$old/settings.dconf"
            "$script" --restore "$day"
            [[ $(<"$prefs") == "$original" && $(dconf read "${key}saved") == "'before reset'" ]]
            [[ -z $(dconf read "${key}later") ]]
        fi
    fi
fi
echo "通过：$scenario"
