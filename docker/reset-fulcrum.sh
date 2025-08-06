#!/bin/bash

# Script to reset Fulcrum data when corrupted
# This will delete all Fulcrum data and require a full resync

echo "Fulcrum Database Reset Tool"
echo "=========================="
echo ""
echo "⚠️  WARNING: This will delete all Fulcrum data!"
echo "A full resync from Alpha node will be required."
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Stopping any running Fulcrum containers..."
    docker stop fulcrum-alpha 2>/dev/null || true
    
    echo "Removing corrupted data volume..."
    docker volume rm fulcrum-data
    
    if [ $? -eq 0 ]; then
        echo "✅ Data volume removed successfully"
        echo ""
        echo "You can now start Fulcrum fresh:"
        echo "  ./run_fulcrum.sh"
        echo ""
        echo "Note: Initial sync may take several hours depending on blockchain size."
    else
        echo "❌ Failed to remove volume. It may be in use."
        echo "Try: docker volume ls"
        echo "     docker volume inspect fulcrum-data"
    fi
else
    echo "Reset cancelled."
fi