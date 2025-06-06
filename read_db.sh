#!/usr/bin/env bash
# read_db.sh - Read the latest sensor data from TimescaleDB (VM deployment)
# Modified to show temperature, humidity, pressure, and motion

set -e

# Load environment variables
if [[ -f .env ]]; then
  source .env
else
  echo "❌ .env file not found. Please copy .env.example to .env and configure it."
  exit 1
fi

# Get VM IP from terraform
echo "Getting VM IP from Terraform..."
cd "$(dirname "$0")/terraform"

VM_IP=$(terraform output -raw vm_ip 2>/dev/null)

if [ -z "$VM_IP" ] || [ "$VM_IP" = "null" ]; then
    echo "❌ Could not retrieve IP address from terraform output." >&2
    echo "Available outputs:"
    terraform output
    exit 1
fi

echo "Connecting to AWS VM at: $VM_IP"
echo

# Configuration from environment variables with fallbacks
SSH_USER=${SSH_USER:-ec2-user}
SSH_KEY_PATH=${SSH_KEY_PATH:-~/.ssh/id_rsa}
TIMESCALE_CONTAINER=${TIMESCALE_CONTAINER_NAME:-timescaledb}
DB_USER=${POSTGRES_USER:-iotuser}
DB_NAME=${POSTGRES_DB:-iotdb}

# Test SSH connectivity first
echo "Testing SSH connection..."
if ! ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$SSH_USER@$VM_IP" "echo 'SSH connection successful'" &>/dev/null; then
  echo "❌ Could not connect to VM via SSH"
  echo "Check your SSH key path: $SSH_KEY_PATH"
  echo "Check your SSH user: $SSH_USER"
  echo "Check VM connectivity: $VM_IP"
  exit 1
fi

# Check if TimescaleDB container is running
echo "Checking TimescaleDB container status..."
if ! ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new "$SSH_USER@$VM_IP" "docker ps | grep $TIMESCALE_CONTAINER" &>/dev/null; then
  echo "❌ TimescaleDB container '$TIMESCALE_CONTAINER' is not running"
  echo "Available containers:"
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new "$SSH_USER@$VM_IP" "docker ps --format 'table {{.Names}}\t{{.Status}}'"
  exit 1
fi

# SQL Query focusing on temperature, humidity, pressure, and motion
SQL_QUERY="
SELECT 
    time AT TIME ZONE 'America/New_York' AS local_time,
    device_id,
    event_type,
    CASE 
        WHEN temperature IS NOT NULL THEN ROUND(temperature::numeric, 1) || '°F'
        ELSE NULL 
    END AS temperature,
    CASE 
        WHEN humidity IS NOT NULL THEN ROUND(humidity::numeric, 1) || '%'
        ELSE NULL 
    END AS humidity,
    CASE 
        WHEN pressure IS NOT NULL THEN ROUND(pressure::numeric, 2) || ' hPa'
        ELSE NULL 
    END AS pressure,
    motion,
    sensor_type
FROM sensor_data 
WHERE temperature IS NOT NULL 
   OR humidity IS NOT NULL 
   OR pressure IS NOT NULL 
   OR motion IS NOT NULL
ORDER BY time DESC 
LIMIT 15;
"

# Execute the query with better formatting
echo "=== Latest 15 Environmental Sensor Records from AWS TimescaleDB ==="
echo

ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new "$SSH_USER@$VM_IP" \
    "docker exec $TIMESCALE_CONTAINER psql -U $DB_USER -d $DB_NAME -c \"$SQL_QUERY\""

echo
echo "=== End of Records ==="
echo "🌡️  Database connection successful via AWS VM: $VM_IP"
echo
echo "💡 Alternative queries:"
echo "   # Show table structure: docker exec $TIMESCALE_CONTAINER psql -U $DB_USER -d $DB_NAME -c \"\\d sensor_data\""
echo "   # Count all records: docker exec $TIMESCALE_CONTAINER psql -U $DB_USER -d $DB_NAME -c \"SELECT COUNT(*) FROM sensor_data;\""