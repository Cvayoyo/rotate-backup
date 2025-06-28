#!/bin/bash

# === Settingan Awal ===
CONFIG_DIR=/etc/shadowsocks
LOG_DIR=/var/log/ss-local
IP_LIST="/home/rotate/ip.list"
PASSWORD="Pass"
METHOD="aes-128-gcm"
SERVER_PORT=8388

mkdir -p "$LOG_DIR"
mkdir -p "$CONFIG_DIR"

ulimit -n 65535

# === Ambil semua IP yang sudah ada dari config yang berjalan ===
EXISTING_IPS=$(jq -r '.server' "$CONFIG_DIR"/*.json 2>/dev/null | sort -u)

# === Step 1: Tambah hanya IP baru dari ip.list ===
echo "🛠️  Mengecek IP baru dari IP list..."
PORT=$(find "$CONFIG_DIR" -name '*.json' | sed -E 's/.*\/(.*)\.json/\1/' | sort -n | tail -n 1)
PORT=${PORT:-9999}
NEW_COUNT=0

while IFS= read -r ip; do
  if echo "$EXISTING_IPS" | grep -q "^$ip$"; then
    echo "ℹ️  IP $ip sudah ada, dilewati."
    continue
  fi

  PORT=$((PORT + 1))
  CONFIG_FILE="$CONFIG_DIR/$PORT.json"

  cat > "$CONFIG_FILE" <<EOF
{
    "server": "$ip",
    "server_port": $SERVER_PORT,
    "password": "$PASSWORD",
    "method": "$METHOD",
    "mode": "tcp_and_udp",
    "local_address": "0.0.0.0",
    "local_port": $PORT,
    "timeout": 120,
    "udp_timeout": 120,
    "fast_open": true,
    "workers": 10
}
EOF
  echo "✅ Config $PORT dibuat untuk IP $ip"
  ((NEW_COUNT++))
done < "$IP_LIST"

# === Step 2: Jalankan ulang semua ss-local secara paralel ===
echo "🔁 Menjalankan ulang semua ss-local secara paralel..."

pkill -f ss-local
sleep 1

find "$CONFIG_DIR" -name '*.json' | xargs -I {} -P 20 bash -c '
  port=$(basename {} .json)
  echo "▶️  Memulai ss-local pada port $port"
  nohup ss-local -c {} > "$LOG_DIR/ss-local-$port.log" 2>&1 &
'

# === Step 3: Tampilkan IP VPS dan daftar port aktif ===
VPS_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
echo -e "\n======== Ringkasan IP dan Port VPS ========"
for file in "$CONFIG_DIR"/*.json; do
  port=$(jq -r '.local_port' "$file")
  echo "✅ $VPS_IP:$port"
done

echo -e "\n✅ $NEW_COUNT IP baru ditambahkan. Semua ss-local dijalankan ulang."

