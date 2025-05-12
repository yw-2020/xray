#!/bin/bash

CONFIG_FILE="/etc/v2ray-agent/sing-box/conf/config.json"
BACKUP_FILE="/etc/v2ray-agent/sing-box/conf/config.bak.json"

# 自动备份
backup_config() {
    cp "$CONFIG_FILE" "$BACKUP_FILE"
}

# 获取当前 warp 域名列表
list_domains() {
    echo "当前走 WARP 的域名有："
    jq -r '.route.rules[] | select(.outbound=="warp") | .domain[]' "$CONFIG_FILE"
}

# 添加域名
add_domain() {
    read -p "请输入要添加的域名（如 scholar.google.com）: " domain
    if [[ -z "$domain" ]]; then echo "❌ 域名不能为空"; return; fi

    # 查找是否已有 outbound 为 warp 的规则
    if jq -e '.route.rules[] | select(.outbound=="warp")' "$CONFIG_FILE" > /dev/null; then
        echo "✅ 找到已有 warp 规则，正在追加域名..."
        jq --arg domain "$domain" '
            (.route.rules[] | select(.outbound=="warp").domain) += [$domain]
        ' "$CONFIG_FILE" > /tmp/config.tmp && mv /tmp/config.tmp "$CONFIG_FILE"
    else
        echo "⚠️ 未找到 warp 规则，正在新建..."
        jq --arg domain "$domain" '
            .route.rules += [{
                "domain": [$domain],
                "outbound": "warp"
            }]
        ' "$CONFIG_FILE" > /tmp/config.tmp && mv /tmp/config.tmp "$CONFIG_FILE"
    fi
    echo "✅ 已添加 $domain"
}

# 删除域名
delete_domain() {
    read -p "请输入要删除的域名（如 scholar.google.com）: " domain
    if [[ -z "$domain" ]]; then echo "❌ 域名不能为空"; return; fi

    jq --arg domain "$domain" '
        .route.rules |= map(
            if .outbound == "warp" then
                .domain |= map(select(. != $domain))
            else .
            end
        )
    ' "$CONFIG_FILE" > /tmp/config.tmp && mv /tmp/config.tmp "$CONFIG_FILE"

    echo "✅ 已尝试删除 $domain"
}

# 重启 sing-box
reload_singbox() {
    systemctl restart sing-box && echo "✅ 已重载 sing-box" || echo "❌ 重载失败"
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n==== WARP 域名分流管理脚本 ===="
        echo "1. 查看当前域名"
        echo "2. 添加新域名"
        echo "3. 删除已存在域名"
        echo "4. 重载 sing-box"
        echo "5. 退出"
        read -p "请选择操作（1-5）: " choice

        case "$choice" in
            1) list_domains ;;
            2) backup_config; add_domain; reload_singbox ;;
            3) backup_config; delete_domain; reload_singbox ;;
            4) reload_singbox ;;
            5) echo "退出"; break ;;
            *) echo "无效选项，请输入 1-5" ;;
        esac
    done
}

main_menu
