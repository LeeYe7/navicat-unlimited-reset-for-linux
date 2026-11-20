#!/usr/bin/env bash
# Managed by navicat-daily-reset
set -euo pipefail
umask 077

if [[ ${XDG_CONFIG_HOME:-} != /* ]]; then export XDG_CONFIG_HOME="$HOME/.config"; fi
if [[ ${XDG_STATE_HOME:-} != /* ]]; then export XDG_STATE_HOME="$HOME/.local/state"; fi
config_dir="$XDG_CONFIG_HOME/navicat/Premium"
prefs="$config_dir/preferences.json"
state_dir="$XDG_STATE_HOME/navicat-daily-reset"
backup_root="$state_dir/backups"
dconf_dir=/com/premiumsoft/navicat-premium/

usage() {
    echo "用法: $0 [--dry-run | --restore YYYY-MM-DD | --help]"
}

mode=daily
case "${1:-}" in
    '') [[ $# == 0 ]] || { usage >&2; exit 2; } ;;
    --dry-run) [[ $# == 1 ]] || { usage >&2; exit 2; }; mode=preview ;;
    --restore)
        [[ $# == 2 && ${2:-} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { usage >&2; exit 2; }
        mode=restore ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

stamp="$state_dir/last-success-date"
history="$state_dir/completed-dates"
retry_stamp="$state_dir/retry-date"
in_history() {
    [[ -f $history ]] || return 1
    local status=0
    grep -Fxq -- "$1" "$history" || status=$?
    if (( status > 1 )); then exit "$status"; fi
    return "$status"
}

already_done() {
    [[ -f $stamp && $(<"$stamp") == "$today" ]] || in_history "$today"
}

# 只归档已提交的旧日期，当天成功仍由最后一次原子替换 stamp 标记。
archive_previous_success() {
    [[ -f $stamp ]] || return 0
    local previous
    previous=$(<"$stamp")
    [[ $previous =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && $previous != "$today" ]] || return 0
    if in_history "$previous"; then return 0; fi
    {
        if [[ -f $history ]]; then cat -- "$history"; fi
        printf '%s\n' "$previous"
    } > "$history.tmp"
    mv -fT -- "$history.tmp" "$history"
}

prune_backups() (
    local LC_ALL=C GLOBSORT=name snapshot day i
    local history_limit=7
    local -a snapshots=()
    shopt -s nullglob dotglob

    is_managed_snapshot() {
        local dir=$1 expected=2
        [[ -d $dir && ! -L $dir ]] || return 1
        local -a files=("$dir"/*)
        if [[ -f $dir/checksums.sha256 && ! -L $dir/checksums.sha256 ]]; then expected=3; fi
        [[ ${#files[@]} == "$expected" && -f $dir/settings.dconf && ! -L $dir/settings.dconf ]] &&
            [[ ( -f $dir/preferences.json && ! -L $dir/preferences.json ) ||
               ( -f $dir/preferences.absent && ! -L $dir/preferences.absent ) ]]
    }

    # YYYY-MM-DD 目录名按名称升序展开，即从最早到最近。
    for snapshot in "$backup_root"/????-??-??; do
        day=${snapshot##*/}
        [[ $day =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
        is_managed_snapshot "$snapshot" || continue
        # 即使日期回拨，本次重置的快照也占一个保留名额。
        if [[ $day == "$today" ]]; then
            history_limit=$((history_limit - 1))
            continue
        fi
        snapshots+=("$snapshot")
    done
    for ((i=0; i<${#snapshots[@]}-history_limit; i++)); do
        snapshot=${snapshots[i]}
        (
            # 固定工作目录，删除前再检查一次；保留同时写入的其他文件。
            cd -P -- "$snapshot"
            [[ ! -L $snapshot && . -ef $snapshot ]] || exit 0
            is_managed_snapshot . || exit 0
            pref_file=preferences.json
            if [[ ! -f $pref_file ]]; then pref_file=preferences.absent; fi
            local -a members=(settings.dconf "$pref_file")
            if [[ -f checksums.sha256 ]]; then members+=(checksums.sha256); fi
            rm -- "${members[@]}"
            rmdir --ignore-fail-on-non-empty -- "$snapshot"
        )
    done
)

if [[ $mode == preview ]]; then
    today=$(date +%F)
    printf '日期 %s\ndconf %s\n文件 %s\n锁文件 %s\n备份目录 %s\n' \
        "$today" "$dconf_dir" "$prefs" "$prefs.lock" "$state_dir/backups"
    if already_done; then echo "今天已处理。"; fi
    if [[ ! -d $config_dir ]]; then echo "找不到此配置目录，运行时将跳过。"; fi
    exit 0
fi

mkdir -p -- "$state_dir"
exec 9>"$state_dir/lock"
# 旧版也使用同一把锁，跨版本的并发登录仍然互斥。
flock -x 9
today=$(date +%F)
if [[ $mode == daily ]] && already_done; then
    prune_backups
    exit 0
fi

log() {
    printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "$state_dir/run.log"
}

fail() { log "$*" >&2; exit 1; }

if [[ $mode == daily && ! -d $config_dir ]]; then
    log "跳过，配置目录不存在: $config_dir"; exit 0
fi
for tool in pgrep dconf; do
    command -v "$tool" >/dev/null || fail "缺少依赖: $tool"
done
# 初次检查避免无用备份，耗时准备结束后在写入前再检查一次。
require_navicat_closed() {
    if pgrep -r R,S,D,T,t,I -iu "$EUID" '^(navicat$|navicat[0-9]|navicat[ ._-]?premium|navicat\.appimag)' >/dev/null; then
        if [[ $mode == restore ]]; then fail "请先关闭 Navicat，再执行恢复。"; fi
        log "跳过，Navicat 正在运行。"; exit 0
    elif [[ $? != 1 ]]; then
        fail "无法检查 Navicat 进程。"
    fi
}
require_navicat_closed

if [[ $mode == daily && -d $backup_root/$today ]] &&
    [[ ! -f $retry_stamp || $(<"$retry_stamp") != "$today" ]]; then
    log "跳过，已有 $today 的快照且无待重试记录；保留当前设置。"
    prune_backups
    exit 0
fi
archive_previous_success

if [[ -L $prefs || ( -e $prefs && ! -f $prefs ) ]]; then fail "偏好文件不是普通文件: $prefs"; fi
if [[ -d $prefs.lock ]]; then fail "预期的锁文件是目录: $prefs.lock"; fi

# dconf dump 会合并所有数据库。只读写入层，避免把管理员的默认值存进用户备份。
write_user_profile() {
    local destination=$1 profile= name=${DCONF_PROFILE-user} path line source= mandatory=false
    local -a dirs
    if [[ -r /run/dconf/user/$UID ]]; then
        profile="/run/dconf/user/$UID"
        mandatory=true
    elif [[ -z ${DCONF_PROFILE+x} && -r ${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/dconf/profile ]]; then
        profile="${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/dconf/profile"
    elif [[ $name == /* ]]; then
        profile=$name
    else
        IFS=: read -ra dirs <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
        for path in /etc "${dirs[@]}"; do
            if [[ -e $path/dconf/profile/$name ]]; then profile="$path/dconf/profile/$name"; break; fi
        done
    fi
    if [[ -z $profile && -z ${DCONF_PROFILE+x} ]]; then
        printf '%s\n' user-db:user > "$destination"
        return
    fi
    [[ -n $profile && -f $profile && -r $profile ]] || fail "无法读取 dconf profile: $name"
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%%#*}
        if [[ $line =~ ^[[:space:]]*$ ]]; then continue; fi
        if [[ -n $source ]]; then
            # 强制 profile 优先于 DCONF_PROFILE，CLI 无法隔离它的多层数据。
            fail "当前 dconf 强制 profile 含多层配置，无法单独导出用户层。"
        fi
        if [[ $line =~ ^[[:space:]]*((user-db:|service-db:)[^[:space:]]+)[[:space:]]*$ ]]; then
            source=${BASH_REMATCH[1]}
            if [[ $mandatory == true ]]; then continue; fi
        fi
        break
    done < "$profile"
    [[ -n $source ]] || fail "无法识别 dconf 的可写用户层: $profile"
    printf '%s\n' "$source" > "$destination"
}

snapshot_checksums() (
    cd -- "$1" || exit 1
    sha256sum -- settings.dconf "$2"
)

dump_user_settings() {
    # dconf 某些版本忽略 stdout 的写错误；负责落盘的 cat 会报告空间不足。
    DCONF_PROFILE="$work/user.profile" dconf dump "$dconf_dir" 2> "$work/dump.errors" | cat > "$1" ||
        { cat -- "$work/dump.errors" >&2; fail "无法完整导出 dconf。"; }
    if [[ -s $work/dump.errors ]]; then
        cat -- "$work/dump.errors" >&2
        fail "dconf 导出报告异常，已停止操作。"
    fi
}

capture_current() {
    local dest=$1 member=preferences.absent
    dump_user_settings "$dest/settings.dconf"
    if [[ -f $prefs ]]; then
        member=preferences.json
        cp -- "$prefs" "$dest/$member"
        cmp -s -- "$prefs" "$dest/$member" || fail "备份期间偏好文件发生变化。"
    else
        touch -- "$dest/$member"
    fi
    snapshot_checksums "$dest" "$member" > "$dest/checksums.sha256"
}

# 失败后应用可能已重新写入设置。只重试仍等于原备份、或已被上次操作清除的内容。
check_retry_inputs() {
    local snapshot=$1
    if [[ -f $prefs ]] && ! cmp -s -- "$prefs" "$snapshot/preferences.json"; then
        fail "偏好文件在上次重置失败后已改变，已保留当前设置和原快照。"
    fi
    dump_user_settings "$work/retry.dconf"
    if [[ -s $work/retry.dconf ]] && ! cmp -s -- "$work/retry.dconf" "$snapshot/settings.dconf"; then
        fail "dconf 在上次重置失败后已改变，已保留当前设置和原快照。"
    fi
}

inspect_snapshot() {
    local dir=$1
    [[ -d $dir && ! -L $dir && -f $dir/settings.dconf && ! -L $dir/settings.dconf ]] ||
        fail "找不到完整的备份: $dir"
    [[ ! -L $dir/preferences.json && ! -L $dir/preferences.absent && ! -L $dir/checksums.sha256 ]] ||
        fail "备份中含有符号链接: $dir"
    if [[ -f $dir/preferences.json && ! -e $dir/preferences.absent ]]; then
        pref_member=preferences.json
    elif [[ -f $dir/preferences.absent && ! -s $dir/preferences.absent && ! -e $dir/preferences.json ]]; then
        pref_member=preferences.absent
    else
        fail "备份中的偏好文件记录不完整: $dir"
    fi
    if [[ -e $dir/checksums.sha256 ]]; then
        [[ -f $dir/checksums.sha256 ]] || fail "备份校验文件不正确: $dir"
        snapshot_checksums "$dir" "$pref_member" | cmp -s -- "$dir/checksums.sha256" - ||
            fail "备份完整性校验失败: $dir"
    fi
}

validate_dump() {
    # compile 使用与 load 相同的 keyfile 和 GVariant 解析器，不改动会话数据库。
    mkdir -p -- "$work/input"
    cat -- "$1" > "$work/input/settings.dconf"
    dconf compile "$work/validated.db" "$work/input"
}

replace_dconf() {
    dconf reset -f "$dconf_dir" || return 1
    # 兼容旧备份内的锁定项，以及快照后新加的系统策略。
    [[ ! -s $1 ]] || dconf load -f "$dconf_dir" < "$1"
}

rollback_restore() {
    local ok=true
    replace_dconf "$work/before/settings.dconf" || ok=false
    if [[ -f $work/before/preferences.json ]]; then
        [[ -n $staging ]] && cp -- "$work/before/preferences.json" "$staging/rollback.json" &&
            mv -fT -- "$staging/rollback.json" "$prefs" || ok=false
    else
        rm -f -- "$prefs" || ok=false
    fi
    if [[ -n $staging && ( -e $staging/previous.lock || -L $staging/previous.lock ) ]]; then
        mv -fT -- "$staging/previous.lock" "$prefs.lock" || ok=false
    fi
    [[ $ok == true ]]
}

staging=
work=
restore_armed=false
created_dirs=()
clean_up() {
    local status=$?
    trap - EXIT
    trap '' HUP INT TERM
    if [[ $restore_armed == true ]]; then
        if rollback_restore; then
            log "已回滚到本次恢复前的配置。" >&2 || :
        else
            log "自动回滚失败，恢复前备份保留在 $work/before，临时文件位于 $staging。" >&2 || :
            exit 1
        fi
    fi
    if [[ -n $staging ]]; then rm -rf -- "$staging" || :; fi
    if [[ -n $work ]]; then rm -rf -- "$work" || :; fi
    if (( status != 0 )); then
        if (( ${#created_dirs[@]} )); then rmdir --ignore-fail-on-non-empty -- "${created_dirs[@]}" || :; fi
        log "操作失败（退出码 $status），可在修复后重试。" >&2
    fi
    exit "$status"
}
trap clean_up EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

work=$(mktemp -d -- "$state_dir/.${mode}-work.XXXXXXXX")
write_user_profile "$work/user.profile"

if [[ $mode == daily ]]; then
    snapshot="$backup_root/$today"
    # 当天第一次操作前发布完整快照；失败重试始终保留最初的备份。
    if [[ ! -d $snapshot ]]; then
        mkdir -p -- "$backup_root"
        staging=$(mktemp -d -- "$backup_root/.pending.XXXXXXXX")
        capture_current "$staging"
        inspect_snapshot "$staging"
        validate_dump "$staging/settings.dconf"
        printf '%s\n' "$today" > "$work/retry-date"
        require_navicat_closed
        mv -fT -- "$work/retry-date" "$retry_stamp"
        mv -T -- "$staging" "$snapshot"
        staging=
    else
        inspect_snapshot "$snapshot"
        validate_dump "$snapshot/settings.dconf"
        check_retry_inputs "$snapshot"
        require_navicat_closed
    fi
    dconf reset -f "$dconf_dir"
    rm -f -- "$prefs" "$prefs.lock"
    result="已重置，备份保存在 $snapshot"
else
    snapshot="$backup_root/$2"
    inspect_snapshot "$snapshot"
    mkdir -- "$work/target" "$work/before"
    cp -- "$snapshot/settings.dconf" "$snapshot/$pref_member" "$work/target/"
    if [[ -f $snapshot/checksums.sha256 ]]; then
        cp -- "$snapshot/checksums.sha256" "$work/target/"
    fi
    inspect_snapshot "$work/target"
    validate_dump "$work/target/settings.dconf"

    capture_current "$work/before"
    inspect_snapshot "$work/before"
    validate_dump "$work/before/settings.dconf"
    if [[ -f $work/target/preferences.json || -d $config_dir ]]; then
        if [[ ! -d $config_dir ]]; then
            mkdir -p -- "$XDG_CONFIG_HOME"
            for dir in "${config_dir%/*}" "$config_dir"; do
                if [[ ! -d $dir ]]; then
                    mkdir -- "$dir"
                    created_dirs=("$dir" "${created_dirs[@]}")
                fi
            done
        fi
        staging=$(mktemp -d -- "$config_dir/.navicat-restore.XXXXXXXX")
        if [[ -f $work/target/preferences.json ]]; then
            cp -- "$work/target/preferences.json" "$staging/preferences.json"
        fi
    fi
    require_navicat_closed
    restore_armed=true
    replace_dconf "$work/target/settings.dconf"
    if [[ -f $work/target/preferences.json ]]; then
        mv -fT -- "$staging/preferences.json" "$prefs"
    else
        rm -f -- "$prefs"
    fi
    if [[ -e $prefs.lock || -L $prefs.lock ]]; then
        [[ -n $staging ]] || fail "恢复期间配置目录发生变化。"
        mv -fT -- "$prefs.lock" "$staging/previous.lock"
    fi
    result="已恢复 $2 的备份，今天再次登录会跳过重置。"
fi

printf '%s\n' "$today" > "$work/success-date"
# 让原子重命名与撤销回滚标志之间也具有一致的中断语义。
trap '' HUP INT TERM
mv -fT -- "$work/success-date" "$stamp"
restore_armed=false
trap - HUP INT TERM
log "$result"
if [[ $mode == daily ]]; then prune_backups; fi
