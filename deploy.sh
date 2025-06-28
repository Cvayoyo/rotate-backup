#!/bin/bash
if [ -z "$1" ]; then
  echo "Usage: $0 profile.env"
  exit 1
fi

ENV_PATH="accounts/$1"
if [ ! -f "$ENV_PATH" ]; then
  echo "❌ Env file not found: $ENV_PATH"
  exit 1
fi

source "$ENV_PATH"

REGIONS=("us-east-1" "us-west-2")
SECURITY_GROUP_NAME="allow-all-ss"

for region in "${REGIONS[@]}"; do
  echo "🌍 Checking region $region..."

  GROUP_ID=$(AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
             AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
             AWS_DEFAULT_REGION=$region \
             aws ec2 describe-security-groups \
             --filters Name=group-name,Values=$SECURITY_GROUP_NAME \
             --query "SecurityGroups[0].GroupId" \
             --output text 2>/dev/null)

  if [[ "$GROUP_ID" == "None" || -z "$GROUP_ID" ]]; then
    echo "➡️  Creating security group in $region..."
    GROUP_ID=$(AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
               AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
               AWS_DEFAULT_REGION=$region \
               aws ec2 create-security-group \
               --group-name "$SECURITY_GROUP_NAME" \
               --description "Allow all traffic" \
               --query 'GroupId' \
               --output text)

    until aws ec2 describe-security-groups --group-ids "$GROUP_ID" --region "$region" >/dev/null 2>&1; do
      echo "⏳ Waiting for Security Group to be ready in $region..."
      sleep 3
    done

    for proto in tcp udp; do
      AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
      AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
      AWS_DEFAULT_REGION=$region \
      aws ec2 authorize-security-group-ingress \
        --group-id "$GROUP_ID" \
        --protocol "$proto" \
        --port 0-65535 \
        --cidr 0.0.0.0/0 \
        --output text
    done
  else
    echo "✅ Security group already exists: $GROUP_ID"
  fi

  KEY_NAME="auto-key-$region"
  if ! AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
       AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
       AWS_DEFAULT_REGION=$region \
       aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
    echo "➡️  Creating key pair $KEY_NAME in $region..."
    AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
    AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
    AWS_DEFAULT_REGION=$region \
    aws ec2 create-key-pair \
      --key-name "$KEY_NAME" \
      --query 'KeyMaterial' \
      --output text > "./$KEY_NAME.pem"
    chmod 400 "./$KEY_NAME.pem"
    until aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$region" >/dev/null 2>&1; do
      echo "⏳ Waiting for Key Pair to be ready in $region..."
      sleep 3
    done
  else
    echo "✅ Key pair already exists: $KEY_NAME"
  fi

done

echo "
✅ Semua security group dan key pair telah disiapkan. Lanjut ke deploy_vm.sh"
ulimit -n 65535
echo "🔧 Applying tuning (ulimit + sysctl)..."
sudo tee -a /etc/sysctl.conf > /dev/null <<EOF

# Shadowsocks client optimization
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF

sudo sysctl -p

# === Load ENV ===
if [ -z "$1" ]; then
  echo "Usage: $0 profile.env"
  exit 1
fi

ENV_PATH="accounts/$1"
if [ ! -f "$ENV_PATH" ]; then
  echo "❌ Env file not found: $ENV_PATH"
  exit 1
fi

source "$ENV_PATH"

# === CONFIG ===
REGIONS=("us-east-1" "us-west-2")
declare -A AMI_MAP
AMI_MAP["us-east-1"]=ami-020cba7c55df1f615
AMI_MAP["us-west-2"]=ami-05f991c49d264708f

INSTANCE_TYPE="t2.micro"
SECURITY_GROUP_NAME="allow-all-ss"
INSTANCE_PER_REGION=8
BASE_DOMAIN="ayoyo-studentart.fun"
VPS_A_IP=$(curl -s ifconfig.me)

# === Port base detection ===
last_port=$(find /etc/shadowsocks -type f -name '*.json' | grep -oE '[0-9]{5}' | sort -n | tail -n 1)
if [ -z "$last_port" ]; then
    PORT_BASE=10000
else
    PORT_BASE=$((last_port + 1))
fi

# === Function: Check vCPU limit ===
check_vcpu_limit() {
  local region="$1"
  echo "🧠 Checking vCPU limits for $region..."

  used=$(AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
         AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
         AWS_DEFAULT_REGION=$region \
         aws ec2 describe-instances \
         --query 'Reservations[*].Instances[*].InstanceType' \
         --output text | grep "$INSTANCE_TYPE" | wc -l)

  limit=$(AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
          AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
          AWS_DEFAULT_REGION=$region \
          aws service-quotas get-service-quota \
          --service-code ec2 \
          --quota-code L-1216C47A \
          --query 'Quota.Value' \
          --output text 2>/dev/null)

  if [[ -z "$limit" ]]; then
    echo "⚠️  Cannot retrieve vCPU quota in $region. Skipping..."
    return 1
  fi

  remaining=$(echo "$limit - $used" | bc)
  if (( $(echo "$remaining < 1" | bc -l) )); then
    echo "❌ Not enough vCPU (used: $used, limit: $limit). Skipping..."
    return 1
  fi

  echo "✅ Enough vCPU available (used: $used, limit: $limit, remaining: $remaining)"
  INSTANCE_PER_REGION=$(printf "%.0f\n" $(echo "if ($remaining<$INSTANCE_PER_REGION) $remaining else $INSTANCE_PER_REGION" | bc))
  return 0
}

# === Function: Setup security group + key pair ===
setup_resources() {
  local region="$1"

  GROUP_ID=$(AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
             AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
             AWS_DEFAULT_REGION=$region \
             aws ec2 describe-security-groups \
             --filters Name=group-name,Values=$SECURITY_GROUP_NAME \
             --query "SecurityGroups[0].GroupId" \
             --output text 2>/dev/null)

  if [[ "$GROUP_ID" == "None" || -z "$GROUP_ID" ]]; then
    echo "➡️  Creating security group in $region..."
    GROUP_ID=$(AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
               AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
               AWS_DEFAULT_REGION=$region \
               aws ec2 create-security-group \
               --group-name "$SECURITY_GROUP_NAME" \
               --description "Allow all traffic" \
               --query 'GroupId' \
               --output text)

    until aws ec2 describe-security-groups \
      --group-ids "$GROUP_ID" \
      --region "$region" >/dev/null 2>&1; do
        echo "⏳ Waiting for Security Group to be ready..."
        sleep 3
    done

    for proto in tcp udp; do
      AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
      AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
      AWS_DEFAULT_REGION=$region \
      aws ec2 authorize-security-group-ingress \
        --group-id "$GROUP_ID" \
        --protocol "$proto" \
        --port 0-65535 \
        --cidr 0.0.0.0/0 \
        --output text
    done
  fi

  KEY_NAME="auto-key-$region"
  if ! AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
       AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
       AWS_DEFAULT_REGION=$region \
       aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
    echo "➡️  Creating key pair $KEY_NAME in $region..."
    AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
    AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
    AWS_DEFAULT_REGION=$region \
    aws ec2 create-key-pair \
      --key-name "$KEY_NAME" \
      --query 'KeyMaterial' \
      --output text > "./$KEY_NAME.pem"
    chmod 400 "./$KEY_NAME.pem"
    sleep 5
    until aws ec2 describe-key-pairs \
      --key-names "$KEY_NAME" \
      --region "$region" >/dev/null 2>&1; do
        echo "⏳ Waiting for Key Pair to be ready..."
        sleep 3
    done
  fi

  echo "$GROUP_ID|$KEY_NAME"
}

# === User data ===
read -r -d '' USER_DATA <<'EOF'
#!/bin/bash
apt update && apt install wget xz-utils -y
cd /usr/local/bin
wget https://github.com/shadowsocks/shadowsocks-rust/releases/download/v1.23.4/shadowsocks-v1.23.4.x86_64-unknown-linux-gnu.tar.xz
tar -xvf shadowsocks-*.tar.xz
mv ssserver sslocal ssmanager ssurl /usr/local/bin/
chmod +x /usr/local/bin/ss*

echo "[Unit]
Description=Shadowsocks Rust Server
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c '/usr/local/bin/ssserver -U -s \$(hostname -I | awk \"{print \\\$1}\"):8388 -k Pass -m aes-128-gcm --worker-threads 10 --tcp-fast-open -v'
Restart=always
StandardOutput=file:/var/log/ssserver.log
StandardError=file:/var/log/ssserver.log

[Install]
WantedBy=multi-user.target" > /etc/systemd/system/shadowsocks-server.service

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable shadowsocks-server
systemctl start shadowsocks-server
EOF

# === Deployment Loop ===
RESULTS=()
echo -e "\n📟 IP VPS A:Port Mapping Result"
echo "======================================"

for region in "${REGIONS[@]}"; do
  echo -e "\n🌎 Deploying to region: $region"
  if ! check_vcpu_limit "$region"; then continue; fi

  RESOURCE_OUTPUT=$(setup_resources "$region") || {
    echo "❌ Failed to setup resources in $region. Skipping..."
    continue
  }

  GROUP_ID=$(echo "$RESOURCE_OUTPUT" | cut -d'|' -f1)
  KEY_NAME=$(echo "$RESOURCE_OUTPUT" | cut -d'|' -f2)

  if [[ -z "$GROUP_ID" || "$GROUP_ID" == "None" || -z "$KEY_NAME" ]]; then
    echo "❌ Invalid GROUP_ID or KEY_NAME. Skipping $region..."
    continue
  fi

  declare -a INSTANCE_IDS=()
  declare -A PORT_MAP

  for i in $(seq 0 $((INSTANCE_PER_REGION - 1))); do
    port=$((PORT_BASE + i))
    domain="s${port}-${BASE_DOMAIN}"
    AMI_ID="${AMI_MAP[$region]}"

    echo "🚀 Launching instance $i in $region (port $port)..."

    INSTANCE_ID=$(AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
                  AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
                  AWS_DEFAULT_REGION=$region \
                  aws ec2 run-instances \
                  --image-id "$AMI_ID" \
                  --count 1 \
                  --instance-type "$INSTANCE_TYPE" \
                  --key-name "$KEY_NAME" \
                  --security-group-ids "$GROUP_ID" \
                  --user-data "$USER_DATA" \
                  --query 'Instances[0].InstanceId' \
                  --output text)

    if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
      echo "❌ Failed to create instance $i in $region. Skipping..."
      continue
    fi

    INSTANCE_IDS+=("$INSTANCE_ID")
    PORT_MAP["$INSTANCE_ID"]=$port
  done

  echo "⏳ Waiting for all instances in $region to be running..."
  if [ ${#INSTANCE_IDS[@]} -eq 0 ]; then
    echo "⚠️  No instances created in $region. Skipping wait and config..."
    continue
  fi

  aws ec2 wait instance-running --instance-ids "${INSTANCE_IDS[@]}" --region "$region"

  for INSTANCE_ID in "${INSTANCE_IDS[@]}"; do
    port="${PORT_MAP[$INSTANCE_ID]}"
    domain="s${port}-${BASE_DOMAIN}"

    PUBLIC_IP=$(aws ec2 describe-instances \
      --instance-ids "$INSTANCE_ID" \
      --query 'Reservations[0].Instances[0].PublicIpAddress' \
      --output text \
      --region "$region")

    mkdir -p /etc/shadowsocks
    cat <<EOT | sudo tee /etc/shadowsocks/${port}.json
{
  "server": "$PUBLIC_IP",
  "server_port": 8388,
  "password": "Pass",
  "method": "aes-128-gcm",
  "mode": "tcp_and_udp",
  "local_address": "0.0.0.0",
  "local_port": ${port},
  "timeout": 600,
  "udp_timeout": 120,
  "fast_open": true,
  "workers": 10
}
EOT

    pkill -f "${port}.json"
    nohup ss-local -c /etc/shadowsocks/${port}.json > /tmp/ss-local-${port}.log 2>&1 &

    RESULTS+=("$VPS_A_IP:$port")
  done

  PORT_BASE=$((PORT_BASE + INSTANCE_PER_REGION))
done

echo -e "\n📌 Summary VPS A IP to Port Mapping:"
printf "%s\n" "${RESULTS[@]}"

echo -e "\n🎉 Semua instance telah dibuat dan ss-local dikonfigurasi!"

