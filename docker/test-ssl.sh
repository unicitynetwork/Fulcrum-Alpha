#!/bin/bash

# Test script to verify SSL is working on port 50002

set -e

CONTAINER_NAME="${1:-fulcrum-alpha}"

echo "Fulcrum SSL Test Script"
echo "======================="
echo "Container: $CONTAINER_NAME"
echo ""

# Check if container is already running
if docker ps | grep -q "$CONTAINER_NAME"; then
    echo "✅ Container '$CONTAINER_NAME' is already running"
    echo ""
else
    echo "❌ Container '$CONTAINER_NAME' is not running"
    echo ""
    echo "Please start Fulcrum first using one of these scripts:"
    echo "  ./run-fulcrum-direct-mount.sh     # Direct mount from Let's Encrypt"
    echo "  ./run-fulcrum-auto-ssl.sh         # Copy certs to local ./ssl"
    echo "  ./run-fulcrum-copy-certs.sh       # Copy certs into container"
    echo ""
    echo "Or specify a different container name:"
    echo "  $0 <container-name>"
    exit 1
fi

# Show container logs
echo "Recent container logs:"
echo "----------------------"
docker logs "$CONTAINER_NAME" 2>&1 | tail -20
echo ""

# Check what's in the /ssl directory inside the container
echo "Checking SSL certificates in container:"
echo "---------------------------------------"
docker exec "$CONTAINER_NAME" ls -la /ssl 2>/dev/null || echo "No /ssl directory in container"
docker exec "$CONTAINER_NAME" ls -la /data/*.{crt,key,pem} 2>/dev/null || echo "No certificates in /data"
echo ""

# Test TCP port
echo "Testing TCP port 50001..."
if nc -zv localhost 50001 2>&1 | grep -q succeeded; then
    echo "✅ TCP port 50001 is listening"
else
    echo "❌ TCP port 50001 is not listening"
fi

# Test SSL port
echo "Testing SSL port 50002..."
if nc -zv localhost 50002 2>&1 | grep -q succeeded; then
    echo "✅ SSL port 50002 is listening"
    
    # Try SSL connection
    echo ""
    echo "Testing SSL handshake..."
    echo | openssl s_client -connect localhost:50002 -servername localhost 2>&1 | grep -E "SSL handshake|Certificate chain|Verify return code|subject|issuer" || true
    
    # Test Electrum protocol over SSL
    echo ""
    echo "Testing Electrum protocol over SSL:"
    RESPONSE=$(echo -e '{"id":1,"method":"server.version","params":["test","1.4"]}\n' | \
        timeout 2 openssl s_client -connect localhost:50002 -quiet -ign_eof 2>/dev/null | grep -a "result" || echo "")
    
    if [ -n "$RESPONSE" ]; then
        echo "✅ Electrum protocol working over SSL"
        echo "Response: $RESPONSE"
    else
        echo "⚠️  No Electrum response (this is normal if the server requires specific protocol version)"
    fi
else
    echo "❌ SSL port 50002 is not listening"
    echo ""
    echo "Checking container configuration:"
    docker exec "$CONTAINER_NAME" grep -E "^(ssl|cert|key)" /data/fulcrum.conf 2>/dev/null || echo "Could not read config"
fi

# Test WebSocket ports
echo ""
echo "Testing WebSocket port 50003..."
nc -zv localhost 50003 2>&1 | grep -q succeeded && echo "✅ WS port 50003 is listening" || echo "❌ WS port 50003 is not listening"

echo "Testing WebSocket Secure port 50004..."
nc -zv localhost 50004 2>&1 | grep -q succeeded && echo "✅ WSS port 50004 is listening" || echo "❌ WSS port 50004 is not listening"

echo ""
echo "Test complete."
echo ""
echo "Commands:"
echo "  View logs: docker logs -f $CONTAINER_NAME"
echo "  Stop: docker stop $CONTAINER_NAME"
echo "  Check config: docker exec $CONTAINER_NAME cat /data/fulcrum.conf"