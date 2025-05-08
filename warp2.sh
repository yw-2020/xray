#!/bin/bash

set -e

# ✅ 检查是否已安装 wireguard-tools
if ! command -v wg &> /dev/null; then
  echo "📦 正在安装 wireguard-tools..."
  apt update && apt install -y wireguard-tools
fi

# 📂 初始化变量
CONFIG_DIR="/etc/v2ray-agent/sing-box/conf"
CONFIG_FILE="$CONFIG_DIR/config.json"
WGCF_CONF="/etc/wireguard/wgcf-profile.conf"

# 🔑 提取 wgcf 配置（已注册的有效配置）
if [[ ! -f "$WGCF_CONF" ]]; then
  echo "❌ 未找到 $WGCF_CONF，请先通过 wgcf 注册 Warp 帐号。"
  echo "👉 使用：bash <(curl -Ls https://raw.githubusercontent.com/fscarmen/warp/main/menu.sh)"
  exit 1
fi

WG_PRIV_KEY=$(grep PrivateKey "$WGCF_CONF" | awk '{print $3}')
WG_PUB_KEY=$(echo "$WG_PRIV_KEY" | wg pubkey)
WARP_PUB_KEY=$(grep PublicKey "$WGCF_CONF" | awk '{print $3}')
WARP_ENDPOINT=$(grep Endpoint "$WGCF_CONF" | awk '{print $3}' | cut -d: -f1)
WARP_PORT=$(grep Endpoint "$WGCF_CONF" | awk '{print $3}' | cut -d: -f2)
LOCAL_IPV4=$(grep Address "$WGCF_CONF" | head -n1 | awk '{print $3}')
RESERVED=$(grep Reserved "$WGCF_CONF" | awk '{print $3}')

# 🧠 检查主 config.json 是否存在
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "❌ 找不到 $CONFIG_FILE，请先配置好你的主配置文件 (如 VLESS) 后再运行本脚本。"
  exit 1
fi

# 🧩 添加 WireGuard outbound（只添加一次）
if ! jq -e '.outbounds[]? | select(.tag=="wireguard_out")' "$CONFIG_FILE" >/dev/null; then
  jq \
    --arg endpoint "$WARP_ENDPOINT" \
    --argjson port "$WARP_PORT" \
    --arg priv "$WG_PRIV_KEY" \
    --arg pub "$WARP_PUB_KEY" \
    --arg local "$LOCAL_IPV4" \
    --arg reserved "$RESERVED" \
    'if .outbounds then .outbounds += [{
      "type": "wireguard",
      "tag": "wireguard_out",
      "server": $endpoint,
      "server_port": $port,
      "local_address": [$local],
      "private_key": $priv,
      "peer_public_key": $pub,
      "reserved": $reserved,
      "mtu": 1280
    }] else . + {"outbounds": [{
      "type": "wireguard",
      "tag": "wireguard_out",
      "server": $endpoint,
      "server_port": $port,
      "local_address": [$local],
      "private_key": $priv,
      "peer_public_key": $pub,
      "reserved": $reserved,
      "mtu": 1280
    }]} end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

  echo -e "\n✅ WireGuard 出站已写入 $CONFIG_FILE"
  echo "🔑 私钥：$WG_PRIV_KEY"
  echo "🔓 公钥：$WG_PUB_KEY"
fi

# 🧩 添加 direct 出站（兜底用）
if ! jq -e '.outbounds[]? | select(.tag=="direct")' "$CONFIG_FILE" >/dev/null; then
  jq '.outbounds += [{"type":"direct","tag":"direct"}]' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
fi

# 🧩 添加默认兜底分流规则（如无则追加）
if ! jq -e '.route.rules[]? | select(.outbound=="direct")' "$CONFIG_FILE" >/dev/null; then
  jq 'if .route then .route.rules += [{"outbound": "direct"}] else . + {"route": {"rules": [{"outbound": "direct"}]}} end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
fi

# 🧩 操作菜单
while true; do
  echo -e "\n=== WireGuard 分流管理 ==="
  echo "1. 添加分流域名"
  echo "2. 查看当前已分流域名"
  echo "3. 删除指定域名"
  echo "4. 清空所有分流规则"
  echo "5. 重启 sing-box 服务"
  echo "6. 退出"
  read -rp $'请选择操作 [1-6]: ' choice

  case $choice in
    1)
      read -rp $'\n🔎 请输入需要分流的域名（多个用逗号分隔）:\n> ' domain_input
      IFS=',' read -ra DOMAIN_ARRAY <<< "$domain_input"
      DOMAIN_JSON=$(printf '%s\n' "${DOMAIN_ARRAY[@]}" | jq -R . | jq -cs .)
      jq --argjson domains "$DOMAIN_JSON" '
        if .route then
          .route.rules += [{"domain_suffix": $domains, "outbound": "wireguard_out"}]
        else
          . + {"route": {"rules": [{"domain_suffix": $domains, "outbound": "wireguard_out"}]}}
        end
      ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
      echo "✅ 已添加分流规则。"
      ;;

    2)
      echo -e "\n📄 当前已分流域名："
      jq -r '.route.rules[]? | select(.outbound=="wireguard_out") | .domain_suffix[]?' "$CONFIG_FILE"
      ;;

    3)
      echo -e "\n📄 当前域名分流列表："
      mapfile -t lines < <(jq -r 'to_entries | .[] | select(.value.outbound=="wireguard_out") | "[\(.key)]: \(.value.domain_suffix[]?)"' "$CONFIG_FILE")
      for i in "${!lines[@]}"; do echo "$i. ${lines[$i]}"; done
      read -rp "请输入要删除的编号: " idx
      index_to_delete=$(echo "${lines[$idx]}" | grep -oP '^\[\K[0-9]+')
      jq --argjson idx "$index_to_delete" 'del(.route.rules[$idx])' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
      echo "✅ 已删除编号 $idx 的分流规则。"
      ;;

    4)
      jq 'if .route.rules then .route.rules |= map(select(.outbound != "wireguard_out")) else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
      echo "🧹 已清空所有 wireguard_out 的分流规则。"
      ;;

    5)
      systemctl restart sing-box && echo "🔄 sing-box 服务已重启"
      ;;

    6)
      echo "👋 已退出。"
      break
      ;;

    *)
      echo "❗ 请输入 1-6 之间的数字"
      ;;
  esac
done
