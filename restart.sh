#!/bin/bash

echo "🔧 Menerapkan tuning sistem untuk ss-local..."

# ====== STEP 1: TUNING SYSTEM ======
# Atur file descriptor
ulimit -n 65535
echo 'ulimit -n 65535' >> ~/.bashrc

# Terapkan sysctl (kalau belum)
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

# ====== STEP 2: HENTIKAN SEMUA ss-local ======
echo "⛔ Mematikan semua proses ss-local..."
pkill -f ss-local

# ====== STEP 3: JALANKAN ULANG ss-local ======
echo "🚀 Menjalankan ulang semua ss-local..."
CONFIG_DIR="/etc/shadowsocks"
LOG_DIR="/tmp"

for config in "$CONFIG_DIR"/*.json; do
  port=$(basename "$config" .json)
  echo "▶️  Memulai ss-local pada port $port"
  nohup ss-local -c "$config" > "$LOG_DIR/ss-local-$port.log" 2>&1 &
done

echo "✅ Semua ss-local telah dijalankan ulang dengan tuning sistem aktif."

