#!/usr/bin/env bash
# verify-deployment.sh - Verify the AWS IoTS6 deployment is working
set -e

echo "Verifying IoT deployment..."
sleep 5

# Ensure we're in the terraform directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(dirname "$SCRIPT_DIR")"
cd "$TERRAFORM_DIR"

# Function to get IP from terraform output or environment
get_ip() {
  # Try environment variable first (from local-exec)
  if [ -n "$VM_IP" ]; then
    echo "$VM_IP"
    return 0
  fi
  
  # Fall back to terraform output
  local ip=$(terraform output -raw vm_ip 2>/dev/null || echo "")
  
  if [ -n "$ip" ] && [ "$ip" != "null" ] && [ "$ip" != "" ]; then
    echo "$ip"
    return 0
  fi
  
  echo ""
  return 1
}

IP=$(get_ip)

if [ -z "$IP" ]; then
  echo "❌ Could not determine IP from terraform state"
  echo "Debug: Trying terraform refresh..."
  terraform refresh > /dev/null 2>&1
  IP=$(get_ip)
fi

if [ -n "$IP" ]; then
  echo "Testing IoT services at $IP..."
  
  # Test TimescaleDB port
  echo "Testing TimescaleDB connectivity..."
  if nc -z -w5 "$IP" 5432 2>/dev/null; then
    echo "✅ TimescaleDB port 5432 is accessible"
    
    # Test actual database connection
    if ssh -i ~/.ssh/id_rsa_aws -o StrictHostKeyChecking=no -o BatchMode=yes ubuntu@"$IP" "PGPASSWORD=iotpass psql -h localhost -U iotuser -d iotdb -c 'SELECT 1;'" >/dev/null 2>&1; then
      echo "✅ TimescaleDB database connection successful"
    else
      echo "⚠️  TimescaleDB port is open but database may still be initializing"
    fi
  else
    echo "❌ TimescaleDB port 5432 is not accessible"
  fi
  
  # Test MQTT broker
  echo "Testing MQTT broker connectivity..."
  if nc -z -w5 "$IP" 1883 2>/dev/null; then
    echo "✅ MQTT broker port 1883 is accessible"
  else
    echo "❌ MQTT broker port 1883 is not accessible"
  fi
  
  # Check Docker containers
  echo "Checking Docker container status..."
  echo "---"
  if ssh -i ~/.ssh/id_rsa_aws -o StrictHostKeyChecking=no -o BatchMode=yes ubuntu@"$IP" "docker ps --format 'table {{.Names}}\t{{.Status}}'" 2>/dev/null; then
    echo "---"
    echo "✅ Container status check successful"
  else
    echo "❌ Could not check container status"
  fi
  
  # Test Docker network
  echo "Checking Docker network..."
  if ssh -i ~/.ssh/id_rsa_aws -o StrictHostKeyChecking=no -o BatchMode=yes ubuntu@"$IP" "docker network ls | grep -q iot_network" 2>/dev/null; then
    echo "✅ Docker iot_network exists"
  else
    echo "❌ Docker iot_network not found"
  fi
  
  echo ""
  echo "✅ IoT Infrastructure Verification Complete!"
  echo "📡 Service endpoints:"
  echo "   • TimescaleDB: postgresql://iotuser:iotpass@$IP:5432/iotdb"
  echo "   • MQTT Broker: mqtt://$IP:1883"
  echo "   • SSH Access: ubuntu@$IP"
  echo "✅ Server IP: $IP"
  
  # Test Grafana dashboard
  echo "Testing Grafana dashboard connectivity..."
  if nc -z -w5 "$IP" 3000 2>/dev/null; then
    echo "✅ Grafana port 3000 is accessible"
    
    # Test Grafana HTTP endpoint
    if curl -s "http://$IP:3000/api/health" | grep -q "ok" 2>/dev/null; then
      echo "✅ Grafana is responding to HTTP requests"
      echo "   • Grafana Dashboard: http://$IP:3000 (admin/admin)"
    else
      echo "⚠️  Grafana port is open but service may still be starting"
    fi
  else
    echo "❌ Grafana port 3000 is not accessible"
  fi

else
  echo "❌ Could not determine valid IP for verification"
  echo "Available terraform outputs:"
  terraform output 2>/dev/null || echo "No outputs available"
  exit 1
fi
