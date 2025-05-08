#!/bin/bash
# Auto-Setup Warp Split Tunneling with sing-box (v2ray-agent edition)

set -e

CONFIG_FILE="/etc/v2ray-agent/sing-box/conf/config.json"
SINGBOX_BIN="/etc/v2ray-agent/sing-box/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

# 安装 jq
if ! command -v jq &>/dev/null; then
  echo "未找到 jq，正在安装..."
  apt update && apt install -y jq
fi

# 初始化 config.json
if [ ! -f "$CONFIG_FILE" ]; then
  echo "⚠️ 未检测到 config.json，已为你创建空配置..."
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "output": "console"
  },
  "route": {
    "rules": [
      {
        "domain_suffix": [],
        "outbound": "warp"
      }
    ]
  }
}
EOF
fi

# 强制保证结构合法
tmp=$(mktemp)
jq '
  if .route == null then .route = {} else . end |
  if (.route.rules | type) != "array" then .route.rules = [] else . end |
  .route.rules |= map(
    if has("domain_suffix") | not then . + {"domain_suffix": []}
    elif (.domain_suffix | type) != "array" then .domain_suffix = [] else . end
  )
' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

# 配置 systemd
if [ ! -f "$SERVICE_FILE" ]; then
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sing-Box
After=network.target

[Service]
ExecStart=$SINGBOX_BIN run -c $CONFIG_FILE
Restart=always
Type=simple

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sing-box
fi

# 主循环
while true; do
  echo -e "\n🌐 当前已有分流域名："
  mapfile -t domains < <(jq -r '.route.rules[] | select(.domain_suffix) | .domain_suffix[]' "$CONFIG_FILE")
  if [ ${#domains[@]} -eq 0 ]; then
    echo " - （无）"
  else
    for i in "${!domains[@]}"; do echo " [$i] ${domains[$i]}"; done
  fi

  echo -e "\n请选择操作："
  echo "1）添加域名"
  echo "2）删除域名"
  echo "0）退出"
  read -rp $'\n请输入选项（默认 0）: ' opt
  opt="${opt:-0}"

  case "$opt" in
    0) echo "👋 已退出"; exit 0 ;;
    1)
      read -rp $'\n请输入要添加的分流域名（多个用英文逗号","分隔）: ' input
      IFS=',' read -ra entries <<< "$input"
      cleaned=()
      for d in "${entries[@]}"; do
        d=$(echo "$d" | xargs)
        [ -n "$d" ] && cleaned+=("\"$d\"")
      done
      [ ${#cleaned[@]} -eq 0 ] && echo "未输入有效域名。" && continue
      joined="[${cleaned[*]}]"

      tmp=$(mktemp)
      jq --argjson new "$joined" '
        .route.rules |= map(
          if has("domain_suffix") and (.domain_suffix | type == "array")
          then .domain_suffix += $new | .domain_suffix |= unique
          else .
          end
        )
      ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
      echo "✅ 域名已添加"
      ;;
    2)
      if [ ${#domains[@]} -eq 0 ]; then echo "⚠️ 无可删项"; continue; fi
      echo -e "\n当前域名："
      for i in "${!domains[@]}"; do echo " [$i] ${domains[$i]}"; done
      read -rp $'\n请输入要删除的编号（多个用英文逗号","分隔）: ' del_input
      IFS=',' read -ra to_del <<< "$del_input"

      remain=()
      for i in "${!domains[@]}"; do
        skip=false
        for idx in "${to_del[@]}"; do
          [[ "$i" == "$(echo "$idx" | xargs)" ]] && skip=true && break
        done
        $skip || remain+=("${domains[$i]}")
      done

      json="[\"${remain[*]// /\",\"}\"]"
      tmp=$(mktemp)
      jq --argjson updated "$json" '
        .route.rules |= map(
          if has("domain_suffix") then .domain_suffix = $updated else . end
        )
      ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
      echo "✅ 已删除指定域名"
      ;;
    *)
      echo "❌ 无效输入"
      ;;
  esac

  echo "🔁 正在重启 sing-box..."
  if systemctl restart sing-box; then
    echo "✅ sing-box 启动成功"
  else
    echo "❌ 启动失败，请运行 journalctl -eu sing-box 查看原因"
  fi
done
