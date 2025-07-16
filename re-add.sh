#!/bin/bash

# Array of IP addresses
declare -a ip_addresses=("35.222.58.205" "34.63.249.47" "34.60.201.200" "34.85.247.101" "34.48.114.8" "34.83.192.159" "34.105.124.57" "34.83.48.73" "35.247.60.111" "35.236.233.130" "34.86.151.163" "34.83.227.229" "34.83.241.221" "34.56.135.52" "34.56.192.90" "34.58.17.79" "35.188.127.170" "34.21.26.194" "34.150.205.95" "35.185.254.220" "34.83.227.106" "34.48.150.208" "35.199.40.147" "34.28.22.143" "34.45.84.52" "35.188.216.154" "35.184.56.157" "23.236.52.206" "34.136.186.148" "34.133.163.130" "104.197.17.80" "34.132.45.211" "34.10.76.175" "34.135.251.118" "34.45.78.64" "34.86.186.207" "34.48.115.136" "34.53.12.21" "34.53.124.73" "35.231.79.28" "35.196.71.82" "35.185.77.221" "34.138.56.153" "104.196.249.37" "34.82.22.80" "34.73.1.197" "35.229.107.233" "34.53.84.113" "35.230.31.132" "35.196.135.174" "35.231.98.210" "34.82.169.160" "34.82.103.218" "34.75.178.7" "34.73.165.110" "35.233.211.27" "34.169.212.151" "35.245.168.204" "34.150.137.236" "34.53.7.192" "34.169.120.163" "35.196.220.195" "34.138.170.61" "34.48.99.2" "35.245.137.224" "34.121.32.70" "34.105.62.241" "34.168.239.51" "34.172.157.168" "34.56.98.201" "34.169.95.156" "34.168.43.141" "34.145.166.78" "35.221.26.196" "34.85.171.12" "34.85.206.5" "34.19.68.22" "34.82.227.44" "34.56.81.39" "34.133.5.247" "34.122.23.39" "34.45.128.9" "35.236.198.58" "34.48.11.22" "34.48.138.41" "34.21.27.215" "34.29.66.113" "34.58.173.190" "34.133.114.115")

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
