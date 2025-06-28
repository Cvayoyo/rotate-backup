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
                echo "🚫 $env_file vCPU limit 0. Dihapus."
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

echo -e "\n🔍 Mencari instance berdasarkan IP dari config..."
for port in "${ports[@]}"; do
    config_file="$CONFIG_DIR/${port}.json"
    [[ ! -f "$config_file" ]] && echo "⚠️ Config $port.json tidak ditemukan." && continue

    ip=$(jq -r '.server' "$config_file")
    [[ -z "$ip" || "$ip" == "null" ]] && echo "⚠️ IP kosong di $config_file" && continue

    found=0
    for pf in "${profile_files[@]}"; do
        source "$pf"
        profile_name=$(basename "$pf" .env)

        for region in "${regions[@]}"; do
            instance_id=$(AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=$region aws ec2 describe-instances \
                --filters Name=ip-address,Values="$ip" \
                --query 'Reservations[].Instances[].InstanceId' \
                --output text 2>/dev/null)

            if [[ -n "$instance_id" && "$instance_id" != "None" ]]; then
                instance_map["$port"]="${instance_id}|${region}|${AWS_ACCESS_KEY_ID}|${AWS_SECRET_ACCESS_KEY}|${profile_name}|${ip}"
                echo "✅ Port $port → $instance_id ($ip) [detected in: $profile_name/$region]"
                found=1
                break 2
            fi
        done
    done

    [[ "$found" -eq 0 ]] && echo "❌ Tidak bisa temukan instance untuk port $port (IP: $ip)"
done

### STEP 1: STOP INSTANCE
echo -e "\n🛑 Stop semua instance..."
for port in "${!instance_map[@]}"; do
    IFS="|" read -r instance_id region akid skey profile_name ip <<< "${instance_map[$port]}"
    with_retry_env "$akid" "$skey" "$region" "aws ec2 stop-instances --instance-ids $instance_id"
done

### STEP 2: WAIT STOPPED
echo -e "\n⏳ Tunggu semua instance berhenti..."
for port in "${!instance_map[@]}"; do
    IFS="|" read -r instance_id region akid skey profile_name ip <<< "${instance_map[$port]}"
    with_retry_env "$akid" "$skey" "$region" "aws ec2 wait instance-stopped --instance-ids $instance_id"
done

### STEP 3: START INSTANCE
echo -e "\n▶️ Start ulang semua instance..."
for port in "${!instance_map[@]}"; do
    IFS="|" read -r instance_id region akid skey profile_name ip <<< "${instance_map[$port]}"
    with_retry_env "$akid" "$skey" "$region" "aws ec2 start-instances --instance-ids $instance_id"
done

### STEP 4: WAIT RUNNING + OK
echo -e "\n⏳ Tunggu semua instance running dan status OK..."
for port in "${!instance_map[@]}"; do
    IFS="|" read -r instance_id region akid skey profile_name ip <<< "${instance_map[$port]}"
    with_retry_env "$akid" "$skey" "$region" "aws ec2 wait instance-running --instance-ids $instance_id"
    with_retry_env "$akid" "$skey" "$region" "aws ec2 wait instance-status-ok --instance-ids $instance_id"
done

### STEP 5: UPDATE CONFIG
echo -e "\n🔁 Update IP di file config dan restart ss-local..."
for port in "${!instance_map[@]}"; do
    IFS="|" read -r instance_id region akid skey profile_name old_ip <<< "${instance_map[$port]}"
    new_ip=$(AWS_ACCESS_KEY_ID=$akid AWS_SECRET_ACCESS_KEY=$skey AWS_DEFAULT_REGION=$region aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)

    config_file="$CONFIG_DIR/${port}.json"
    [[ "$new_ip" == "$old_ip" ]] && echo "⚠️ Port $port IP belum berubah." && continue

    echo "✅ Port $port: $old_ip → $new_ip"
    jq ".server = \"$new_ip\"" "$config_file" | sudo tee "$config_file.tmp" > /dev/null
    sudo mv "$config_file.tmp" "$config_file"

    pkill -f "$port.json"
    nohup ss-local -c "$config_file" > "/tmp/ss-local-${port}.log" 2>&1 &
done

echo -e "\n🎉 Semua selesai! IP berhasil dirotasi untuk semua port yang valid."

