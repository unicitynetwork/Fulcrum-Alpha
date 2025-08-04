# Fulcrum-Alpha Docker Setup

This directory contains Docker configuration for running Fulcrum-Alpha SPV server alongside an Alpha cryptocurrency node.

## Quick Start

### Using Pre-built Images (Production)

1. **Use production docker-compose:**
   ```bash
   cd /path/to/Fulcrum-Alpha/docker
   docker-compose -f docker-compose.prod.yml up -d
   ```

### Building from Source (Development)

1. **Clone and prepare:**
   ```bash
   cd /path/to/Fulcrum-Alpha
   cd docker
   ```

2. **Review configuration:**
   The default configuration uses `user:password` credentials for RPC.
   To change credentials, edit both `config/alpha.conf` and `config/fulcrum.conf`:
   ```bash
   # Default credentials (change if needed)
   rpcuser=user
   rpcpassword=password
   ```

3. **Start both services:**
   ```bash
   docker-compose up -d
   ```

## Docker Compose Services

The setup includes two services:

### alpha-node
- Alpha cryptocurrency full node
- Image: `ghcr.io/unicitynetwork/alpha/alpha:latest`
- Ports:
  - `8589` (RPC, localhost only)
  - `8590` (P2P, public)
- Data volume: `alpha-data`

### fulcrum-alpha
- Fulcrum SPV server for Alpha
- Built from local source
- Ports:
  - `50001` (TCP)
  - `50002` (SSL)
  - `50003` (WebSocket, optional)
- Data volume: `fulcrum-data`

## Usage Examples

### Basic Operations

```bash
# Start services
docker-compose up -d

# View logs
docker-compose logs -f fulcrum-alpha
docker-compose logs -f alpha-node

# Stop services
docker-compose down

# Stop and remove volumes (WARNING: deletes blockchain data)
docker-compose down -v
```

### Building and Publishing Fulcrum-Alpha Image

```bash
# Build the image locally
docker-compose build fulcrum-alpha

# Or build manually
docker build -t fulcrum-alpha:latest -f Dockerfile ..

# Publish to GitHub Container Registry
./publish-image.sh [tag]

# Or with custom registry
FULCRUM_REGISTRY=docker.io/myuser ./publish-image.sh v1.0.0
```

### Using Published Images

```bash
# Pull the latest published image
docker pull ghcr.io/unicitynetwork/alpha/fulcrum:latest

# Use production docker-compose
docker-compose -f docker-compose.prod.yml up -d
```

### Running Standalone Containers

#### Default Configuration (Simplest)

Both containers will use their built-in default configurations:

```bash
# Create a shared network
docker network create alpha-net

# Run Alpha node with default config
docker run -d --rm --name alpha-node \
    --network alpha-net \
    -p 8589:8589 -p 8590:8590 \
    -v alpha-data:/root/.alpha \
    ghcr.io/unicitynetwork/alpha/alpha:latest

# Run Fulcrum-Alpha with default config (auto-connects to alpha-node)
docker run -d --rm --name fulcrum-alpha \
    --network alpha-net \
    -p 50001:50001 -p 50002:50002 \
    -v fulcrum-data:/data \
    ghcr.io/unicitynetwork/alpha/fulcrum:latest
```

#### With Custom Configuration

```bash
# Run Alpha node with custom config
docker run -d --rm --name alpha-node \
    -p 8589:8589 -p 8590:8590 \
    -v alpha-data:/root/.alpha \
    -v ./config:/config \
    ghcr.io/unicitynetwork/alpha/alpha:latest

# Run Fulcrum-Alpha with custom config
docker run -d --rm --name fulcrum-alpha \
    --network container:alpha-node \
    -p 50001:50001 -p 50002:50002 \
    -v fulcrum-data:/data \
    -v ./config:/config \
    ghcr.io/unicitynetwork/alpha/fulcrum:latest
```

### Monitoring and Debugging

```bash
# Check Alpha node sync status
docker exec alpha-node alpha-cli getblockcount
docker exec alpha-node alpha-cli getblockchaininfo

# Access Fulcrum admin console
docker exec -it fulcrum-alpha FulcrumAdmin -h fulcrum-alpha

# View Fulcrum stats
curl -s http://localhost:50001/ | jq .

# Test Electrum protocol
echo '{"id":1,"method":"server.version","params":["test","1.4"]}' | \
    nc localhost 50001
```

## Configuration

### Default Configuration

Both images include default configuration files that work out-of-the-box when containers are on the same Docker network:

- **Alpha Node**: Uses `/etc/alpha/alpha.conf.default` with `user:password` credentials
- **Fulcrum**: Uses `/etc/fulcrum/fulcrum.conf.default` configured to connect to `alpha-node:8589`

### Custom Configuration

#### Alpha Node (`config/alpha.conf`)

Key settings:
- `chain=alpha` - Specifies Alpha blockchain
- `txindex=1` - Required for Fulcrum
- `rpcuser=user` / `rpcpassword=password` - Default RPC credentials (must match Fulcrum config)
- `randomxfastmode=1` - Enables fast RandomX validation
- `daemon=0` - Run in foreground for Docker

#### Fulcrum (`config/fulcrum.conf`)

Key settings:
- `coin=alpha` - REQUIRED for Alpha support
- `bitcoind=alpha-node:8589` - Alpha node connection
- `rpcuser=user` / `rpcpassword=password` - Must match Alpha node (default credentials)
- `tcp/ssl/ws` - Server endpoints

### Configuration Priority

Fulcrum checks for configuration in this order (same pattern as Alpha node):
1. `/config/fulcrum.conf` - Mounted config directory (copied to /data)
2. `/etc/fulcrum/fulcrum.conf` - Built into image
3. `/etc/fulcrum/fulcrum.conf.default` - Default fallback

The config is always copied to `/data/fulcrum.conf` before use.

### Environment Variables

Copy `.env.example` to `.env` and customize:
```bash
cp config/.env.example .env
# Edit .env with your settings
```

## SSL Certificates

SSL certificates are automatically generated on first run. To use custom certificates:

1. Place your certificates in the data volume:
   ```bash
   docker cp fulcrum.crt fulcrum-alpha:/data/
   docker cp fulcrum.key fulcrum-alpha:/data/
   ```

2. Restart the container:
   ```bash
   docker-compose restart fulcrum-alpha
   ```

## Networking

The services communicate over a Docker bridge network (`alpha-network`). This provides:
- Service discovery by name
- Network isolation
- No exposed RPC ports to host

To connect from host applications:
- Alpha RPC: `http://localhost:8589`
- Fulcrum TCP: `localhost:50001`
- Fulcrum SSL: `localhost:50002`

## Troubleshooting

### Alpha node not syncing
```bash
# Check node logs
docker-compose logs alpha-node

# Verify network connectivity
docker exec alpha-node alpha-cli getpeerinfo
```

### Fulcrum connection errors
```bash
# Test Alpha RPC connection
docker exec fulcrum-alpha nc -zv alpha-node 8589

# Check Fulcrum logs
docker-compose logs fulcrum-alpha | grep -i error
```

### Permission issues
```bash
# Fix volume permissions
docker-compose down
sudo chown -R $USER:$USER ./config
docker-compose up -d
```

## Performance Tuning

### Alpha Node
- Increase `dbcache` for faster initial sync
- Set `maxconnections` based on available bandwidth

### Fulcrum
- Adjust `db_mem` based on available RAM
- Set `worker_threads=0` for auto-detection
- Use `fast-sync` during initial sync

## Security Considerations

1. **Change default credentials** (`user:password`) in configuration files if exposed to network
2. **Restrict RPC access** - Alpha RPC is bound to localhost only
3. **Use SSL** for Electrum connections over the internet
4. **Regular updates** - Pull latest images periodically
5. **Firewall rules** - Only expose required ports

## Backup and Recovery

### Backup
```bash
# Stop services
docker-compose down

# Backup volumes
docker run --rm -v alpha-data:/data -v $(pwd):/backup alpine \
    tar czf /backup/alpha-data-backup.tar.gz -C /data .

docker run --rm -v fulcrum-data:/data -v $(pwd):/backup alpine \
    tar czf /backup/fulcrum-data-backup.tar.gz -C /data .
```

### Restore
```bash
# Restore volumes
docker run --rm -v alpha-data:/data -v $(pwd):/backup alpine \
    tar xzf /backup/alpha-data-backup.tar.gz -C /data

docker run --rm -v fulcrum-data:/data -v $(pwd):/backup alpine \
    tar xzf /backup/fulcrum-data-backup.tar.gz -C /data

# Start services
docker-compose up -d
```

## Additional Resources

- [Fulcrum Documentation](https://github.com/cculianu/Fulcrum)
- [Alpha Blockchain Info](https://github.com/unicitynetwork/alpha)
- [Electrum Protocol](https://electrum.readthedocs.io/en/latest/protocol.html)