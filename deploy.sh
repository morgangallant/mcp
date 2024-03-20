#!/bin/bash

# Deploy script for MCP.

zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu
RESULT=$?
if [ $RESULT -ne 0 ]; then
    echo "Build failed, terminating..."
    exit 1
fi

scp ./zig-out/bin/mcp morgan@mcp:/home/morgan/mcp-tmp
ssh morgan@mcp "sudo systemctl stop mcp && mv /home/morgan/mcp-tmp /home/morgan/mcp && sudo systemctl start mcp"
echo "Binary uploaded and service reloaded on mcp"
