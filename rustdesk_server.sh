#!/bin/bash

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || ip -4 addr show tailscale0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "")
if [ -n "$1" ]; then
    SERVER_IP="$1"
elif [ -n "$TAILSCALE_IP" ]; then
    SERVER_IP="$TAILSCALE_IP"
else
    SERVER_IP=$(curl -s ifconfig.me || echo "localhost")
fi
HBBS_PORT=21115
HBBR_PORT=21117
UDP_PORT=21116
WEBSOCKET_PORT=21118

echo -e "${BLUE}=== RustDesk Personal Server Setup ===${NC}"
echo -e "${YELLOW}Server IP configured: ${SERVER_IP}${NC}"
if [ -n "$TAILSCALE_IP" ]; then
    echo -e "${GREEN}Tailscale IP detected: ${TAILSCALE_IP}${NC}"
fi

# Function to print status
print_status() {
   echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
   echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
   echo -e "${RED}[ERROR]${NC} $1"
}

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
   print_error "Docker is not installed. Please install Docker first."
   exit 1
fi

print_status "Docker found, proceeding with setup..."

# Clean up existing containers and volumes
print_status "Cleaning up existing RustDesk containers..."
docker stop hbbs hbbr 2>/dev/null || true
docker rm hbbs hbbr 2>/dev/null || true

# Create Docker volumes for persistent data
print_status "Creating Docker volumes..."
docker volume create hbbs-data 2>/dev/null || true
docker volume create hbbr-data 2>/dev/null || true

# Check for port conflicts (but don't kill RustDesk client)
print_status "Checking for port conflicts..."
if lsof -i :21117 >/dev/null 2>&1; then
   print_warning "Port 21117 is in use - this may cause issues"
fi
if lsof -i :21115 >/dev/null 2>&1; then
   print_warning "Port 21115 is in use - this may cause issues"
fi

# Start hbbr (relay server) first
print_status "Starting RustDesk Relay Server (hbbr)..."
docker run -d \
   --name hbbr \
   --restart unless-stopped \
   -p ${HBBR_PORT}:21117 \
   -v hbbr-data:/root \
   rustdesk/rustdesk-server:latest \
   hbbr

# Wait for hbbr to start
sleep 3

# Start hbbs (ID server)
print_status "Starting RustDesk ID Server (hbbs)..."
docker run -d \
   --name hbbs \
   --restart unless-stopped \
   -p ${HBBS_PORT}:21115 \
   -p ${UDP_PORT}:21116 \
   -p ${UDP_PORT}:21116/udp \
   -v hbbs-data:/root \
   rustdesk/rustdesk-server:latest \
   hbbs --relay-servers ${SERVER_IP}:${HBBR_PORT}

# Wait for containers to fully start
print_status "Waiting for servers to initialize..."
sleep 5

# Check if containers are running
if ! docker ps | grep -q hbbs; then
   print_error "hbbs container failed to start"
   docker logs hbbs
   exit 1
fi

if ! docker ps | grep -q hbbr; then
   print_error "hbbr container failed to start"
   docker logs hbbr
   exit 1
fi

print_status "Both containers are running successfully!"

# Extract the public key
print_status "Extracting server public key..."
sleep 2  # Give time for key generation

# Try to get the public key using docker cp method
PUBLIC_KEY=""
for i in {1..10}; do
   if docker cp hbbs:/root/id_ed25519.pub /tmp/rustdesk_key_temp.txt 2>/dev/null; then
       PUBLIC_KEY=$(cat /tmp/rustdesk_key_temp.txt 2>/dev/null | tr -d '\0' || echo "")
       rm -f /tmp/rustdesk_key_temp.txt
       if [ ! -z "$PUBLIC_KEY" ]; then
           print_status "✓ Public key extracted successfully!"
           break
       fi
   fi
   print_warning "Waiting for key generation... (attempt $i/10)"
   sleep 2
done

if [ -z "$PUBLIC_KEY" ]; then
   print_warning "Could not extract public key automatically. Check container logs."
   PUBLIC_KEY="<Check container logs for public key>"
fi

# Display server information immediately after extraction
echo ""
echo -e "${GREEN}=== SERVER INFORMATION ===${NC}"
echo -e "${BLUE}Server IP:${NC} ${SERVER_IP}"
echo -e "${BLUE}ID Server:${NC} ${SERVER_IP}:${HBBS_PORT}"
echo -e "${BLUE}Relay Server:${NC} ${SERVER_IP}:${HBBR_PORT}"
echo -e "${BLUE}Public Key:${NC} ${PUBLIC_KEY}"
echo ""

# Test connectivity
print_status "Testing server connectivity..."

# Test ID server
if nc -z -w 3 ${SERVER_IP} ${HBBS_PORT} 2>/dev/null; then
   print_status "✓ ID Server (port ${HBBS_PORT}) is accessible"
else
   print_warning "✗ ID Server (port ${HBBS_PORT}) connectivity test failed"
fi

# Test Relay server
if nc -z -w 3 ${SERVER_IP} ${HBBR_PORT} 2>/dev/null; then
   print_status "✓ Relay Server (port ${HBBR_PORT}) is accessible"
else
   print_warning "✗ Relay Server (port ${HBBR_PORT}) connectivity test failed"
fi

# Generate configuration file
CONFIG_FILE="/tmp/rustdesk-config.txt"
cat > ${CONFIG_FILE} << EOF
=== RustDesk Personal Server Configuration ===

Server IP: ${SERVER_IP}
ID Server: ${SERVER_IP}:${HBBS_PORT}
Relay Server: ${SERVER_IP}:${HBBR_PORT}
Public Key: ${PUBLIC_KEY}

=== Client Configuration ===
In your RustDesk client:
1. Go to Settings → Network → ID/Relay Server
2. Enter ONLY the server IP (without port):
  - ID/Relay Server: ${SERVER_IP}
  - Key: ${PUBLIC_KEY}
3. Click Apply

Note: RustDesk uses default ports automatically:
- Port 21115 for ID Server (TCP)
- Port 21116 for ID Server (UDP)
- Port 21117 for Relay Server

=== Docker Management ===
View logs: docker logs hbbs / docker logs hbbr
Stop servers: docker stop hbbs hbbr
Start servers: docker start hbbs hbbr
Remove servers: docker rm hbbs hbbr

=== Port Information ===
- ${HBBS_PORT}/TCP: ID Server
- ${UDP_PORT}/UDP: ID Server (UDP)
- ${HBBR_PORT}/TCP: Relay Server
- ${WEBSOCKET_PORT}/TCP: WebSocket (hbbr)
- 21119/TCP: Additional relay port

EOF

# Display final configuration
echo ""
echo -e "${GREEN}=== Setup Complete! ===${NC}"
echo ""
cat ${CONFIG_FILE}
echo ""
print_status "Configuration saved to: ${CONFIG_FILE}"

# Show container status
echo ""
print_status "Container Status:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "(hbbs|hbbr|NAMES)"

echo ""
print_status "RustDesk Personal Server is ready for client connections!"
print_warning "Make sure ports ${HBBS_PORT}, ${UDP_PORT}, and ${HBBR_PORT} are open in your firewall."

exit 0


