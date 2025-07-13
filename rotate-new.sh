#!/bin/bash

CONFIG_DIR="/etc/shadowsocks"
ACCOUNTS_DIR="./accounts"
profile_files=(./accounts/*.env)
regions=("us-east-1" "us-west-2")
MAX_ATTEMPT=5

check_account_limits() {
    local QUOTA_NAME_FILTER="Running On-Demand Standard"

    for env_file in "$ACCOUNTS_DIR"/*.env; do
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_REGION
        source "$env_file"
        [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" || -z "$AWS_DEFAULT_REGION" ]] && continue

        REGION="$AWS_DEFAULT_REGION"
        LIMITS=$(aws service-quotas list-service-quotas \
            --service-code ec2 \
            --region "$REGION" \
            --query "Quotas[?contains(QuotaName, \`$QUOTA_NAME_FILTER\`)].Value" \
            --output text 2>/dev/null)

        for val in $LIMITS; do
            if [[ "$val" == "0.0" ]]; then
                echo "🛛 $env_file vCPU limit 0. Dihapus."
                rm -f "$env_file"
                break
            fi
        done
    done
}

with_retry_env() {
    local akid="$1"
    local skey="$2"
    local region="$3"
    local cmd="$4"
    local max_retry=${5:-3}
    local delay=3

    for ((i=1; i<=max_retry; i++)); do
        output=$(AWS_ACCESS_KEY_ID=$akid AWS_SECRET_ACCESS_KEY=$skey AWS_DEFAULT_REGION=$region bash -c "$cmd" 2>&1)
        status=$?

        [[ "$output" == *"InvalidInstanceID.NotFound"* ]] && status=100
        [[ "$output" == *"UnauthorizedOperation"* ]] && status=101

        if [[ $status -eq 0 ]]; then return 0; fi

        echo "⚠️ Gagal ($status): $cmd"
        echo "👉 $output"
        sleep $delay
        delay=$((delay * 2))
    done

    return 1
}

check_account_limits

# --- Ambil port
if [[ "$1" == "--all" ]]; then
    echo "📦 Mode --all: membaca semua port dari $CONFIG_DIR ..."
    ports=()
    for f in "$CONFIG_DIR"/*.json; do
        [[ -e "$f" ]] || continue
        port=$(basename "$f" .json)
        ports+=("$port")
    done
elif [[ $# -ge 1 ]]; then
    ports=("$@")
else
    echo "Usage: $0 <PORT1> [PORT2] ...  atau  $0 --all"
    exit 1
fi

[[ ${#ports[@]} -eq 0 ]] && echo "❌ Tidak ada port ditemukan." && exit 1

declare -A instance_map
declare -A ip_to_instance_map
declare -A ip_to_meta_map

### FAST IP-TO-INSTANCE SCAN
echo -e "\n🚀 Optimized: scan semua instance per akun-region..."

# 1. Ambil semua IP dari config
declare -A port_to_ip
for port in "${ports[@]}"; do
    config_file="$CONFIG_DIR/${port}.json"
    [[ ! -f "$config_file" ]] && echo "⚠️ Config $port.json tidak ditemukan." && continue
    ip=$(jq -r '.server' "$config_file")
    [[ -z "$ip" || "$ip" == "null" ]] && echo "⚠️ IP kosong di $config_file" && continue
    port_to_ip["$port"]="$ip"
done

# 2. Scan semua instance dari semua akun + region
for pf in "${profile_files[@]}"; do
    source "$pf"
    profile_name=$(basename "$pf" .env)
    for region in "${regions[@]}"; do
        result=$(AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=$region aws ec2 describe-instances \
            --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress]' \
            --output text 2>/dev/null)

        while read -r iid pip; do
            [[ -z "$pip" || "$pip" == "None" ]] && continue
            ip_to_instance_map["$pip"]="$iid"
            ip_to_meta_map["$pip"]="${region}|${AWS_ACCESS_KEY_ID}|${AWS_SECRET_ACCESS_KEY}|${profile_name}"
        done <<< "$result"
    done
done

# 3. Mencocokkan IP dari config dengan hasil scan
echo -e "\n🔍 Mencocokkan IP ke instance..."
for port in "${!port_to_ip[@]}"; do
    ip="${port_to_ip[$port]}"
    instance_id="${ip_to_instance_map[$ip]}"
    meta="${ip_to_meta_map[$ip]}"

    if [[ -n "$instance_id" && -n "$meta" ]]; then
        instance_map["$port"]="${instance_id}|${meta}|${ip}"
        echo "✅ Port $port → $instance_id ($ip) [detected in: ${meta##*|}]"
    else
        echo "❌ Tidak bisa temukan instance untuk port $port (IP: $ip)"
    fi
done

### STEP: REASSIGN ELASTIC IPs ###
echo -e "\n🔁 Reassign Elastic IP untuk semua instance..."

for port in "${!instance_map[@]}"; do
    IFS="|" read -r instance_id region akid skey profile_name old_ip <<< "${instance_map[$port]}"
    echo -e "\n[$port] Instance $instance_id ($old_ip) di region $region"

    # 1. Cek apakah IP sekarang adalah Elastic IP
    is_elastic=$(AWS_ACCESS_KEY_ID=$akid AWS_SECRET_ACCESS_KEY=$skey AWS_DEFAULT_REGION=$region \
        aws ec2 describe-addresses --public-ips "$old_ip" --query 'Addresses[0].AllocationId' --output text 2>/dev/null)

    if [[ "$is_elastic" == "None" || -z "$is_elastic" ]]; then
        echo "🔍 $old_ip BUKAN Elastic IP → buat dan assign EIP baru."
    else
        echo "♻️ $old_ip adalah Elastic IP → release & buat baru."
        assoc_id=$(AWS_ACCESS_KEY_ID=$akid AWS_SECRET_ACCESS_KEY=$skey AWS_DEFAULT_REGION=$region \
            aws ec2 describe-addresses --public-ips "$old_ip" --query 'Addresses[0].AssociationId' --output text)

        AWS_ACCESS_KEY_ID=$akid AWS_SECRET_ACCESS_KEY=$skey AWS_DEFAULT_REGION=$region \
            aws ec2 disassociate-address --association-id "$assoc_id" 2>/dev/null

        AWS_ACCESS_KEY_ID=$akid AWS_SECRET_ACCESS_KEY=$skey AWS_DEFAULT_REGION=$region \
            aws ec2 release-address --allocation-id "$is_elastic" 2>/dev/null
    fi

    # 2. Allocate EIP baru
    echo "📱 Mengalokasikan Elastic IP baru..."
    allocation_output=$(AWS_ACCESS_KEY_ID=$akid AWS_SECRET_ACCESS_KEY=$skey AWS_DEFAULT_REGION=$region \
        aws ec2 allocate-address --domain vpc --output json)

    new_ip=$(echo "$allocation_output" | jq -r '.PublicIp')
    alloc_id=$(echo "$allocation_output" | jq -r '.AllocationId')

    # 3. Associate EIP ke instance
    echo "🔗 Associate EIP $new_ip ke instance..."
    AWS_ACCESS_KEY_ID=$akid AWS_SECRET_ACCESS_KEY=$skey AWS_DEFAULT_REGION=$region \
        aws ec2 associate-address --instance-id "$instance_id" --allocation-id "$alloc_id" >/dev/null

    # 4. Update config + restart
    config_file="$CONFIG_DIR/${port}.json"
    jq ".server = \"$new_ip\"" "$config_file" | sudo tee "$config_file.tmp" > /dev/null
    sudo mv "$config_file.tmp" "$config_file"

    pkill -f "$port.json"
    nohup ss-local -c "$config_file" > "/tmp/ss-local-${port}.log" 2>&1 &

    echo "✅ $port: $old_ip → $new_ip [Elastic IP assigned]"
done

echo -e "\n🎉 Semua IP berhasil dirotasi via Elastic IP!"

