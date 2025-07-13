#!/bin/bash
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

# === System Tuning ===
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
sudo sysctl -p > /dev/null

# === CONFIG ===
REGIONS=("us-east-1" "us-west-2")
declare -A AMI_MAP
AMI_MAP["us-east-1"]="ami-020cba7c55df1f615"
AMI_MAP["us-east-2"]="ami-0d1b5a8c13042c939"
AMI_MAP["us-west-1"]="ami-014e30c8a36252ae5"
AMI_MAP["us-west-2"]="ami-05f991c49d264708f"
INSTANCE_TYPE="t2.micro"
SECURITY_GROUP_NAME="allow-all-ss"
INSTANCE_PER_REGION=5
BASE_DOMAIN="ayoyo-studentart.fun"
VPS_A_IP=$(curl -s ifconfig.me)

# === Port base detection ===
last_port=$(find /etc/shadowsocks -type f -name '*.json' 2>/dev/null | grep -oE '[0-9]{5}' | sort -n | tail -n 1)
if [ -z "$last_port" ]; then
  PORT_BASE=10000
else
  PORT_BASE=$((last_port + 1))
fi

# === Function: Check vCPU limit ===
check_vcpu_limit() {
  local region="$1"
  echo "🧠 Checking vCPU limits for $region..."

  used=$(AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=$region \
    aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceType' --output text | grep "$INSTANCE_TYPE" | wc -l)

  limit=$(AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=$region \
      aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --query 'Quota.Value' --output text 2>/dev/null)

  if [[ -z "$limit" ]]; then
  echo "⚠️ Cannot retrieve vCPU quota in $region. Assuming high limit."
  limit=100 # Default to a high number if quota check fails
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

# === Function: Setup Custom VPC, Subnet, IGW, and Route ===
setup_network() {
    local region="$1"
    local vpc_name="custom-vpc-for-ss"
    local subnet_name="custom-subnet-for-ss"
    local vpc_cidr="172.20.0.0/16"
    local subnet_cidr="172.20.1.0/24"

    echo "🏗️ Setting up custom network in $region using range $vpc_cidr..."

    # 1. Check for or Create VPC
    VPC_ID=$(aws ec2 describe-vpcs --region "$region" --filters "Name=tag:Name,Values=$vpc_name" "Name=isDefault,Values=false" --query "Vpcs[0].VpcId" --output text 2>/dev/null)
    if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
        echo "➡️ Creating VPC ($vpc_name) in $region..."
        VPC_ID=$(aws ec2 create-vpc --region "$region" --cidr-block "$vpc_cidr" --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$vpc_name}]" --query "Vpc.VpcId" --output text)
        aws ec2 wait vpc-available --vpc-ids "$VPC_ID" --region "$region"
        echo "✅ VPC created: $VPC_ID"
    else
        echo "✅ Custom VPC already exists: $VPC_ID"
    fi

    # 2. Check for or Create Subnet and enable public IP mapping
    SUBNET_ID=$(aws ec2 describe-subnets --region "$region" --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$subnet_name" --query "Subnets[0].SubnetId" --output text 2>/dev/null)
    if [[ "$SUBNET_ID" == "None" || -z "$SUBNET_ID" ]]; then
        echo "➡️ Creating Subnet ($subnet_name) in $region..."
        SUBNET_ID=$(aws ec2 create-subnet --region "$region" --vpc-id "$VPC_ID" --cidr-block "$subnet_cidr" --availability-zone "${region}a" --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$subnet_name}]" --query "Subnet.SubnetId" --output text)
        aws ec2 wait subnet-available --subnet-ids "$SUBNET_ID" --region "$region"
        aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_ID" --map-public-ip-on-launch --region "$region" > /dev/null
        echo "✅ Subnet created and enabled for public IP: $SUBNET_ID"
    else
        echo "✅ Custom Subnet already exists: $SUBNET_ID"
    fi

    # 3. Check for or Create and Attach Internet Gateway
    IGW_ID=$(aws ec2 describe-internet-gateways --region "$region" --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[0].InternetGatewayId" --output text 2>/dev/null)
    if [[ "$IGW_ID" == "None" || -z "$IGW_ID" ]]; then
        echo "➡️ Creating and attaching Internet Gateway in $region..."
        IGW_ID=$(aws ec2 create-internet-gateway --region "$region" --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${vpc_name}-igw}]" --query "InternetGateway.InternetGatewayId" --output text)
        aws ec2 attach-internet-gateway --region "$region" --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"
        echo "✅ Internet Gateway created and attached: $IGW_ID"
    else
        echo "✅ Internet Gateway already attached: $IGW_ID"
    C
    fi

    # 4. Check for or Create Route to the Internet
    ROUTE_TABLE_ID=$(aws ec2 describe-route-tables --region "$region" --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" --query "RouteTables[0].RouteTableId" --output text 2>/dev/null)
    ROUTE_EXISTS=$(aws ec2 describe-route-tables --region "$region" --route-table-id "$ROUTE_TABLE_ID" --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0' && GatewayId=='$IGW_ID']" --output text 2>/dev/null)
    if [[ -z "$ROUTE_EXISTS" ]]; then
        echo "➡️ Creating route to Internet Gateway in Route Table $ROUTE_TABLE_ID..."
        aws ec2 create-route --region "$region" --route-table-id "$ROUTE_TABLE_ID" --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" > /dev/null
        echo "✅ Route to internet created."
    else
        echo "✅ Route to internet already exists."
    fi

    # IMPORTANT: Only echo the IDs needed for the calling script
    echo "$SUBNET_ID,$VPC_ID" # Use a comma or space as a delimiter
}

# === Function: Setup security group + key pair ===
setup_resources() {
  local region="$1"
  local vpc_id="$2"

  GROUP_ID=$(AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=$region \
             aws ec2 describe-security-groups --filters Name=group-name,Values=$SECURITY_GROUP_NAME Name=vpc-id,Values=$vpc_id --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)

  if [[ "$GROUP_ID" == "None" || -z "$GROUP_ID" ]]; then
    echo "➡️ Creating security group in $region for VPC $vpc_id..."
    GROUP_ID=$(AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=$region \
                aws ec2 create-security-group --group-name "$SECURITY_GROUP_NAME" --description "Allow all traffic" --vpc-id "$vpc_id" --query 'GroupId' --output text)
    until aws ec2 describe-security-groups --group-ids "$GROUP_ID" --region "$region" >/dev/null 2>&1; do
      echo "⏳ Waiting for Security Group to be ready..."
      sleep 3
    done
    for proto in tcp udp; do
      AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=$region \
        aws ec2 authorize-security-group-ingress --group-id "$GROUP_ID" --protocol "$proto" --port 0-65535 --cidr 0.0.0.0/0
    done
  else
    echo "✅ Security group already exists: $GROUP_ID"
  fi

  KEY_NAME="auto-key-$region"
  if ! AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=$region aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
    echo "➡️ Creating key pair $KEY_NAME in $region..."
    AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=$region \
      aws ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "./$KEY_NAME.pem"
    chmod 400 "./$KEY_NAME.pem"
    until aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$region" >/dev/null 2>&1; do
      echo "⏳ Waiting for Key Pair to be ready..."
      sleep 3
    done
  else
    echo "✅ Key pair already exists: $KEY_NAME"
  fi

  # IMPORTANT: Only echo the IDs needed for the calling script
  echo "$GROUP_ID,$KEY_NAME" # Use a comma or space as a delimiter
}

# === User data ===
read -r -d '' USER_DATA <<'EOF'
#!/bin/bash
apt update
apt install shadowsocks-libev -y
echo "[Unit]
Description=Shadowsocks Rust Server
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c '/usr/bin/ss-server -u -s \$(hostname -I | awk \"{print \\\$1}\") -p 8388 -k Pass -m aes-128-gcm -n 65535 --fast-open --reuse-port --no-delay -v'
Restart=always
StandardOutput=file:/var/log/ssserver.log
StandardError=file:/var/log/ssserver.log

[Install]
WantedBy=multi-user.target" > /etc/systemd/system/shadowsocks-server.service

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable shadowsocks-server
systemctl start shadowsocks-server
systemctl status shadowsocks-server
EOF

# === Deployment Loop ===
RESULTS=()
echo -e "\n📟 IP VPS A:Port Mapping Result"
echo "======================================"

for region in "${REGIONS[@]}"; do
  echo -e "\n🌎 Deploying to region: $region"
  if ! check_vcpu_limit "$region"; then continue; fi

  # Capture only the last line of output from setup_network
  # Redirecting stderr to dev/null for cleaner output in the variable
  NETWORK_INFO=$(setup_network "$region" 2>/dev/null | tail -n 1)
  SUBNET_ID=$(echo "$NETWORK_INFO" | cut -d',' -f1)
  VPC_ID=$(echo "$NETWORK_INFO" | cut -d',' -f2)

  if [[ -z "$SUBNET_ID" || -z "$VPC_ID" ]]; then
    echo "❌ Failed to get Subnet ID or VPC ID from setup_network in $region. Skipping..."
    continue
  fi

  # Capture only the last line of output from setup_resources
  RESOURCE_INFO=$(setup_resources "$region" "$VPC_ID" 2>/dev/null | tail -n 1)
  GROUP_ID=$(echo "$RESOURCE_INFO" | cut -d',' -f1)
  KEY_NAME=$(echo "$RESOURCE_INFO" | cut -d',' -f2)

  if [[ -z "$GROUP_ID" || "$GROUP_ID" == "None" || -z "$KEY_NAME" || "$KEY_NAME" == "None" ]]; then
    echo "❌ Invalid Security Group ID or Key Name. Skipping $region..."
    continue
  fi

  declare -a INSTANCE_IDS=()
  declare -A PORT_MAP

  for i in $(seq 0 $((INSTANCE_PER_REGION - 1))); do
    port=$((PORT_BASE + i))
    AMI_ID="${AMI_MAP[$region]}"
    echo "🚀 Launching instance $i in $region (port $port) into subnet $SUBNET_ID..."

    INSTANCE_ID=$(AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=$region \
                  aws ec2 run-instances \
                  --image-id "$AMI_ID" \
                  --count 1 \
                  --instance-type "$INSTANCE_TYPE" \
                  --key-name "$KEY_NAME" \
                  --security-group-ids "$GROUP_ID" \
                  --subnet-id "$SUBNET_ID" \
                  --user-data "$USER_DATA" \
                  --query 'Instances[0].InstanceId' --output text)

    if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
      echo "❌ Failed to create instance $i in $region. Skipping..."
      continue
    fi
    INSTANCE_IDS+=("$INSTANCE_ID")
    PORT_MAP["$INSTANCE_ID"]=$port
  done

  echo "⏳ Waiting for all instances in $region to be running..."
  if [ ${#INSTANCE_IDS[@]} -eq 0 ]; then
    echo "⚠️ No instances created in $region. Skipping wait and config..."
    continue
  fi

  aws ec2 wait instance-running --instance-ids "${INSTANCE_IDS[@]}" --region "$region"
  echo "Instances are running. Waiting 30s for initialization..."
  sleep 30

  for INSTANCE_ID in "${INSTANCE_IDS[@]}"; do
    port="${PORT_MAP[$INSTANCE_ID]}"
    PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region "$region")

    if [[ -z "$PUBLIC_IP" || "$PUBLIC_IP" == "None" ]]; then
        echo "❌ Could not get Public IP for instance $INSTANCE_ID. Skipping config."
        continue
    fi

    mkdir -p /etc/shadowsocks
    sudo tee /etc/shadowsocks/${port}.json > /dev/null <<EOT
{
  "server": "$PUBLIC_IP",
  "server_port": 8388,
  "password": "Pass",
  "method": "aes-128-gcm",
  "mode": "tcp_and_udp",
  "local_address": "0.0.0.0",
  "local_port": ${port},
  "timeout": 60,
  "udp_timeout": 60,
  "fast_open": true,
  "reuse_port": true
}
EOT

    pkill -f "ss-local -c /etc/shadowsocks/${port}.json"
    nohup ss-local -c /etc/shadowsocks/${port}.json > /tmp/ss-local-${port}.log 2>&1 &
    RESULTS+=("$VPS_A_IP:$port")
  done
  PORT_BASE=$((PORT_BASE + INSTANCE_PER_REGION))
done

echo -e "\n📌 Summary VPS A IP to Port Mapping:"
printf "%s\n" "${RESULTS[@]}"
echo -e "\n🎉 All instances have been created and ss-local is configured!"
