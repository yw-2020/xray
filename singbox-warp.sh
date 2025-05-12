#!/bin/bash

CONFIG_PATH="/etc/v2ray-agent/sing-box/conf/config.json"
OUTBOUND_TAG="warp-out"

check_dependencies() {
    if ! command -v jq &>/dev/null; then
        echo "❌ 请先安装 jq 工具: apt install -y jq"
        exit 1
    fi
}

load_domains() {
    jq -r --arg tag "$OUTBOUND_TAG" '
      .route.rules[] | select(.outbound == $tag) | .domain_suffix[]?' "$CONFIG_PATH"
}

add_domain() {
    read -rp "请输入要添加的域名（如 example.com）: " domain
    [[ -z "$domain" ]] && echo "❌ 域名不能为空" && return

    if load_domains | grep -qx "$domain"; then
        echo "⚠️ 域名已存在: $domain"
        return
    fi

    tmp=$(mktemp)
    jq --arg tag "$OUTBOUND_TAG" --arg domain "$domain" '
      .route.rules |= (
        map(
          if .outbound == $tag then
            .domain_suffix += [$domain]
          else .
          end
        )
      )
    ' "$CONFIG_PATH" > "$tmp" && mv "$tmp" "$CONFIG_PATH"

    echo "✅ 域名已添加: $domain"
    restart_singbox
}

delete_domain() {
    echo "📋 当前分流域名列表："
    mapfile -t domains < <(load_domains)
    for i in "${!domains[@]}"; do
        printf "%2d. %s\n" "$((i+1))" "${domains[$i]}"
    done

    read -rp "请输入要删除的域名编号: " index
    if ! [[ "$index" =~ ^[0-9]+$ ]] || (( index < 1 || index > ${#domains[@]} )); then
        echo "❌ 输入不合法"
        return
    fi

    domain="${domains[$((index-1))]}"
    tmp=$(mktemp)
    jq --arg tag "$OUTBOUND_TAG" --arg domain "$domain" '
      .route.rules |= (
        map(
          if .outbound == $tag then
            .domain_suffix |= map(select(. != $domain))
          else .
          end
        )
      )
    ' "$CONFIG_PATH" > "$tmp" && mv "$tmp" "$CONFIG_PATH"

    echo "✅ 域名已删除: $domain"
    restart_singbox
}

restart_singbox() {
    echo "🔄 重启 sing-box..."
    systemctl restart sing-box && echo "✅ sing-box 已重启"
}

main() {
    check_dependencies
    while true; do
        echo -e "\n====== sing-box 分流管理 ======"
        echo "1. 添加分流域名"
        echo "2. 删除分流域名"
        echo "3. 查看当前分流域名"
        echo "0. 退出"
        read -rp "请选择操作: " choice
        case "$choice" in
            1) add_domain ;;
            2) delete_domain ;;
            3) load_domains ;;
            0) exit 0 ;;
            *) echo "❌ 无效选项" ;;
        esac
    done
}

main
