#!/bin/bash

ACCOUNTS_DIR="/home/rotate/accounts"
REGIONS=("us-east-1" "us-west-2")

# === Cek apakah folder ada ===
if [ ! -d "$ACCOUNTS_DIR" ]; then
  echo "❌ Folder credential tidak ditemukan: $ACCOUNTS_DIR"
  exit 1
fi

# === Loop semua file .env di folder ===
for ENV_FILE in "$ACCOUNTS_DIR"/*.env; do
  [ -e "$ENV_FILE" ] || continue # skip jika tidak ada file .env
  echo -e "\n🔐 Menggunakan credential: $(basename "$ENV_FILE")"
  source "$ENV_FILE"

  for region in "${REGIONS[@]}"; do
    echo -e "🌍 Region: $region"
    
    ips=$(aws ec2 describe-instances \
      --region "$region" \
      --query 'Reservations[*].Instances[*].PublicIpAddress' \
      --output text 2>/dev/null \
      | tr '\t' '\n' \
      | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' \
      | sort -u)
    
    if [ -z "$ips" ]; then
      echo "  ⚠️  Tidak ada IP publik ditemukan."
    else
      echo "$ips" | sed 's/^/  • /'
    fi
  done
done

