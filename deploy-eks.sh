#!/usr/bin/env bash
# deploy-eks.sh - AWS EKS deployment script for IoTS6 (GitOps)
set -e

echo "=========================================="
echo "Deploying IoT Stack to AWS EKS with GitOps"
echo "=========================================="

# Load environment variables from .env
if [[ ! -f ".env" ]]; then
    echo "❌ .env file not found. Please create it with required variables"
    exit 1
fi

echo "Loading environment variables..."
set -a
source .env
set +a

# Validate required variables (now includes new ones)
REQUIRED_VARS=("NAMESPACE" "POSTGRES_DB" "POSTGRES_USER" "POSTGRES_PASSWORD" "GRAFANA_ADMIN_USER" "GRAFANA_ADMIN_PASSWORD" "AWS_REGION" "CLUSTER_NAME" "ARGOCD_VERSION" "ARGOCD_NAMESPACE")
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var}" ]]; then
        echo "❌ Required environment variable $var is not set in .env"
        exit 1
    fi
done

# Check prerequisites
if ! aws sts get-caller-identity &> /dev/null; then
    echo "❌ Not logged in to AWS. Please run: aws configure"
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl not found. Please install kubectl"
    exit 1
fi

echo "✅ Prerequisites check passed"
echo "📋 Using cluster: $CLUSTER_NAME in region: $AWS_REGION"

# Source AWS environment variables
source ./set-aws-env.sh

# Deploy EKS cluster
EKS_DIR="terraform-eks"
cd "$EKS_DIR"

if [[ -f "terraform.tfstate" ]]; then
    TERRAFORM_CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null || echo "")
    if [[ -n "$TERRAFORM_CLUSTER_NAME" ]]; then
        echo "📋 EKS cluster already exists: $TERRAFORM_CLUSTER_NAME"
        CLUSTER_NAME="$TERRAFORM_CLUSTER_NAME"  # Use existing cluster name
    fi
else
    echo "🚀 Creating EKS cluster..."
    terraform init
    terraform plan \
        -var="cluster_name=$CLUSTER_NAME" \
        -var="aws_region=$AWS_REGION"
    
    read -p "Proceed with creating the EKS cluster? This will take 10-15 minutes (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Deployment cancelled."
        exit 0
    fi
    
    terraform apply -auto-approve \
        -var="cluster_name=$CLUSTER_NAME" \
        -var="aws_region=$AWS_REGION"
    CLUSTER_NAME=$(terraform output -raw cluster_name)
fi

# Configure kubectl access
echo "Configuring kubectl access..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

cd ..

# Set up EBS CSI driver with improved error handling
echo "🔧 Setting up EBS CSI driver..."

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_ISSUER_URL=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query "cluster.identity.oidc.issuer" --output text)
OIDC_ISSUER=$(echo "$OIDC_ISSUER_URL" | sed 's|https://||')

echo "   AWS Account: $AWS_ACCOUNT_ID"
echo "   OIDC Issuer: $OIDC_ISSUER"

# Create OIDC Identity Provider if needed
echo "Checking OIDC Identity Provider..."
if [[ -z "$(aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?contains(Arn, '$OIDC_ISSUER')]" --output text)" ]]; then
    echo "   Creating OIDC Identity Provider..."
    aws iam create-open-id-connect-provider \
        --url "$OIDC_ISSUER_URL" \
        --thumbprint-list 9e99a48a9960b14926bb7f3b02e22da2b0ab7280 \
        --client-id-list sts.amazonaws.com > /dev/null
    echo "   ✅ OIDC Identity Provider created"
else
    echo "   ✅ OIDC Identity Provider already exists"
fi

# Clean up and recreate IAM role for better reliability
echo "Setting up EBS CSI driver IAM role..."
aws iam detach-role-policy --role-name AmazonEKS_EBS_CSI_DriverRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy 2>/dev/null || true
aws iam delete-role --role-name AmazonEKS_EBS_CSI_DriverRole 2>/dev/null || true

# Create trust policy with proper OIDC configuration
cat > /tmp/trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER}"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_ISSUER}:sub": "system:serviceaccount:kube-system:ebs-csi-controller-sa",
        "${OIDC_ISSUER}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF

# Create IAM role and attach policy with better error handling
echo "   Creating IAM role..."
if aws iam create-role --role-name AmazonEKS_EBS_CSI_DriverRole --assume-role-policy-document file:///tmp/trust-policy.json > /dev/null 2>&1; then
    echo "   ✅ IAM role created successfully"
else
    echo "   ℹ️ IAM role may already exist, continuing..."
fi

echo "   Attaching EBS CSI policy..."
if aws iam attach-role-policy --role-name AmazonEKS_EBS_CSI_DriverRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy 2>/dev/null; then
    echo "   ✅ Policy attached successfully"
else
    echo "   ℹ️ Policy may already be attached, continuing..."
fi

# Verify the policy is attached
ATTACHED_POLICIES=$(aws iam list-attached-role-policies --role-name AmazonEKS_EBS_CSI_DriverRole --query 'AttachedPolicies[?PolicyArn==`arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy`]' --output text)
if [[ -n "$ATTACHED_POLICIES" ]]; then
    echo "   ✅ EBS CSI policy is properly attached"
else
    echo "   ❌ Failed to attach EBS CSI policy"
    exit 1
fi

rm -f /tmp/trust-policy.json

# Install/Update EBS CSI driver addon with better error handling
echo "Installing EBS CSI driver addon..."
if aws eks create-addon \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/AmazonEKS_EBS_CSI_DriverRole" \
  --resolve-conflicts OVERWRITE 2>/dev/null; then
    echo "   ✅ EBS CSI driver addon created"
elif aws eks update-addon \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/AmazonEKS_EBS_CSI_DriverRole" \
  --resolve-conflicts OVERWRITE 2>/dev/null; then
    echo "   ✅ EBS CSI driver addon updated"
else
    echo "   ❌ Failed to create or update EBS CSI driver addon"
    echo "   Checking current addon status..."
    aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-ebs-csi-driver --query "addon.{Status:status,Health:health}" --output table || echo "   No addon found"
fi

# Wait for EBS CSI driver with better status reporting and timeout handling
echo "Waiting for EBS CSI driver to become active..."
EBS_CSI_READY=false

for i in {1..30}; do
    STATUS=$(aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-ebs-csi-driver --query "addon.status" --output text 2>/dev/null || echo "UNKNOWN")
    echo "   EBS CSI driver status: $STATUS (attempt $i/30)"
    
    if [[ "$STATUS" == "ACTIVE" ]]; then
        echo "   ✅ EBS CSI driver is ready"
        EBS_CSI_READY=true
        break
    elif [[ "$STATUS" == "DEGRADED" ]] || [[ "$STATUS" == "CREATE_FAILED" ]]; then
        echo "   ❌ EBS CSI driver failed. Status: $STATUS"
        echo "   Getting detailed addon information..."
        aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-ebs-csi-driver --query "addon" --output json
        exit 1
    elif [[ "$STATUS" == "UNKNOWN" ]]; then
        echo "   ⚠️ Unable to get addon status. Checking if addon exists..."
        if ! aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-ebs-csi-driver >/dev/null 2>&1; then
            echo "   ❌ EBS CSI driver addon not found. Please check addon installation."
            exit 1
        fi
    fi
    
    sleep 10
done

if [[ "$EBS_CSI_READY" != "true" ]]; then
    echo "   ⚠️ EBS CSI driver timeout after 5 minutes"
    echo "   Current status: $STATUS"
    echo "   Continuing deployment but storage may not work properly"
    echo "   You can check addon status later with: aws eks describe-addon --cluster-name $CLUSTER_NAME --addon-name aws-ebs-csi-driver"
fi

# Create storage classes
echo "🗂️ Creating storage classes..."
kubectl apply -f - << EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  fsType: ext4
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
EOF

# Update gp2 for CSI compatibility
kubectl delete storageclass gp2 --ignore-not-found=true
kubectl apply -f - << EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp2
provisioner: ebs.csi.aws.com
parameters:
  type: gp2
  fsType: ext4
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
EOF

echo "   ✅ Storage classes configured (gp3 default, gp2 compatibility)"

# Wait for cluster ready
echo "⏳ Waiting for cluster nodes to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=600s
echo "   ✅ All nodes are ready"

echo ""
echo "🚀 Installing ArgoCD..."
kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "$ARGOCD_NAMESPACE" -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n "$ARGOCD_NAMESPACE"
ARGOCD_PASSWORD=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
kubectl patch svc argocd-server -n "$ARGOCD_NAMESPACE" -p '{"spec": {"type": "LoadBalancer"}}'
echo "✅ ArgoCD installed - Username: admin, Password: $ARGOCD_PASSWORD"

echo ""
echo "🎯 Setting up GitOps deployment..."
kubectl apply -f argocd/applicationsets/iot-environments.yaml
echo "✅ ArgoCD ApplicationSet will now deploy IoT services to multiple environments from Git repo"

echo ""
echo "⏳ Waiting for ArgoCD to sync the applications..."
echo "   This may take 5-10 minutes for all services to start..."
sleep 30  # Give ArgoCD time to start syncing

# Wait for the dev application to sync and become healthy
for i in {1..20}; do
    APP_STATUS=$(kubectl get application iot-stack-dev -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    APP_HEALTH=$(kubectl get application iot-stack-dev -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    
    echo "   ArgoCD Application (dev) - Sync: $APP_STATUS, Health: $APP_HEALTH (attempt $i/20)"
    
    if [[ "$APP_STATUS" == "Synced" && "$APP_HEALTH" == "Healthy" ]]; then
        echo "   ✅ ArgoCD dev application is synced and healthy"
        break
    fi
    
    if [[ $i -eq 20 ]]; then
        echo "   ⚠️ ArgoCD applications may still be syncing. Check status with:"
        echo "      kubectl get applications -n $ARGOCD_NAMESPACE"
        echo "      kubectl describe application iot-stack-dev -n $ARGOCD_NAMESPACE"
    fi
    
    sleep 30
done

echo ""
echo "🌐 Getting service endpoints (dev environment)..."
kubectl get services -n iots6-dev 2>/dev/null || echo "   Services not yet created - ArgoCD is still deploying"

echo ""
echo "📊 Final status check (dev environment)..."
kubectl get all -n iots6-dev 2>/dev/null || echo "   Resources not yet created - ArgoCD is still deploying"

echo ""
echo "=========================================="
echo "GitOps IoT Stack Deployment Complete!"
echo "=========================================="
echo "✅ EKS Cluster: $CLUSTER_NAME"
echo "✅ Region: $AWS_REGION"
echo "✅ Environments: dev, staging, prod"
echo "✅ Storage: gp3 (default), gp2 (compatibility)"
echo ""
echo "🎯 ArgoCD: Username=admin, Password=$ARGOCD_PASSWORD"
echo "   Namespace: $ARGOCD_NAMESPACE"
echo "   Version: $ARGOCD_VERSION"
echo "   Applications: iot-stack-dev, iot-stack-staging, iot-stack-prod"
echo ""
echo "🔍 Monitor GitOps deployment:"
echo "   kubectl get applications -n $ARGOCD_NAMESPACE"
echo "   kubectl get pods -n iots6-dev"
echo "   kubectl get services -n iots6-dev"
echo ""
echo "🌐 Check all environments:"
echo "   kubectl get all -n iots6-dev"
echo "   kubectl get all -n iots6-staging"
echo "   kubectl get all -n iots6-prod"
echo ""
echo "🌐 ArgoCD UI will be available once LoadBalancer is provisioned (~5 minutes)"
echo "🚀 IoT services will be deployed automatically by ArgoCD to all environments!"
echo "=========================================="