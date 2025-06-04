#!/usr/bin/env bash
# taillogs.sh - Tail Docker container logs from Azure IoTS6 deployment
set -e

echo "Connecting to Azure VM for log monitoring..."

# Get IP from terraform
cd terraform
VM_IP=$(terraform output -raw vm_ip 2>/dev/null || echo "")

if [ -z "$VM_IP" ] || [ "$VM_IP" = "null" ]; then
  echo "❌ Could not get VM IP from terraform output"
  echo "Make sure the deployment completed successfully"
  exit 1
fi

echo "Connecting to Azure VM at $VM_IP..."

# Clean up old SSH keys to avoid conflicts
ssh-keygen -R $VM_IP 2>/dev/null || true

# Show available containers
echo "Available Docker containers:"
ssh -i ~/.ssh/id_rsa_aws -o StrictHostKeyChecking=accept-new ubuntu@$VM_IP "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"

echo ""
echo "Select container to monitor:"
echo "1) timescaledb - Database logs"
echo "2) mosquitto - MQTT broker logs" 
echo "3) grafana - Dashboard logs"
echo "4) iot_service - IoT service logs"
echo "5) All containers - Combined logs"

read -p "Enter choice (1-5) or container name: " choice

case $choice in
  1|timescaledb)
    echo "Tailing TimescaleDB logs (Ctrl+C to stop)..."
    ssh -i ~/.ssh/id_rsa_aws -o StrictHostKeyChecking=accept-new ubuntu@$VM_IP "docker logs -f timescaledb"
    ;;
  2|mosquitto)
    echo "Tailing MQTT broker logs (Ctrl+C to stop)..."
    ssh -i ~/.ssh/id_rsa_aws -o StrictHostKeyChecking=accept-new ubuntu@$VM_IP "docker logs -f mosquitto"
    ;;
  3|grafana)
    echo "Tailing Grafana dashboard logs (Ctrl+C to stop)..."
    ssh -i ~/.ssh/id_rsa_aws -o StrictHostKeyChecking=accept-new ubuntu@$VM_IP "docker logs -f grafana"
    ;;
  4|iot_service)
    echo "Tailing IoT service logs (Ctrl+C to stop)..."
    ssh -i ~/.ssh/id_rsa_aws -o StrictHostKeyChecking=accept-new ubuntu@$VM_IP "docker logs -f iot_service"
    ;;
  5|all)
    echo "Tailing all IoT service logs (Ctrl+C to stop)..."
    ssh -i ~/.ssh/id_rsa_aws -o StrictHostKeyChecking=accept-new ubuntu@$VM_IP "docker logs --tail=50 -f \$(docker ps -q)"
    ;;
  *)
    # Custom container name
    echo "Tailing logs for container: $choice (Ctrl+C to stop)..."
    ssh -i ~/.ssh/id_rsa_aws -o StrictHostKeyChecking=accept-new ubuntu@$VM_IP "docker logs -f $choice"
    ;;
esac