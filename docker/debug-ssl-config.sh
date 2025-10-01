#!/bin/bash

echo "Debugging SSL configuration issue"
echo "================================="

# Test the logic from the entrypoint script
CONFIG_FILE="/tmp/test-fulcrum.conf"

# Create a test config similar to the default
cat > "$CONFIG_FILE" << 'EOF'
# Fulcrum-Alpha Configuration
bitcoind = alpha-node:8589
rpcuser = user
rpcpassword = password
coin = alpha
datadir = /data

# Network Interfaces
tcp = 0.0.0.0:50001
#ssl = 0.0.0.0:50002
ws = 0.0.0.0:50003
#wss = 0.0.0.0:50004

cert = /data/fulcrum.crt
key = /data/fulcrum.key
EOF

echo "Original config:"
cat "$CONFIG_FILE"
echo ""

# Test the grep and sed logic
echo "Testing: Does 'ssl =' exist as active line?"
if ! grep -q "^ssl\s*=" "$CONFIG_FILE"; then
    echo "  No active ssl line found (correct)"
    echo "  Would add: ssl = 0.0.0.0:50002"
else
    echo "  Active ssl line found (this would skip adding)"
fi

echo ""
echo "Testing: Trying to uncomment ssl line"
sed -i 's/^#ssl\s*=/ssl =/' "$CONFIG_FILE"

echo ""
echo "Config after sed:"
grep -E "^#?ssl" "$CONFIG_FILE"

echo ""
echo "Testing complete logic from entrypoint:"
cp "$CONFIG_FILE" "$CONFIG_FILE.tmp"

# Logic from entrypoint
if ! grep -q "^ssl\s*=" "$CONFIG_FILE.tmp"; then
    echo "  Adding ssl line..."
    echo "ssl = 0.0.0.0:50002" >> "$CONFIG_FILE.tmp"
else
    echo "  Uncommenting ssl line..."
    sed -i 's/^#ssl\s*=/ssl =/' "$CONFIG_FILE.tmp"
fi

echo ""
echo "Final result:"
grep -E "^ssl" "$CONFIG_FILE.tmp"

# Cleanup
rm -f "$CONFIG_FILE" "$CONFIG_FILE.tmp"