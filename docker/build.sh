#!/bin/bash
# Build script for Fulcrum-Alpha Docker image

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "Building Fulcrum-Alpha Docker image..."
echo "Project root: $PROJECT_ROOT"

# Build the Docker image
cd "$PROJECT_ROOT"
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