#!/bin/bash

# Array of IP addresse
declare -a ip_addresses=("34.85.151.204" "35.245.199.166" "35.245.192.43" "34.21.65.199" "34.150.128.39" "34.86.107.147" "34.122.88.234" "35.203.187.215" "34.122.106.226" "34.169.58.148" "34.86.200.2" "35.245.139.122" "35.227.110.143" "35.237.31.183" "35.245.35.99" "34.21.65.57" "34.75.64.99" "34.75.210.218" "34.28.177.118" "34.41.135.81" "34.48.171.56" "34.21.58.108" "34.21.10.207" "34.21.117.229" "35.233.183.201" "35.197.108.78" "34.23.84.176" "35.227.76.164" "35.227.13.182" "34.73.130.88" "34.122.162.212" "34.170.56.103" "35.222.203.201" "34.10.15.129" "35.236.250.1" "34.21.113.78" "35.186.186.48" "34.21.9.59" "34.145.118.23" "34.82.198.84" "34.139.66.247" "35.243.253.26" "35.227.188.27" "34.83.61.239" "34.123.255.128" "35.225.107.0" "35.231.222.110" "34.139.143.142" "34.148.128.156" "35.185.0.219" "34.75.175.101" "34.75.5.207" "34.82.231.234" "34.105.24.46" "34.148.26.24" "34.138.250.118" "35.196.203.74" "35.227.33.25" "35.245.25.133" "35.230.168.32" "104.196.38.14" "34.138.177.161" "34.138.76.201" "35.229.119.132" "34.53.62.17" "35.247.94.74" "34.148.2.186" "35.231.110.138" "35.203.130.155" "34.127.122.12" "35.230.92.163" "35.185.227.69" "35.197.53.163" "34.168.229.148" "34.72.139.23" "35.239.138.110" "34.173.181.4" "104.197.171.90" "104.155.165.146" "34.56.241.41" "34.56.60.207" "34.59.31.202" "35.202.55.206" "35.225.54.225" "34.41.62.135" "34.42.248.174" "34.86.44.181" "35.188.247.46" "34.172.194.144" "34.69.166.255" "34.168.239.89" "34.169.12.222" "35.245.210.112" "34.48.138.255" "34.86.215.225" "34.48.52.228" "34.57.125.148" "34.63.157.29" "34.82.29.175" "35.203.172.172" "34.85.201.69" "35.245.130.77" "34.82.124.0" "34.83.240.150" "35.237.242.250" "34.73.131.85" "34.145.114.31" "104.196.253.254")

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
