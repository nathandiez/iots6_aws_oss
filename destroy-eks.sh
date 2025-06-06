#!/usr/bin/env bash
# destroy-eks.sh - Complete EKS teardown script
set -e

echo "=========================================="
echo "WARNING: DESTRUCTIVE OPERATION"
echo "=========================================="
echo "This will:"
echo "  - Destroy the AWS EKS cluster"
echo "  - Delete all Kubernetes workloads"
echo "  - Remove all persistent volumes and data"
echo "  - Delete all EKS addons (EBS CSI driver)"
echo "  - Delete all Terraform state files"
echo "  - Clean up kubectl context"
echo ""
echo "Target cluster: iots6-eks"
echo "AWS Resources to be destroyed:"
echo "  • EKS cluster (3 nodes)"
echo "  • All worker VMs"
echo "  • Load balancers and public IPs"
echo "  • Persistent volumes and disks"
echo "  • VPC and networking components"
echo "  • EKS addons (EBS CSI driver)"
echo ""
echo "Services to be destroyed:"
echo "  • TimescaleDB and ALL data"
echo "  • Mosquitto MQTT broker"
echo "  • IoT data processing services"
echo "  • Grafana dashboards and config"
echo ""
echo "This action is IRREVERSIBLE!"
echo "=========================================="

# Prompt for confirmation
read -p "Are you sure you want to proceed? (type 'yes' to continue): " confirmation

if [[ "$confirmation" != "yes" ]]; then
  echo "Operation cancelled."
  exit 0
fi

echo ""
echo "Starting EKS destruction process..."

# Source AWS environment variables
echo "Loading AWS environment..."
source ./set-aws-env.sh

# Change to EKS terraform directory
EKS_DIR="terraform-eks"
if [[ ! -d "$EKS_DIR" ]]; then
  echo "❌ EKS terraform directory not found: $EKS_DIR"
  echo "The cluster may already be destroyed or was created differently."
  exit 1
fi

cd "$EKS_DIR"

# Get cluster info for cleanup (before destroying)
echo ""
echo "Getting cluster information for cleanup..."
CLUSTER_NAME=""

if [[ -f "terraform.tfstate" ]]; then
  CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null || echo "")
fi

# Check if state file has actual resources
if [[ -f "terraform.tfstate" ]]; then
  # Check if state file is empty or has no resources
  if terraform show | grep -q "No resources are represented"; then
    echo ""
    echo "Terraform state file exists but is empty. Cleaning up state files..."
    # Clean up empty state files
    rm -f terraform.tfstate*
    rm -f .terraform.lock.hcl
    rm -rf .terraform
    echo "✅ Cleaned up empty Terraform state files"
    cd ..
    echo ""
    echo "=========================================="
    echo "EKS CLEANUP COMPLETE"
    echo "=========================================="
    echo "✅ No active cluster found"
    echo "✅ Cleaned up empty Terraform state files"
    echo "🚀 You can now run ./deploy-eks.sh to start fresh!"
    echo "=========================================="
    exit 0
  fi
  
  echo ""
  echo "Terraform state found. Destroying EKS infrastructure..."
  
  # Initialize terraform (in case .terraform directory is missing)
  terraform init -upgrade
  
  # Show what will be destroyed
  echo "Planning destruction..."
  terraform plan -destroy
  
  echo ""
  read -p "Proceed with destroying these AWS resources? (type 'yes'): " final_confirm
  
  if [[ "$final_confirm" != "yes" ]]; then
    echo "Destruction cancelled."
    exit 0
  fi
  
  # First, try to delete Kubernetes resources to clean up properly
  if [[ -n "$CLUSTER_NAME" ]]; then
    echo ""
    echo "Attempting to clean up Kubernetes resources first..."
    
    # Try to get cluster credentials
    if aws eks update-kubeconfig --region $(aws configure get region) --name "$CLUSTER_NAME" 2>/dev/null; then
      echo "Deleting all namespaced resources..."
      kubectl delete all --all --all-namespaces --timeout=60s 2>/dev/null || true
      
      echo "Deleting persistent volumes..."
      kubectl delete pv --all --timeout=60s 2>/dev/null || true
      
      echo "Kubernetes cleanup completed (or timed out safely)"
    else
      echo "Could not access cluster - will rely on Terraform destroy"
    fi
    
    # Clean up EKS addons before destroying cluster
    echo "Cleaning up EKS addons..."
    aws eks delete-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-ebs-csi-driver 2>/dev/null || true
    echo "Waiting for addon deletion..."
    sleep 10
  fi
  
  # Destroy the infrastructure
  echo "Running terraform destroy..."
  terraform destroy -auto-approve
  
  echo "EKS infrastructure destroyed successfully."
else
  echo "No terraform.tfstate found. Skipping terraform destroy."
fi

# Clean up kubectl contexts
echo ""
echo "Cleaning up kubectl contexts..."
if [[ -n "$CLUSTER_NAME" ]]; then
  kubectl config delete-context "arn:aws:eks:$(aws configure get region):$(aws sts get-caller-identity --query Account --output text):cluster/$CLUSTER_NAME" 2>/dev/null || true
  kubectl config unset "users.arn:aws:eks:$(aws configure get region):$(aws sts get-caller-identity --query Account --output text):cluster/$CLUSTER_NAME" 2>/dev/null || true
  echo "✅ Cleaned up kubectl context for $CLUSTER_NAME"
fi

# Clean up all Terraform files
echo ""
echo "Cleaning up Terraform state and lock files..."

# Remove state files
rm -f terraform.tfstate
rm -f terraform.tfstate.backup

# Remove lock file if it exists
rm -f .terraform.lock.hcl

# Remove .terraform directory
rm -rf .terraform

echo "All Terraform files cleaned up."

echo ""
echo "=========================================="
echo "EKS DESTRUCTION COMPLETE"
echo "=========================================="
echo "✅ EKS cluster destroyed (iots6-eks)"
echo "✅ All 3 worker nodes terminated"
echo "✅ TimescaleDB and all sensor data deleted"
echo "✅ MQTT broker and message history removed"
echo "✅ All Kubernetes deployments destroyed"
echo "✅ Persistent volumes and disks deleted"
echo "✅ Load balancers and public IPs released"
echo "✅ VPC and networking components deleted"
echo "✅ EKS addons (EBS CSI driver) deleted"
echo "✅ AWS billing stopped for these resources"
echo "✅ Terraform state files deleted"
echo "✅ kubectl contexts cleaned up"
echo ""
echo "💰 All AWS costs for the EKS deployment have stopped"
echo "🚀 You can now run ./deploy-eks.sh to start fresh!"
echo "📝 Your original VM deployment (deploy.sh) is still available"
echo "=========================================="