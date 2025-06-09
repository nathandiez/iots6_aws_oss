#!/usr/bin/env bash
# destroy-eks.sh - Complete EKS teardown script with enhanced cleanup
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
export TF_VAR_cluster_name="$CLUSTER_NAME"

echo "=========================================="
echo "WARNING: DESTRUCTIVE OPERATION"
echo "=========================================="
echo "This will:"
echo "  - Destroy the AWS EKS cluster"
echo "  - Delete all Kubernetes workloads"
echo "  - Remove all persistent volumes and data"
echo "  - Delete all EKS addons (EBS CSI driver)"
echo "  - Delete External Secrets Operator and resources"
echo "  - Delete AWS Parameter Store parameters"
echo "  - Delete all Terraform state files"
echo "  - Clean up kubectl context"
echo ""
echo "Target cluster: ${CLUSTER_NAME}"
echo "Project name: ${PROJECT_NAME}"
echo "AWS Resources to be destroyed:"
echo "  • EKS cluster (3 nodes)"
echo "  • All worker VMs"
echo "  • Load balancers and public IPs"
echo "  • Persistent volumes and disks"
echo "  • VPC and networking components"
echo "  • EKS addons (EBS CSI driver)"
echo "  • External Secrets IAM roles and policies"
echo "  • AWS Parameter Store configuration"
echo ""
echo "Services to be destroyed:"
echo "  • TimescaleDB and ALL data"
echo "  • Mosquitto MQTT broker"
echo "  • IoT data processing services"
echo "  • Grafana dashboards and config"
echo "  • External Secrets Operator"
echo ""
echo "This action is IRREVERSIBLE!"
echo "=========================================="

echo ""
echo "Starting EKS destruction process..."

# Source AWS environment variables
echo "Loading AWS environment..."
if [[ -f "./set-aws-env.sh" ]]; then
    source ./set-aws-env.sh
fi

# Function to wait for resources to be released
wait_for_resource_deletion() {
    local resource_type=$1
    local wait_time=${2:-30}
    echo "⏳ Waiting ${wait_time} seconds for ${resource_type} to be released..."
    sleep $wait_time
}

# Function to force delete ENIs
force_delete_enis() {
    local vpc_id=$1
    echo "🔧 Force deleting ENIs in VPC: $vpc_id"
    
    # Get all ENIs in the VPC
    ALL_ENIS=$(aws ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "$ALL_ENIS" && "$ALL_ENIS" != "None" ]]; then
        echo "$ALL_ENIS" | tr '\t' '\n' | while read eni; do
            if [[ -n "$eni" && "$eni" != "None" ]]; then
                # Get ENI details
                ENI_INFO=$(aws ec2 describe-network-interfaces \
                    --network-interface-ids "$eni" \
                    --query 'NetworkInterfaces[0].[Status,Description,Attachment.AttachmentId,Attachment.InstanceId]' \
                    --output text 2>/dev/null || echo "")
                
                ENI_STATUS=$(echo "$ENI_INFO" | awk '{print $1}')
                ENI_DESC=$(echo "$ENI_INFO" | awk '{print $2}')
                ATTACHMENT_ID=$(echo "$ENI_INFO" | awk '{print $3}')
                INSTANCE_ID=$(echo "$ENI_INFO" | awk '{print $4}')
                
                echo "  Processing ENI: $eni (Status: $ENI_STATUS, Desc: $ENI_DESC)"
                
                # If attached, try to detach first
                if [[ "$ENI_STATUS" == "in-use" && "$ATTACHMENT_ID" != "None" && -n "$ATTACHMENT_ID" ]]; then
                    echo "    Detaching ENI..."
                    aws ec2 detach-network-interface --attachment-id "$ATTACHMENT_ID" --force 2>/dev/null || true
                    sleep 5
                fi
                
                # Try to delete
                echo "    Deleting ENI..."
                aws ec2 delete-network-interface --network-interface-id "$eni" 2>/dev/null || true
            fi
        done
        wait_for_resource_deletion "ENIs" 10
    fi
}

# Function to clean up security group rules and delete security groups
clean_security_group_rules() {
    local vpc_id=$1
    echo "🔧 Cleaning security group rules in VPC: $vpc_id"
    
    # Get all security groups in VPC
    SG_IDS=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "$SG_IDS" && "$SG_IDS" != "None" ]]; then
        echo "$SG_IDS" | tr '\t' '\n' | while read sg; do
            if [[ -n "$sg" && "$sg" != "None" ]]; then
                echo "  Revoking all rules from security group: $sg"
                # Revoke all ingress rules
                aws ec2 revoke-security-group-ingress \
                    --group-id "$sg" \
                    --ip-permissions "$(aws ec2 describe-security-groups --group-ids "$sg" --query 'SecurityGroups[0].IpPermissions' 2>/dev/null || echo '[]')" \
                    2>/dev/null || true
                # Revoke all egress rules
                aws ec2 revoke-security-group-egress \
                    --group-id "$sg" \
                    --ip-permissions "$(aws ec2 describe-security-groups --group-ids "$sg" --query 'SecurityGroups[0].IpPermissionsEgress' 2>/dev/null || echo '[]')" \
                    2>/dev/null || true
            fi
        done
        
        # Wait a moment for rules to be processed
        sleep 5
        
        # Now try to delete the security groups
        echo "🗑️  Deleting security groups..."
        echo "$SG_IDS" | tr '\t' '\n' | while read sg; do
            if [[ -n "$sg" && "$sg" != "None" ]]; then
                echo "  Deleting security group: $sg"
                aws ec2 delete-security-group --group-id "$sg" 2>/dev/null || true
            fi
        done
    fi
}

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
   VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${CLUSTER_NAME}-vpc" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "")
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
       echo "$LB_ARNS" | tr '\t' '\n' | while read arn; do
           if [[ -n "$arn" && "$arn" != "None" ]]; then
               echo "  🗑️  Deleting ELBv2: $arn"
               aws elbv2 delete-load-balancer --load-balancer-arn "$arn" 2>/dev/null || true
           fi
       done
       wait_for_resource_deletion "Load Balancers" 30
   fi
   
   # Delete classic ELBs
   ELB_NAMES=$(aws elb describe-load-balancers --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" --output text 2>/dev/null || echo "")
   if [[ -n "$ELB_NAMES" && "$ELB_NAMES" != "None" ]]; then
       echo "$ELB_NAMES" | tr '\t' '\n' | while read name; do
           if [[ -n "$name" && "$name" != "None" ]]; then
               echo "  🗑️  Deleting ELB: $name"
               aws elb delete-load-balancer --load-balancer-name "$name" 2>/dev/null || true
           fi
       done
       wait_for_resource_deletion "Classic Load Balancers" 20
   fi
   
   # Clean up any Kubernetes-specific security groups that might be lingering
   echo "🔧 Cleaning up Kubernetes ELB security groups..."
   K8S_SGS=$(aws ec2 describe-security-groups \
       --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=k8s-elb-*" \
       --query 'SecurityGroups[].GroupId' \
       --output text 2>/dev/null || echo "")
   if [[ -n "$K8S_SGS" && "$K8S_SGS" != "None" ]]; then
       echo "$K8S_SGS" | tr '\t' '\n' | while read sg; do
           if [[ -n "$sg" && "$sg" != "None" ]]; then
               echo "  🗑️  Deleting Kubernetes ELB security group: $sg"
               # Clear rules first
               aws ec2 revoke-security-group-ingress \
                   --group-id "$sg" \
                   --ip-permissions "$(aws ec2 describe-security-groups --group-ids "$sg" --query 'SecurityGroups[0].IpPermissions' 2>/dev/null || echo '[]')" \
                   2>/dev/null || true
               aws ec2 revoke-security-group-egress \
                   --group-id "$sg" \
                   --ip-permissions "$(aws ec2 describe-security-groups --group-ids "$sg" --query 'SecurityGroups[0].IpPermissionsEgress' 2>/dev/null || echo '[]')" \
                   2>/dev/null || true
               sleep 2
               aws ec2 delete-security-group --group-id "$sg" 2>/dev/null || true
           fi
       done
       wait_for_resource_deletion "Kubernetes ELB security groups" 10
   fi
   
   # Initial ENI cleanup
   force_delete_enis "$VPC_ID"
   
   # Clean up security group rules AND delete the security groups
   clean_security_group_rules "$VPC_ID"

   # Clean up NAT Gateways that might be in the VPC
   echo "Checking for NAT Gateways..."
   NAT_GWS=$(aws ec2 describe-nat-gateways \
       --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending,deleting" \
       --query 'NatGateways[].NatGatewayId' \
       --output text 2>/dev/null || echo "")
   if [[ -n "$NAT_GWS" && "$NAT_GWS" != "None" ]]; then
       echo "$NAT_GWS" | tr '\t' '\n' | while read nat; do
           if [[ -n "$nat" && "$nat" != "None" ]]; then
               echo "  🗑️  Deleting NAT Gateway: $nat"
               aws ec2 delete-nat-gateway --nat-gateway-id "$nat" 2>/dev/null || true
           fi
       done
       wait_for_resource_deletion "NAT Gateways" 60
   fi

   # Clean up Internet Gateways
   echo "Checking for Internet Gateways..."
   IGW_IDS=$(aws ec2 describe-internet-gateways \
       --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
       --query 'InternetGateways[].InternetGatewayId' \
       --output text 2>/dev/null || echo "")
   if [[ -n "$IGW_IDS" && "$IGW_IDS" != "None" ]]; then
       echo "$IGW_IDS" | tr '\t' '\n' | while read igw; do
           if [[ -n "$igw" && "$igw" != "None" ]]; then
               echo "  🗑️  Detaching and deleting Internet Gateway: $igw"
               aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC_ID" 2>/dev/null || true
               aws ec2 delete-internet-gateway --internet-gateway-id "$igw" 2>/dev/null || true
           fi
       done
   fi
   
   wait_for_resource_deletion "pre-cleanup resources" 20
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
TERRAFORM_CLUSTER_NAME=""

if [[ -f "terraform.tfstate" ]]; then
 # Try to get cluster name, filtering out warnings
 CLUSTER_OUTPUT=$(terraform output -raw cluster_name 2>&1 || echo "")
 TERRAFORM_CLUSTER_NAME=$(echo "$CLUSTER_OUTPUT" | grep -v "Warning" | grep -v "╷" | grep -v "│" | head -1 || echo "")
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
 
 # First, try to delete Kubernetes resources to clean up properly
 if [[ -n "$TERRAFORM_CLUSTER_NAME" ]]; then
   echo ""
   echo "Attempting to clean up Kubernetes resources first..."
   
   # Try to get cluster credentials
   if aws eks update-kubeconfig --region ${AWS_REGION} --name "$TERRAFORM_CLUSTER_NAME" 2>/dev/null; then
     echo "Cleaning up External Secrets resources..."
     kubectl delete externalsecrets --all --all-namespaces --timeout=30s 2>/dev/null || true
     kubectl delete clustersecretstore aws-parameter-store --timeout=30s 2>/dev/null || true
     
     # Uninstall External Secrets Helm releases
     echo "Uninstalling External Secrets Helm releases..."
     helm uninstall external-secrets-config -n default 2>/dev/null || true
     helm uninstall external-secrets -n external-secrets-system 2>/dev/null || true
     kubectl delete namespace external-secrets-system --timeout=60s 2>/dev/null || true
     
     # Uninstall ArgoCD
     echo "Uninstalling ArgoCD..."
     kubectl delete -n ${ARGOCD_NAMESPACE} -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" 2>/dev/null || true
     kubectl delete namespace ${ARGOCD_NAMESPACE} --timeout=60s 2>/dev/null || true
     
     echo "Deleting all namespaced resources..."
     kubectl delete all --all --all-namespaces --timeout=60s 2>/dev/null || true
     
     # CRITICAL: Delete PVCs to ensure EBS volumes are cleaned up
     echo "🗑️  Deleting PersistentVolumeClaims to clean up EBS volumes..."
     for ns in ${PROJECT_NAME}-dev ${PROJECT_NAME}-staging ${PROJECT_NAME}-prod; do
         echo "  Deleting PVCs in namespace: $ns"
         kubectl delete pvc --all -n $ns --wait=true --timeout=60s 2>/dev/null || true
     done
     
     # Also delete PVCs in any other namespaces that might exist
     echo "  Checking for PVCs in all namespaces..."
     kubectl get pvc --all-namespaces --no-headers 2>/dev/null | while read ns name rest; do
         echo "  🗑️  Deleting PVC $name in namespace $ns"
         kubectl delete pvc $name -n $ns --wait=true --timeout=30s 2>/dev/null || true
     done
     
     echo "Deleting persistent volumes..."
     kubectl delete pv --all --timeout=60s 2>/dev/null || true
     
     # Delete project namespaces
     echo "Deleting project namespaces..."
     for ns in ${PROJECT_NAME}-dev ${PROJECT_NAME}-staging ${PROJECT_NAME}-prod; do
         kubectl delete namespace $ns --timeout=60s 2>/dev/null || true
     done
     
     wait_for_resource_deletion "Kubernetes volumes" 30
     
     echo "Kubernetes cleanup completed (or timed out safely)"
   else
     echo "Could not access cluster - will rely on Terraform destroy"
   fi
   
   # Clean up EKS addons before destroying cluster
   echo "Cleaning up EKS addons..."
   aws eks delete-addon --cluster-name "$TERRAFORM_CLUSTER_NAME" --addon-name aws-ebs-csi-driver 2>/dev/null || true
   
   # Clean up External Secrets IAM resources
   echo "Cleaning up External Secrets IAM resources..."
   AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
   aws iam detach-role-policy \
     --role-name ExternalSecretsRole \
     --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/ExternalSecretsParameterStorePolicy" 2>/dev/null || true
   
   aws iam delete-role --role-name ExternalSecretsRole 2>/dev/null || true
   aws iam delete-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/ExternalSecretsParameterStorePolicy" 2>/dev/null || true
   
   # Clean up EBS CSI Driver IAM resources
   echo "Cleaning up EBS CSI Driver IAM resources..."
   aws iam detach-role-policy \
     --role-name AmazonEKS_EBS_CSI_DriverRole \
     --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy 2>/dev/null || true
   
   aws iam delete-role --role-name AmazonEKS_EBS_CSI_DriverRole 2>/dev/null || true
   
   echo "Cleaning up AWS Parameter Store parameters..."
   aws ssm delete-parameters --names \
     "/${PROJECT_NAME}/postgres/db" \
     "/${PROJECT_NAME}/postgres/user" \
     "/${PROJECT_NAME}/postgres/password" \
     "/${PROJECT_NAME}/grafana/admin-user" \
     "/${PROJECT_NAME}/grafana/admin-password" \
     "/${PROJECT_NAME}/kubernetes/namespace" \
     "/${PROJECT_NAME}/project/name" \
     "/${PROJECT_NAME}/datadog/api-key" \
     "/${PROJECT_NAME}/project/name" 2>/dev/null || true
   
   wait_for_resource_deletion "addon deletion" 10
 fi
 
 # Destroy the infrastructure
 echo "Running terraform destroy..."
 terraform destroy -auto-approve
 
 TERRAFORM_EXIT_CODE=$?
 
 if [[ $TERRAFORM_EXIT_CODE -ne 0 ]]; then
     echo ""
     echo "⚠️  Terraform destroy encountered errors. Attempting additional cleanup..."
     
     # If we still have the VPC ID, try more aggressive cleanup
     if [[ -n "$VPC_ID" ]]; then
         echo "Performing aggressive VPC cleanup..."
         
         # Force delete all ENIs again
         force_delete_enis "$VPC_ID"
         
         # Delete VPC Endpoints
         echo "Checking for VPC Endpoints..."
         VPC_ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
             --filters "Name=vpc-id,Values=$VPC_ID" \
             --query 'VpcEndpoints[].VpcEndpointId' \
             --output text 2>/dev/null || echo "")
         if [[ -n "$VPC_ENDPOINTS" && "$VPC_ENDPOINTS" != "None" ]]; then
             echo "$VPC_ENDPOINTS" | tr '\t' '\n' | while read endpoint; do
                 if [[ -n "$endpoint" && "$endpoint" != "None" ]]; then
                     echo "  🗑️  Deleting VPC Endpoint: $endpoint"
                     aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$endpoint" 2>/dev/null || true
                 fi
             done
             wait_for_resource_deletion "VPC Endpoints" 10
         fi
         
         # Try to delete all security groups one more time
         echo "Final security group cleanup..."
         REMAINING_SGS=$(aws ec2 describe-security-groups \
             --filters "Name=vpc-id,Values=$VPC_ID" \
             --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
             --output text 2>/dev/null || echo "")
         if [[ -n "$REMAINING_SGS" && "$REMAINING_SGS" != "None" ]]; then
             echo "$REMAINING_SGS" | tr '\t' '\n' | while read sg; do
                 if [[ -n "$sg" && "$sg" != "None" ]]; then
                     echo "  🗑️  Force deleting security group: $sg"
                     # First try to clear any remaining rules
                     aws ec2 revoke-security-group-ingress \
                         --group-id "$sg" \
                         --ip-permissions "$(aws ec2 describe-security-groups --group-ids "$sg" --query 'SecurityGroups[0].IpPermissions' 2>/dev/null || echo '[]')" \
                         2>/dev/null || true
                     aws ec2 revoke-security-group-egress \
                         --group-id "$sg" \
                         --ip-permissions "$(aws ec2 describe-security-groups --group-ids "$sg" --query 'SecurityGroups[0].IpPermissionsEgress' 2>/dev/null || echo '[]')" \
                         2>/dev/null || true
                     sleep 2
                     # Then delete the security group
                     aws ec2 delete-security-group --group-id "$sg" 2>/dev/null || true
                 fi
             done
         fi
         
         # Final attempt to delete the VPC
         echo "Final VPC deletion attempt..."
         aws ec2 delete-vpc --vpc-id "$VPC_ID" 2>/dev/null || true
     fi
     
     echo ""
     echo "Attempting terraform destroy again..."
     terraform destroy -auto-approve -refresh=false
 fi
 
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
        
        # One more aggressive ENI cleanup
        force_delete_enis "$VPC_ID"
        
        # One more pass at security groups
        REMAINING_SGS=$(aws ec2 describe-security-groups \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
            --output text 2>/dev/null || echo "")
        if [[ -n "$REMAINING_SGS" && "$REMAINING_SGS" != "None" ]]; then
            echo "$REMAINING_SGS" | tr '\t' '\n' | while read sg; do
                if [[ -n "$sg" && "$sg" != "None" ]]; then
                    echo "  🗑️  Final cleanup - deleting security group: $sg"
                    # Clear any remaining rules first
                    aws ec2 revoke-security-group-ingress \
                        --group-id "$sg" \
                        --ip-permissions "$(aws ec2 describe-security-groups --group-ids "$sg" --query 'SecurityGroups[0].IpPermissions' 2>/dev/null || echo '[]')" \
                        2>/dev/null || true
                    aws ec2 revoke-security-group-egress \
                        --group-id "$sg" \
                        --ip-permissions "$(aws ec2 describe-security-groups --group-ids "$sg" --query 'SecurityGroups[0].IpPermissionsEgress' 2>/dev/null || echo '[]')" \
                        2>/dev/null || true
                    sleep 2
                    aws ec2 delete-security-group --group-id "$sg" 2>/dev/null || true
                fi
            done
        fi
        
        # Try to delete VPC
        echo "  🗑️  Attempting to delete VPC: $VPC_ID"
        aws ec2 delete-vpc --vpc-id "$VPC_ID" 2>/dev/null || true
        
        # Check if VPC still exists
        if aws ec2 describe-vpcs --vpc-ids "$VPC_ID" >/dev/null 2>&1; then
            echo ""
            echo "⚠️  WARNING: VPC $VPC_ID still exists. You may need to manually clean up:"
            echo "   1. Check for remaining ENIs: aws ec2 describe-network-interfaces --filters \"Name=vpc-id,Values=$VPC_ID\""
            echo "   2. Check for remaining security groups: aws ec2 describe-security-groups --filters \"Name=vpc-id,Values=$VPC_ID\""
            echo "   3. Check AWS Console for any resources we might have missed"
            echo ""
        fi
    fi
fi

# Clean up any orphaned EBS volumes with project tags
echo ""
echo "🔍 Checking for orphaned EBS volumes..."
ORPHANED_VOLUMES=$(aws ec2 describe-volumes \
    --filters "Name=tag:Name,Values=${PROJECT_NAME}-eks-dynamic-pvc-*" "Name=status,Values=available" \
    --query "Volumes[*].VolumeId" --output text 2>/dev/null || echo "")

if [[ -n "$ORPHANED_VOLUMES" && "$ORPHANED_VOLUMES" != "None" ]]; then
    echo "⚠️  Found orphaned EBS volumes from previous runs:"
    echo "$ORPHANED_VOLUMES" | tr '\t' '\n' | while read vol; do
        if [[ -n "$vol" && "$vol" != "None" ]]; then
            echo "  🗑️  Deleting orphaned volume: $vol"
            aws ec2 delete-volume --volume-id "$vol" 2>/dev/null || true
        fi
    done
    echo "✅ Orphaned volumes cleaned up"
else
    echo "✅ No orphaned volumes found"
fi

# Clean up kubectl contexts
echo ""
echo "Cleaning up kubectl contexts..."
if [[ -n "$TERRAFORM_CLUSTER_NAME" ]]; then
 kubectl config delete-context "arn:aws:eks:${AWS_REGION}:$(aws sts get-caller-identity --query Account --output text):cluster/$TERRAFORM_CLUSTER_NAME" 2>/dev/null || true
 kubectl config unset "users.arn:aws:eks:${AWS_REGION}:$(aws sts get-caller-identity --query Account --output text):cluster/$TERRAFORM_CLUSTER_NAME" 2>/dev/null || true
 echo "✅ Cleaned up kubectl context for $TERRAFORM_CLUSTER_NAME"
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
echo "✅ EKS cluster destroyed (${CLUSTER_NAME})"
echo "✅ Project cleaned up (${PROJECT_NAME})"
echo "✅ All 3 worker nodes terminated"
echo "✅ TimescaleDB and all sensor data deleted"
echo "✅ MQTT broker and message history removed"
echo "✅ All Kubernetes deployments destroyed"
echo "✅ Persistent volumes and disks deleted"
echo "✅ PersistentVolumeClaims cleaned up"
echo "✅ Orphaned EBS volumes removed"
echo "✅ Load balancers and public IPs released"
echo "✅ VPC and networking components deleted"
echo "✅ EKS addons (EBS CSI driver) deleted"
echo "✅ External Secrets Operator uninstalled"
echo "✅ External Secrets IAM resources deleted"
echo "✅ AWS Parameter Store parameters deleted"
echo "✅ ArgoCD uninstalled"
echo "✅ AWS billing stopped for these resources"
echo "✅ Terraform state files deleted"
echo "✅ kubectl contexts cleaned up"
echo ""
echo "💰 All AWS costs for the EKS deployment have stopped"
echo "🚀 You can now run ./deploy-eks.sh to start fresh!"
echo "📝 Your original VM deployment (deploy.sh) is still available"
echo "=========================================="