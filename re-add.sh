#!/bin/bash

# Array of IP addresse
declare -a ip_addresses=("34.73.81.73" "35.237.197.27" "34.48.63.130" "35.236.240.56" "35.247.96.42" "34.83.3.142" "35.226.156.200" "35.230.191.202" "34.85.226.253" "34.23.175.70" "35.188.160.225" "34.168.228.204" "34.148.137.23" "34.82.231.206" "35.185.86.31" "34.148.123.38" "34.145.127.228" "34.83.204.149" "34.10.40.255" "34.63.198.177" "34.172.16.111" "35.194.15.231" "34.48.151.185" "34.21.17.44" "34.28.130.83" "34.16.14.7" "34.85.153.199" "34.21.21.10" "34.73.90.45" "34.23.13.20" "34.21.70.179" "34.150.218.221" "35.245.206.180" "34.21.0.200" "34.29.83.5" "34.59.209.200" "34.41.102.110" "34.23.12.205" "34.10.31.36" "34.28.132.208" "34.29.108.206" "34.86.203.89" "35.245.72.255" "35.247.13.241" "34.169.190.126" "35.233.140.236" "35.199.181.57" "34.150.131.242" "34.48.49.199" "35.230.65.120" "34.19.30.172" "34.48.189.226" "34.48.106.174" "34.148.45.81" "35.243.227.83" "35.221.63.142" "34.150.195.197" "35.236.222.189" "34.48.153.218" "34.55.98.41" "34.58.177.85" "34.145.147.111" "35.245.151.139" "35.230.110.56" "34.169.126.158" "34.72.150.241" "35.202.189.61" "34.48.174.158" "34.75.238.188" "35.229.124.250")

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
