#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# ============================================================
# Cloudflare Tunnel 一键管理脚本
# 作者：白小纯
#
# 默认用法：
#   bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager-fixed.sh)
#
# 默认行为：
#   不带参数运行 = 显示中文菜单
#
# 适用场景：
#   Cloudflare Zero Trust 面板里创建的 remotely-managed tunnel
#
# 安全设计：
#   1. Token 输入时隐藏
#   2. Token 保存到 /etc/cloudflared/token
#   3. systemd 使用 --token-file 启动
#   4. 不把 Token 写进 ExecStart
#   5. 不上传 Token
# ============================================================

APP_NAME="Cloudflare Tunnel 一键管理脚本"
AUTHOR_NAME="白小纯"

SERVICE_NAME="cloudflared"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
INSTALL_PATH="/usr/local/bin/cloudflared"
CONFIG_DIR="/etc/cloudflared"
TOKEN_FILE="${CONFIG_DIR}/token"

CLOUDFLARED_VERSION="${CLOUDFLARED_VERSION:-latest}"
CLOUDFLARED_PROTOCOL="${CLOUDFLARED_PROTOCOL:-auto}"
CLOUDFLARED_LOGLEVEL="${CLOUDFLARED_LOGLEVEL:-info}"
YES="${YES:-0}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
BOLD='\033[1m'
RESET='\033[0m'

die() {
  echo -e "${RED}错误：$*${RESET}" >&2
  exit 1
}

info() {
  echo -e "${GREEN}==>${RESET} $*"
}

warn() {
  echo -e "${YELLOW}警告：$*${RESET}" >&2
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "请使用 root 权限运行。建议先执行：sudo -i，然后重新运行本脚本。"
  fi
}

need_systemd() {
  command_exists systemctl || die "没有找到 systemctl。本脚本需要 systemd 环境。"
}

confirm_action() {
  local question="$1"

  if [ "$YES" = "1" ]; then
    return 0
  fi

  read -r -p "${question} [y/N]: " answer
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

pause_return() {
  echo
  read -r -p "按回车键返回菜单..."
}

print_header() {
  clear || true
  echo -e "${CYAN}"
  echo "╔════════════════════════════════════════════╗"
  echo "║        Cloudflare Tunnel 一键管理脚本       ║"
  echo "╚════════════════════════════════════════════╝"
  echo -e "${RESET}"
  echo -e "作者：${BOLD}${AUTHOR_NAME}${RESET}"
  echo
}

show_menu() {
  print_header
  echo -e "${BOLD}${GREEN}1) 安装 / 重新配置 Cloudflare Tunnel${RESET}"
  echo -e "${BOLD}${RED}2) 卸载 Cloudflare Tunnel${RESET}"
  echo -e "${BOLD}${BLUE}3) 查看服务状态${RESET}"
  echo -e "${BOLD}${CYAN}4) 查看实时日志${RESET}"
  echo -e "${BOLD}${YELLOW}5) 重启服务${RESET}"
  echo -e "${BOLD}${YELLOW}6) 更新 cloudflared${RESET}"
  echo -e "${BOLD}7) 查看 cloudflared 版本${RESET}"
  echo -e "${BOLD}8) 退出脚本${RESET}"
  echo
}

detect_arch_asset() {
  local arch
  arch="$(uname -m)"

  case "$arch" in
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
      die "暂不支持当前 CPU 架构：$arch"
      ;;
  esac
}

install_dependencies() {
  info "检查必要工具..."

  if command_exists curl && command_exists install && command_exists systemctl; then
    return 0
  fi

  if command_exists apt-get; then
    apt-get update -y
    apt-get install -y curl ca-certificates coreutils
  elif command_exists dnf; then
    dnf install -y curl ca-certificates coreutils
  elif command_exists yum; then
    yum install -y curl ca-certificates coreutils
  elif command_exists apk; then
    apk add --no-cache curl ca-certificates coreutils
  else
    die "没有找到支持的包管理器。请手动安装 curl 和 coreutils。"
  fi
}

build_download_url() {
  local asset="$1"

  if [ "$CLOUDFLARED_VERSION" = "latest" ]; then
    echo "https://github.com/cloudflare/cloudflared/releases/latest/download/${asset}"
  else
    echo "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/${asset}"
  fi
}

install_cloudflared() {
  local asset url tmp_file
  asset="$(detect_arch_asset)"
  url="$(build_download_url "$asset")"
  tmp_file="$(mktemp)"

  info "正在下载 cloudflared，版本：${CLOUDFLARED_VERSION}，架构：$(uname -m)"
  curl -fL --proto '=https' --tlsv1.2 -o "$tmp_file" "$url" || {
    rm -f "$tmp_file"
    die "下载 cloudflared 失败：$url"
  }

  install -m 0755 "$tmp_file" "$INSTALL_PATH"
  rm -f "$tmp_file"

  info "cloudflared 安装完成：$INSTALL_PATH"
  "$INSTALL_PATH" --version || true
}

ensure_token_file_supported() {
  if ! "$INSTALL_PATH" tunnel run --help 2>&1 | grep -q -- '--token-file'; then
    die "当前 cloudflared 不支持 --token-file。请使用 CLOUDFLARED_VERSION=latest 或 2025.4.0 以上版本。"
  fi
}

validate_protocol() {
  case "$CLOUDFLARED_PROTOCOL" in
    auto|quic|http2) ;;
    *)
      die "CLOUDFLARED_PROTOCOL 参数无效：$CLOUDFLARED_PROTOCOL。可选值：auto / quic / http2"
      ;;
  esac
}

validate_loglevel() {
  case "$CLOUDFLARED_LOGLEVEL" in
    debug|info|warn|error|fatal) ;;
    *)
      die "CLOUDFLARED_LOGLEVEL 参数无效：$CLOUDFLARED_LOGLEVEL。可选值：debug / info / warn / error / fatal"
      ;;
  esac
}

read_and_save_token() {
  local token_value=""

  if [ -n "${TUNNEL_TOKEN:-}" ]; then
    token_value="$TUNNEL_TOKEN"
  elif [ -f "$TOKEN_FILE" ]; then
    if confirm_action "检测到已有 Token 文件：$TOKEN_FILE，是否继续使用？"; then
      return 0
    fi

    echo
    echo "请粘贴新的 Cloudflare Tunnel Token。"
    echo "获取位置：Cloudflare Zero Trust 面板 > Networks > Tunnels"
    read -r -s -p "Tunnel Token: " token_value
    echo
  else
    echo
    echo "请粘贴 Cloudflare Tunnel Token。"
    echo "获取位置：Cloudflare Zero Trust 面板 > Networks > Tunnels"
    read -r -s -p "Tunnel Token: " token_value
    echo
  fi

  token_value="$(printf "%s" "$token_value" | tr -d '\r\n[:space:]')"

  if [ -z "$token_value" ]; then
    die "Tunnel Token 不能为空。"
  fi

  if [[ "$token_value" != eyJ* ]]; then
    warn "这个 Token 不是以 eyJ 开头。Cloudflare Tunnel Token 通常以 eyJ 开头，但脚本会继续执行。"
  fi

  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  printf "%s" "$token_value" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"

  info "Token 已保存到：$TOKEN_FILE"
}

backup_old_service_file() {
  if [ -f "$SERVICE_FILE" ]; then
    local backup_file
    backup_file="${SERVICE_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$SERVICE_FILE" "$backup_file"
    info "已备份旧服务文件：$backup_file"
  fi
}

write_systemd_service() {
  validate_protocol
  validate_loglevel
  backup_old_service_file

  info "正在写入 systemd 服务文件：$SERVICE_FILE"

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare Tunnel Connector
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_PATH} tunnel --no-autoupdate --protocol ${CLOUDFLARED_PROTOCOL} --loglevel ${CLOUDFLARED_LOGLEVEL} run --token-file ${TOKEN_FILE}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
UMask=0077

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "$SERVICE_FILE"
}

start_service() {
  info "重新加载 systemd..."
  systemctl daemon-reload

  info "启用并启动 ${SERVICE_NAME}.service..."
  systemctl enable --now "${SERVICE_NAME}.service"

  sleep 2

  if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    info "${SERVICE_NAME}.service 已成功运行。"
  else
    echo
    warn "${SERVICE_NAME}.service 启动失败。"
    echo "你可以使用下面命令排查："
    echo "  systemctl status ${SERVICE_NAME}.service --no-pager"
    echo "  journalctl -u ${SERVICE_NAME}.service -n 80 --no-pager"
    exit 1
  fi
}

install_flow() {
  print_header
  need_root
  need_systemd
  install_dependencies

  if [ -x "$INSTALL_PATH" ]; then
    info "检测到 cloudflared 已存在：$INSTALL_PATH"
    "$INSTALL_PATH" --version || true
  else
    install_cloudflared
  fi

  ensure_token_file_supported
  read_and_save_token
  write_systemd_service
  start_service

  echo
  echo -e "${GREEN}安装完成。${RESET}"
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
}

uninstall_flow() {
  print_header
  need_root
  need_systemd

  echo -e "${RED}即将卸载 Cloudflare Tunnel 本机服务。${RESET}"
  echo
  echo "将会停止并删除："
  echo "  - ${SERVICE_FILE}"
  echo "  - ${TOKEN_FILE}"
  echo "  - ${CONFIG_DIR}"
  echo
  echo "注意："
  echo "  1. 这不会删除 Cloudflare 面板里的 Tunnel。"
  echo "  2. 这不会删除 Cloudflare DNS 记录。"
  echo "  3. 这只清理当前 VPS 上的 cloudflared 服务。"
  echo

  if ! confirm_action "确认继续卸载？"; then
    echo "已取消卸载。"
    return 0
  fi

  systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload || true

  if [ -f "$INSTALL_PATH" ]; then
    if confirm_action "是否删除 cloudflared 程序文件：${INSTALL_PATH}？"; then
      rm -f "$INSTALL_PATH"
      info "已删除 cloudflared 程序文件。"
    else
      info "已保留 cloudflared 程序文件。"
    fi
  fi

  if [ -d "$CONFIG_DIR" ]; then
    if confirm_action "是否删除 ${CONFIG_DIR}？这会删除本机保存的 Tunnel Token。"; then
      rm -rf "$CONFIG_DIR"
      info "已删除配置目录。"
    else
      info "已保留配置目录。"
    fi
  fi

  info "卸载完成。"
}

status_flow() {
  print_header
  need_root
  need_systemd
  systemctl status "${SERVICE_NAME}.service" --no-pager || true
}

logs_flow() {
  print_header
  need_root
  need_systemd
  echo "正在查看实时日志。按 Ctrl + C 退出日志。"
  echo
  journalctl -u "${SERVICE_NAME}.service" -f
}

restart_flow() {
  print_header
  need_root
  need_systemd

  info "正在重启 ${SERVICE_NAME}.service..."
  systemctl restart "${SERVICE_NAME}.service"
  systemctl status "${SERVICE_NAME}.service" --no-pager || true
}

update_flow() {
  print_header
  need_root
  need_systemd
  install_dependencies
  install_cloudflared
  ensure_token_file_supported

  if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
    systemctl restart "${SERVICE_NAME}.service" || true
  fi

  info "更新完成。"
}

version_flow() {
  print_header

  if [ -x "$INSTALL_PATH" ]; then
    "$INSTALL_PATH" --version
  elif command_exists cloudflared; then
    cloudflared --version
  else
    echo "cloudflared 尚未安装。"
  fi
}

show_help() {
  cat <<EOF
${APP_NAME}
作者：${AUTHOR_NAME}

默认菜单模式：
  bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager-fixed.sh)

也可以直接使用命令参数：
  bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager-fixed.sh) install
  bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager-fixed.sh) uninstall
  bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager-fixed.sh) status
  bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager-fixed.sh) logs
  bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager-fixed.sh) restart
  bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager-fixed.sh) update
  bash <(curl -fsSL https://raw.githubusercontent.com/yw-2020/xray/main/cf-tunnel-manager-fixed.sh) version

可选环境变量：
  TUNNEL_TOKEN="..."              非交互方式传入 Token，不推荐公开环境使用
  CLOUDFLARED_VERSION="latest"    指定 cloudflared 版本，例如 2025.4.0
  CLOUDFLARED_PROTOCOL="auto"     连接协议：auto / quic / http2
  CLOUDFLARED_LOGLEVEL="info"     日志级别：debug / info / warn / error / fatal
  YES=1                           跳过确认提示
EOF
}

menu_loop() {
  while true; do
    show_menu
    read -r -p "请选择操作 [1-8]: " choice
    echo

    case "$choice" in
      1)
        install_flow
        pause_return
        ;;
      2)
        uninstall_flow
        pause_return
        ;;
      3)
        status_flow
        pause_return
        ;;
      4)
        logs_flow
        ;;
      5)
        restart_flow
        pause_return
        ;;
      6)
        update_flow
        pause_return
        ;;
      7)
        version_flow
        pause_return
        ;;
      8)
        echo "已退出脚本。"
        exit 0
        ;;
      *)
        echo -e "${RED}无效选择，请输入 1-8。${RESET}"
        sleep 1
        ;;
    esac
  done
}

main() {
  local cmd="${1:-menu}"

  case "$cmd" in
    menu)
      menu_loop
      ;;
    install)
      install_flow
      ;;
    uninstall)
      uninstall_flow
      ;;
    status)
      status_flow
      ;;
    logs)
      logs_flow
      ;;
    restart)
      restart_flow
      ;;
    update)
      update_flow
      ;;
    version)
      version_flow
      ;;
    -h|--help|help)
      show_help
      ;;
    *)
      show_help
      die "未知命令：$cmd"
      ;;
  esac
}

main "$@"
