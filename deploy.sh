#!/bin/bash

# Deploy script for MCP.

mkdir -p bin
GOOS=linux GOARCH=amd64 go build -o bin/mcp mcp.go
RESULT=$?
if [ $RESULT -ne 0 ]; then
    echo "Go build failed, terminating..."
    exit 1
fi

source .env

if [ -z "$MACHINES" ]; then
    echo "Missing MACHINES environment variable"
    exit 1
fi

IFS=',' read -ra MACHINE_ARRAY <<< "$MACHINES"

if [ ${#MACHINE_ARRAY[@]} -eq 0 ]; then
    echo "No machines provided in MACHINES environment variable, should be comma seperated list"
    exit 1
fi

check_and_upload_service_file() {
    local machine=$1
    local service_file="/lib/systemd/system/mcp.service"

    ssh root@"$machine" "[ -f $service_file ]"
    if [ $? -ne 0 ]; then
	echo "Service file not found on $machine. Uploading..."
	scp mcp.service root@"$machine":/lib/systemd/system/
	ssh root@"$machine" systemctl daemon-reload
	echo "Service file uploaded and systemd daemon reloaded on $machine"
    fi
}

upload_binary_and_start_service() {
    local machine=$1
    scp bin/mcp root@"$machine":/root/mcp-tmp
    scp .env root@"$machine":/root/.env
    ssh root@"$machine" "systemctl stop mcp && mv /root/mcp-tmp /root/mcp && systemctl start mcp"
    echo "Binary uploaded and service started/reloaded on $machine"
}

for machine in "${MACHINE_ARRAY[@]}"; do
    check_and_upload_service_file "$machine"
    upload_binary_and_start_service "$machine"
done
