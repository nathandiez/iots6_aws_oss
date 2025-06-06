#!/usr/bin/env bash
# taillogs.sh - Tail Docker container logs from AWS IoTS6 deployment
set -e

# Load environment variables
if [[ -f .env ]]; then
  source .env
else
  echo "❌ .env file not found. Please copy .env.example to .env and configure it."
  exit 1
fi

echo "Connecting to AWS VM for log monitoring..."

# Get IP from terraform
cd terraform
VM_IP=$(terraform output -raw vm_ip 2>/dev/null || echo "")

if [ -z "$VM_IP" ] || [ "$VM_IP" = "null" ]; then
  echo "❌ Could not get VM IP from terraform output"
  echo "Make sure the deployment completed successfully"
  exit 1
fi

echo "Connecting to AWS VM at $VM_IP..."

# Set SSH defaults from environment or use sensible defaults
SSH_KEY_PATH=${SSH_KEY_PATH:-~/.ssh/id_rsa}
SSH_USER=${SSH_USER:-ec2-user}

# Clean up old SSH keys to avoid conflicts
ssh-keygen -R $VM_IP 2>/dev/null || true

# Test SSH connection first
if ! ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$SSH_USER@$VM_IP" "echo 'Connection successful'" &>/dev/null; then
  echo "❌ Could not connect to VM via SSH"
  echo "Check your SSH key path: $SSH_KEY_PATH"
  echo "Check your SSH user: $SSH_USER"
  echo "Check VM connectivity: $VM_IP"
  exit 1
fi

# Show available containers
echo "Available Docker containers:"
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new "$SSH_USER@$VM_IP" "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" || {
  echo "❌ Could not list Docker containers"
  echo "Make sure Docker is running and your user has access"
  exit 1
}

echo ""
echo "Select container to monitor:"
echo "1) ${TIMESCALE_CONTAINER_NAME:-timescaledb} - Database logs"
echo "2) ${MQTT_CONTAINER_NAME:-mosquitto} - MQTT broker logs" 
echo "3) ${GRAFANA_CONTAINER_NAME:-grafana} - Dashboard logs"
echo "4) ${IOT_SERVICE_CONTAINER_NAME:-iot_service} - IoT service logs"
echo "5) All containers - Combined logs"

read -p "Enter choice (1-5) or container name: " choice

case $choice in
  1|timescaledb)
    CONTAINER=${TIMESCALE_CONTAINER_NAME:-timescaledb}
    echo "Tailing $CONTAINER logs (Ctrl+C to stop)..."
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new "$SSH_USER@$VM_IP" "docker logs -f $CONTAINER"
    ;;
  2|mosquitto)
    CONTAINER=${MQTT_CONTAINER_NAME:-mosquitto}
    echo "Tailing $CONTAINER logs (Ctrl+C to stop)..."
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new "$SSH_USER@$VM_IP" "docker logs -f $CONTAINER"
    ;;
  3|grafana)
    CONTAINER=${GRAFANA_CONTAINER_NAME:-grafana}
    echo "Tailing $CONTAINER logs (Ctrl+C to stop)..."
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new "$SSH_USER@$VM_IP" "docker logs -f $CONTAINER"
    ;;
  4|iot_service)
    CONTAINER=${IOT_SERVICE_CONTAINER_NAME:-iot_service}
    echo "Tailing $CONTAINER logs (Ctrl+C to stop)..."
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new "$SSH_USER@$VM_IP" "docker logs -f $CONTAINER"
    ;;
  5|all)
    echo "Tailing all container logs (Ctrl+C to stop)..."
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new "$SSH_USER@$VM_IP" "docker logs --tail=50 -f \$(docker ps -q)"
    ;;
  *)
    # Custom container name
    echo "Tailing logs for container: $choice (Ctrl+C to stop)..."
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new "$SSH_USER@$VM_IP" "docker logs -f $choice"
    ;;
esac