#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# ============================================================
# Cloudflare Tunnel 一键管理脚本
# 作者：白小纯
#
# 默认用法：
#   bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager.sh)
#
# 默认行为：
#   不带参数运行 = 安装 cloudflared 并创建 systemd 服务
#
# 支持命令：
#   install    安装 / 重新配置
#   uninstall  卸载
#   status     查看状态
#   logs       查看实时日志
#   restart    重启服务
#   update     更新 cloudflared
#   version    查看版本
#
# 适用场景：
#   Cloudflare Zero Trust 面板里创建的 remotely-managed tunnel
#
# 这个脚本会做什么：
#   1. 安装 cloudflared
#   2. 保存 Cloudflare Tunnel Token 到 /etc/cloudflared/token
#   3. 创建 systemd 服务
#   4. 使用 --token-file 启动，避免 Token 出现在 ExecStart 命令里
#
# 这个脚本不会做什么：
#   1. 不会配置 V2Ray / Xray / sing-box 客户端
#   2. 不会上传你的 Token
#   3. 不会在 Cloudflare 面板里创建或删除 Tunnel
#   4. 不会把 Token 写到 GitHub
# ============================================================

脚本名称="Cloudflare Tunnel 一键管理脚本"
服务名称="cloudflared"
服务文件="/etc/systemd/system/${服务名称}.service"
安装路径="/usr/local/bin/cloudflared"
配置目录="/etc/cloudflared"
TOKEN文件="${配置目录}/token"

# 可选：指定 cloudflared 版本
# 示例：
#   CLOUDFLARED_VERSION="2025.4.0" bash <(curl -fsSL 脚本地址)
# 默认：latest
CLOUDFLARED_VERSION="${CLOUDFLARED_VERSION:-latest}"

# 可选：连接协议
# 可选值：auto / quic / http2
CLOUDFLARED_PROTOCOL="${CLOUDFLARED_PROTOCOL:-auto}"

# 可选：日志级别
# 可选值：debug / info / warn / error / fatal
CLOUDFLARED_LOGLEVEL="${CLOUDFLARED_LOGLEVEL:-info}"

# 可选：跳过确认提示
# 示例：
#   YES=1 bash <(curl -fsSL 脚本地址) uninstall
YES="${YES:-0}"

报错退出() {
  echo "错误：$*" >&2
  exit 1
}

提示() {
  echo "==> $*"
}

警告() {
  echo "警告：$*" >&2
}

检查root权限() {
  if [ "$(id -u)" -ne 0 ]; then
    报错退出 "请使用 root 权限运行。建议先执行：sudo -i，然后重新运行本脚本。"
  fi
}

检查systemd() {
  command -v systemctl >/dev/null 2>&1 || 报错退出 "没有找到 systemctl。本脚本需要 systemd 环境。"
}

命令存在() {
  command -v "$1" >/dev/null 2>&1
}

确认操作() {
  local 提问="$1"

  if [ "$YES" = "1" ]; then
    return 0
  fi

  read -r -p "${提问} [y/N]: " 回答
  case "$回答" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

识别架构文件() {
  local 架构
  架构="$(uname -m)"

  case "$架构" in
    x86_64|amd64)
      echo "cloudflared-linux-amd64"
      ;;
    aarch64|arm64)
      echo "cloudflared-linux-arm64"
      ;;
    armv7l|armv6l)
      echo "cloudflared-linux-arm"
      ;;
    *)
      报错退出 "暂不支持当前 CPU 架构：$架构"
      ;;
  esac
}

安装依赖() {
  提示 "检查必要工具..."

  if 命令存在 curl && 命令存在 install && 命令存在 systemctl; then
    return 0
  fi

  if 命令存在 apt-get; then
    apt-get update -y
    apt-get install -y curl ca-certificates coreutils
  elif 命令存在 dnf; then
    dnf install -y curl ca-certificates coreutils
  elif 命令存在 yum; then
    yum install -y curl ca-certificates coreutils
  elif 命令存在 apk; then
    apk add --no-cache curl ca-certificates coreutils
  else
    报错退出 "没有找到支持的包管理器。请手动安装 curl 和 coreutils。"
  fi
}

生成下载地址() {
  local 架构文件="$1"

  if [ "$CLOUDFLARED_VERSION" = "latest" ]; then
    echo "https://github.com/cloudflare/cloudflared/releases/latest/download/${架构文件}"
  else
    echo "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/${架构文件}"
  fi
}

安装cloudflared() {
  local 架构文件 下载地址 临时文件
  架构文件="$(识别架构文件)"
  下载地址="$(生成下载地址 "$架构文件")"
  临时文件="$(mktemp)"

  提示 "正在下载 cloudflared，版本：${CLOUDFLARED_VERSION}，架构：$(uname -m)"
  curl -fL --proto '=https' --tlsv1.2 -o "$临时文件" "$下载地址" || {
    rm -f "$临时文件"
    报错退出 "下载 cloudflared 失败：$下载地址"
  }

  install -m 0755 "$临时文件" "$安装路径"
  rm -f "$临时文件"

  提示 "cloudflared 安装完成：$安装路径"
  "$安装路径" --version || true
}

检查token_file支持() {
  if ! "$安装路径" tunnel run --help 2>&1 | grep -q -- '--token-file'; then
    报错退出 "当前 cloudflared 不支持 --token-file。请使用 CLOUDFLARED_VERSION=latest 或 2025.4.0 以上版本。"
  fi
}

校验协议() {
  case "$CLOUDFLARED_PROTOCOL" in
    auto|quic|http2) ;;
    *)
      报错退出 "CLOUDFLARED_PROTOCOL 参数无效：$CLOUDFLARED_PROTOCOL。可选值：auto / quic / http2"
      ;;
  esac
}

校验日志级别() {
  case "$CLOUDFLARED_LOGLEVEL" in
    debug|info|warn|error|fatal) ;;
    *)
      报错退出 "CLOUDFLARED_LOGLEVEL 参数无效：$CLOUDFLARED_LOGLEVEL。可选值：debug / info / warn / error / fatal"
      ;;
  esac
}

读取并保存Token() {
  local TOKEN内容=""

  if [ -n "${TUNNEL_TOKEN:-}" ]; then
    TOKEN内容="$TUNNEL_TOKEN"
  elif [ -f "$TOKEN文件" ]; then
    if 确认操作 "检测到已有 Token 文件：$TOKEN文件，是否继续使用？"; then
      return 0
    fi
  else
    echo
    echo "请粘贴 Cloudflare Tunnel Token。"
    echo "获取位置：Cloudflare Zero Trust 面板 > Networks > Tunnels"
    read -r -s -p "Tunnel Token: " TOKEN内容
    echo
  fi

  TOKEN内容="$(printf "%s" "$TOKEN内容" | tr -d '\r\n[:space:]')"

  if [ -z "$TOKEN内容" ]; then
    报错退出 "Tunnel Token 不能为空。"
  fi

  if [[ "$TOKEN内容" != eyJ* ]]; then
    警告 "这个 Token 不是以 eyJ 开头。Cloudflare Tunnel Token 通常以 eyJ 开头，但脚本会继续执行。"
  fi

  mkdir -p "$配置目录"
  chmod 700 "$配置目录"
  printf "%s" "$TOKEN内容" > "$TOKEN文件"
  chmod 600 "$TOKEN文件"

  提示 "Token 已保存到：$TOKEN文件"
}

备份旧服务文件() {
  if [ -f "$服务文件" ]; then
    local 备份文件
    备份文件="${服务文件}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$服务文件" "$备份文件"
    提示 "已备份旧服务文件：$备份文件"
  fi
}

写入systemd服务() {
  校验协议
  校验日志级别
  备份旧服务文件

  提示 "正在写入 systemd 服务文件：$服务文件"

  cat > "$服务文件" <<EOF
[Unit]
Description=Cloudflare Tunnel Connector
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${安装路径} tunnel --no-autoupdate --protocol ${CLOUDFLARED_PROTOCOL} --loglevel ${CLOUDFLARED_LOGLEVEL} run --token-file ${TOKEN文件}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
UMask=0077

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "$服务文件"
}

启动服务() {
  提示 "重新加载 systemd..."
  systemctl daemon-reload

  提示 "启用并启动 ${服务名称}.service..."
  systemctl enable --now "${服务名称}.service"

  sleep 2

  if systemctl is-active --quiet "${服务名称}.service"; then
    提示 "${服务名称}.service 已成功运行。"
  else
    echo
    警告 "${服务名称}.service 启动失败。"
    echo "你可以使用下面命令排查："
    echo "  systemctl status ${服务名称}.service --no-pager"
    echo "  journalctl -u ${服务名称}.service -n 80 --no-pager"
    exit 1
  fi
}

安装流程() {
  检查root权限 "$@"
  检查systemd
  安装依赖

  if [ -x "$安装路径" ]; then
    提示 "检测到 cloudflared 已存在：$安装路径"
    "$安装路径" --version || true
  else
    安装cloudflared
  fi

  检查token_file支持
  读取并保存Token
  写入systemd服务
  启动服务

  echo
  echo "安装完成。"
  echo
  echo "下一步："
  echo "  1. 打开 Cloudflare Zero Trust 面板"
  echo "  2. 进入你的 Tunnel"
  echo "  3. 添加 Public Hostnames"
  echo
  echo "示例："
  echo "  Public hostname: app.example.com"
  echo "  Service: http://localhost:8080"
  echo
  echo "常用命令："
  echo "  bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager.sh) status"
  echo "  bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager.sh) logs"
  echo "  bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager.sh) restart"
}

卸载流程() {
  检查root权限 "$@"
  检查systemd

  echo "即将停止并删除以下内容："
  echo "  - ${服务文件}"
  echo "  - ${TOKEN文件}"
  echo "  - ${配置目录}"
  echo
  echo "注意：这不会删除 Cloudflare 面板里的 Tunnel。"
  echo

  if ! 确认操作 "确认继续卸载？"; then
    echo "已取消。"
    exit 0
  fi

  systemctl disable --now "${服务名称}.service" 2>/dev/null || true
  rm -f "$服务文件"
  systemctl daemon-reload || true

  if 确认操作 "是否删除 cloudflared 程序文件：${安装路径}？"; then
    rm -f "$安装路径"
  fi

  if 确认操作 "是否删除 ${配置目录}？这会删除本机保存的 Tunnel Token。"; then
    rm -rf "$配置目录"
  fi

  提示 "卸载完成。"
}

查看状态() {
  检查root权限 "$@"
  检查systemd
  systemctl status "${服务名称}.service" --no-pager || true
}

查看日志() {
  检查root权限 "$@"
  检查systemd
  journalctl -u "${服务名称}.service" -f
}

重启服务() {
  检查root权限 "$@"
  检查systemd
  systemctl restart "${服务名称}.service"
  systemctl status "${服务名称}.service" --no-pager || true
}

更新cloudflared() {
  检查root权限 "$@"
  检查systemd
  安装依赖
  安装cloudflared
  检查token_file支持
  systemctl restart "${服务名称}.service" || true
  提示 "更新完成。"
}

查看版本() {
  if [ -x "$安装路径" ]; then
    "$安装路径" --version
  elif 命令存在 cloudflared; then
    cloudflared --version
  else
    echo "cloudflared 尚未安装。"
  fi
}

显示帮助() {
  cat <<EOF
${脚本名称}
作者：白小纯

用法：
  bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager.sh)              # 默认安装
  bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager.sh) install
  bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager.sh) uninstall
  bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager.sh) status
  bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager.sh) logs
  bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager.sh) restart
  bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager.sh) update
  bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager.sh) version

可选环境变量：
  TUNNEL_TOKEN="..."              非交互方式传入 Token，不推荐公开环境使用
  CLOUDFLARED_VERSION="latest"    指定 cloudflared 版本，例如 2025.4.0
  CLOUDFLARED_PROTOCOL="auto"     连接协议：auto / quic / http2
  CLOUDFLARED_LOGLEVEL="info"     日志级别：debug / info / warn / error / fatal
  YES=1                           跳过确认提示

示例：
  bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager.sh)
  bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager.sh) logs
  YES=1 bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager.sh) uninstall
EOF
}

主函数() {
  local 命令="${1:-install}"

  case "$命令" in
    install)
      安装流程 "$@"
      ;;
    uninstall)
      卸载流程 "$@"
      ;;
    status)
      查看状态 "$@"
      ;;
    logs)
      查看日志 "$@"
      ;;
    restart)
      重启服务 "$@"
      ;;
    update)
      更新cloudflared "$@"
      ;;
    version)
      查看版本
      ;;
    -h|--help|help)
      显示帮助
      ;;
    *)
      显示帮助
      报错退出 "未知命令：$命令"
      ;;
  esac
}

主函数 "$@"
