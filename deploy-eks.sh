#!/usr/bin/env bash
# deploy-eks.sh - AWS EKS deployment script for IoTS6
set -e

echo "=========================================="
echo "Deploying IoT Stack to AWS EKS"
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

# Validate required variables
REQUIRED_VARS=("NAMESPACE" "POSTGRES_DB" "POSTGRES_USER" "POSTGRES_PASSWORD" "GRAFANA_ADMIN_USER" "GRAFANA_ADMIN_PASSWORD")
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

# Source AWS environment variables
source ./set-aws-env.sh

# Deploy EKS cluster
EKS_DIR="terraform-eks"
cd "$EKS_DIR"

if [[ -f "terraform.tfstate" ]]; then
    CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null || echo "")
    if [[ -n "$CLUSTER_NAME" ]]; then
        echo "📋 EKS cluster already exists: $CLUSTER_NAME"
    fi
else
    echo "🚀 Creating EKS cluster..."
    terraform init
    terraform plan
    
    read -p "Proceed with creating the EKS cluster? This will take 10-15 minutes (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Deployment cancelled."
        exit 0
    fi
    
    terraform apply -auto-approve
    CLUSTER_NAME=$(terraform output -raw cluster_name)
fi

# Configure kubectl access
echo "Configuring kubectl access..."
aws eks update-kubeconfig --region $(aws configure get region) --name "$CLUSTER_NAME"

cd ..

# Set up EBS CSI driver with improved error handling
echo "🔧 Setting up EBS CSI driver..."

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_ISSUER_URL=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text)
OIDC_ISSUER=$(echo $OIDC_ISSUER_URL | sed 's|https://||')

echo "   AWS Account: $AWS_ACCOUNT_ID"
echo "   OIDC Issuer: $OIDC_ISSUER"

# Create OIDC Identity Provider if needed
echo "Checking OIDC Identity Provider..."
if [[ -z "$(aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?contains(Arn, '$OIDC_ISSUER')]" --output text)" ]]; then
    echo "   Creating OIDC Identity Provider..."
    aws iam create-open-id-connect-provider \
        --url $OIDC_ISSUER_URL \
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
  --cluster-name $CLUSTER_NAME \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn arn:aws:iam::${AWS_ACCOUNT_ID}:role/AmazonEKS_EBS_CSI_DriverRole \
  --resolve-conflicts OVERWRITE 2>/dev/null; then
    echo "   ✅ EBS CSI driver addon created"
elif aws eks update-addon \
  --cluster-name $CLUSTER_NAME \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn arn:aws:iam::${AWS_ACCOUNT_ID}:role/AmazonEKS_EBS_CSI_DriverRole \
  --resolve-conflicts OVERWRITE 2>/dev/null; then
    echo "   ✅ EBS CSI driver addon updated"
else
    echo "   ❌ Failed to create or update EBS CSI driver addon"
    echo "   Checking current addon status..."
    aws eks describe-addon --cluster-name $CLUSTER_NAME --addon-name aws-ebs-csi-driver --query "addon.{Status:status,Health:health}" --output table || echo "   No addon found"
fi

# Wait for EBS CSI driver with better status reporting and timeout handling
echo "Waiting for EBS CSI driver to become active..."
EBS_CSI_READY=false

for i in {1..30}; do
    STATUS=$(aws eks describe-addon --cluster-name $CLUSTER_NAME --addon-name aws-ebs-csi-driver --query "addon.status" --output text 2>/dev/null || echo "UNKNOWN")
    echo "   EBS CSI driver status: $STATUS (attempt $i/30)"
    
    if [[ "$STATUS" == "ACTIVE" ]]; then
        echo "   ✅ EBS CSI driver is ready"
        EBS_CSI_READY=true
        break
    elif [[ "$STATUS" == "DEGRADED" ]] || [[ "$STATUS" == "CREATE_FAILED" ]]; then
        echo "   ❌ EBS CSI driver failed. Status: $STATUS"
        echo "   Getting detailed addon information..."
        aws eks describe-addon --cluster-name $CLUSTER_NAME --addon-name aws-ebs-csi-driver --query "addon" --output json
        exit 1
    elif [[ "$STATUS" == "UNKNOWN" ]]; then
        echo "   ⚠️ Unable to get addon status. Checking if addon exists..."
        if ! aws eks describe-addon --cluster-name $CLUSTER_NAME --addon-name aws-ebs-csi-driver >/dev/null 2>&1; then
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
echo "🚀 Deploying IoT services..."

# Function to apply YAML with proper variable substitution and error handling
apply_with_envsubst() {
    local file="$1"
    local description="${2:-$file}"
    
    if [[ ! -f "$file" ]]; then
        echo "   ❌ File not found: $file"
        return 1
    fi
    
    echo "   Applying $description..."
    if envsubst < "$file" | kubectl apply -f - 2>/dev/null; then
        echo "   ✅ $description applied successfully"
    else
        echo "   ❌ Failed to apply $description"
        echo "   Checking file content for debugging..."
        echo "   First 10 lines of processed file:"
        envsubst < "$file" | head -10
        return 1
    fi
}

echo "1. Creating namespace..."
apply_with_envsubst kubernetes/namespace/namespace.yaml

echo "2. Creating secrets..."
apply_with_envsubst kubernetes/secrets/credentials.yaml

echo "3. Creating config maps..."
apply_with_envsubst kubernetes/configmaps/timescaledb-init.yaml
apply_with_envsubst kubernetes/configmaps/mosquitto-config.yaml

echo "4. Creating persistent volumes..."
# Clean up any existing PVCs that might have wrong storage class
kubectl delete pvc timescaledb-data mosquitto-data grafana-data -n $NAMESPACE --ignore-not-found=true
sleep 5  # Give it a moment to clean up

apply_with_envsubst kubernetes/storage/timescaledb-pvc.yaml
apply_with_envsubst kubernetes/storage/mosquitto-pvc.yaml
apply_with_envsubst kubernetes/storage/grafana-pvc.yaml

echo "   📋 PVC Status (will be Pending until pods are created):"
kubectl get pvc -n $NAMESPACE

echo "5. Creating deployments..."
apply_with_envsubst kubernetes/deployments/timescaledb.yaml
apply_with_envsubst kubernetes/deployments/mosquitto.yaml
apply_with_envsubst kubernetes/deployments/iot-service.yaml
apply_with_envsubst kubernetes/deployments/grafana.yaml

echo "6. Creating services..."
apply_with_envsubst kubernetes/services/timescaledb.yaml
apply_with_envsubst kubernetes/services/mosquitto.yaml
apply_with_envsubst kubernetes/services/grafana.yaml

echo ""
echo "⏳ Waiting for deployments to become available..."
echo "   This may take 5-10 minutes for all services to start..."

for deployment in timescaledb mosquitto iot-service grafana; do
    echo "   Waiting for $deployment..."
    if kubectl wait --for=condition=available --timeout=600s deployment/$deployment -n $NAMESPACE; then
        echo "   ✅ $deployment is ready"
    else
        echo "   ⚠️ $deployment may still be starting (check logs: kubectl logs deployment/$deployment -n $NAMESPACE)"
    fi
done

echo ""
echo "🌐 Getting service endpoints..."
kubectl get services -n $NAMESPACE

echo ""
echo "📊 Final status check..."
kubectl get all -n $NAMESPACE

echo ""
echo "=========================================="
echo "IoT Stack Deployment Complete!"
echo "=========================================="
echo "✅ EKS Cluster: $CLUSTER_NAME"
echo "✅ Namespace: $NAMESPACE"
echo "✅ Storage: gp3 (default), gp2 (compatibility)"
echo ""
echo "🔍 Check pods: kubectl get pods -n $NAMESPACE"
echo "🔍 Check PVCs: kubectl get pvc -n $NAMESPACE"
echo "🔍 Check logs: kubectl logs deployment/<service-name> -n $NAMESPACE"
echo "📊 Monitor: ./status.sh"
echo ""
echo "🌐 External endpoints will be available once LoadBalancers are provisioned (~5 minutes)"
echo "=========================================="