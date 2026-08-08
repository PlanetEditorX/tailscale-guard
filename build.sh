#!/bin/bash
# =============================================================================
# tailscale-guard 构建脚本
# 从源码目录生成 fnOS 可安装的发布包：
#   1) app.tgz                      —— 应用程序主体（app/ ui/ www/）
#   2) tailscale-guard-<版本>.fpk    —— fnOS 应用中心安装包
# 用法：在源码根目录执行 bash build.sh
# =============================================================================
set -e

APP="tailscale-guard"
# 从 manifest 读取版本号（如 1.0.0）
VER=$(sed -n 's/^version[[:space:]]*=[[:space:]]*//p' manifest | tr -d '[:space:]')
[ -n "$VER" ] || { echo "manifest 中未找到 version"; exit 1; }

# 1) 打包应用主体：app（守护脚本）、ui（应用中心 UI 描述）、www（Web UI）
echo "[1/2] 打包 app.tgz"
tar czf app.tgz app ui www

# 2) 打包 fpk：manifest/图标/系统钩子脚本 + 上面的 app.tgz
#    fnOS 应用中心安装时按此结构解包到对应目录
echo "[2/2] 打包 ${APP}-${VER}.fpk"
tar czf "${APP}-${VER}.fpk" manifest ICON.PNG ICON_256.PNG cmd config wizard app.tgz

echo "构建完成: ${APP}-${VER}.fpk"
