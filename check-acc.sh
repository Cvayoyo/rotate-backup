#!/bin/bash

ACCOUNTS_DIR="./accounts"
QUOTA_NAME_FILTER="Running On-Demand Standard"

# Cek apakah awscli tersedia
if ! command -v aws &> /dev/null; then
    echo "❌ aws CLI belum terpasang. Install dulu dengan: sudo apt install awscli"
    exit 1
fi

echo "🔍 Memulai pengecekan limit EC2 untuk semua akun di folder $ACCOUNTS_DIR"
echo

for env_file in "$ACCOUNTS_DIR"/*.env; do
    echo "📁 Menggunakan kredensial dari: $env_file"

    # Unset dulu biar tidak konflik antar akun
    unset AWS_ACCESS_KEY_ID
    unset AWS_SECRET_ACCESS_KEY
    unset AWS_SESSION_TOKEN
    unset AWS_DEFAULT_REGION

    # Load env file
    source "$env_file"

    if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" || -z "$AWS_DEFAULT_REGION" ]]; then
        echo "⚠️  $env_file tidak memiliki variabel yang lengkap. Lewati."
        echo
        continue
    fi

    REGION="$AWS_DEFAULT_REGION"
    echo "🔄 Region: $REGION"

    # Ambil semua limit Value yang cocok
    LIMITS=$(aws service-quotas list-service-quotas \
        --service-code ec2 \
        --region "$REGION" \
        --query "Quotas[?contains(QuotaName, \`$QUOTA_NAME_FILTER\`)].Value" \
        --output text 2>/dev/null)

    # Loop semua limit yang ditemukan
    VALID_LIMIT=""
    for val in $LIMITS; do
        if [[ "$val" != "None" && "$val" != "" ]]; then
            VALID_LIMIT="$val"
            break
        fi
    done

    if [[ "$VALID_LIMIT" == "0.0" ]]; then
        echo "🚫 Limit: 0.0 ➜ Account suspended"
    elif [[ -n "$VALID_LIMIT" ]]; then
        echo "✅ Limit: $VALID_LIMIT"
    else
        echo "❌ Tidak menemukan limit valid (None semua atau gagal ambil)."
    fi

    echo "----------------------------------------------------"
    echo
done

