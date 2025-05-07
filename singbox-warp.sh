#!/bin/bash
# Auto-Setup Warp Split Tunneling with sing-box (v2ray-agent edition)
# 支持首次安装和后续追加、删除分流域名，完全兼容 v2ray-agent 自带 sing-box 路径

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

# 获取现有域名列表
existing_domains=$(jq -r '.route.rules[] | select(.domain_suffix) | .domain_suffix[]' "$CONFIG_FILE" 2>/dev/null || true)
echo -e "\n🌐 当前已有分流域名："
printf " - %s\n" $existing_domains

# 提供菜单：添加或删除
echo -e "\n请选择操作："
echo "1) 添加域名"
echo "2) 删除域名"
echo "0) 退出"
read -p $'\n请输入选项 (默认 0): ' option
option=${option:-0}

if [[ "$option" == "0" ]]; then
  echo "👋 已退出脚本"
  exit 0
fi

if [[ "$option" == "1" ]]; then
  read -p $'\n请输入要添加的分流域名（多个用空格分隔）: ' -a new_domains

  if [ ${#new_domains[@]} -eq 0 ]; then
    echo "未输入任何域名，退出。"
    exit 0
  fi

  temp_file=$(mktemp)
  jq --argjson new "$(printf '%s\n' "${new_domains[@]}" | jq -R . | jq -s .)" '
    .route.rules |= map(
      if has("domain_suffix") then
        .domain_suffix += $new | .domain_suffix |= unique
      else
        .
      end
    )
  ' "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"
  echo -e "\n✅ 域名已添加"

elif [[ "$option" == "2" ]]; then
  read -p $'\n请输入要删除的分流域名（多个用空格分隔）: ' -a del_domains

  if [ ${#del_domains[@]} -eq 0 ]; then
    echo "未输入任何域名，退出。"
    exit 0
  fi

  temp_file=$(mktemp)
  jq --argjson del "$(printf '%s\n' "${del_domains[@]}" | jq -R . | jq -s .)" '
    .route.rules |= map(
      if has("domain_suffix") then
        .domain_suffix |= map(select(INDEX($del) | not))
      else
        .
      end
    )
  ' "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"
  echo -e "\n✅ 域名已删除"
else
  echo "❌ 无效的选项，退出"
  exit 1
fi

# 重启服务
echo -e "\n🔄 正在尝试重启 sing-box..."
$SINGBOX_BIN run -c "$CONFIG_FILE" &>/dev/null &
sleep 2
pgrep -f "$SINGBOX_BIN run" > /dev/null && echo "✅ sing-box 启动成功" || echo "❌ sing-box 启动失败"

# 展示结果
echo -e "\n🌐 最新分流域名："
jq -r '.route.rules[] | select(.domain_suffix) | .domain_suffix[]' "$CONFIG_FILE" | sed 's/^/ - /'
