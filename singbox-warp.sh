#!/bin/bash
# Auto-Setup Warp Split Tunneling with sing-box (by @yw-2020)
# 支持首次安装、追加与删除分流域名，添加前后显示当前域名

set -e

CONFIG_FILE="/etc/sing-box/config.json"
WGCF_PROFILE="wgcf-profile.conf"

# 检测是否已经安装
if [ -f "$CONFIG_FILE" ]; then
  echo -e "\n检测到 sing-box 已安装"

  if ! command -v jq &>/dev/null; then
    echo "未找到 jq ，正在安装..."
    apt update && apt install -y jq
  fi

  echo -e "\n🌐 当前已有分流域名："
  jq -r '.route.rules[] | select(.domain_suffix) | .domain_suffix[]' "$CONFIG_FILE" | sed 's/^/ - /'

  read -p $'\n请输入要添加的分流域名（多个用空格分隔，输入0跳过）: ' -a new_domains

  # 用户输入 0 跳过添加
  if [[ "${new_domains[*]}" =~ (^|[[:space:]])0($|[[:space:]]) ]]; then
    echo -e "\n⚙️ 选择了跳过添加域名。"
  else
    temp_file=$(mktemp)
    jq --argjson new "$(printf '%s\n' "${new_domains[@]}" | jq -R . | jq -s .)" '
      .route.rules |= map(
        if has("domain_suffix") then
          .domain_suffix += $new | .domain_suffix |= unique
        else . end
      )
    ' "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"
    echo -e "\n✅ 已添加新域名，已重启 sing-box 服务..."
    systemctl restart sing-box
  fi

  read -p $'\n是否要删除已有的分流域名？输入 y 继续，其他任意键跳过：' confirm
  if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
    current_domains=($(jq -r '.route.rules[] | select(.domain_suffix) | .domain_suffix[]' "$CONFIG_FILE"))
    echo -e "\n🌐 当前可删除的域名："
    for i in "${!current_domains[@]}"; do
      printf " [%d] %s\n" "$i" "${current_domains[$i]}"
    done

    read -p $'\n请输入要删除的编号（多个用空格分隔）: ' -a del_indexes

    for idx in "${del_indexes[@]}"; do
      unset 'current_domains[idx]'
    done

    new_json=$(printf '%s\n' "${current_domains[@]}" | jq -R . | jq -s .)
    temp_file=$(mktemp)
    jq --argjson updated "$new_json" '
      .route.rules |= map(
        if has("domain_suffix") then .domain_suffix = $updated else . end
      )
    ' "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"

    echo -e "\n✅ 已删除选定域名，正在重启 sing-box 服务..."
    systemctl restart sing-box
  fi

  echo -e "\n🌐 最新所有分流域名："
  jq -r '.route.rules[] | select(.domain_suffix) | .domain_suffix[]' "$CONFIG_FILE" | sed 's/^/ - /'
  exit 0
fi

# 第一次安装
apt update && apt install -y curl wget sudo gnupg wireguard-tools jq

wget -O /usr/local/bin/wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.15/wgcf_2.2.15_linux_amd64
chmod +x /usr/local/bin/wgcf

wgcf register --accept-tos
wgcf generate

PRIVATE_KEY=$(grep 'PrivateKey' $WGCF_PROFILE | cut -d ' ' -f3)
ADDRESS4=$(grep -m1 'Address' $WGCF_PROFILE | cut -d ' ' -f3)
ADDRESS6=$(grep -m2 'Address' $WGCF_PROFILE | tail -n1 | cut -d ' ' -f3)
PEER_PUBLIC_KEY=$(grep 'PublicKey' $WGCF_PROFILE | cut -d ' ' -f3)

read -p "请输入要分流的域名（多个用空格分隔）: " -a DOMAIN_LIST
json_array=$(printf '%s\n' "${DOMAIN_LIST[@]}" | jq -R . | jq -s .)

mkdir -p /etc/sing-box
cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "info",
    "output": "stderr"
  },
  "dns": {
    "servers": [
      {
        "tag": "dns_direct",
        "address": "8.8.8.8",
        "detour": "direct"
      }
    ]
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "wireguard",
      "tag": "warp",
      "server": "engage.cloudflareclient.com",
      "server_port": 2408,
      "local_address": [
        "$ADDRESS4",
        "$ADDRESS6"
      ],
      "private_key": "$PRIVATE_KEY",
      "peer_public_key": "$PEER_PUBLIC_KEY",
      "reserved": [0, 0, 0],
      "mtu": 1280
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "domain_suffix": $json_array,
        "outbound": "warp"
      }
    ],
    "auto_detect_interface": true,
    "final": "direct"
  }
}
EOF

curl -fsSL https://sing-box.app/deb-install.sh | bash

cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-Box Service
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
LimitNPROC=infinity
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box

echo -e "\n✅ Sing-box Warp 分流已完成并启动成功！"
echo -e "\n🌐 当前分流域名："
printf " - %s\n" "${DOMAIN_LIST[@]}"
