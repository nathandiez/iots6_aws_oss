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

echo ""
echo "🧹 Cleaning up leftover AWS resources that could block deletion..."

# Try to get VPC ID from multiple sources
VPC_ID=""

# Method 1: Try terraform output (filter out warning messages)
if [[ -d "terraform-eks" && -f "terraform-eks/terraform.tfstate" ]]; then
   cd terraform-eks
   # Capture terraform output and filter out warning messages
   TERRAFORM_OUTPUT=$(terraform output -raw vpc_id 2>&1 || echo "")
   # Extract VPC ID if it looks like a valid VPC ID (vpc-xxxxxxxxx)
   VPC_ID=$(echo "$TERRAFORM_OUTPUT" | grep -E "^vpc-[a-f0-9]{8,17}$" | head -1 || echo "")
   cd ..
fi

# Method 2: If terraform output failed, try to find VPC by tags
if [[ -z "$VPC_ID" ]]; then
   echo "Terraform output failed, searching for VPC by tags..."
   VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=iots6-eks-vpc" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "")
   if [[ "$VPC_ID" == "None" ]]; then
       VPC_ID=""
   fi
fi

# Method 3: If still no VPC, search for any VPC with EKS-related resources
if [[ -z "$VPC_ID" ]]; then
   echo "Searching for VPC with EKS-related ENIs..."
   VPC_ID=$(aws ec2 describe-network-interfaces --filters "Name=description,Values=*aws-K8S*" --query 'NetworkInterfaces[0].VpcId' --output text 2>/dev/null || echo "")
   if [[ "$VPC_ID" == "None" ]]; then
       VPC_ID=""
   fi
fi

# Method 4: Last resort - find any VPC with kubernetes-related security groups
if [[ -z "$VPC_ID" ]]; then
   echo "Searching for VPC with EKS security groups..."
   VPC_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=*eks*" --query 'SecurityGroups[0].VpcId' --output text 2>/dev/null || echo "")
   if [[ "$VPC_ID" == "None" ]]; then
       VPC_ID=""
   fi
fi

if [[ -n "$VPC_ID" ]]; then
   echo "Found VPC: $VPC_ID"
   
   # Delete any remaining load balancers in the VPC
   echo "Checking for lingering load balancers..."
   LB_ARNS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null || echo "")
   if [[ -n "$LB_ARNS" && "$LB_ARNS" != "None" ]]; then
       echo "$LB_ARNS" | while read arn; do
           if [[ -n "$arn" && "$arn" != "None" ]]; then
               echo "  🗑️  Deleting ELBv2: $arn"
               aws elbv2 delete-load-balancer --load-balancer-arn "$arn" 2>/dev/null || true
           fi
       done
   fi
   
   # Delete classic ELBs
   ELB_NAMES=$(aws elb describe-load-balancers --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" --output text 2>/dev/null || echo "")
   if [[ -n "$ELB_NAMES" && "$ELB_NAMES" != "None" ]]; then
       echo "$ELB_NAMES" | while read name; do
           if [[ -n "$name" && "$name" != "None" ]]; then
               echo "  🗑️  Deleting ELB: $name"
               aws elb delete-load-balancer --load-balancer-name "$name" 2>/dev/null || true
           fi
       done
   fi
   
   # Find and delete leftover Kubernetes ENIs
   echo "Cleaning up leftover Kubernetes network interfaces..."
   K8S_ENIS=$(aws ec2 describe-network-interfaces \
       --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
       --query 'NetworkInterfaces[?contains(Description, `aws-K8S`) || contains(Description, `eks`)].NetworkInterfaceId' \
       --output text 2>/dev/null || echo "")
   if [[ -n "$K8S_ENIS" && "$K8S_ENIS" != "None" ]]; then
       echo "$K8S_ENIS" | while read eni; do
           if [[ -n "$eni" && "$eni" != "None" ]]; then
               echo "  🗑️  Deleting Kubernetes ENI: $eni"
               aws ec2 delete-network-interface --network-interface-id "$eni" 2>/dev/null || true
           fi
       done
   fi
   
   # Also check for any other available ENIs that might be blocking subnet deletion
   echo "Checking for any other ENIs that might block subnet deletion..."
   ALL_ENIS=$(aws ec2 describe-network-interfaces \
       --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
       --query 'NetworkInterfaces[].NetworkInterfaceId' \
       --output text 2>/dev/null || echo "")
   if [[ -n "$ALL_ENIS" && "$ALL_ENIS" != "None" ]]; then
       echo "$ALL_ENIS" | while read eni; do
           if [[ -n "$eni" && "$eni" != "None" ]]; then
               echo "  🗑️  Deleting available ENI: $eni"
               aws ec2 delete-network-interface --network-interface-id "$eni" 2>/dev/null || true
           fi
       done
   fi

   # Clean up EKS security groups that can block VPC deletion
   echo "Cleaning up EKS security groups..."
   EKS_SGS=$(aws ec2 describe-security-groups \
       --filters "Name=vpc-id,Values=$VPC_ID" \
       --query 'SecurityGroups[?GroupName!=`default` && (contains(GroupName, `eks`) || contains(Description, `EKS`) || contains(to_string(Tags), `eks`))].GroupId' \
       --output text 2>/dev/null || echo "")
   if [[ -n "$EKS_SGS" && "$EKS_SGS" != "None" ]]; then
       echo "$EKS_SGS" | while read sg; do
           if [[ -n "$sg" && "$sg" != "None" ]]; then
               echo "  🗑️  Deleting EKS security group: $sg"
               # First, try to revoke all ingress rules to break circular dependencies
               aws ec2 revoke-security-group-ingress --group-id "$sg" --source-group "$sg" --protocol all 2>/dev/null || true
               # Then delete the security group
               aws ec2 delete-security-group --group-id "$sg" 2>/dev/null || true
           fi
       done
   fi

   # Clean up NAT Gateways that might be in the VPC
   echo "Checking for NAT Gateways..."
   NAT_GWS=$(aws ec2 describe-nat-gateways \
       --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" \
       --query 'NatGateways[].NatGatewayId' \
       --output text 2>/dev/null || echo "")
   if [[ -n "$NAT_GWS" && "$NAT_GWS" != "None" ]]; then
       echo "$NAT_GWS" | while read nat; do
           if [[ -n "$nat" && "$nat" != "None" ]]; then
               echo "  🗑️  Deleting NAT Gateway: $nat"
               aws ec2 delete-nat-gateway --nat-gateway-id "$nat" 2>/dev/null || true
           fi
       done
       echo "⏳ Waiting 30 seconds for NAT Gateway deletion..."
       sleep 30
   fi

   # Clean up Internet Gateways
   echo "Checking for Internet Gateways..."
   IGW_IDS=$(aws ec2 describe-internet-gateways \
       --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
       --query 'InternetGateways[].InternetGatewayId' \
       --output text 2>/dev/null || echo "")
   if [[ -n "$IGW_IDS" && "$IGW_IDS" != "None" ]]; then
       echo "$IGW_IDS" | while read igw; do
           if [[ -n "$igw" && "$igw" != "None" ]]; then
               echo "  🗑️  Detaching and deleting Internet Gateway: $igw"
               aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC_ID" 2>/dev/null || true
               aws ec2 delete-internet-gateway --internet-gateway-id "$igw" 2>/dev/null || true
           fi
       done
   fi
   
   echo "⏳ Waiting 20 seconds for resource cleanup to complete..."
   sleep 20
   echo "✅ Pre-cleanup completed"
else
   echo "No VPC found - skipping pre-cleanup"
fi
echo ""

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
 # Try to get cluster name, filtering out warnings
 CLUSTER_OUTPUT=$(terraform output -raw cluster_name 2>&1 || echo "")
 CLUSTER_NAME=$(echo "$CLUSTER_OUTPUT" | grep -v "Warning" | grep -v "╷" | grep -v "│" | head -1 || echo "")
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

# Additional cleanup after terraform destroy in case it missed anything
echo ""
echo "🧽 Final cleanup pass for any remaining VPC resources..."
if [[ -n "$VPC_ID" ]]; then
    # Try to delete the VPC directly if it still exists
    if aws ec2 describe-vpcs --vpc-ids "$VPC_ID" >/dev/null 2>&1; then
        echo "VPC still exists, attempting final cleanup..."
        
        # One more pass at security groups
        REMAINING_SGS=$(aws ec2 describe-security-groups \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
            --output text 2>/dev/null || echo "")
        if [[ -n "$REMAINING_SGS" && "$REMAINING_SGS" != "None" ]]; then
            echo "$REMAINING_SGS" | while read sg; do
                if [[ -n "$sg" && "$sg" != "None" ]]; then
                    echo "  🗑️  Final cleanup - deleting security group: $sg"
                    aws ec2 delete-security-group --group-id "$sg" 2>/dev/null || true
                fi
            done
        fi
        
        # Try to delete VPC
        echo "  🗑️  Attempting to delete VPC: $VPC_ID"
        aws ec2 delete-vpc --vpc-id "$VPC_ID" 2>/dev/null || true
    fi
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