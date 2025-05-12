#!/bin/bash

CONFIG_PATH="/etc/v2ray-agent/sing-box/conf/config.json"
BACKUP_PATH="${CONFIG_PATH}.bak"
TAG_WARP="warp-out"
TAG_DIRECT="direct-out"
SERVICE_NAME="sing-box"

# 备份
cp "$CONFIG_PATH" "$BACKUP_PATH"

# 初始化 jq 检查
if ! command -v jq &>/dev/null; then
  echo "请先安装 jq：apt install -y jq"
  exit 1
fi

# 保证 outbounds 存在并包含 warp-out 和 direct-out
ensure_outbounds() {
  local modified=0
  local tmp=$(mktemp)

  cat "$CONFIG_PATH" |
    jq --argjson warp '{
      "type": "socks",
      "tag": "warp-out",
      "server": "127.0.0.1",
      "server_port": 40000
    }' \
       --argjson direct '{
      "type": "direct",
      "tag": "direct-out"
    }' '
    .outbounds = (
      .outbounds // [] |
      map(select(.tag != "warp-out" and .tag != "direct-out")) +
      [$warp, $direct]
    )' > "$tmp" && mv "$tmp" "$CONFIG_PATH"
}

# 保证 route.rules 存在并有一条 fallback 的 direct-out
ensure_route_structure() {
  local tmp=$(mktemp)
  cat "$CONFIG_PATH" |
    jq '
      .route.rules = (
        .route.rules // [] |
        map(select(.outbound != "direct-out")) +
        [{"outbound": "direct-out"}]
      )
    ' > "$tmp" && mv "$tmp" "$CONFIG_PATH"
}

# 显示当前域名
list_domains() {
  echo "当前分流域名列表："
  jq -r '
    .route.rules[] | select(.domain_suffix) | .domain_suffix
    ' "$CONFIG_PATH" |
    jq -r '.[]' | nl
}

# 添加域名
add_domain() {
  read -rp "请输入要追加的域名（如 example.com）: " domain
  [[ -z "$domain" ]] && echo "❌ 域名不能为空" && return

  local tmp=$(mktemp)

  cat "$CONFIG_PATH" |
    jq --arg d "$domain" '
      .route.rules |=
        map(if .domain_suffix then
              .domain_suffix += [$d] | unique
            else
              .
            end)
    ' > "$tmp" && mv "$tmp" "$CONFIG_PATH"

  echo "✅ 域名已添加：$domain"
}

# 删除域名
delete_domain() {
  list_domains
  read -rp "请输入要删除的域名索引号: " index

  local domain=$(jq -r '
    .route.rules[] | select(.domain_suffix) | .domain_suffix
    ' "$CONFIG_PATH" | jq -r '.[]' | sed -n "${index}p")

  [[ -z "$domain" ]] && echo "❌ 无效的索引" && return

  local tmp=$(mktemp)
  cat "$CONFIG_PATH" |
    jq --arg d "$domain" '
      .route.rules |=
        map(if .domain_suffix then
              .domain_suffix -= [$d]
            else
              .
            end)
    ' > "$tmp" && mv "$tmp" "$CONFIG_PATH"

  echo "✅ 域名已删除：$domain"
}

# 重启服务
restart_singbox() {
  systemctl restart "$SERVICE_NAME"
  echo "🔄 sing-box 服务已重启"
}

# 初始化结构
ensure_outbounds
ensure_route_structure

# 菜单
while true; do
  echo -e "\n======== sing-box 分流域名管理 ========"
  echo "1. 查看当前域名"
  echo "2. 添加新域名"
  echo "3. 删除域名（按编号）"
  echo "4. 退出"
  echo "======================================="
  read -rp "请选择操作（1-4）: " choice

  case "$choice" in
  1)
    list_domains
    ;;
  2)
    add_domain
    restart_singbox
    ;;
  3)
    delete_domain
    restart_singbox
    ;;
  4)
    echo "Bye"
    exit 0
    ;;
  *)
    echo "无效输入"
    ;;
  esac
done
