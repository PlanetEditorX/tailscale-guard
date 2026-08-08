#!/bin/bash
# =============================================================================
# tailscale-guard 守护进程 — 哨兵探测 + Tailscale 自动启停
# =============================================================================
# 用途：
#   监控局域网内"哨兵设备"（手机/平板等随身设备）的在线状态，从而推断主人
#   是否在家，据此自动启停 Tailscale：
#     - 哨兵全部离线 → 推断已出门 → 自动启动 Tailscale，便于外部远程访问 NAS
#     - 哨兵恢复在线 → 推断已回家 → 自动停止 Tailscale，减少对外暴露面
#
# 状态机（phase）：
#   idle   (正常态，每 NORMAL_INTERVAL 秒探测一次)
#     └─ 首次满足"启动条件"但未达阈值  → retry（快速复测）
#     └─ 连续 START_THRESHOLD 次满足   → 启动 TS → active
#   retry  (可疑离线态，每 RETRY_INTERVAL 秒快速复测)
#     └─ 累计满足 START_THRESHOLD 次   → 启动 TS → active
#     └─ 中途条件不再满足              → 回到 idle
#   active (Tailscale 已启动，每 NORMAL_INTERVAL 秒探测一次)
#     └─ 连续 STOP_THRESHOLD 次满足"停止条件" → 停止 TS → idle
#
# 信号：
#   TERM —— 退出守护进程；USR1 —— 立即重载配置并提前结束本轮休眠
# =============================================================================

# ---- 路径常量（fnOS 安装后的固定路径）----
PKG_VAR="/vol1/@appdata/tailscale-guard"            # 数据目录：配置/状态/日志/PID
TS_MAIN="/var/apps/tailscale/cmd/main"              # Tailscale 应用的启停入口
TS_CLI="/vol1/@appcenter/tailscale/bin/tailscale"   # Tailscale 命令行工具
TS_SOCK="/vol1/@appdata/tailscale/tailscaled.sock"  # tailscaled 控制 socket
CONF="${PKG_VAR}/guard.conf"                        # 配置文件（key=value，可被 source）
STATE="${PKG_VAR}/state.json"                       # 状态文件（供 Web UI 轮询读取）
LOG="${PKG_VAR}/guard.log"                          # 日志文件
HISTORY="${PKG_VAR}/history.log"                    # 历史记录（折线图数据源）

# 导出环境变量：让被调用的 Tailscale 应用脚本定位到自己的数据/安装目录
export TRIM_PKGVAR="/vol1/@appdata/tailscale"
export TRIM_APPDEST="/vol1/@appcenter/tailscale"
export TRIM_PKGNAME="tailscale"

# ---- 工具函数 ----
# 追加一行带时间戳的日志
logmsg() { echo "$(date '+%Y-%m-%d %H:%M:%S') [guard] $1" >> "${LOG}"; }

# 转义 JSON 特殊字符（反斜杠/双引号），用于安全嵌入状态文件
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# ---- 配置 ----
# 读取 guard.conf 到全局变量；文件缺失或字段缺失时用默认值兜底
load_conf() {
    # 默认值
    SENTINELS=""                  # 哨兵设备列表，逗号分隔（IP 或 MAC）
    NORMAL_INTERVAL=600           # 正常态探测间隔（秒）
    RETRY_INTERVAL=180            # 可疑态复测间隔（秒）
    START_THRESHOLD=3             # 启动 Tailscale 所需连续离线次数
    START_CONDITION="all_offline" # 启动条件：all/any _ offline/online
    STOP_THRESHOLD=1              # 停止 Tailscale 所需连续在线次数
    STOP_CONDITION="any_online"   # 停止条件
    EFFECTIVE_TIME=""             # 生效时段 "HHMM-HHMM"，留空=全天
    LAN_IFACE="enp6s18"           # 局域网网卡（ARP 探测用）
    SUBNET="192.168.1.0/24"       # 局域网网段（广播 ping 用）
    [ -f "${CONF}" ] && source "${CONF}" 2>/dev/null
}

# ---- Tailscale 控制 ----
ts_running() { bash "${TS_MAIN}" status >/dev/null 2>&1; }          # 是否运行中
ts_start()  { logmsg "动作: 启动 Tailscale"; bash "${TS_MAIN}" start >>"${LOG}" 2>&1; }  # 启动
ts_stop()   { logmsg "动作: 停止 Tailscale"; bash "${TS_MAIN}" stop >>"${LOG}" 2>&1; }   # 停止

# ---- 设备探测 ----
# 按 IP 探测设备是否在线（三道检测，逐级兜底）：
#   1) ICMP ping：放宽包数与超时，容忍首包丢失/设备休眠唤醒
#   2) ARP 表兜底：广播 ping 触发 ARP 解析后查 /proc/net/arp，
#      Flags 含 0x2(ATF_COM, complete) 即 MAC 已解析 → 设备在线
#   3) arping 末道：直接发送 ARP 请求确认
probe_ip() {
    ping -c4 -W2 "$1" >/dev/null 2>&1 && return 0
    ping -c1 -W1 -b 192.168.1.255 >/dev/null 2>&1   # 广播 ping 刷新 ARP 表
    local flags
    flags=$(awk -v ip="$1" '$1==ip{print $3; exit}' /proc/net/arp 2>/dev/null)
    case "$flags" in
        *2*) return 0 ;;   # 0x2 或更高位含 0x2 → ARP complete
    esac
    arping -c2 -w3 "$1" >/dev/null 2>&1 && return 0
    return 1
}

# 按 MAC 地址探测：先广播 ping 刷新 ARP 表，再在表内查找该 MAC 是否存在
probe_mac() {
    local mac="$1" iface="${LAN_IFACE}"
    ping -c1 -W1 -b 192.168.1.255 >/dev/null 2>&1
    ( arp -n 2>/dev/null; cat /proc/net/arp 2>/dev/null ) | grep -i "$mac" >/dev/null 2>&1 && return 0
    return 1
}

# 探测单个哨兵：自动识别 IP 或 MAC 格式，走对应探测函数
probe_one() {
    local d="$1"
    if [[ "$d" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then        # IPv4 格式
        probe_ip "$d" && return 0 || return 1
    elif [[ "$d" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then  # MAC 格式
        probe_mac "$d" && return 0 || return 1
    fi
    return 1
}

# 探测全部哨兵，把结果汇总到全局变量：
#   any_online        —— 是否存在任一设备在线（1/0）
#   all_online        —— 是否全部设备在线（1/0）
#   online_count      —— 当前在线设备数量（折线图用）
#   total_count       —— 哨兵设备总数（折线图用）
#   sentinel_states   —— 每台设备的 JSON 数组字符串（供状态文件使用）
probe_all() {
    any_online=0; all_online=1; online_count=0; total_count=0
    sentinel_states=""
    local IFS=','
    for d in ${SENTINELS}; do
        [ -z "$d" ] && continue
        d=$(echo "$d" | xargs)     # 去除首尾空格
        [ -z "$d" ] && continue
        total_count=$((total_count+1))
        if probe_one "$d"; then
            any_online=1; online_count=$((online_count+1)); st="online"
        else
            all_online=0; st="offline"
        fi
        sentinel_states="${sentinel_states}{\"device\":\"$(json_escape "$d")\",\"status\":\"$st\"},"
    done
    sentinel_states="${sentinel_states%,}"   # 去掉末尾逗号
    sentinel_states="[${sentinel_states}]"
}

# 判断条件是否满足；$1=条件名，读取全局 any_online/all_online
cond_met() {
    case "$1" in
        all_offline) [ $any_online -eq 0 ] ;;   # 全部离线
        any_offline) [ $all_online -eq 0 ] ;;   # 任一离线
        all_online)  [ $all_online -eq 1 ] ;;   # 全部在线
        any_online)  [ $any_online -eq 1 ] ;;   # 任一在线
        *) return 1 ;;
    esac
}

# 当前是否处于生效时段内；EFFECTIVE_TIME 为空则全天生效。
# 支持跨天时段（如 23:00-06:00，即 start > end 时按"或"逻辑判断）。
in_effective_window() {
    [ -z "$EFFECTIVE_TIME" ] && return 0
    local now start end cur
    now=$(date +%H%M)
    start=$(echo "$EFFECTIVE_TIME" | cut -d- -f1 | tr -d ':' )
    end=$(echo "$EFFECTIVE_TIME" | cut -d- -f2 | tr -d ':')
    [ -z "$start" ] || [ -z "$end" ] && return 0
    cur=$now
    if [ "$start" -le "$end" ]; then
        # 同一天内：start <= cur < end
        [ "$cur" -ge "$start" ] && [ "$cur" -lt "$end" ] && return 0 || return 1
    else
        # 跨天（如 23:00-06:00）：cur >= start 或 cur < end 都算生效
        { [ "$cur" -ge "$start" ] || [ "$cur" -lt "$end" ]; } && return 0 || return 1
    fi
}

# 把当前运行状态写入 state.json，供 Web UI 轮询展示
#   $1 phase        当前状态机阶段
#   $2 last_action  最近一次实际执行的启停动作（start/stop/none）
write_state() {
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

# 追加一条历史记录：时间戳,在线设备数,设备总数,Tailscale状态(1运行/0停止)
# 只保留最近 720 条（默认 10 分钟间隔 ≈ 5 天）
write_history() {
    local ts=0
    ts_running && ts=1
    { tail -n 719 "${HISTORY}" 2>/dev/null; printf '%s,%s,%s,%s\n' "$(date +%s)" "${online_count:-0}" "${total_count:-0}" "$ts"; } \
        > "${HISTORY}.tmp" && mv "${HISTORY}.tmp" "${HISTORY}"
}

# 分段睡眠：每 1 秒检查一次 RELOAD_NOW 标志，收到 USR1 信号时立即提前返回
sleep_guard() {
    local secs="$1"
    local i=0
    while [ $i -lt $secs ]; do
        sleep 1; i=$((i+1))
        [ "$RELOAD_NOW" = "1" ] && { RELOAD_NOW=0; return 0; }
    done
}

# ---- 信号处理 ----
trap 'logmsg "guard received TERM, exiting"; exit 0' TERM                    # 停止守护
trap 'logmsg "guard received USR1, reloading config"; RELOAD_NOW=1' USR1     # 重载配置

# ---- 主循环 ----
logmsg "=== guard started (pid=$$) ==="
phase="idle"        # 初始阶段：正常探测
start_hits=0        # 已累计满足"启动条件"的次数
stop_hits=0         # 已累计满足"停止条件"的次数

while true; do
    load_conf   # 每轮重新读配置，保证改动即时生效（配合 USR1 提前唤醒）

    # 生效时段外：不探测也不动 Tailscale，保持现状
    if ! in_effective_window; then
        logmsg "当前在生效时间段外 (${EFFECTIVE_TIME:-全天})，保持现状不动"
        write_state "paused" "none"
        sleep_guard "$NORMAL_INTERVAL"
        continue
    fi

    probe_all
    logmsg "探测完成: any_online=$any_online all_online=$all_online phase=$phase start_hits=$start_hits stop_hits=$stop_hits"
    write_history

    # 状态机转换
    case "$phase" in
        idle)
            # 空闲态：满足启动条件则计数，达阈值立即启动，否则进入快速复测
            if cond_met "$START_CONDITION"; then
                start_hits=1
                if [ $start_hits -ge "$START_THRESHOLD" ]; then
                    # 阈值=1（默认不允许）或已达标时直接启动
                    ts_running || ts_start
                    phase="active"; stop_hits=0
                    write_state "active" "start"
                else
                    # 首次命中但未达阈值 → 进入 retry 快速复测
                    phase="retry"
                    write_state "retry" "none"
                fi
            else
                start_hits=0
                write_state "idle" "none"
            fi
            ;;
        retry)
            # 重试态：累计命中达阈值则启动；中途条件失效则放弃回 idle
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
            # 活动态：满足停止条件则计数，达阈值后停止 Tailscale 回 idle
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

    # 重试态用较短间隔快速复测，其余阶段用正常间隔
    if [ "$phase" = "retry" ]; then
        sleep_guard "$RETRY_INTERVAL"
    else
        sleep_guard "$NORMAL_INTERVAL"
    fi
done
