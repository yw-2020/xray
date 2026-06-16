#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# ======================================================
# install-argo-clean.sh
# Cloudflare Tunnel 多域名自动安装脚本（支持 WS / gRPC / TCP）
# 作者：白小纯
#
# 说明：
#   本脚本保留原安装流程：
#   菜单 -> 安装/卸载/退出 -> 输入域名数量 -> 域名/端口/传输方式
#   -> 输入 Token 或 credentials JSON -> 生成 config.yml -> 创建 systemd 服务
#
# 安全改动：
#   1. 去除广告信息
#   2. Token 输入隐藏
#   3. Token 优先使用 --token-file，不直接写入 ExecStart
#   4. 域名、端口、协议做基础校验
#   5. 重复安装前备份旧配置和旧服务文件
#   6. 所有变量和函数使用英文，避免 Bash 不兼容中文变量名
# ======================================================

APP_NAME="Cloudflare Tunnel 多域名自动安装脚本"
AUTHOR_NAME="白小纯"

SERVICE_NAME="cloudflared"
CLOUDFLARED_VERSION="${CLOUDFLARED_VERSION:-latest}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
BOLD='\033[1m'
RESET='\033[0m'

die() {
  echo -e "${RED}✖ $*${RESET}" >&2
  exit 1
}

info() {
  echo -e "${GREEN}→${RESET} $*"
}

warn() {
  echo -e "${YELLOW}⚠ $*${RESET}" >&2
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

is_root() {
  [ "$(id -u)" -eq 0 ]
}

pause_return() {
  echo
  read -r -p "按回车键返回菜单..."
}

print_header() {
  clear || true
  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════════╗"
  echo "║     Cloudflare Tunnel 多域名安装器       ║"
  echo "╚══════════════════════════════════════════╝"
  echo -e "${RESET}"
  echo -e "作者：${BOLD}${AUTHOR_NAME}${RESET}"
  echo -e "${CYAN}──────────────────────────────────────────${RESET}"
  echo
}

confirm_action() {
  local question="$1"
  local answer=""

  read -r -p "${question} [y/N]: " answer
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

validate_domain() {
  local domain="$1"
  [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] && [[ "$domain" == *.* ]] && [[ "$domain" != .* ]] && [[ "$domain" != *. ]]
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

validate_proto() {
  local proto="$1"
  case "$proto" in
    http|https|tcp) return 0 ;;
    *) return 1 ;;
  esac
}

validate_stream_type() {
  local stream_type="$1"
  case "$stream_type" in
    1|2|3) return 0 ;;
    *) return 1 ;;
  esac
}

validate_uuid() {
  local uuid="$1"
  [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

detect_system() {
  if [ -f /etc/alpine-release ]; then
    PKG_MGR="apk"
  elif [ -f /etc/debian_version ]; then
    PKG_MGR="apt"
  elif [ -f /etc/redhat-release ]; then
    PKG_MGR="yum"
  else
    die "不支持的系统类型。"
  fi
}

install_tools() {
  info "正在检查并安装必要工具..."

  if command_exists curl && command_exists wget && command_exists sed && command_exists grep; then
    info "必要工具已存在。"
    return 0
  fi

  case "$PKG_MGR" in
    apk)
      apk add --no-cache curl wget sed grep ca-certificates coreutils
      ;;
    apt)
      apt update -y
      apt install -y curl wget sed grep ca-certificates coreutils
      ;;
    yum)
      yum install -y curl wget sed grep ca-certificates coreutils
      ;;
  esac
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
      die "不支持的架构：$arch"
      ;;
  esac
}

build_cloudflared_url() {
  local asset="$1"

  if [ "$CLOUDFLARED_VERSION" = "latest" ]; then
    echo "https://github.com/cloudflare/cloudflared/releases/latest/download/${asset}"
  else
    echo "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/${asset}"
  fi
}

install_cloudflared() {
  local asset url tmp_file dest
  asset="$(detect_arch_asset)"
  url="$(build_cloudflared_url "$asset")"

  if is_root; then
    dest="/usr/local/bin"
  else
    dest="${HOME}/.local/bin"
    mkdir -p "$dest"
  fi

  if [ -x "${dest}/cloudflared" ]; then
    info "检测到 cloudflared 已安装：${dest}/cloudflared"
    "${dest}/cloudflared" --version || true
    return 0
  fi

  info "正在安装 cloudflared..."
  tmp_file="$(mktemp)"

  curl -fL --proto '=https' --tlsv1.2 -o "$tmp_file" "$url" || {
    rm -f "$tmp_file"
    die "下载 cloudflared 失败：$url"
  }

  install -m 0755 "$tmp_file" "${dest}/cloudflared"
  rm -f "$tmp_file"

  info "cloudflared 安装完成：${dest}/cloudflared"
  "${dest}/cloudflared" --version || true

  if ! is_root; then
    warn "非 root 模式：cloudflared 已安装到 ${dest}。如果提示 command not found，请把 ${dest} 加入 PATH。"
  fi
}

find_cloudflared_bin() {
  if command_exists cloudflared; then
    command -v cloudflared
    return 0
  fi

  if is_root && [ -x "/usr/local/bin/cloudflared" ]; then
    echo "/usr/local/bin/cloudflared"
    return 0
  fi

  if [ -x "${HOME}/.local/bin/cloudflared" ]; then
    echo "${HOME}/.local/bin/cloudflared"
    return 0
  fi

  die "没有找到 cloudflared。"
}

prepare_paths() {
  if is_root; then
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    CF_DIR="/root/.cloudflared"
    BIN_PATH="/usr/local/bin/cloudflared"
    SYSTEMCTL_CMD="systemctl"
    JOURNAL_CMD="journalctl -u ${SERVICE_NAME}"
  else
    SERVICE_FILE="${HOME}/.config/systemd/user/${SERVICE_NAME}.service"
    CF_DIR="${HOME}/.cloudflared"
    BIN_PATH="${HOME}/.local/bin/cloudflared"
    SYSTEMCTL_CMD="systemctl --user"
    JOURNAL_CMD="journalctl --user -u ${SERVICE_NAME}"
  fi

  CONFIG_FILE="${CF_DIR}/config.yml"
  TOKEN_FILE="${CF_DIR}/token"
  MAP_FILE="${CF_DIR}/mappings.txt"

  mkdir -p "$CF_DIR"
  chmod 700 "$CF_DIR"
}

backup_if_exists() {
  local file="$1"
  if [ -f "$file" ]; then
    local backup_file="${file}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$file" "$backup_file"
    info "已备份旧文件：$backup_file"
  fi
}

collect_mappings() {
  local num i domain port stream_choice stream_type ws_path proto

  while true; do
    read -r -p "需要配置多少个域名->端口？(例如 2)： " num
    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -gt 0 ]; then
      break
    fi
    echo -e "${RED}✖ 请输入有效的数字（必须大于 0）。${RESET}"
  done

  : > "$MAP_FILE"

  for i in $(seq 1 "$num"); do
    echo
    echo "=== 配置第 ${i} 个域名 ==="

    while true; do
      read -r -p "请输入要绑定的域名（Public Hostname）： " domain
      if validate_domain "$domain"; then
        break
      fi
      echo -e "${RED}✖ 域名格式不正确，请重新输入。${RESET}"
    done

    while true; do
      read -r -p "请输入本地监听端口（默认 443）： " port
      port="${port:-443}"
      if validate_port "$port"; then
        break
      fi
      echo -e "${RED}✖ 端口必须是 1-65535 的数字。${RESET}"
    done

    echo
    echo "请选择传输方式："
    echo "1) WebSocket（默认）"
    echo "2) gRPC"
    echo "3) TCP"

    while true; do
      read -r -p "选择传输类型 (1/2/3，默认 1)： " stream_choice
      stream_choice="${stream_choice:-1}"
      if validate_stream_type "$stream_choice"; then
        break
      fi
      echo -e "${RED}✖ 请输入 1、2 或 3。${RESET}"
    done

    case "$stream_choice" in
      1)
        stream_type="ws"
        read -r -p "请输入 WebSocket 路径（默认 /）： " ws_path
        ws_path="${ws_path:-/}"
        [[ "$ws_path" != /* ]] && ws_path="/$ws_path"
        ;;
      2)
        stream_type="grpc"
        read -r -p "请输入 gRPC ServiceName（默认 vmess-grpc）： " ws_path
        ws_path="${ws_path:-vmess-grpc}"
        ;;
      3)
        stream_type="tcp"
        ws_path="-"
        ;;
    esac

    while true; do
      read -r -p "请输入协议类型 (http/https/tcp，默认 http)： " proto
      proto="${proto:-http}"
      if validate_proto "$proto"; then
        break
      fi
      echo -e "${RED}✖ 协议只能是 http、https 或 tcp。${RESET}"
    done

    printf "%s,%s,%s,%s,%s\n" "$domain" "$port" "$ws_path" "$proto" "$stream_type" >> "$MAP_FILE"
  done
}

extract_tunnel_id_from_json() {
  local json_file="$1"
  local tunnel_id=""

  tunnel_id="$(grep -oE '"TunnelID"[[:space:]]*:[[:space:]]*"[^"]+"' "$json_file" 2>/dev/null | head -n1 | sed -E 's/.*"TunnelID"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"

  if [ -z "$tunnel_id" ]; then
    tunnel_id="$(grep -oE '"tunnel_id"[[:space:]]*:[[:space:]]*"[^"]+"' "$json_file" 2>/dev/null | head -n1 | sed -E 's/.*"tunnel_id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
  fi

  echo "$tunnel_id"
}

collect_credentials() {
  local mode token_value json_content line choice json_file_name tmp_json tunnel_id

  echo
  echo "请选择凭证方式："
  echo "1) Cloudflare Token（推荐，流程同原脚本）"
  echo "2) credentials JSON（直接粘贴内容）"
  read -r -p "选择 (1/2) 默认 1： " mode
  mode="${mode:-1}"

  TUNNEL_TOKEN=""
  CREDENTIAL_FILE=""
  TUNNEL_ID=""

  if [ "$mode" = "1" ]; then
    while true; do
      read -r -s -p "请输入 Cloudflare Tunnel Token（以 eyJ 开头）： " token_value
      echo
      token_value="$(printf "%s" "$token_value" | tr -d '\r\n[:space:]')"

      if [ -n "$token_value" ]; then
        break
      fi

      echo -e "${RED}✖ 必须输入 Token，请重新输入。${RESET}"
    done

    if [[ "$token_value" != eyJ* ]]; then
      warn "这个 Token 不是以 eyJ 开头。Cloudflare Tunnel Token 通常以 eyJ 开头。"
    fi

    printf "%s" "$token_value" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    TUNNEL_TOKEN="$token_value"
    info "Token 已保存：$TOKEN_FILE"

  elif [ "$mode" = "2" ]; then
    while true; do
      echo
      echo "请输入 Cloudflare Tunnel credentials JSON 内容（可多行粘贴，输入完按回车两次结束）"
      echo "---------------------------------------------"

      json_content=""
      while IFS= read -r line; do
        [ -z "$line" ] && break
        json_content="${json_content}${line}"$'\n'
      done

      if [ -z "$json_content" ]; then
        echo -e "${RED}✖ JSON 内容不能为空。${RESET}"
        continue
      fi

      echo "---------------------------------------------"
      echo "你输入的内容为："
      echo "$json_content"
      echo "---------------------------------------------"
      read -r -p "确认保存吗？(1=保存, 2=重新输入)： " choice

      case "$choice" in
        1)
          tmp_json="${CF_DIR}/credentials-temp.json"
          printf "%s" "$json_content" > "$tmp_json"
          chmod 600 "$tmp_json"

          tunnel_id="$(extract_tunnel_id_from_json "$tmp_json")"
          if [ -z "$tunnel_id" ]; then
            while true; do
              read -r -p "无法自动识别 Tunnel UUID，请手动输入： " tunnel_id
              if validate_uuid "$tunnel_id"; then
                break
              fi
              echo -e "${RED}✖ Tunnel UUID 格式不正确。${RESET}"
            done
          fi

          json_file_name="${tunnel_id}.json"
          CREDENTIAL_FILE="${CF_DIR}/${json_file_name}"
          mv "$tmp_json" "$CREDENTIAL_FILE"
          chmod 600 "$CREDENTIAL_FILE"
          TUNNEL_ID="$tunnel_id"
          info "凭证文件已保存：$CREDENTIAL_FILE"
          break
          ;;
        2)
          echo "重新输入..."
          ;;
        *)
          echo "无效选择，请输入 1 或 2。"
          ;;
      esac
    done
  else
    die "无效凭证方式。"
  fi

  CREDENTIAL_MODE="$mode"
}

generate_config() {
  local domain port ws_path proto stream_type service_url

  info "生成配置文件：$CONFIG_FILE"
  backup_if_exists "$CONFIG_FILE"

  {
    echo "# Cloudflare Tunnel Auto Generated"
    echo "# Author: ${AUTHOR_NAME}"
    echo

    if [ "${CREDENTIAL_MODE:-}" = "2" ] && [ -n "${TUNNEL_ID:-}" ] && [ -n "${CREDENTIAL_FILE:-}" ]; then
      echo "tunnel: ${TUNNEL_ID}"
      echo "credentials-file: ${CREDENTIAL_FILE}"
      echo
    fi

    echo "ingress:"

    while IFS=',' read -r domain port ws_path proto stream_type; do
      [ -z "$domain" ] && continue

      case "$proto" in
        tcp)
          service_url="tcp://localhost:${port}"
          ;;
        https)
          service_url="https://localhost:${port}"
          ;;
        http|*)
          service_url="http://localhost:${port}"
          ;;
      esac

      echo "  - hostname: ${domain}"
      echo "    service: ${service_url}"

      if [ "$proto" = "http" ] || [ "$proto" = "https" ]; then
        echo "    originRequest:"
        echo "      noTLSVerify: true"
        echo "      httpHostHeader: ${domain}"

        if [ "$stream_type" = "ws" ]; then
          echo "      headers:"
          echo "        Connection: Upgrade"
          echo "        Upgrade: websocket"
        fi
      fi

      echo
    done < "$MAP_FILE"

    echo "  - service: http_status:404"
  } > "$CONFIG_FILE"

  chmod 600 "$CONFIG_FILE"
  info "配置文件写入完成。"
}

cloudflared_supports_token_file() {
  "$CLOUD_BIN" tunnel run --help 2>&1 | grep -q -- '--token-file'
}

build_exec_cmd() {
  if [ "${CREDENTIAL_MODE:-}" = "1" ]; then
    if cloudflared_supports_token_file; then
      # 安全做法：Token 不进入 systemd ExecStart
      EXEC_CMD="${CLOUD_BIN} tunnel run --token-file ${TOKEN_FILE}"
    else
      # 理论上不会走到这里，因为本脚本会下载新版 cloudflared
      die "当前 cloudflared 不支持 --token-file。请更新 cloudflared 后重试。"
    fi
  else
    if [ -n "${TUNNEL_ID:-}" ]; then
      EXEC_CMD="${CLOUD_BIN} tunnel --config ${CONFIG_FILE} run ${TUNNEL_ID}"
    else
      EXEC_CMD="${CLOUD_BIN} tunnel --config ${CONFIG_FILE} run"
    fi
  fi
}

write_service() {
  backup_if_exists "$SERVICE_FILE"

  if is_root; then
    info "生成 systemd 服务文件（system）：$SERVICE_FILE"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare Tunnel Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${EXEC_CMD}
Restart=on-failure
RestartSec=5s
User=root
WorkingDirectory=${CF_DIR}
NoNewPrivileges=true
PrivateTmp=true
UMask=0077

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$SERVICE_FILE"

  else
    local user_service_dir="${HOME}/.config/systemd/user"
    mkdir -p "$user_service_dir"
    SERVICE_FILE="${user_service_dir}/${SERVICE_NAME}.service"

    info "生成 systemd 用户服务文件（user）：$SERVICE_FILE"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare Tunnel Service (user)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${EXEC_CMD}
Restart=on-failure
RestartSec=5s
WorkingDirectory=${CF_DIR}
NoNewPrivileges=true
PrivateTmp=true
UMask=0077

[Install]
WantedBy=default.target
EOF

    chmod 644 "$SERVICE_FILE"
  fi
}

start_service() {
  if is_root; then
    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME" || true
    sleep 2

    if systemctl is-active --quiet "$SERVICE_NAME"; then
      info "cloudflared system service 启动成功"
    else
      print_failure_help
      exit 1
    fi
  else
    systemctl --user daemon-reload || true
    systemctl --user enable --now "$SERVICE_NAME" || true
    sleep 1

    if systemctl --user is-active --quiet "$SERVICE_NAME"; then
      info "cloudflared 用户服务启动成功（systemd --user）"
      echo "注意：要使用户服务在系统重启后无须登录也能运行，请让管理员执行：loginctl enable-linger ${USER}"
    else
      print_failure_help
      exit 1
    fi
  fi
}

print_failure_help() {
  echo
  echo -e "${RED}✖ Cloudflared 启动失败！${RESET}"
  echo "------------------------------------------------------------"
  echo "可能原因如下："
  echo -e "  ${YELLOW}[1]${RESET} 凭证 Token 或 credentials JSON 无效"
  echo -e "  ${YELLOW}[2]${RESET} config.yml 格式错误"
  echo -e "  ${YELLOW}[3]${RESET} 本地端口未监听 / 被占用"
  echo -e "  ${YELLOW}[4]${RESET} VPS 网络无法连接 Cloudflare"
  echo "------------------------------------------------------------"
  echo "快速排查命令："
  if is_root; then
    echo "  journalctl -u cloudflared -n 80 --no-pager"
    echo "  systemctl status cloudflared"
    echo "  systemctl restart cloudflared"
  else
    echo "  journalctl --user -u cloudflared -n 80 --no-pager"
    echo "  systemctl --user status cloudflared"
    echo "  systemctl --user restart cloudflared"
  fi
  echo "------------------------------------------------------------"
}

print_install_summary() {
  local domain port ws_path proto stream_type

  echo
  echo -e "${YELLOW}"
  echo "安装完成"
  echo "=========================================="
  echo "config: $CONFIG_FILE"
  [ -f "$TOKEN_FILE" ] && echo "token: $TOKEN_FILE"
  [ -n "${CREDENTIAL_FILE:-}" ] && [ -f "$CREDENTIAL_FILE" ] && echo "凭证: $CREDENTIAL_FILE"
  echo
  echo "映射列表："

  if [ -f "$MAP_FILE" ]; then
    cat "$MAP_FILE"
  fi

  echo
  if is_root; then
    echo "查看日志： journalctl -u cloudflared -f"
    echo "重启服务： systemctl restart cloudflared"
  else
    echo "查看日志： journalctl --user -u cloudflared -f"
    echo "重启服务： systemctl --user restart cloudflared"
  fi
  echo "重新执行此脚本并选择 2 可卸载"
  echo "=========================================="
  echo -e "${RESET}"

  echo
  echo "=== 客户端配置与 Zero Trust 面板设置提示 ==="

  if [ -f "$MAP_FILE" ]; then
    while IFS=',' read -r domain port ws_path proto stream_type; do
      [ -z "$domain" ] && continue

      echo
      echo "域名: ${domain}"
      echo "Cloudflare Zero Trust 面板中添加 Service："

      if [ "$proto" = "tcp" ]; then
        echo "  Service type: TCP"
        echo "  URL: tcp://localhost:${port}"
      else
        echo "  Service type: HTTP"
        echo "  URL: ${proto}://localhost:${port}"
      fi

      echo "  Public hostname: ${domain}"
      echo
      echo "v2rayN / v2rayNG 客户端设置示例："

      case "$stream_type" in
        ws)
          echo "  传输协议: WebSocket"
          echo "  路径: ${ws_path}"
          ;;
        grpc)
          echo "  传输协议: gRPC"
          echo "  ServiceName: ${ws_path}"
          ;;
        tcp)
          echo "  传输协议: TCP"
          ;;
      esac

      echo "  地址: ${domain}"
      echo "  端口: 443"
      echo "  TLS: tls"
    done < "$MAP_FILE"
  fi

  echo "=========================================="

  if [ "${CREDENTIAL_MODE:-}" = "1" ]; then
    echo
    warn "你选择的是 Cloudflare Token。新版 cloudflared 的 Token 模式通常由 Zero Trust 面板管理 Public Hostname。"
    warn "本脚本仍按原流程生成 config.yml 和映射提示，但实际路由是否生效取决于你的 Tunnel 类型和 Cloudflare 面板配置。"
    warn "如果你明确需要本机 config.yml 的 ingress 规则生效，建议使用 credentials JSON 方式。"
  fi
}

install_flow() {
  print_header
  echo "进入安装流程..."
  echo

  detect_system
  install_tools
  install_cloudflared
  CLOUD_BIN="$(find_cloudflared_bin)"
  prepare_paths

  local cf_version=""
  cf_version="$("$CLOUD_BIN" --version 2>/dev/null | head -n1 || true)"
  if [ -n "$cf_version" ]; then
    echo "检测到 cloudflared 版本：$cf_version"
  fi

  collect_mappings
  collect_credentials
  generate_config
  build_exec_cmd
  write_service
  start_service
  print_install_summary
}

uninstall_flow() {
  print_header
  echo "进入卸载流程..."
  echo

  prepare_paths

  echo "即将卸载 Cloudflare Tunnel 本机服务。"
  echo
  echo "将会停止并删除："
  echo "  - $SERVICE_FILE"
  echo
  echo "可选删除："
  echo "  - $CF_DIR"
  echo "  - $BIN_PATH"
  echo

  if ! confirm_action "确认继续卸载？"; then
    echo "已取消卸载。"
    return 0
  fi

  if is_root; then
    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload || true
  else
    systemctl --user disable --now "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl --user daemon-reload || true
  fi

  if [ -d "$CF_DIR" ]; then
    if confirm_action "是否删除配置目录 $CF_DIR？这会删除本机保存的 Token / credentials / config.yml。"; then
      rm -rf "$CF_DIR"
      info "已删除配置目录。"
    else
      info "已保留配置目录。"
    fi
  fi

  if [ -f "$BIN_PATH" ]; then
    if confirm_action "是否删除 cloudflared 程序 $BIN_PATH？"; then
      rm -f "$BIN_PATH"
      info "已删除 cloudflared 程序。"
    else
      info "已保留 cloudflared 程序。"
    fi
  fi

  echo
  info "卸载完成。"
}

status_flow() {
  print_header
  prepare_paths

  if is_root; then
    systemctl status "$SERVICE_NAME" --no-pager || true
  else
    systemctl --user status "$SERVICE_NAME" --no-pager || true
  fi
}

logs_flow() {
  print_header
  prepare_paths

  echo "正在查看实时日志。按 Ctrl + C 退出日志。"
  echo

  if is_root; then
    journalctl -u "$SERVICE_NAME" -f
  else
    journalctl --user -u "$SERVICE_NAME" -f
  fi
}

show_config_flow() {
  print_header
  prepare_paths

  echo "配置文件：$CONFIG_FILE"
  echo

  if [ -f "$CONFIG_FILE" ]; then
    cat "$CONFIG_FILE"
  else
    echo "没有找到配置文件。"
  fi
}

restart_flow() {
  print_header
  prepare_paths

  if is_root; then
    systemctl restart "$SERVICE_NAME"
    systemctl status "$SERVICE_NAME" --no-pager || true
  else
    systemctl --user restart "$SERVICE_NAME"
    systemctl --user status "$SERVICE_NAME" --no-pager || true
  fi
}

show_menu() {
  print_header
  echo -e "${BOLD}${GREEN}1) 安装 Argo Tunnel${RESET}"
  echo -e "${BOLD}${RED}2) 卸载 Argo Tunnel${RESET}"
  echo -e "${BOLD}${BLUE}3) 查看服务状态${RESET}"
  echo -e "${BOLD}${CYAN}4) 查看实时日志${RESET}"
  echo -e "${BOLD}${YELLOW}5) 查看配置文件${RESET}"
  echo -e "${BOLD}${YELLOW}6) 重启 Cloudflared${RESET}"
  echo -e "${BOLD}7) 退出脚本${RESET}"
  echo
}

menu_loop() {
  while true; do
    show_menu
    read -r -p "请选择操作 (1/2/3/4/5/6/7): " action
    echo

    case "$action" in
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
        show_config_flow
        pause_return
        ;;
      6)
        restart_flow
        pause_return
        ;;
      7)
        echo "已退出脚本。"
        exit 0
        ;;
      *)
        echo -e "${RED}✖ 无效选择，请输入 1-7。${RESET}"
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
    config)
      show_config_flow
      ;;
    restart)
      restart_flow
      ;;
    -h|--help|help)
      echo "${APP_NAME}"
      echo "作者：${AUTHOR_NAME}"
      echo
      echo "默认菜单：bash <(curl -fsSL 脚本地址)"
      echo "命令模式：bash <(curl -fsSL 脚本地址) install|uninstall|status|logs|config|restart"
      ;;
    *)
      die "未知命令：$cmd"
      ;;
  esac
}

main "$@"
