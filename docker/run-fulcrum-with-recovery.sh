#!/bin/bash

# Fulcrum Auto-Recovery Runner
# Automatically handles crashes and database corruption

CONTAINER_NAME="fulcrum-alpha"
VOLUME_NAME="fulcrum-data"
MAX_RETRIES=3
RETRY_COUNT=0
LAST_CRASH_TIME=0
CRASH_THRESHOLD=300  # 5 minutes

echo "Fulcrum Auto-Recovery Runner"
echo "==========================="
echo ""

# Function to check if database is corrupted
check_corruption() {
    local logs="$1"
    if echo "$logs" | grep -q "database has been corrupted\|inconsistent state\|forcefully killed"; then
        return 0  # Corrupted
    fi
    return 1  # Not corrupted
}

# Function to reset database
reset_database() {
    echo "🔧 Database corruption detected. Resetting..."
    docker stop $CONTAINER_NAME 2>/dev/null || true
    docker rm $CONTAINER_NAME 2>/dev/null || true
    
    # Backup corrupted data for investigation (optional)
    local backup_name="${VOLUME_NAME}-corrupted-$(date +%Y%m%d-%H%M%S)"
    echo "📦 Backing up corrupted data to: $backup_name"
    docker volume create $backup_name
    docker run --rm -v $VOLUME_NAME:/source -v $backup_name:/backup alpine cp -a /source/. /backup/ 2>/dev/null || true
    
    # Remove corrupted volume
    docker volume rm $VOLUME_NAME
    echo "✅ Database reset complete"
}

# Function to run Fulcrum
run_fulcrum() {
    echo "🚀 Starting Fulcrum..."
    docker run --name $CONTAINER_NAME \
        --network alpha-net \
        -p 50001:50001 -p 50002:50002 -p 50003:50003 -p 50004:50004 \
        -v $VOLUME_NAME:/data \
        -v ./config:/config \
        ghcr.io/unicitynetwork/alpha/fulcrum:latest
}

# Main loop
while true; do
    # Check if we're in a crash loop
    CURRENT_TIME=$(date +%s)
    if [ $((CURRENT_TIME - LAST_CRASH_TIME)) -lt $CRASH_THRESHOLD ]; then
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
            echo "❌ Fulcrum crashed $MAX_RETRIES times within $CRASH_THRESHOLD seconds"
            echo "This indicates a serious problem. Manual intervention required."
            exit 1
        fi
    else
        # Reset retry count if enough time has passed
        RETRY_COUNT=0
    fi
    
    # Run Fulcrum
    run_fulcrum
    EXIT_CODE=$?
    
    # Container exited, check why
    echo ""
    echo "⚠️  Fulcrum exited with code: $EXIT_CODE"
    
    # Get the last logs
    LOGS=$(docker logs --tail 100 $CONTAINER_NAME 2>&1)
    
    # Check for corruption
    if check_corruption "$LOGS"; then
        reset_database
        RETRY_COUNT=0  # Reset retry count after database reset
    else
        echo "💡 No database corruption detected"
        
        # Check exit code
        if [ $EXIT_CODE -eq 0 ]; then
            echo "✅ Fulcrum exited cleanly"
            break
        elif [ $EXIT_CODE -eq 137 ]; then
            echo "⚠️  Fulcrum was killed (possibly OOM)"
            echo "Consider increasing memory limits"
        fi
    fi
    
    # Clean up container
    docker rm $CONTAINER_NAME 2>/dev/null || true
    
    # Record crash time
    LAST_CRASH_TIME=$CURRENT_TIME
    
    # Wait before retry
    echo ""
    echo "🔄 Restarting in 10 seconds... (Retry $((RETRY_COUNT + 1))/$MAX_RETRIES)"
    echo "Press Ctrl+C to stop"
    sleep 10
done

echo "👋 Fulcrum runner exiting"