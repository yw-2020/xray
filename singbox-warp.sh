#!/bin/bash

CONFIG_PATH="/etc/v2ray-agent/sing-box/conf/config.json"

ensure_outbounds_and_routes() {
  # 确保 outbounds 存在
  if ! jq -e '.outbounds' "$CONFIG_PATH" >/dev/null; then
    jq '. + {outbounds: []}' "$CONFIG_PATH" > tmp && mv tmp "$CONFIG_PATH"
  fi

  # 确保 warp-out 存在
  if ! jq -e '.outbounds[]? | select(.tag == "warp-out")' "$CONFIG_PATH" >/dev/null; then
    jq '.outbounds += [{"type":"socks","tag":"warp-out","server":"127.0.0.1","server_port":40000}]' "$CONFIG_PATH" > tmp && mv tmp "$CONFIG_PATH"
  fi

  # 确保 direct-out 存在
  if ! jq -e '.outbounds[]? | select(.tag == "direct-out")' "$CONFIG_PATH" >/dev/null; then
    jq '.outbounds += [{"type":"direct","tag":"direct-out"}]' "$CONFIG_PATH" > tmp && mv tmp "$CONFIG_PATH"
  fi

  # 确保 route.rules 存在
  if ! jq -e '.route.rules' "$CONFIG_PATH" >/dev/null; then
    jq '. + {route: {rules: []}}' "$CONFIG_PATH" > tmp && mv tmp "$CONFIG_PATH"
  fi

  # 确保 warp-out 规则存在
  if ! jq -e '.route.rules[]? | select(.outbound == "warp-out")' "$CONFIG_PATH" >/dev/null; then
    jq '.route.rules += [{"domain_suffix": [], "outbound": "warp-out"}]' "$CONFIG_PATH" > tmp && mv tmp "$CONFIG_PATH"
  fi

  # 确保 direct-out 规则存在
  if ! jq -e '.route.rules[]? | select(.outbound == "direct-out")' "$CONFIG_PATH" >/dev/null; then
    jq '.route.rules += [{"outbound": "direct-out"}]' "$CONFIG_PATH" > tmp && mv tmp "$CONFIG_PATH"
  fi
}

list_domains() {
  echo "当前使用 warp 分流的域名："
  jq -r '.route.rules[] | select(.outbound == "warp-out").domain_suffix[]?' "$CONFIG_PATH" | nl
}

add_domain() {
  read -rp "请输入要添加的域名（如 example.com）: " domain
  [ -z "$domain" ] && echo "无效输入" && return
  jq --arg d "$domain" '(.route.rules[] | select(.outbound=="warp-out").domain_suffix) += [$d]' "$CONFIG_PATH" > tmp && mv tmp "$CONFIG_PATH"
  echo "✅ 域名已添加：$domain"
}

delete_domain() {
  list_domains
  total=$(jq -r '.route.rules[] | select(.outbound == "warp-out").domain_suffix | length' "$CONFIG_PATH")
  [ "$total" -eq 0 ] && echo "⚠️ 当前无域名可删。" && return
  read -rp "请输入要删除的域名编号: " idx
  if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "$total" ]; then
    jq --argjson i "$((idx - 1))" '(.route.rules[] | select(.outbound=="warp-out").domain_suffix) |= .[:$i] + .[$i+1:]' "$CONFIG_PATH" > tmp && mv tmp "$CONFIG_PATH"
    echo "✅ 已删除编号 $idx"
  else
    echo "❌ 无效编号"
  fi
}

main() {
  ensure_outbounds_and_routes

  while true; do
    echo -e "\n===== sing-box 分流域名管理 ====="
    echo "1. 查看当前域名"
    echo "2. 添加新域名"
    echo "3. 删除域名（按编号）"
    echo "0. 退出"
    read -rp "请选择操作 (0-3): " choice
    case "$choice" in
      1) list_domains ;;
      2) add_domain && systemctl restart sing-box ;;
      3) delete_domain && systemctl restart sing-box ;;
      0) echo "退出。" && break ;;
      *) echo "❌ 无效输入" ;;
    esac
  done
}

main
