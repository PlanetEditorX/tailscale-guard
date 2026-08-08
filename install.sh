#!/bin/bash
# =============================================================================
# Tailscale 看门狗 — 飞牛 fnOS 手动安装脚本
# 适用于不便打包 .fpk 的场景：直接从源码目录把文件拷贝到系统对应路径。
# 用法: 以 root 身份在源码根目录执行 bash install.sh
# =============================================================================
set -e

APP=tailscale-guard
DA=/var/apps/$APP         # 应用注册目录（fnOS 应用中心在此查找应用信息）
AC=/vol1/@appcenter/$APP  # 应用主目录（实际程序文件）
AD=/vol1/@appdata/$APP    # 数据目录（配置/状态/日志）

# 前置检查：必须以 root 执行；必须先装好 Tailscale 应用
[ "$(id -u)" = "0" ] || { echo "请以 root 执行"; exit 1; }
command -v tailscaled >/dev/null 2>&1 || [ -f /var/apps/tailscale/cmd/main ] || {
  echo "未检测到 Tailscale 应用，请先在飞牛应用中心安装 Tailscale"; exit 1; }

echo "[1/5] 创建目录与符号链接"
mkdir -p $DA/cmd $DA/config $DA/ui/images $AC/app $AC/ui/images $AC/www $AD
# 让 /var/apps 下的注册目录能解析到数据/目标目录
ln -sfn $AD $DA/var
ln -sfn $AD $DA/etc
ln -sfn $AC $DA/target

echo "[2/5] 拷贝应用文件"
cp -r ./cmd/* $DA/cmd/
cp -r ./config/* $DA/config/
cp ./manifest $DA/manifest
cp ./ICON.PNG $DA/ICON.PNG 2>/dev/null
cp ./ICON_256.PNG $DA/ICON_256.PNG 2>/dev/null
cp -r ./app/* $AC/app/
cp -r ./ui/* $AC/ui/
cp -r ./ui/* $DA/ui/ 2>/dev/null || true
# 显式同步新旧文件名与根图标，兼容不同 fnOS 入口并绕过旧图标缓存。
cp -f ./ui/images/guard_64.png  $DA/ui/images/guard_64.png 2>/dev/null || true
cp -f ./ui/images/guard_256.png $DA/ui/images/guard_256.png 2>/dev/null || true
cp -f ./ui/images/guard_64.png  $DA/ui/images/icon_64.png 2>/dev/null || true
cp -f ./ui/images/guard_256.png $DA/ui/images/icon_256.png 2>/dev/null || true
cp -f ./ui/images/guard_64.png  $DA/ICON.PNG 2>/dev/null || true
cp -f ./ui/images/guard_256.png $DA/ICON_256.PNG 2>/dev/null || true
cp -r ./www/* $AC/www/

echo "[3/5] 设置权限"
chmod +x $DA/cmd/main $AC/app/guard.sh $AC/ui/index.cgi
chmod +x $DA/cmd/*_init $DA/cmd/*_callback 2>/dev/null || true

echo "[4/5] 生成默认配置"
if [ ! -f $AD/guard.conf ]; then
cat > $AD/guard.conf <<"CONF"
SENTINELS=192.168.1.30
NORMAL_INTERVAL=600
RETRY_INTERVAL=180
START_THRESHOLD=3
START_CONDITION=all_offline
STOP_THRESHOLD=1
STOP_CONDITION=any_online
EFFECTIVE_TIME=
HISTORY_KEEP=2592000
LAN_IFACE=enp6s18
CONF
fi

echo "[5/5] 刷新应用中心"
# 通知 trim_app_center 重载，让新应用出现在网页应用中心
if pgrep -x trim_app_center >/dev/null 2>&1; then
  kill -HUP "$(pgrep -x trim_app_center | head -1)" 2>/dev/null && echo "已通知 trim_app_center 重载"
fi

echo
echo "安装完成。请刷新飞牛网页应用中心，应出现「Tailscale 看门狗」。"
echo "首次使用：进入应用 → 设置哨兵设备 IP/MAC → 保存 → 启动守护进程。"
echo "若应用中心未显示，执行: systemctl restart trim_app_center"
