#!/bin/bash
# =============================================================================
# tailscale-guard Web UI CGI
# 由 fnOS 内置 Web 服务器以 CGI 方式调用。
# 职责：
#   1) 提供 /api/* JSON 接口 —— 状态、日志、配置读写、启停动作
#   2) 路由 /www/* 下的静态文件（index.html 等）
# 路径约定：URL 形如 /cgi/ThirdParty/tailscale-guard/index.cgi/路径
# =============================================================================

APP=tailscale-guard
PKG_VAR="/vol1/@appdata/${APP}"        # 数据目录
APP_DEST="/vol1/@appcenter/${APP}"     # 应用安装目录
WWW="${APP_DEST}/www"                  # 静态资源目录
CONF="${PKG_VAR}/guard.conf"           # 配置文件
STATE="${PKG_VAR}/state.json"          # 状态文件
LOG="${PKG_VAR}/guard.log"             # 日志文件
KEEPALIVE="${PKG_VAR}/.reload"         # 触发重载的占位文件
GUARD_PID="${PKG_VAR}/guard.pid"       # 守护进程 PID 文件

# 从 REQUEST_URI 提取 index.cgi 之后的部分作为相对路径（默认首页）
URI_NO_QUERY="${REQUEST_URI%%\?*}"
REL_PATH="/"
case "$URI_NO_QUERY" in
    *index.cgi*) REL_PATH="${URI_NO_QUERY#*index.cgi}" ;;
esac
[ -z "$REL_PATH" ] || [ "$REL_PATH" = "/" ] && REL_PATH="/index.html"

# ---- CGI 辅助函数 ----
header()  { echo "Content-Type: $1"; echo ""; }               # 输出响应头
json_ok() { header "application/json; charset=utf-8"; printf '%s' "$1"; exit 0; }  # 返回 JSON 并结束
err()     { header "application/json; charset=utf-8"; printf '{"error":"%s"}' "$1"; exit 0; }  # 返回错误并结束
# 手动动作记录（写入 guard.log 供用户追踪）
action_log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [action] $1" >> "${PKG_VAR}/guard.log"; }

# ---- 通过 fnOS 应用中心 API 启停 Tailscale ----
# 应用中心的状态只认它自己的 API 操作，直接启动进程会导致状态不同步，
# 因此这里调用应用中心接口；token 取自浏览器 cookie(fnos-token)并持久化，
# 供后台守护进程复用。API 失败时回退为直接操作进程（功能保底）。
#   $1 = start|stop
ts_control() {
    local op="$1" token resp
    token=$(echo "${HTTP_COOKIE:-}" | tr ';' '\n' | sed -n 's/^ *fnos-token=//p')
    if [ -n "$token" ]; then
        # 持久化 token：守护进程自动启停时复用
        printf '%s' "$token" > "${PKG_VAR}/.fnos_token"
        resp=$(curl -s -m 30 -X POST \
            -H "authorization: trim ${token}" \
            -H 'Content-Type: application/json' \
            -d "{\"appName\":\"tailscale\",\"ignoreDependencies\":true,\"language\":\"zh-CN\"}" \
            "http://127.0.0.1:5666/app-center/v1/${op}/start" 2>/dev/null)
        if echo "$resp" | grep -q '"code":0'; then
            action_log "应用中心 API 执行 ${op} 成功"
            return 0
        fi
        action_log "应用中心 API 执行 ${op} 失败，回退直接操作进程"
    fi
    TRIM_PKGVAR=/vol1/@appdata/tailscale TRIM_APPDEST=/vol1/@appcenter/tailscale \
        bash /var/apps/tailscale/cmd/main "$op" >>"${PKG_VAR}/guard.log" 2>&1
}

# ---- API 端点 ----
case "$REL_PATH" in
# 运行状态：直接返回守护进程写入的 state.json
/api/state)
    json_ok "$(cat "${STATE}" 2>/dev/null || echo '{}')"
    ;;

# 日志：返回 JSON 字符串，携带转义后的最近 N 行
/api/log)
    header "application/json; charset=utf-8"
    lines="${QUERY_STRING#lines=}"
    [ -z "$lines" ] && lines=200
    [ "$lines" = "$QUERY_STRING" ] && lines=200
    data=$(tail -n "$lines" "${LOG}" 2>/dev/null)
    # 转义反斜杠/引号/换行，保证 JSON 合法
    esc=$(printf '%s' "$data" | sed 's/\\/\\\\/g; s/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    printf '{"log":"%s"}' "$esc"
    exit 0
    ;;

# 配置读写
/api/config)
    if [ "$REQUEST_METHOD" = "POST" ]; then
        # ---- 保存配置 ----
        # body 为 URL 编码的 name=value&name=value 形式
        body=$(cat 2>/dev/null)
        tmp="${PKG_VAR}/.config.new"
        : > "$tmp"
        IFS='&'
        for kv in $body; do
            k=$(printf '%s' "$kv" | cut -d= -f1)
            v=$(printf '%s' "$kv" | cut -d= -f2- | sed 's/+/ /g; s/%0D//g; s/%0A/\n/g')
            # 只允许写入白名单字段，防止注入
            case "$k" in
                SENTINELS|NORMAL_INTERVAL|RETRY_INTERVAL|START_THRESHOLD|START_CONDITION|STOP_THRESHOLD|STOP_CONDITION|EFFECTIVE_TIME|LAN_IFACE|HISTORY_KEEP)
                    printf '%s=%s\n' "$k" "$v" >> "$tmp"
                    ;;
            esac
        done
        unset IFS
        mv "$tmp" "$CONF"
        # 通知守护进程重载：touch 占位文件 + 发送 USR1 信号
        touch "$KEEPALIVE"
        [ -f "$GUARD_PID" ] && kill -USR1 "$(head -n1 "$GUARD_PID" | tr -d '[:space:]')" 2>/dev/null
        json_ok '{"ok":true}'
    else
        # ---- 读取配置：key=value 逐行转成 JSON 对象 ----
        header "application/json; charset=utf-8"
        echo "{"
        first=1
        while IFS='=' read -r k v; do
            [ -z "$k" ] && continue
            [ $first -eq 0 ] && echo ","
            printf '"%s":"%s"' "$k" "$v"
            first=0
        done < "${CONF}" 2>/dev/null
        echo ""
        echo "}"
    fi
    exit 0
    ;;

# 历史趋势：返回 history.log 全部记录（保留时长由守护进程控制），供折线图使用
# 每行格式: 时间戳,在线设备数,设备总数,Tailscale状态(1运行/0停止)
/api/history)
    header "application/json; charset=utf-8"
    { echo '{"history":['; cat "${PKG_VAR}/history.log" 2>/dev/null | awk -F, 'NR>1{printf ","}{printf "{\"t\":%s,\"online\":%s,\"total\":%s,\"ts\":%s}", $1,$2,$3,$4}'; echo ']}'; }
    exit 0
    ;;

# 状态同步：打开页面时调用，用页面 cookie 的 token 校正应用中心状态。
# 应用中心状态与真实进程可能不一致（如 guard 无 token 时回退直接启停进程），
# 这里以进程状态为准，通过应用中心 API 校正，并刷新持久化 token。
/api/sync)
    token=$(echo "${HTTP_COOKIE:-}" | tr ';' '\n' | sed -n 's/^ *fnos-token=//p')
    if [ -n "$token" ]; then
        printf '%s' "$token" > "${PKG_VAR}/.fnos_token"   # 刷新持久化 token
    else
        token=$(cat "${PKG_VAR}/.fnos_token" 2>/dev/null)
    fi
    if [ -z "$token" ]; then
        json_ok '{"synced":false,"reason":"no-token"}'
    fi
    app_status=$(curl -s -m 10 -H "authorization: trim $token" \
        "http://127.0.0.1:5666/app-center/v1/app/detail?appName=tailscale" 2>/dev/null \
        | sed -n 's/.*"status":"\([^"]*\)".*/\1/p' | head -1)
    if TRIM_PKGVAR=/vol1/@appdata/tailscale TRIM_APPDEST=/vol1/@appcenter/tailscale \
        bash /var/apps/tailscale/cmd/main status >/dev/null 2>&1; then
        proc_status="running"
    else
        proc_status="stopped"
    fi
    if [ "$app_status" = "running" ] && [ "$proc_status" = "stopped" ]; then
        curl -s -m 30 -X POST -H "authorization: trim $token" -H 'Content-Type: application/json' \
            -d '{"appName":"tailscale","ignoreDependencies":true,"language":"zh-CN"}' \
            "http://127.0.0.1:5666/app-center/v1/stop/start" >/dev/null 2>&1
        action_log "状态校正：应用中心显示运行但进程未运行，执行停止"
    elif [ "$app_status" = "stopped" ] && [ "$proc_status" = "running" ]; then
        curl -s -m 30 -X POST -H "authorization: trim $token" -H 'Content-Type: application/json' \
            -d '{"appName":"tailscale","ignoreDependencies":true,"language":"zh-CN"}' \
            "http://127.0.0.1:5666/app-center/v1/start/start" >/dev/null 2>&1
        action_log "状态校正：应用中心显示未运行但进程在运行，执行启动"
    fi
    json_ok "{\"synced\":true,\"app\":\"${app_status:-unknown}\",\"process\":\"$proc_status\"}"
    ;;

# 启停动作
/api/action)
    [ "$REQUEST_METHOD" = "POST" ] || err "method not allowed"
    body=$(cat 2>/dev/null)
    act=$(printf '%s' "$body" | sed -n 's/.*action=\([^&]*\).*/\1/p')
    case "$act" in
        # 控制本应用守护进程
        start)      action_log "手动启动守护进程"; bash /var/apps/${APP}/cmd/main start >>"${PKG_VAR}/guard.log" 2>&1 ;;
        stop)       action_log "手动停止守护进程"; bash /var/apps/${APP}/cmd/main stop >>"${PKG_VAR}/guard.log" 2>&1 ;;
        restart)    action_log "手动重启守护进程"; bash /var/apps/${APP}/cmd/main restart >>"${PKG_VAR}/guard.log" 2>&1 ;;
        # 直接控制 Tailscale 应用（通过应用中心 API，保证状态同步）
        ts-start)   action_log "手动启动 Tailscale"; ts_control start ;;
        ts-stop)    action_log "手动停止 Tailscale"; ts_control stop ;;
        # 立即检测一次：向守护进程发 USR2，唤醒并执行一轮探测
        probe-now)  [ -f "$GUARD_PID" ] && kill -USR2 "$(head -n1 "$GUARD_PID" | tr -d '[:space:]')" 2>/dev/null ;;
        # 清除在线统计历史
        clear-history) action_log "清除在线统计历史"; rm -f "${PKG_VAR}/history.log" ;;
        *) err "unknown action" ;;
    esac
    json_ok "{\"ok\":true,\"action\":\"$act\"}"
    ;;
esac

# ---- 静态文件路由（非 /api/* 时走到这里）----
TARGET_FILE="${WWW}${REL_PATH}"
# 防目录穿越：拒绝含 .. 的路径
if echo "$TARGET_FILE" | grep -q '\.\.'; then
    header "text/plain; charset=utf-8"; echo "Bad Request"; exit 0
fi
[ ! -f "$TARGET_FILE" ] && { header "text/plain; charset=utf-8"; echo "404: ${REL_PATH}"; exit 0; }

# 按扩展名返回对应 MIME 类型
ext="${TARGET_FILE##*.}"
case "$ext" in
    html|htm) mime="text/html; charset=utf-8" ;;
    css)      mime="text/css; charset=utf-8" ;;
    js)       mime="application/javascript; charset=utf-8" ;;
    json)     mime="application/json; charset=utf-8" ;;
    png)      mime="image/png" ;;
    svg)      mime="image/svg+xml" ;;
    *)        mime="application/octet-stream" ;;
esac
header "$mime"
cat "$TARGET_FILE"
