#!/bin/bash

CONFIG_PATH="/etc/v2ray-agent/sing-box/conf/config.json"
OUTBOUND_TAG="warp-out"
SERVICE_NAME="sing-box"

restart_singbox() {
    echo "🔁 重启 $SERVICE_NAME..."
    systemctl restart "$SERVICE_NAME"
}

load_domains() {
    jq -r --arg tag "$OUTBOUND_TAG" '
      .route.rules[] | select(.outbound == $tag) | (.domain_suffix // [])[]?' "$CONFIG_PATH"
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
      .route.rules |= map(
        if .outbound == $tag then
          .domain_suffix = (.domain_suffix // []) + [$domain]
        else .
        end
      )
    ' "$CONFIG_PATH" > "$tmp" && mv "$tmp" "$CONFIG_PATH"

    echo "✅ 域名已添加: $domain"
    restart_singbox
}

delete_domain() {
    domains=($(load_domains))
    if [ ${#domains[@]} -eq 0 ]; then
        echo "⚠️ 当前无可删除的域名"
        return
    fi

    echo "请选择要删除的域名:"
    for i in "${!domains[@]}"; do
        echo "$((i+1)). ${domains[$i]}"
    done

    read -rp "请输入编号: " idx
    ((idx--))
    if [[ $idx -ge 0 && $idx -lt ${#domains[@]} ]]; then
        del_domain="${domains[$idx]}"
        tmp=$(mktemp)
        jq --arg tag "$OUTBOUND_TAG" --arg domain "$del_domain" '
          .route.rules |= map(
            if .outbound == $tag and (.domain_suffix != null) then
              .domain_suffix |= map(select(. != $domain))
            else .
            end
          )
        ' "$CONFIG_PATH" > "$tmp" && mv "$tmp" "$CONFIG_PATH"

        echo "✅ 已删除域名: $del_domain"
        restart_singbox
    else
        echo "❌ 编号无效"
    fi
}

list_domains() {
    echo "当前分流域名列表："
    load_domains | nl
}

main_menu() {
    while true; do
        echo "===== sing-box 分流域名管理 ====="
        echo "1. 查看当前域名"
        echo "2. 添加新域名"
        echo "3. 删除域名（按编号）"
        echo "4. 退出"
        read -rp "请选择操作 (1-4): " choice
        case "$choice" in
            1) list_domains ;;
            2) add_domain ;;
            3) delete_domain ;;
            4) break ;;
            *) echo "❌ 无效选项" ;;
        esac
        echo ""
    done
}

main_menu
