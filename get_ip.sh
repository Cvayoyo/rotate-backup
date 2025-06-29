#!/bin/bash

ACCOUNTS_DIR="./accounts"
profile_files=("$ACCOUNTS_DIR"/*.env)
regions=("us-east-1" "us-west-2")

# Cek apakah AWS CLI tersedia
if ! command -v aws &> /dev/null; then
    echo "❌ AWS CLI belum terpasang."
    exit 1
fi

echo -e "\n🌐 Cek EC2 Instance di 3 region utama..."

for pf in "${profile_files[@]}"; do
    [[ ! -f "$pf" ]] && continue
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_REGION

    source "$pf"
    profile_name=$(basename "$pf" .env)

    if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" ]]; then
        echo "⚠️  $profile_name: kredensial tidak lengkap."
        continue
    fi

    for region in "${regions[@]}"; do
        echo -e "\n🔍 Akun: $profile_name | Region: $region"

        result=$(AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
                 AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
                 AWS_DEFAULT_REGION=$region \
                 aws ec2 describe-instances \
                 --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress,State.Name]' \
                 --output text 2>&1)

        status=$?

        if [[ $status -ne 0 ]]; then
            echo "⚠️  Gagal: $result"
            continue
        elif [[ -z "$result" ]]; then
            echo "⚠️  Tidak ada instance ditemukan."
            continue
        fi

        while read -r iid pip state; do
            pip=${pip:-<no-ip>}
            echo "$pip"
        done <<< "$result"
    done
done

echo -e "\n✅ Selesai."

