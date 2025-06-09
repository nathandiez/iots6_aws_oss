#!/usr/bin/env bash
# wait-for-ssh.sh - Wait for AWS EC2 to be accessible via SSH and update Ansible inventory
set -e

# Load environment variables from .env if available
if [[ -f "../../.env" ]]; then
    set -a
    source ../../.env
    set +a
elif [[ -f "../.env" ]]; then
    set -a
    source ../.env
    set +a
elif [[ -f ".env" ]]; then
    set -a
    source .env
    set +a
fi

echo "Waiting for SSH to become available..."
max_attempts=30
attempt=0

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
  
  if [ -n "$ip" ] && [ "$ip" != "null" ]; then
    echo "$ip"
    return 0
  fi
  
  echo ""
  return 1
}

# Get IP address with retries
for i in {1..5}; do
  IP=$(get_ip)
  if [ -n "$IP" ]; then
    break
  fi
  echo "IP detection attempt $i failed, waiting 10 seconds..."
  sleep 10
done

if [ -z "$IP" ]; then
  echo "Error: Could not retrieve a valid IP address after multiple attempts"
  echo "Debug: Trying terraform refresh..."
  terraform refresh
  IP=$(get_ip)
fi

if [ -z "$IP" ]; then
  echo "Error: Still could not retrieve a valid IP address"
  echo "Debug info:"
  terraform output || echo "No outputs available"
  exit 1
fi

echo "Using IP: $IP"

# Wait for SSH to actually be available
echo "Testing SSH connectivity..."
while [ $attempt -lt $max_attempts ]; do
  if ssh -i ${SSH_KEY_PATH:-~/.ssh/id_rsa_aws} -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 ${ANSIBLE_USER:-ubuntu}@"$IP" echo "SSH Ready" 2>/dev/null; then
    echo "✅ SSH is available!"
    break
  fi
  
  attempt=$((attempt + 1))
  echo "⏳ SSH attempt $attempt/$max_attempts failed, waiting 10 seconds..."
  
  if [ $attempt -eq $max_attempts ]; then
    echo "❌ SSH timeout after $max_attempts attempts"
    exit 1
  fi
  
  sleep 10
done

# Update Ansible inventory with correct IP
# Create hosts file directory if it doesn't exist
mkdir -p ../ansible/inventory
echo "Updating Ansible inventory with IP: $IP"
cat > ../ansible/inventory/hosts << EOF
[iot_servers]
${TARGET_HOSTNAME:-awiots6} ansible_host=$IP

[all:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=${ANSIBLE_USER:-ubuntu}
ansible_ssh_private_key_file=${SSH_KEY_PATH:-~/.ssh/id_rsa_aws}
EOF

echo "✅ SSH ready and inventory updated"