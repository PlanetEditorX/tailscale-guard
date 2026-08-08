#!/bin/bash
# tailscale-guard Web UI CGI
# 路由静态文件 (/www/*) 并提供 /api/* 端点

APP=tailscale-guard
PKG_VAR="/vol1/@appdata/${APP}"
APP_DEST="/vol1/@appcenter/${APP}"
WWW="${APP_DEST}/www"
CONF="${PKG_VAR}/guard.conf"
STATE="${PKG_VAR}/state.json"
LOG="${PKG_VAR}/guard.log"
KEEPALIVE="${PKG_VAR}/.reload"
GUARD_PID="${PKG_VAR}/guard.pid"

# 从 REQUEST_URI 提取 index.cgi 后的路径
URI_NO_QUERY="${REQUEST_URI%%\?*}"
REL_PATH="/"
case "$URI_NO_QUERY" in
    *index.cgi*) REL_PATH="${URI_NO_QUERY#*index.cgi}" ;;
esac
[ -z "$REL_PATH" ] || [ "$REL_PATH" = "/" ] && REL_PATH="/index.html"

header() { echo "Content-Type: $1"; echo ""; }
json_ok() { header "application/json; charset=utf-8"; printf '%s' "$1"; exit 0; }
err()    { header "application/json; charset=utf-8"; printf '{"error":"%s"}' "$1"; exit 0; }

# API 端点
case "$REL_PATH" in
/api/state)
    json_ok "$(cat "${STATE}" 2>/dev/null || echo '{}')"
    ;;
/api/log)
    header "application/json; charset=utf-8"
    lines="${QUERY_STRING#lines=}"
    [ -z "$lines" ] && lines=200
    [ "$lines" = "$QUERY_STRING" ] && lines=200
    data=$(tail -n "$lines" "${LOG}" 2>/dev/null)
    # 转义换行与引号后输出 JSON
    esc=$(printf '%s' "$data" | sed 's/\\/\\\\/g; s/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    printf '{"log":"%s"}' "$esc"
    exit 0
    ;;
/api/config)
    if [ "$REQUEST_METHOD" = "POST" ]; then
        # 读取 body
        body=$(cat 2>/dev/null)
        # 逐行解析 key=value（body为 name=value&name=value URL编码）
        # 简化：用 sed 还原
        tmp="${PKG_VAR}/.config.new"
        : > "$tmp"
        IFS='&'
        for kv in $body; do
            k=$(printf '%s' "$kv" | cut -d= -f1)
            v=$(printf '%s' "$kv" | cut -d= -f2- | sed 's/+/ /g; s/%0D//g; s/%0A/\n/g')
            case "$k" in
                SENTINELS|NORMAL_INTERVAL|RETRY_INTERVAL|START_THRESHOLD|START_CONDITION|STOP_THRESHOLD|STOP_CONDITION|EFFECTIVE_TIME|LAN_IFACE)
                    printf '%s=%s\n' "$k" "$v" >> "$tmp"
                    ;;
            esac
        done
        unset IFS
        mv "$tmp" "$CONF"
        # 触发守护进程重载
        touch "$KEEPALIVE"
        [ -f "$GUARD_PID" ] && kill -USR1 "$(head -n1 "$GUARD_PID" | tr -d '[:space:]')" 2>/dev/null
        json_ok '{"ok":true}'
    else
        # 返回配置(简单 key=value 转成 JSON)
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
/api/action)
    [ "$REQUEST_METHOD" = "POST" ] || err "method not allowed"
    body=$(cat 2>/dev/null)
    act=$(printf '%s' "$body" | sed -n 's/.*action=\([^&]*\).*/\1/p')
    case "$act" in
        start)      bash /var/apps/${APP}/cmd/main start >>"${PKG_VAR}/guard.log" 2>&1 ;;
        stop)       bash /var/apps/${APP}/cmd/main stop >>"${PKG_VAR}/guard.log" 2>&1 ;;
        restart)    bash /var/apps/${APP}/cmd/main restart >>"${PKG_VAR}/guard.log" 2>&1 ;;
        ts-start)   TRIM_PKGVAR=/vol1/@appdata/tailscale TRIM_APPDEST=/vol1/@appcenter/tailscale bash /var/apps/tailscale/cmd/main start >>"${PKG_VAR}/guard.log" 2>&1 ;;
        ts-stop)    TRIM_PKGVAR=/vol1/@appdata/tailscale TRIM_APPDEST=/vol1/@appcenter/tailscale bash /var/apps/tailscale/cmd/main stop >>"${PKG_VAR}/guard.log" 2>&1 ;;
        *) err "unknown action" ;;
    esac
    json_ok "{\"ok\":true,\"action\":\"$act\"}"
    ;;
esac

# 静态文件路由
TARGET_FILE="${WWW}${REL_PATH}"
if echo "$TARGET_FILE" | grep -q '\.\.'; then
    header "text/plain; charset=utf-8"; echo "Bad Request"; exit 0
fi
[ ! -f "$TARGET_FILE" ] && { header "text/plain; charset=utf-8"; echo "404: ${REL_PATH}"; exit 0; }

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