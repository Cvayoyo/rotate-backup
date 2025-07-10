#!/bin/bash

echo "Mendeteksi semua port yang digunakan oleh ss-local..."
VPS_A_IP=$(curl -s ifconfig.me)

# Cek dependensi
for cmd in jq curl; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: '$cmd' tidak ditemukan. Install dengan: sudo apt install $cmd"
        exit 1
    fi
done

# Inisialisasi array
declare -a PROXY_IPS=()
declare -a VPS_PORTS=()

# Ambil semua baris ps dan simpan dalam array
mapfile -t SS_LOCAL_LINES < <(ps -ef | grep '[s]s-local')

# Loop manual agar array tetap di parent shell
for line in "${SS_LOCAL_LINES[@]}"; do
    config_file=$(echo "$line" | grep -oP '(?<=-c )[^ ]+')

    if [[ -f "$config_file" ]]; then
        port=$(jq -r '.local_port' "$config_file")
        ip_proxy=$(curl --socks5 "$VPS_A_IP:$port" -s --max-time 0.5 http://ifconfig.me)

        if [[ -n "$ip_proxy" ]]; then
            echo "✅ Aktif: studentart.cloud:$port -> $ip_proxy"
            PROXY_IPS+=("$ip_proxy")
            VPS_PORTS+=("studentart.cloud:$port")
        else
            echo "❌ Tidak aktif: studentart.cloud:$port"
            pkill -f "ss-local -c $config_file"
            rm -f "$config_file"
            sed -i "/s$port-ayoyo-studentart.fun/d" /etc/hosts
        fi
    else
        echo "⚠️ Config file tidak ditemukan untuk baris: $line"
    fi
done

echo ""
echo "======== Ringkasan IP dari ifconfig.me (via Proxy) ========"
printf "%s\n" "${PROXY_IPS[@]}"

echo ""
echo "======== Ringkasan VPS IP + Port yang Aktif ========"
printf "%s\n" "${VPS_PORTS[@]}"

# Simpan semua IP proxy ke dalam file ip.list
printf "%s\n" "${PROXY_IPS[@]}" > ip.list

echo ""
echo "✅ Semua IP proxy telah disimpan ke ip.list"
echo "IP VPS asli (tanpa proxy): studentart.cloud"

