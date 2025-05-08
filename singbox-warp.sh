#!/bin/bash
# Auto-Setup Warp Split Tunneling with sing-box (v2ray-agent edition)
# 支持首次安装、后续追加、删除分流域名，完全兼容 v2ray-agent 自带 sing-box 路径

set -e

CONFIG_FILE="/etc/v2ray-agent/sing-box/conf/config.json"
SINGBOX_BIN="/etc/v2ray-agent/sing-box/sing-box"

# 检查是否存在配置文件
if [ ! -f "$CONFIG_FILE" ]; then
  echo "❌ 配置文件不存在：$CONFIG_FILE"
  exit 1
fi

# 检查 jq 工具
if ! command -v jq &>/dev/null; then
  echo "未找到 jq ，正在安装..."
  apt update && apt install -y jq
fi

# 自动初始化 domain_suffix 结构
init_config() {
  temp_file=$(mktemp)
  jq 'if .route == null then .route = {} else . end |
      if .route.rules == null then .route.rules = [{"domain_suffix": [], "outbound": "warp"}] else .route.rules |= map(if .domain_suffix == null then . + {"domain_suffix": []} else . end) end' \
      "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"
}

init_config

while true; do
  echo -e "\n🌐 当前已有分流域名："
  domain_list=( $(jq -r '.route.rules[] | select(.domain_suffix) | .domain_suffix[]' "$CONFIG_FILE") )
  if [ ${#domain_list[@]} -eq 0 ]; then
    echo " - （无）"
  else
    for i in "${!domain_list[@]}"; do
      printf " [%d] %s\n" "$i" "${domain_list[$i]}"
    done
  fi

  echo -e "\n请选择操作："
  echo "1）添加域名"
  echo "2）删除域名"
  echo "0）退出"
  read -p $'\n请输入选项（默认 0）: ' option
  option=${option:-0}

  if [[ "$option" == "0" ]]; then
    echo "👋 已退出脚本"
    exit 0
  fi

  if [[ "$option" == "1" ]]; then
    read -p $'\n请输入要添加的分流域名（多个用英文逗号","分隔）: ' domain_input
    IFS=',' read -ra raw_domains <<< "$domain_input"
    new_domains=()
    for d in "${raw_domains[@]}"; do
      trimmed=$(echo "$d" | xargs)
      if [ -n "$trimmed" ]; then
        new_domains+=("$trimmed")
      fi
    done
    if [ ${#new_domains[@]} -eq 0 ]; then
      echo "未输入任何有效域名，退出。"
      exit 0
    fi
    temp_file=$(mktemp)
    jq --argjson new "$(printf '%s\n' "${new_domains[@]}" | jq -R . | jq -s .)" '
      .route.rules |= map(
        if has("domain_suffix") then
          .domain_suffix += $new | .domain_suffix |= unique
        else . end
      )
    ' "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"
    echo -e "\n✅ 域名已添加"

  elif [[ "$option" == "2" ]]; then
    if [ ${#domain_list[@]} -eq 0 ]; then
      echo "⚠️ 没有可删除的域名。"
      continue
    fi
    echo -e "\n当前分流域名："
    for i in "${!domain_list[@]}"; do
      printf " [%d] %s\n" "$i" "${domain_list[$i]}"
    done

    read -p $'\n请输入要删除的编号（多个用英文逗号","分隔）: ' indexes_input
    IFS=',' read -ra del_indexes <<< "$indexes_input"

    # 验证 index 合法性
    valid_indexes=()
    for idx in "${del_indexes[@]}"; do
      idx=$(echo "$idx" | xargs)
      if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 0 ] && [ "$idx" -lt ${#domain_list[@]} ]; then
        valid_indexes+=("$idx")
      fi
    done

    # 构造新的 domain_suffix 列表
    filtered_list=()
    for i in "${!domain_list[@]}"; do
      skip=false
      for j in "${valid_indexes[@]}"; do
        if [ "$i" == "$j" ]; then
          skip=true
          break
        fi
      done
      if [ "$skip" = false ]; then
        filtered_list+=("${domain_list[$i]}")
      fi
    done

    # 写入新 domain_suffix
    new_json=$(printf '%s\n' "${filtered_list[@]}" | jq -R . | jq -s .)
    temp_file=$(mktemp)
    jq --argjson updated "$new_json" '
      .route.rules |= map(
        if has("domain_suffix") then .domain_suffix = $updated else . end
      )
    ' "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"

    echo -e "\n✅ 指定域名已删除"

  else
    echo "❌ 无效的选项，退出"
    exit 1
  fi

  echo -e "\n🔄 正在尝试重启 sing-box..."
  pkill -f "$SINGBOX_BIN run" 2>/dev/null || true
  sleep 1
  nohup "$SINGBOX_BIN" run -c "$CONFIG_FILE" &>/dev/null &
  sleep 2
  pgrep -f "$SINGBOX_BIN run" > /dev/null && echo "✅ sing-box 启动成功" || {
    echo "❌ sing-box 启动失败"
    echo -e "\n🧨 请执行 journalctl -eu sing-box.service 查看具体报错日志"
  }
done
