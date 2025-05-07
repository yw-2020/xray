#!/bin/bash

set -e

### Step 1: 用户输入分流域名
read -p "请输入需要走WARP分流的域名（多个用空格隔开）: " -a DOMAIN_LIST

### Step 2: 安装依赖
apt update && apt install -y wireguard wireguard-tools curl sudo

### Step 3: 安装 wgcf 并注册 WARP 账户
cd /tmp
curl -L -o wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.15/wgcf_2.2.15_linux_amd64
chmod +x wgcf
./wgcf register --accept-tos
./wgcf generate

mkdir -p /etc/sing-box
cp wgcf-profile.conf /etc/sing-box/

### Step 4: 解析必要参数
PRIVATE_KEY=$(grep PrivateKey /etc/sing-box/wgcf-profile.conf | awk '{print $3}')
PEER_PUBLIC_KEY=$(grep PublicKey /etc/sing-box/wgcf-profile.conf | awk '{print $3}')
ADDR_IPV4=$(grep Address /etc/sing-box/wgcf-profile.conf | grep 172 | awk '{print $3}')
ADDR_IPV6=$(grep Address /etc/sing-box/wgcf-profile.conf | grep ":" | awk '{print $3}')

### Step 5: 安装 sing-box
curl -fsSL https://sing-box.app/deb-install.sh | bash

### Step 6: 生成配置文件
cat > /etc/sing-box/config.json <<EOF
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
        "$ADDR_IPV4",
        "$ADDR_IPV6"
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
        "domain_suffix": [
$(for domain in "${DOMAIN_LIST[@]}"; do echo "          \"$domain\","; done | sed '$s/,$//')
        ],
        "outbound": "warp"
      }
    ],
    "auto_detect_interface": true,
    "final": "direct"
  }
}
EOF

### Step 7: 设置为开机自启服务
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-Box Service
Documentation=https://sing-box.sagernet.org
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

clear
echo -e "\n\e[32m✅ 已成功配置 WARP 分流，当前已生效！\e[0m"
echo -e "\n以下域名已通过 WARP 分流:"
for domain in "${DOMAIN_LIST[@]}"; do
  echo "  - $domain"
done
