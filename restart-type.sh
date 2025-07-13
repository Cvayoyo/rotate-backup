#!/bin/bash

CONFIG_DIR="/etc/shadowsocks"
ACCOUNTS_DIR="./accounts"
profile_files=(./accounts/*.env)
regions=("us-east-1" "us-west-2")
MAX_ATTEMPT=5

OLD_INSTANCE_TYPE="r7a.medium"
NEW_INSTANCE_TYPE="t2.micro"

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

echo -e "\n🚀 Optimized: scan semua instance per akun-region..."

declare -A port_to_ip
for port in "${ports[@]}"; do
    config_file="$CONFIG_DIR/${port}.json"
    [[ ! -f "$config_file" ]] && echo "⚠️ Config $port.json tidak ditemukan." && continue
    ip=$(jq -r '.server' "$config_file")
    [[ -z "$ip" || "$ip" == "null" ]] && echo "⚠️ IP kosong di $config_file" && continue
    port_to_ip["$port"]="$ip"
done

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

echo -e "\n🛬 Stop semua instance..."
for port in "${!instance_map[@]}"; do
    IFS="|" read -r instance_id region akid skey profile_name ip <<< "${instance_map[$port]}"
    with_retry_env "$akid" "$skey" "$region" "aws ec2 stop-instances --instance-ids $instance_id"
done

echo -e "\n⏳ Tunggu semua instance berhenti..."
for port in "${!instance_map[@]}"; do
    IFS="|" read -r instance_id region akid skey profile_name ip <<< "${instance_map[$port]}"
    with_retry_env "$akid" "$skey" "$region" "aws ec2 wait instance-stopped --instance-ids $instance_id"
done

echo -e "\n🔧 Mengecek dan mengganti instance type dari $OLD_INSTANCE_TYPE ke $NEW_INSTANCE_TYPE..."
for port in "${!instance_map[@]}"; do
    IFS="|" read -r instance_id region akid skey profile_name ip <<< "${instance_map[$port]}"
    instance_type=$(AWS_ACCESS_KEY_ID=$akid AWS_SECRET_ACCESS_KEY=$skey AWS_DEFAULT_REGION=$region \
        aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query "Reservations[0].Instances[0].InstanceType" \
        --output text 2>/dev/null)

    if [[ "$instance_type" == "$OLD_INSTANCE_TYPE" ]]; then
        echo "🔁 Port $port: $instance_id ($ip) → $NEW_INSTANCE_TYPE"
        with_retry_env "$akid" "$skey" "$region" \
            "aws ec2 modify-instance-attribute --instance-id $instance_id --instance-type \"{\\\"Value\\\":\\\"$NEW_INSTANCE_TYPE\\\"}\""
    else
        echo "✅ Port $port: $instance_id ($ip) sudah bertipe $instance_type, dilewati."
    fi
done

echo -e "\n▶️ Start ulang semua instance..."
for port in "${!instance_map[@]}"; do
    IFS="|" read -r instance_id region akid skey profile_name ip <<< "${instance_map[$port]}"
    with_retry_env "$akid" "$skey" "$region" "aws ec2 start-instances --instance-ids $instance_id"
done

echo -e "\n⏳ Tunggu semua instance running dan status OK..."
for port in "${!instance_map[@]}"; do
    IFS="|" read -r instance_id region akid skey profile_name ip <<< "${instance_map[$port]}"
    with_retry_env "$akid" "$skey" "$region" "aws ec2 wait instance-running --instance-ids $instance_id"
    with_retry_env "$akid" "$skey" "$region" "aws ec2 wait instance-status-ok --instance-ids $instance_id"
done

echo -e "\n🔁 Update IP di file config dan restart ss-local..."
declare -A region_instance_ids
declare -A region_auth
declare -A instance_old_ip

for port in "${!instance_map[@]}"; do
    IFS="|" read -r instance_id region akid skey profile_name old_ip <<< "${instance_map[$port]}"
    key="${akid}|${skey}|${region}"
    region_instance_ids["$key"]+="$instance_id "
    region_auth["$instance_id"]="$akid|$skey|$region"
    instance_old_ip["$instance_id"]="$old_ip"
done

declare -A instance_new_ips
for key in "${!region_instance_ids[@]}"; do
    IFS="|" read -r akid skey region <<< "$key"
    ids="${region_instance_ids[$key]}"

    result=$(AWS_ACCESS_KEY_ID=$akid AWS_SECRET_ACCESS_KEY=$skey AWS_DEFAULT_REGION=$region aws ec2 describe-instances \
        --instance-ids $ids \
        --query 'Reservations[].Instances[].[InstanceId, PublicIpAddress]' \
        --output text)

    while read -r iid ip; do
        instance_new_ips["$iid"]="$ip"
    done <<< "$result"
done

for port in "${!instance_map[@]}"; do
    IFS="|" read -r instance_id region akid skey profile_name old_ip <<< "${instance_map[$port]}"
    new_ip="${instance_new_ips[$instance_id]}"
    config_file="$CONFIG_DIR/${port}.json"

    if [[ "$new_ip" == "$old_ip" || -z "$new_ip" ]]; then
        echo "⚠️ Port $port IP belum berubah atau gagal ambil IP baru."
        continue
    fi

    echo "✅ Port $port: $old_ip → $new_ip"
    jq ".server = \"$new_ip\"" "$config_file" | sudo tee "$config_file.tmp" > /dev/null
    sudo mv "$config_file.tmp" "$config_file"

    pkill -f "$port.json"
    nohup ss-local -c "$config_file" > "/tmp/ss-local-${port}.log" 2>&1 &
done

echo -e "\n🎉 Semua selesai! IP berhasil dirotasi dan instance type diperbarui."

