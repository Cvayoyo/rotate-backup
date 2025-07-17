#!/bin/bash

# Array of IP addresse
declare -a ip_addresses=("34.46.38.15" "34.70.146.177" "35.231.251.125" "35.231.87.221" "34.10.12.209" "34.60.146.107" "35.245.78.60" "34.48.7.0" "34.31.226.5" "34.42.134.34" "35.245.56.238" "34.48.97.204" "34.23.194.181" "34.23.104.3" "34.74.75.103" "34.73.165.156" "34.123.76.121" "35.223.94.204" "35.227.9.197" "34.172.70.254" "34.44.75.149" "34.63.189.118" "34.134.144.227" "34.46.7.210" "104.197.99.224" "34.46.213.161" "34.41.197.89" "35.185.96.254" "34.23.35.156" "34.63.29.126" "34.61.95.19" "34.75.54.137" "34.73.136.106" "35.202.247.69" "34.72.64.120" "34.41.87.176" "34.58.196.163" "35.188.185.163" "34.134.191.223" "34.123.151.84" "35.222.36.94" "34.145.193.56" "35.194.67.229" "34.60.163.152" "104.198.137.12" "34.85.177.224" "35.245.82.212" "35.245.136.199" "34.145.200.76" "34.23.221.157" "34.74.166.17" "34.150.195.85" "34.48.58.154" "34.86.183.113" "34.21.67.140" "35.236.241.0" "34.145.178.54" "34.150.143.241" "34.21.31.109" "104.196.173.63" "34.74.90.80" "34.73.40.241" "34.73.33.93" "34.75.222.126" "35.243.199.175" "34.58.150.253" "34.132.21.28" "35.245.28.188" "34.48.53.114" "34.45.248.113" "34.61.133.157" "34.170.97.213" "34.10.21.6" "35.188.183.16" "34.134.185.196" "34.48.55.20" "34.86.222.7" "35.221.45.138" "35.194.92.140" "34.74.132.3" "34.23.30.165" "35.226.151.230" "104.155.184.78" "34.31.102.236" "34.123.23.217" "34.16.24.231" "34.28.17.237" "34.86.74.30" "35.236.201.186" "34.55.98.152" "34.66.255.255" "35.229.87.7" "35.185.112.167" "35.245.100.167" "34.145.156.217" "146.148.46.143" "34.170.248.24" "35.188.253.158" "35.221.51.62" "34.21.124.77" "35.236.213.24" "34.58.13.123" "34.10.54.211" "34.150.203.163" "34.21.7.156" "35.243.216.72" "35.243.199.126" "34.74.255.3" "34.138.86.152" "34.46.157.101" "35.225.16.138" "34.138.55.49" "34.139.105.95")

# Base domain name and timestamp
base_domain="ayoyo-studentart.fun"
timestamp=$(date +%m%d%H%M)

# Find the last used port
last_port=$(ss -tln | grep -oE ':1[0-9]{4}' | sed 's/://' | sort -n | tail -n 1)
if [ -z "$last_port" ]; then
    start_port=10000
else
    start_port=$((last_port + 1))
fi

echo "Setting up servers for session ${timestamp}..."
echo "Starting from port: ${start_port}"
echo "-------------------"

# Loop through the IP addresses and create host entries
for i in "${!ip_addresses[@]}"; do
    server_num=$((i + 1))  # Starting from 1
    current_port=$((start_port + i))
    host_alias="s${current_port}-${base_domain}"
    # echo "${ip_addresses[$i]} ${host_alias}" | sudo tee -a /etc/hosts

    # Create shadowsocks config for each server
    config_file="/etc/shadowsocks/${current_port}.json"
    sudo tee "$config_file" > /dev/null <<EOF
{
    "server": "${ip_addresses[$i]}",
    "server_port": 8388,
    "password": "Pass",
    "method": "aes-128-gcm",
    "mode": "tcp_and_udp",
    "local_address": "0.0.0.0",
    "local_port": ${current_port},
    "timeout": 60,
    "udp_timeout": 60,
    "fast_open": true,
    "workers": 10,
    "reuse_port": true
}
EOF

    # Start shadowsocks client for each server
    nohup ss-local -c "$config_file" > /tmp/ss-local-${current_port}.log 2>&1 &
done

# Print the results
echo -e "\nServer configurations for session ${timestamp}:"
echo "====================="
for i in "${!ip_addresses[@]}"; do
    server_num=$((i + 1))
    current_port=$((start_port + i))
    echo "studentart.cloud:${current_port}"
done
echo "====================="
echo -e "\nLogs available at /tmp/ss-local-*-${timestamp}.log"
