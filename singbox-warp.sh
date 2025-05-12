#!/bin/bash

CONFIG_PATH="/etc/v2ray-agent/sing-box/conf/config.json"

ensure_outbounds_and_routes() {
  if ! jq '.outbounds' "$CONFIG_PATH" >/dev/null 2>&1; then
    jq '. + {outbounds: []}' "$CONFIG_PATH" > tmp && mv tmp "$CONFIG_PATH"
  fi

  if jq '.outbounds[]?.tag' "$CONFIG_PATH" | grep -q '"warp-out"'; then
    :
  else
    jq '.outbounds += [{"type":"socks","tag":"warp-out","server":"127.0.0.1","server_port":40000}]' "$CONFIG_PATH" > tmp && mv tmp "$CONFIG_PATH"
  fi

  if jq '.outbounds[]?.tag' "$CONFIG_PATH" | grep -q '"direct-out"'; then
    :
  else
    jq '.outbounds += [{"type":"direct","tag":"direct-out"}]' "$CONFIG_PATH" > tmp && mv tmp "$CONFIG_PATH"
  fi

  if ! jq '.route' "$CONFIG_PATH" >/dev/null 2>&1; then
    jq '. + {route: {rules: []}}' "$CONFIG_PATH" > tmp && mv tmp "$CONFIG_PATH"
  fi

  if ! jq '.route.rules[]?.outbound' "$CONFIG_PATH" | grep -q '"warp-out"'; then
    jq '.route.rules += [{"domain_suffix": [], "outbound": "warp-out"}]' "$CONFIG_PATH" > tmp && mv tmp "$CONFIG_PATH"
  fi

  if ! jq '.route.rules[]?.outbound' "$CONFIG_PATH" | grep -q '"direct-out"'; then
    jq '.route.rules += [{"outbound": "direct-out"}]' "$CONFIG_PATH" > tmp && mv tmp "$CONFIG_PATH"
  fi
}

list_domains() {
  echo "当前使用 WARP 分流的域名："
  jq -r '.route.rules[] | select(.outbound == "warp-out") | .domain_suffix[]' "$CONFIG_PATH" | nl
}

add_domain() {
  read -rp "请输入要添加的域名（不含 https://）： " domain
  [ -z "$domain" ] && echo "无效输入" && return
  jq --arg d "$domain" '(.route.rules[] | select(.outbound=="warp-out").domain_suffix) += [$d]' "$CONFIG_PATH" > tmp && mv tmp "$CONFIG_PATH"
  echo "已添加：$domain"
}

delete_domain() {
  list_domains
  total=$(jq -r '.route.rules[] | select(.outbound == "warp-out") | .domain_suffix | length' "$CONFIG_PATH")
  [ "$total" -eq 0 ] && echo "当前无域名可删。" && return
  read -rp "请输入要删除的域名编号： " idx
  if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "$total" ]; then
    jq --argjson i "$((idx - 1))" '(.route.rules[] | select(.outbound=="warp-out").domain_suffix) |= (.[:$i] + .[$i+1:])' "$CONFIG_PATH" > tmp && mv tmp "$CONFIG_PATH"
    echo "已删除编号 $idx"
  else
    echo "无效编号"
  fi
}

main() {
  ensure_outbounds_and_routes

  echo -e "\n请选择操作："
  echo "1) 查看当前 WARP 域名"
  echo "2) 添加域名"
  echo "3) 删除域名"
  echo "0) 退出"
  read -rp "输入选项编号: " choice

  case "$choice" in
    1) list_domains ;;
    2) add_domain ;;
    3) delete_domain ;;
    0) exit 0 ;;
    *) echo "无效输入" ;;
  esac
}

main
