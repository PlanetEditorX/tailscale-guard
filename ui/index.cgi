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
                SENTINELS|NORMAL_INTERVAL|RETRY_INTERVAL|START_THRESHOLD|START_CONDITION|STOP_THRESHOLD|STOP_CONDITION|EFFECTIVE_TIME|LAN_IFACE)
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

# 启停动作
/api/action)
    [ "$REQUEST_METHOD" = "POST" ] || err "method not allowed"
    body=$(cat 2>/dev/null)
    act=$(printf '%s' "$body" | sed -n 's/.*action=\([^&]*\).*/\1/p')
    case "$act" in
        # 控制本应用守护进程
        start)      bash /var/apps/${APP}/cmd/main start >>"${PKG_VAR}/guard.log" 2>&1 ;;
        stop)       bash /var/apps/${APP}/cmd/main stop >>"${PKG_VAR}/guard.log" 2>&1 ;;
        restart)    bash /var/apps/${APP}/cmd/main restart >>"${PKG_VAR}/guard.log" 2>&1 ;;
        # 直接控制 Tailscale 应用（临时手动启停）
        ts-start)   TRIM_PKGVAR=/vol1/@appdata/tailscale TRIM_APPDEST=/vol1/@appcenter/tailscale bash /var/apps/tailscale/cmd/main start >>"${PKG_VAR}/guard.log" 2>&1 ;;
        ts-stop)    TRIM_PKGVAR=/vol1/@appdata/tailscale TRIM_APPDEST=/vol1/@appcenter/tailscale bash /var/apps/tailscale/cmd/main stop >>"${PKG_VAR}/guard.log" 2>&1 ;;
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
