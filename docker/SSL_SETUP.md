# Fulcrum Docker SSL/TLS Setup Guide

## Overview
Fulcrum Docker supports both TCP (port 50001) and SSL/TLS (port 50002) connections for the Electrum protocol.

## Quick Start

### Without SSL (default)
```bash
cd docker
./run-fulcrum.sh
```

### With SSL (auto-detect Let's Encrypt)
```bash
cd docker
sudo ./run-fulcrum.sh
```
The script will automatically find and use Let's Encrypt certificates.

### With SSL (specific domain)
```bash
cd docker
./run-fulcrum.sh --domain example.com
```

### With SSL (custom certificates)
```bash
cd docker
./run-fulcrum.sh --cert /path/to/cert.pem --key /path/to/key.pem
```

## Available Ports
- **50001**: TCP (unencrypted Electrum protocol)
- **50002**: SSL/TLS (encrypted Electrum protocol) - only when SSL is configured
- **50003**: WebSocket (unencrypted)
- **50004**: WebSocket Secure (encrypted) - only when SSL is configured

## Testing SSL Connection

Use the included test script:
```bash
cd docker
./test-ssl.sh
```

Or test manually:
```bash
# Test if port is listening
nc -zv localhost 50002

# Test SSL handshake
echo | openssl s_client -connect localhost:50002

# Test with Electrum client
electrum --oneserver --server localhost:50002:s
```

## Multiple Containers

Run multiple Fulcrum instances with different certificates:
```bash
# First instance
./run-fulcrum.sh --domain site1.com --container-name fulcrum-site1

# Second instance  
./run-fulcrum.sh --domain site2.com --container-name fulcrum-site2
```

## Troubleshooting

### Check Container Logs
```bash
docker logs fulcrum-alpha
```

Look for:
- "Found mounted SSL certificates"
- "Configuration updated: Both SSL and non-SSL ports enabled"
- "Service started, listening for connections on 0.0.0.0:50002"

### Common Issues
1. **SSL not working**: Ensure certificates are readable (may need sudo)
2. **Port not listening**: Check logs for configuration errors
3. **Certificate errors**: Verify certificates match your hostname

## Building the Docker Image

```bash
cd docker
./build.sh
```

This creates the `fulcrum-alpha:latest` image locally.