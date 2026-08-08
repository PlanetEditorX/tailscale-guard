#!/bin/bash
# tailscale-guard 守护进程 — 哨兵探测 + Tailscale 自启停
# 状态机: idle(10min监测) -> retry(3min累计) -> start -> active(10min监测) -> stop -> idle

PKG_VAR="/vol1/@appdata/tailscale-guard"
TS_MAIN="/var/apps/tailscale/cmd/main"
TS_CLI="/vol1/@appcenter/tailscale/bin/tailscale"
TS_SOCK="/vol1/@appdata/tailscale/tailscaled.sock"
CONF="${PKG_VAR}/guard.conf"
STATE="${PKG_VAR}/state.json"
LOG="${PKG_VAR}/guard.log"

export TRIM_PKGVAR="/vol1/@appdata/tailscale"
export TRIM_APPDEST="/vol1/@appcenter/tailscale"
export TRIM_PKGNAME="tailscale"

logmsg() { echo "$(date '+%Y-%m-%d %H:%M:%S') [guard] $1" >> "${LOG}"; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

load_conf() {
    # 默认值
    SENTINELS=""
    NORMAL_INTERVAL=600
    RETRY_INTERVAL=180
    START_THRESHOLD=3
    START_CONDITION="all_offline"
    STOP_THRESHOLD=1
    STOP_CONDITION="any_online"
    EFFECTIVE_TIME=""
    LAN_IFACE="enp6s18"
    SUBNET="192.168.1.0/24"
    [ -f "${CONF}" ] && source "${CONF}" 2>/dev/null
}

ts_running() { bash "${TS_MAIN}" status >/dev/null 2>&1; }
ts_start()  { logmsg "动作: 启动 Tailscale"; bash "${TS_MAIN}" start >>"${LOG}" 2>&1; }
ts_stop()   { logmsg "动作: 停止 Tailscale"; bash "${TS_MAIN}" stop >>"${LOG}" 2>&1; }

probe_ip() {
    # ICMP ping：放宽超时与包数，容忍首包丢/设备休眠唤醒
    ping -c4 -W2 "$1" >/dev/null 2>&1 && return 0
    # ARP 表兜底：触发解析后查 /proc/net/arp
    #    Flags 含 0x2 (ATF_COM, complete) 即表示 MAC 已解析 → 设备在线
    ping -c1 -W1 -b 192.168.1.255 >/dev/null 2>&1
    local flags
    flags=$(awk -v ip="$1" '$1==ip{print $3; exit}' /proc/net/arp 2>/dev/null)
    case "$flags" in
        *2*) return 0 ;;   # 0x2 或更高位含 0x2 → complete
    esac
    # arping 末道
    arping -c2 -w3 "$1" >/dev/null 2>&1 && return 0
    return 1
}

probe_mac() {
    local mac="$1" iface="${LAN_IFACE}"
    ping -c1 -W1 -b 192.168.1.255 >/dev/null 2>&1
    ( arp -n 2>/dev/null; cat /proc/net/arp 2>/dev/null ) | grep -i "$mac" >/dev/null 2>&1 && return 0
    return 1
}

probe_one() {
    local d="$1"
    if [[ "$d" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        probe_ip "$d" && return 0 || return 1
    elif [[ "$d" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        probe_mac "$d" && return 0 || return 1
    fi
    return 1
}

probe_all() {
    any_online=0; all_online=1
    sentinel_states=""
    local IFS=','
    for d in ${SENTINELS}; do
        [ -z "$d" ] && continue
        d=$(echo "$d" | xargs)
        [ -z "$d" ] && continue
        if probe_one "$d"; then
            any_online=1; st="online"
        else
            all_online=0; st="offline"
        fi
        sentinel_states="${sentinel_states}{\"device\":\"$(json_escape "$d")\",\"status\":\"$st\"},"
    done
    sentinel_states="${sentinel_states%,}"
    sentinel_states="[${sentinel_states}]"
}

cond_met() {
    # $1=condition  全局 any_online all_online
    case "$1" in
        all_offline) [ $any_online -eq 0 ] ;;
        any_offline) [ $all_online -eq 0 ] ;;
        all_online)  [ $all_online -eq 1 ] ;;
        any_online)  [ $any_online -eq 1 ] ;;
        *) return 1 ;;
    esac
}

in_effective_window() {
    [ -z "$EFFECTIVE_TIME" ] && return 0
    local now start end cur
    now=$(date +%H%M)
    start=$(echo "$EFFECTIVE_TIME" | cut -d- -f1 | tr -d ':' )
    end=$(echo "$EFFECTIVE_TIME" | cut -d- -f2 | tr -d ':')
    [ -z "$start" ] || [ -z "$end" ] && return 0
    cur=$now
    if [ "$start" -le "$end" ]; then
        [ "$cur" -ge "$start" ] && [ "$cur" -lt "$end" ] && return 0 || return 1
    else
        { [ "$cur" -ge "$start" ] || [ "$cur" -lt "$end" ]; } && return 0 || return 1
    fi
}

write_state() {
    # $1 phase $2 last_action
    local phase="$1" action="$2"
    local ts_status="stopped"
    ts_running && ts_status="running"
    cat > "${STATE}" <<JSON
{
  "phase": "${phase}",
  "tailscale": "${ts_status}",
  "start_hits": ${start_hits:-0},
  "stop_hits": ${stop_hits:-0},
  "sentinels": ${sentinel_states:-[]},
  "any_online": ${any_online:-0},
  "all_online": ${all_online:-1},
  "last_action": "$(json_escape "${action:-}")",
  "last_probe": "$(date '+%Y-%m-%d %H:%M:%S')",
  "ts_running_check": "$(date '+%Y-%m-%d %H:%M:%S')",
  "effective": "$(in_effective_window && echo yes || echo no)"
}
JSON
}

sleep_guard() {
    local secs="$1"
    local i=0
    while [ $i -lt $secs ]; do
        sleep 1; i=$((i+1))
        [ "$RELOAD_NOW" = "1" ] && { RELOAD_NOW=0; return 0; }
    done
}

trap 'logmsg "guard received TERM, exiting"; exit 0' TERM
trap 'logmsg "guard received USR1, reloading config"; RELOAD_NOW=1' USR1

logmsg "=== guard started (pid=$$) ==="
phase="idle"
start_hits=0
stop_hits=0

while true; do
    load_conf
    if ! in_effective_window; then
        logmsg "当前在生效时间段外 (${EFFECTIVE_TIME:-全天})，保持现状不动"
        write_state "paused" "none"
        sleep_guard "$NORMAL_INTERVAL"
        continue
    fi

    probe_all
    logmsg "探测完成: any_online=$any_online all_online=$all_online phase=$phase start_hits=$start_hits stop_hits=$stop_hits"

    case "$phase" in
        idle)
            if cond_met "$START_CONDITION"; then
                start_hits=1
                if [ $start_hits -ge "$START_THRESHOLD" ]; then
                    ts_running || ts_start
                    phase="active"; stop_hits=0
                    write_state "active" "start"
                else
                    phase="retry"
                    write_state "retry" "none"
                fi
            else
                start_hits=0
                write_state "idle" "none"
            fi
            ;;
        retry)
            if cond_met "$START_CONDITION"; then
                start_hits=$((start_hits+1))
                if [ $start_hits -ge "$START_THRESHOLD" ]; then
                    ts_running || ts_start
                    phase="active"; start_hits=0; stop_hits=0
                    write_state "active" "start"
                else
                    write_state "retry" "none"
                fi
            else
                logmsg "重试中断：启动条件不再满足，回到 idle"
                phase="idle"; start_hits=0
                write_state "idle" "none"
            fi
            ;;
        active)
            if cond_met "$STOP_CONDITION"; then
                stop_hits=$((stop_hits+1))
                if [ $stop_hits -ge "$STOP_THRESHOLD" ]; then
                    ts_running && ts_stop
                    phase="idle"; stop_hits=0; start_hits=0
                    write_state "idle" "stop"
                else
                    write_state "active" "none"
                fi
            else
                stop_hits=0
                write_state "active" "none"
            fi
            ;;
    esac

    if [ "$phase" = "retry" ]; then
        sleep_guard "$RETRY_INTERVAL"
    else
        sleep_guard "$NORMAL_INTERVAL"
    fi
done