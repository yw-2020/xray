#!/bin/bash
# Auto-Setup Warp Split Tunneling with sing-box (by @yw-2020)
# 支持首次安装和后续追加分流域名

set -e

CONFIG_FILE="/etc/sing-box/config.json"
WGCF_PROFILE="wgcf-profile.conf"

# 检测是否已经安装
if [ -f "$CONFIG_FILE" ]; then
  echo "\n检测到 sing-box 已安装\n"
  read -p "请输入要添加的分流域名（多个用空格分隔）: " -a new_domains

  if ! command -v jq &>/dev/null; then
    echo "未找到 jq ，正在安装..."
    apt update && apt install -y jq
  fi

  temp_file=$(mktemp)
  jq --argjson new "$(printf '%s\n' "${new_domains[@]}" | jq -R . | jq -s .)" \
     '(.route.rules[] | select(.domain_suffix)) |= . + ($new - (. // [] | unique))' \
     "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"

  echo -e "\n✅ 分流域名已添加，正在重启 sing-box 服务...\n"
  systemctl restart sing-box && echo "✅ 重启成功"
  exit 0
fi

# 第一次安装

# Step 1: Install dependencies
apt update && apt install -y curl wget sudo gnupg wireguard-tools jq

# Step 2: Install wgcf
wget -O /usr/local/bin/wgcf https://github.com/V1J3/wgcf/releases/download/v2.2.15/wgcf_2.2.15_linux_amd64
chmod +x /usr/local/bin/wgcf

# Step 3: Register and generate Warp config
wgcf register --accept-tos
wgcf generate

# Step 4: Extract info from wgcf-profile.conf
PRIVATE_KEY=$(grep 'PrivateKey' $WGCF_PROFILE | cut -d ' ' -f3)
ADDRESS4=$(grep -m1 'Address' $WGCF_PROFILE | cut -d ' ' -f3)
ADDRESS6=$(grep -m2 'Address' $WGCF_PROFILE | tail -n1 | cut -d ' ' -f3)
PEER_PUBLIC_KEY=$(grep 'PublicKey' $WGCF_PROFILE | cut -d ' ' -f3)

# Step 5: Ask user for domains
read -p "请输入要分流的域名（多个用空格分隔）: " -a DOMAIN_LIST

# Convert to JSON array
json_array=$(printf '%s\n' "${DOMAIN_LIST[@]}" | jq -R . | jq -s .)

# Step 6: Create sing-box config
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

# Step 7: Install sing-box
curl -fsSL https://sing-box.app/deb-install.sh | bash

# Step 8: Set up systemd service
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

# Step 9: Enable and start service
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box

echo -e "\n✅ Sing-box Warp 分流已完成并启动成功！"
echo -e "\n🌐 当前分流域名："
printf " - %s\n" "${DOMAIN_LIST[@]}"
