#!/bin/bash

# Array of IP addresses
declare -a ip_addresses=("34.48.174.118" "34.85.219.126" "34.48.19.187" "34.21.74.169")


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
