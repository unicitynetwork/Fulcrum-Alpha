#!/bin/bash
# Build script for Fulcrum-Alpha Docker image

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "Building Fulcrum-Alpha Docker image..."
echo "Project root: $PROJECT_ROOT"

cd "$PROJECT_ROOT"

# Step 1: Build ssl-manager base image (required by Fulcrum Dockerfile)
echo ""
echo "Step 1/2: Building ssl-manager base image..."
docker build -t ssl-manager:latest -f docker/ssl-manager/Dockerfile docker/ssl-manager/
echo "ssl-manager:latest built successfully"

# Step 2: Build Fulcrum image (FROM ssl-manager:latest)
echo ""
echo "Step 2/2: Building Fulcrum image..."
docker build -t fulcrum-alpha:latest -f docker/Dockerfile .

echo "Build complete!"
echo ""
echo "To run the services:"
echo "  cd docker"
echo "  docker-compose up -d"
echo ""
echo "To run Fulcrum-Alpha standalone:"
echo "  docker run -d --name fulcrum-alpha \\"
echo "    -p 50001:50001 -p 50002:50002 \\"
echo "    -v fulcrum-data:/data \\"
echo "    fulcrum-alpha:latest"