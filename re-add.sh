#!/bin/bash

# Array of IP addresse
declare -a ip_addresses=("35.243.151.140" "34.73.103.159" "34.46.185.60" "34.55.215.247" "34.48.184.141" "34.150.235.102" "34.30.42.125" "34.56.24.97" "34.72.165.35" "34.66.12.109" "35.237.183.218" "35.237.41.95" "34.73.111.195" "34.21.0.170" "34.73.6.198" "35.188.239.169" "35.194.17.19" "34.58.108.242" "34.21.63.48" "34.48.88.208" "34.74.112.28" "34.75.17.207" "34.67.13.129" "34.133.173.68" "34.86.98.9" "34.74.254.228" "34.48.162.195" "35.231.225.233" "34.9.94.161" "34.173.35.99" "34.75.94.140" "34.73.51.3" "35.243.181.73" "34.75.237.126" "35.185.78.181" "35.237.128.130" "34.135.22.174" "104.198.48.189" "34.21.30.95" "35.245.117.104" "35.196.16.171" "35.237.225.126" "35.231.70.216" "35.243.177.71" "35.237.205.185" "104.196.4.223" "35.194.28.254" "35.188.219.182" "34.16.83.2" "34.66.155.192" "34.68.85.24" "35.202.231.189" "34.72.184.160" "35.243.175.50" "34.31.128.153" "35.227.52.210" "35.227.93.251" "34.74.8.123" "34.70.192.196" "34.68.125.222" "34.48.160.165" "34.150.243.133" "35.231.71.105" "34.75.124.60" "35.230.187.194" "34.21.82.11" "34.138.55.157" "34.75.114.220" "35.229.31.36" "35.245.123.235" "35.245.250.126" "35.196.154.217" "35.188.0.219" "34.123.32.24" "35.226.65.246" "35.239.23.189" "35.192.124.255" "34.67.111.6" "34.150.254.20" "35.245.230.18" "34.173.39.154" "35.192.79.244" "104.196.113.204" "34.58.11.202" "34.145.141.182" "34.171.63.239" "34.138.54.16" "35.239.40.246" "35.245.65.217" "34.59.215.2" "34.145.221.32" "34.21.110.212" "35.237.50.202" "34.139.12.179" "34.56.130.138" "34.57.17.11" "34.67.75.225" "34.171.63.247" "34.63.180.162" "34.173.200.167" "35.202.25.166" "35.232.172.170" "34.73.99.126" "34.74.8.207")

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
