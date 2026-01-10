#!/bin/bash

# Script to build and push the Fulcrum-Alpha Docker image to GitHub Container Registry
# Usage: ./publish-image.sh [tag]

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE_NAME="fulcrum"
TAG="${1:-latest}"
DEFAULT_REGISTRY="ghcr.io/unicitynetwork/alpha"

# Allow override via environment variable
REGISTRY="${FULCRUM_REGISTRY:-${DEFAULT_REGISTRY}}"
FULL_IMAGE_NAME="${REGISTRY}/${IMAGE_NAME}"

echo "============================================"
echo "   Fulcrum-Alpha Docker Image Publisher    "
echo "============================================"
echo ""
echo "Building and publishing Docker image for Fulcrum-Alpha"
echo "Image: ${FULL_IMAGE_NAME}:${TAG}"
echo ""

# Check Docker installation
if ! command -v docker &>/dev/null; then
    echo "❌ Error: Docker is not installed"
    echo "Please install Docker first: https://docs.docker.com/get-docker/"
    exit 1
fi

# Check if Docker daemon is running
if ! docker info >/dev/null 2>&1; then
    echo "❌ Error: Docker daemon is not running"
    echo "Please start Docker daemon and try again"
    exit 1
fi

# Check if user is logged in to GitHub Container Registry
if [[ "${FULL_IMAGE_NAME}" == ghcr.io/* ]]; then
    REGISTRY_URL=$(echo "${FULL_IMAGE_NAME}" | cut -d'/' -f1)
    if ! docker info 2>/dev/null | grep -q "${REGISTRY_URL}"; then
        echo "⚠️  You don't appear to be logged in to GitHub Container Registry"
        echo ""
        echo "To login, run:"
        echo "  echo \${GITHUB_PAT} | docker login ghcr.io -u USERNAME --password-stdin"
        echo ""
        echo "Your GITHUB_PAT needs 'write:packages' permission."
        echo ""
        read -p "Continue anyway? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
fi

# Build arguments
BUILD_ARGS=""
if [ -n "${MAKEFLAGS}" ]; then
    BUILD_ARGS="--build-arg MAKEFLAGS=${MAKEFLAGS}"
fi

# Build the Docker image
echo "Building Docker image..."
echo "Build context: ${PROJECT_ROOT}"
echo "Dockerfile: ${SCRIPT_DIR}/Dockerfile"

docker build \
    ${BUILD_ARGS} \
    -t "${FULL_IMAGE_NAME}:${TAG}" \
    -f "${SCRIPT_DIR}/Dockerfile" \
    "${PROJECT_ROOT}"

if [ $? -ne 0 ]; then
    echo "❌ Build failed!"
    exit 1
fi

echo "✅ Build successful!"

# Tag as latest if not already
if [ "${TAG}" != "latest" ]; then
    echo "Tagging as latest as well..."
    docker tag "${FULL_IMAGE_NAME}:${TAG}" "${FULL_IMAGE_NAME}:latest"
fi

# Get image size
IMAGE_SIZE=$(docker images --format "{{.Size}}" "${FULL_IMAGE_NAME}:${TAG}")
echo ""
echo "Image size: ${IMAGE_SIZE}"

# Ask for confirmation before pushing
if [[ "${FULL_IMAGE_NAME}" == ghcr.io/* ]] || [[ "${FULL_IMAGE_NAME}" == docker.io/* ]]; then
    echo ""
    echo "Ready to push the following tags to registry:"
    echo "  ${FULL_IMAGE_NAME}:${TAG}"
    if [ "${TAG}" != "latest" ]; then
        echo "  ${FULL_IMAGE_NAME}:latest"
    fi
    echo ""
    read -p "Push these images? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Pushing images to registry..."
        docker push "${FULL_IMAGE_NAME}:${TAG}"
        if [ "${TAG}" != "latest" ]; then
            docker push "${FULL_IMAGE_NAME}:latest"
        fi
        echo ""
        echo "✅ Images pushed successfully!"
        echo ""
        echo "Images are now available at:"
        echo "  ${FULL_IMAGE_NAME}:${TAG}"
        if [ "${TAG}" != "latest" ]; then
            echo "  ${FULL_IMAGE_NAME}:latest"
        fi
    else
        echo "Push cancelled. Images are built locally only."
    fi
else
    echo ""
    echo "✅ Local image built successfully:"
    echo "  ${FULL_IMAGE_NAME}:${TAG}"
fi

echo ""
echo "To run this image with docker-compose:"
echo "  cd ${SCRIPT_DIR}"
echo "  docker-compose up -d"
echo ""
echo "To run this image standalone:"
echo "  docker run -d --name fulcrum-alpha \\"
echo "    -p 50001:50001 -p 50002:50002 \\"
echo "    -v fulcrum-data:/data \\"
echo "    -v ./config/fulcrum.conf:/data/fulcrum.conf \\"
echo "    ${FULL_IMAGE_NAME}:${TAG}"
echo ""
echo "To run with existing alpha-node container:"
echo "  docker run -d --name fulcrum-alpha \\"
echo "    --network container:alpha-node \\"
echo "    -v fulcrum-data:/data \\"
echo "    -v ./config/fulcrum.conf:/data/fulcrum.conf \\"
echo "    ${FULL_IMAGE_NAME}:${TAG}"