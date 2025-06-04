#!/usr/bin/env bash
# read_db.sh - Read the latest sensor data from TimescaleDB (Azure version)
# Modified to show temperature, humidity, pressure, and motion

set -e

# Get VM IP from terraform
echo "Getting VM IP from Terraform..."
cd "$(dirname "$0")/terraform"

VM_IP=$(terraform output -raw vm_ip 2>/dev/null)

if [ -z "$VM_IP" ] || [ "$VM_IP" = "null" ]; then
    echo "Error: Could not retrieve IP address from terraform output." >&2
    echo "Available outputs:"
    terraform output
    exit 1
fi

echo "Connecting to Azure VM at: $VM_IP"
echo

# Configuration
VM_USER="ubuntu"
SSH_KEY="~/.ssh/id_rsa_aws"
CONTAINER="timescaledb"
DB_USER="iotuser"
DB_NAME="iotdb"

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
echo "=== Latest 15 Environmental Sensor Records from Azure TimescaleDB ==="
echo

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$VM_USER@$VM_IP" \
    "docker exec $CONTAINER psql -U $DB_USER -d $DB_NAME -c \"$SQL_QUERY\""

echo
echo "=== End of Records ==="
echo "🌡️  Database connection successful via Azure VM: $VM_IP"