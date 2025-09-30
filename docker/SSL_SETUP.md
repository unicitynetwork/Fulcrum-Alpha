# Fulcrum Docker SSL/TLS Setup Guide

## Overview
Fulcrum Docker now fully supports both TCP (port 50001) and SSL/TLS (port 50002) connections for the Electrum protocol.

## What Was Fixed
1. **Docker entrypoint script**: Now properly enables both TCP and SSL ports when certificates are available
2. **Certificate configuration**: Automatically uncomments and sets `cert` and `key` paths in the config
3. **Debug output**: Added logging to help diagnose SSL setup issues

## How to Enable SSL/TLS

### Option 1: Using run-fulcrum-auto-ssl.sh (Automatic Let's Encrypt)
```bash
cd docker
./run-fulcrum-auto-ssl.sh
```
This script automatically:
- Finds Let's Encrypt certificates on your system
- Copies them to the `./ssl` directory
- Starts Fulcrum with SSL support

### Option 2: Manual SSL Setup
1. Create an SSL directory:
   ```bash
   mkdir -p docker/ssl
   ```

2. Place your SSL certificates in the `ssl` directory:
   - `fullchain.pem` and `privkey.pem` (Let's Encrypt style), OR
   - `fulcrum.crt` and `fulcrum.key` (standard names)

3. Start Fulcrum:
   ```bash
   docker run -d --rm --name fulcrum-alpha \
       --network alpha-net \
       -p 50001:50001 -p 50002:50002 -p 50003:50003 -p 50004:50004 \
       -v fulcrum-data:/data \
       -v ./config:/config \
       -v ./ssl:/ssl:ro \
       fulcrum-alpha:latest
   ```

### Option 3: Using Docker Compose
Add the SSL volume mount to your docker-compose.yml:
```yaml
volumes:
  - fulcrum-data:/data
  - ./ssl:/ssl:ro  # Add this line
```

## Available Ports
When SSL is configured, all ports are available:
- **50001**: TCP (unencrypted Electrum protocol)
- **50002**: SSL/TLS (encrypted Electrum protocol)
- **50003**: WebSocket (unencrypted)
- **50004**: WebSocket Secure (encrypted)

Without SSL certificates:
- **50001**: TCP (unencrypted Electrum protocol)
- **50003**: WebSocket (unencrypted)

## Testing SSL Connection

### Quick Test
```bash
cd docker
./test-ssl.sh
```

### Manual Test
```bash
# Test if port is listening
nc -zv localhost 50002

# Test SSL handshake
echo | openssl s_client -connect localhost:50002

# Test with Electrum client
electrum --oneserver --server localhost:50002:s
```

## Troubleshooting

### Check Container Logs
```bash
docker logs fulcrum-alpha
```
Look for:
- "Found mounted SSL certificates"
- "SSL certificates copied to data directory"
- "Configuration updated: Both SSL and non-SSL ports enabled"
- "Final configuration check" showing ssl and cert/key settings

### Common Issues
1. **SSL not working**: Check that certificates are properly mounted and readable
2. **Port not listening**: Verify the config shows `ssl = 0.0.0.0:50002`
3. **Certificate errors**: Ensure certificates are valid and match your hostname

## Configuration Details
The entrypoint script automatically:
1. Detects SSL certificates in `/ssl` volume
2. Copies them to `/data` directory
3. Updates the configuration to enable SSL ports
4. Preserves TCP port for backward compatibility