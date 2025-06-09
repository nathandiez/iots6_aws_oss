#!/usr/bin/env bash
# destroy.sh - Complete AWS teardown script
# WARNING: This will completely destroy the VM and all Terraform state!
set -e

# Load environment variables from .env
if [[ ! -f ".env" ]]; then
    echo "❌ .env file not found. Please create it with required variables"
    exit 1
fi

echo "Loading environment variables..."
set -a
source .env
set +a

# Export Terraform variables from .env
echo "Setting Terraform variables..."
export TF_VAR_aws_region="$AWS_REGION"
export TF_VAR_project_name="$PROJECT_NAME"
export TF_VAR_vm_name="$TARGET_HOSTNAME"
export TF_VAR_admin_username="$ANSIBLE_USER"
export TF_VAR_ssh_public_key_path="${SSH_KEY_PATH}.pub"
export TF_VAR_key_pair_name="$SSH_KEY_NAME"

echo "=========================================="
echo "WARNING: DESTRUCTIVE OPERATION"
echo "=========================================="
echo "This will:"
echo "  - Destroy the AWS IoT infrastructure VM"
echo "  - Delete all Terraform state files"
echo "  - Clean up lock files"
echo "  - Reset everything to a clean slate"
echo ""
echo "Target VM: ${TARGET_HOSTNAME}"
echo "AWS Resources to be destroyed:"
echo "  • EC2 Instance (t3.small)"
echo "  • Elastic IP address"
echo "  • Security groups and VPC networking"
echo "  • VPC, subnets, and internet gateway"
echo ""
echo "Services to be destroyed:"
echo "  • TimescaleDB database and all data"
echo "  • Mosquitto MQTT broker"
echo "  • IoT data processing services"
echo "  • All Docker containers and networks"
echo ""
echo "This action is IRREVERSIBLE!"
echo "Billing will stop after resource deletion."
echo "=========================================="

echo ""
echo "Starting destruction process..."

# Source AWS environment variables
echo "Loading AWS environment..."
source ./set-aws-env.sh

# Change to terraform directory
cd "$(dirname "$0")/terraform"

# Get VM IP for cleanup (before destroying)
echo ""
echo "Getting VM information for cleanup..."
VM_IP=$(terraform output -raw vm_ip 2>/dev/null || echo "")

# Check if terraform state exists
if [[ -f "terraform.tfstate" ]]; then
  echo ""
  echo "Terraform state found. Destroying AWS infrastructure..."
  
  # Initialize terraform (in case .terraform directory is missing)
  terraform init -upgrade
  
  # Show what will be destroyed
  echo "Planning destruction..."
  terraform plan -destroy
  
  # Destroy the infrastructure
  echo "Running terraform destroy..."
  terraform destroy -auto-approve
  
  echo "AWS infrastructure destroyed successfully."
else
  echo "No terraform.tfstate found. Skipping terraform destroy."
fi

# Clean up SSH known_hosts
echo ""
echo "Cleaning up SSH known_hosts..."
if [[ -n "$VM_IP" ]] && [[ "$VM_IP" != "null" ]]; then
  ssh-keygen -R "$VM_IP" 2>/dev/null || true
  echo "✅ Cleaned up SSH entry for $VM_IP"
fi

# Clean up all Terraform files
echo ""
echo "Cleaning up Terraform state and lock files..."

# Remove state files
rm -f terraform.tfstate
rm -f terraform.tfstate.backup

# Remove lock file if it exists
rm -f .terraform.lock.hcl

# Remove .terraform directory (contains providers and modules)
rm -rf .terraform

echo "All Terraform files cleaned up."

# Optional: Clean up Ansible inventory
echo ""
echo "Resetting Ansible inventory..."
cd ../ansible

# Reset the inventory to a default state (remove the IP)
if [[ -f "inventory/hosts" ]]; then
  cat > inventory/hosts << EOF
[iot_servers]
${TARGET_HOSTNAME} ansible_host=PLACEHOLDER

[all:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=${ANSIBLE_USER}
ansible_ssh_private_key_file=${SSH_KEY_PATH}
EOF
  echo "Ansible inventory reset to placeholder state."
fi

echo ""
echo "=========================================="
echo "DESTRUCTION COMPLETE"
echo "=========================================="
echo "✅ AWS EC2 instance destroyed (${TARGET_HOSTNAME})"
echo "✅ TimescaleDB and all sensor data deleted"
echo "✅ MQTT broker and message history removed"
echo "✅ All Docker containers and networks destroyed"
echo "✅ Public IP address released"
echo "✅ Network security groups deleted"
echo "✅ VPC, subnets, and internet gateway removed"
echo "✅ AWS billing stopped for these resources"
echo "✅ Terraform state files deleted"
echo "✅ Terraform lock files removed"
echo "✅ Provider cache cleared"
echo "✅ SSH known_hosts cleaned up"
echo "✅ Ansible inventory reset"
echo ""
echo "💰 All AWS costs for this deployment have stopped"
echo "🚀 You can now run ./deploy.sh to start fresh!"
echo "=========================================="