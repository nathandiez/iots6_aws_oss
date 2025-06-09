#!/usr/bin/env bash
# deploy-eks.sh - AWS EKS deployment script for IoTS6 (Production GitOps)
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

# Export Terraform variables from .env
echo "Setting Terraform variables..."
export TF_VAR_aws_region="$AWS_REGION"
export TF_VAR_cluster_name="$CLUSTER_NAME"

# Validate required variables
REQUIRED_VARS=("EKS_NAMESPACE" "POSTGRES_DB" "POSTGRES_USER" "POSTGRES_PASSWORD" "GRAFANA_ADMIN_USER" "GRAFANA_ADMIN_PASSWORD" "AWS_REGION" "CLUSTER_NAME" "ARGOCD_VERSION" "ARGOCD_NAMESPACE" "PROJECT_NAME")
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

if ! command -v helm &> /dev/null; then
    echo "❌ helm not found. Please install helm"
    exit 1
fi

echo "✅ Prerequisites check passed"
echo "📋 Using cluster: $CLUSTER_NAME in region: $AWS_REGION"

# Store configuration in AWS Parameter Store
echo ""
echo "📦 Storing configuration in AWS Parameter Store..."
aws ssm put-parameter --name "/${PROJECT_NAME}/postgres/db" --value "$POSTGRES_DB" --type "String" --overwrite
aws ssm put-parameter --name "/${PROJECT_NAME}/postgres/user" --value "$POSTGRES_USER" --type "String" --overwrite
aws ssm put-parameter --name "/${PROJECT_NAME}/postgres/password" --value "$POSTGRES_PASSWORD" --type "SecureString" --overwrite
aws ssm put-parameter --name "/${PROJECT_NAME}/grafana/admin-user" --value "$GRAFANA_ADMIN_USER" --type "String" --overwrite
aws ssm put-parameter --name "/${PROJECT_NAME}/grafana/admin-password" --value "$GRAFANA_ADMIN_PASSWORD" --type "SecureString" --overwrite
aws ssm put-parameter --name "/${PROJECT_NAME}/kubernetes/namespace" --value "$EKS_NAMESPACE" --type "String" --overwrite
aws ssm put-parameter --name "/${PROJECT_NAME}/project/name" --value "$PROJECT_NAME" --type "String" --overwrite
aws ssm put-parameter --name "/${PROJECT_NAME}/datadog/api-key" --value "$DATADOG_API_KEY" --type "SecureString" --overwrite
aws ssm put-parameter --name "/${PROJECT_NAME}/datadog/site" --value "$DATADOG_SITE" --type "String" --overwrite
echo "✅ Configuration stored in AWS Parameter Store"

# Source AWS environment variables
if [[ -f "./set-aws-env.sh" ]]; then
    source ./set-aws-env.sh
fi

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
    
    terraform apply -auto-approve \
        -var="cluster_name=$CLUSTER_NAME" \
        -var="aws_region=$AWS_REGION"
    CLUSTER_NAME=$(terraform output -raw cluster_name)
fi

# Configure kubectl access
echo "Configuring kubectl access..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

cd ..

# Set up EBS CSI driver
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

# Set up EBS CSI driver IAM role
echo "Setting up EBS CSI driver IAM role..."
aws iam detach-role-policy --role-name AmazonEKS_EBS_CSI_DriverRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy 2>/dev/null || true
aws iam delete-role --role-name AmazonEKS_EBS_CSI_DriverRole 2>/dev/null || true

# Create trust policy
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

# Create IAM role and attach policy
echo "   Creating IAM role..."
if aws iam create-role --role-name AmazonEKS_EBS_CSI_DriverRole --assume-role-policy-document file:///tmp/trust-policy.json > /dev/null 2>&1; then
    echo "   ✅ IAM role created successfully"
else
    echo "   ℹ️ IAM role may already exist, continuing..."
fi

echo "   Attaching EBS CSI policy..."
aws iam attach-role-policy --role-name AmazonEKS_EBS_CSI_DriverRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy 2>/dev/null || true

# Verify the policy is attached
ATTACHED_POLICIES=$(aws iam list-attached-role-policies --role-name AmazonEKS_EBS_CSI_DriverRole --query 'AttachedPolicies[?PolicyArn==`arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy`]' --output text)
if [[ -n "$ATTACHED_POLICIES" ]]; then
    echo "   ✅ EBS CSI policy is properly attached"
else
    echo "   ❌ Failed to attach EBS CSI policy"
    exit 1
fi

rm -f /tmp/trust-policy.json

# Install/Update EBS CSI driver addon
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
    echo "   ⚠️ EBS CSI driver addon may already be configured"
fi

# Wait for EBS CSI driver
echo "Waiting for EBS CSI driver to become active..."
for i in {1..30}; do
    STATUS=$(aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-ebs-csi-driver --query "addon.status" --output text 2>/dev/null || echo "UNKNOWN")
    echo "   EBS CSI driver status: $STATUS (attempt $i/30)"
    
    if [[ "$STATUS" == "ACTIVE" ]]; then
        echo "   ✅ EBS CSI driver is ready"
        break
    elif [[ "$STATUS" == "DEGRADED" ]] || [[ "$STATUS" == "CREATE_FAILED" ]]; then
        echo "   ❌ EBS CSI driver failed. Status: $STATUS"
        exit 1
    fi
    
    sleep 10
done

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

echo "   ✅ Storage classes configured"

# Wait for cluster ready
echo "⏳ Waiting for cluster nodes to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=600s
echo "   ✅ All nodes are ready"

# Install External Secrets Operator
echo ""
echo "🔐 Installing External Secrets Operator..."
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets-system \
  --create-namespace \
  --set installCRDs=true \
  --wait --timeout=300s

# Wait for CRDs to be registered
echo "⏳ Waiting for External Secrets CRDs to be ready..."
for i in {1..60}; do
    CRD_CSS=$(kubectl get crd clustersecretstores.external-secrets.io -o name 2>/dev/null || echo "")
    CRD_ES=$(kubectl get crd externalsecrets.external-secrets.io -o name 2>/dev/null || echo "")
    
    if [[ -n "$CRD_CSS" && -n "$CRD_ES" ]]; then
        echo "   ✅ External Secrets CRDs found"
        kubectl wait --for condition=established --timeout=60s crd/clustersecretstores.external-secrets.io
        kubectl wait --for condition=established --timeout=60s crd/externalsecrets.external-secrets.io
        echo "   ✅ External Secrets CRDs are ready"
        break
    fi
    
    if [[ $i -eq 60 ]]; then
        echo "   ❌ External Secrets CRDs not found after 5 minutes"
        exit 1
    fi
    
    echo "   Waiting for CRDs... (attempt $i/60)"
    sleep 5
done

# Wait for webhook to be ready
echo "⏳ Waiting for External Secrets webhook to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=external-secrets-webhook \
    -n external-secrets-system --timeout=120s || true

# Create IRSA for External Secrets
echo "🔑 Setting up IRSA for External Secrets..."

# Wait for service account
echo "   Waiting for External Secrets service account..."
for i in {1..30}; do
    if kubectl get serviceaccount external-secrets -n external-secrets-system >/dev/null 2>&1; then
        echo "   ✅ Service account exists"
        break
    fi
    sleep 5
done

# Create IAM policy for External Secrets
cat > /tmp/external-secrets-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ssm:GetParameter",
                "ssm:GetParameters",
                "ssm:GetParametersByPath"
            ],
            "Resource": "arn:aws:ssm:${AWS_REGION}:${AWS_ACCOUNT_ID}:parameter/${PROJECT_NAME}/*"
        }
    ]
}
EOF

echo "   Creating IAM policy..."
if aws iam create-policy \
  --policy-name ExternalSecretsParameterStorePolicy \
  --policy-document file:///tmp/external-secrets-policy.json >/dev/null 2>&1; then
    echo "   ✅ IAM policy created"
else
    echo "   ℹ️ IAM policy already exists"
fi

# Create trust policy for External Secrets
cat > /tmp/external-secrets-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_ISSUER}:sub": "system:serviceaccount:external-secrets-system:external-secrets",
          "${OIDC_ISSUER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

echo "   Creating IAM role..."
if aws iam create-role \
  --role-name ExternalSecretsRole \
  --assume-role-policy-document file:///tmp/external-secrets-trust-policy.json >/dev/null 2>&1; then
    echo "   ✅ IAM role created"
else
    echo "   ℹ️ IAM role already exists"
fi

echo "   Attaching policy to role..."
aws iam attach-role-policy \
  --role-name ExternalSecretsRole \
  --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/ExternalSecretsParameterStorePolicy" 2>&1 || true

# Annotate the service account
echo "   Annotating service account..."
kubectl annotate serviceaccount external-secrets \
  -n external-secrets-system \
  eks.amazonaws.com/role-arn="arn:aws:iam::${AWS_ACCOUNT_ID}:role/ExternalSecretsRole" \
  --overwrite

rm -f /tmp/external-secrets-policy.json /tmp/external-secrets-trust-policy.json

# Restart External Secrets pods to pick up IRSA
echo "   Restarting External Secrets pods to pick up IRSA..."
kubectl rollout restart deployment -n external-secrets-system --selector=app.kubernetes.io/name=external-secrets
kubectl rollout status deployment -n external-secrets-system --selector=app.kubernetes.io/name=external-secrets --timeout=120s || true

echo "✅ External Secrets Operator configured with AWS Parameter Store"

# Deploy External Secrets configuration using Helm
echo ""
echo "📋 Deploying External Secrets configuration with Helm..."
sleep 10  # Give API server time to register CRDs

# Check if external-secrets-config chart exists
if [[ -d "external-secrets-config" ]]; then
    echo "   ✅ Found external-secrets-config Helm chart"
    
    # Install or upgrade External Secrets configuration
    helm upgrade --install external-secrets-config ./external-secrets-config \
        --set global.projectName="$PROJECT_NAME" \
        --set global.awsRegion="$AWS_REGION" \
        --create-namespace \
        --wait --timeout=300s
        
    echo "   ✅ External Secrets configuration deployed via Helm"
else
    echo "   ⚠️ No Helm chart found for External Secrets - falling back to direct manifests"
    
    # Create namespaces BEFORE applying External Secrets
    echo "   📦 Creating namespaces for all environments..."
    for ENV in dev staging prod; do
        if kubectl create namespace "${PROJECT_NAME}-$ENV" --dry-run=client -o yaml | kubectl apply -f -; then
            echo "   ✅ Namespace ${PROJECT_NAME}-$ENV created/verified"
        else
            echo "   ❌ Failed to create namespace ${PROJECT_NAME}-$ENV"
        fi
    done
    
    if [[ -d "external-secrets" ]]; then
        echo "   ✅ Found external-secrets directory"
        
        # Apply ClusterSecretStore
        if [[ -f "external-secrets/cluster-secret-store.yaml" ]]; then
            echo "   Applying ClusterSecretStore..."
            kubectl apply -f external-secrets/cluster-secret-store.yaml
            echo "   ✅ ClusterSecretStore applied"
        fi
        
        # Apply External Secrets (namespaces now exist)
        if [[ -f "external-secrets/iot-secrets.yaml" ]]; then
            echo "   Applying External Secrets..."
            kubectl apply -f external-secrets/iot-secrets.yaml
            echo "   ✅ External Secrets applied"
        fi
    else
        echo "   Creating External Secrets resources inline..."
        
        # Create ClusterSecretStore inline
        kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-parameter-store
spec:
  provider:
    aws:
      service: ParameterStore
      region: ${AWS_REGION}
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets-system
EOF
        
        # Create External Secrets for each environment
        for ENV in dev staging prod; do
            kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: iot-secrets
  namespace: ${PROJECT_NAME}-$ENV
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-parameter-store
    kind: ClusterSecretStore
  target:
    name: iot-secrets
    creationPolicy: Owner
  data:
  - secretKey: POSTGRES_DB
    remoteRef:
      key: /${PROJECT_NAME}/postgres/db
  - secretKey: POSTGRES_USER
    remoteRef:
      key: /${PROJECT_NAME}/postgres/user
  - secretKey: POSTGRES_PASSWORD
    remoteRef:
      key: /${PROJECT_NAME}/postgres/password
  - secretKey: GRAFANA_ADMIN_USER
    remoteRef:
      key: /${PROJECT_NAME}/grafana/admin-user
  - secretKey: GRAFANA_ADMIN_PASSWORD
    remoteRef:
      key: /${PROJECT_NAME}/grafana/admin-password
EOF
        done
    fi
fi

# Wait for External Secrets to sync
echo "⏳ Waiting for External Secrets to sync..."
sleep 15

# Check ClusterSecretStore status
echo "   Checking ClusterSecretStore status..."
kubectl get clustersecretstore aws-parameter-store -o yaml | grep -A5 "status:" || echo "   No status yet"

# Wait for secrets to be created
echo "   Waiting for secrets to be created..."
for i in {1..12}; do
    echo "   Checking attempt $i/12..."
    
    ES_OUTPUT=$(kubectl get externalsecrets -A --no-headers 2>/dev/null || echo "")
    
    if [[ -n "$ES_OUTPUT" ]]; then
        READY_COUNT=$(echo "$ES_OUTPUT" | grep -c "SecretSynced" || echo "0")
        TOTAL_COUNT=$(echo "$ES_OUTPUT" | wc -l | tr -d ' ')
        
        echo "   External Secrets ready: $READY_COUNT/$TOTAL_COUNT"
        
        if [[ "$READY_COUNT" -eq "$TOTAL_COUNT" && "$TOTAL_COUNT" -gt 0 ]]; then
            echo "   ✅ All External Secrets are synced!"
            break
        fi
    else
        echo "   No External Secrets found yet"
    fi
    
    sleep 10
done

# Install ArgoCD
echo ""
echo "🚀 Installing ArgoCD..."
kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "$ARGOCD_NAMESPACE" -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n "$ARGOCD_NAMESPACE"
ARGOCD_PASSWORD=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
kubectl patch svc argocd-server -n "$ARGOCD_NAMESPACE" -p '{"spec": {"type": "LoadBalancer"}}'
echo "✅ ArgoCD installed - Username: admin, Password: $ARGOCD_PASSWORD"

# Deploy ArgoCD ApplicationSet
echo ""
echo "🎯 Setting up GitOps deployment..."
kubectl apply -f argocd/applicationsets/iot-environments.yaml
echo "✅ ArgoCD ApplicationSet deployed!"

# Wait for ArgoCD to sync
echo ""
echo "⏳ Waiting for ArgoCD to sync the applications..."
echo "   This may take 5-10 minutes for all services to start..."
sleep 30

# Check application status
for i in {1..20}; do
    APP_STATUS=$(kubectl get application iot-stack-dev -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    APP_HEALTH=$(kubectl get application iot-stack-dev -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    
    echo "   ArgoCD Application (dev) - Sync: $APP_STATUS, Health: $APP_HEALTH (attempt $i/20)"
    
    if [[ "$APP_STATUS" == "Synced" && "$APP_HEALTH" == "Healthy" ]]; then
        echo "   ✅ ArgoCD dev application is synced and healthy"
        break
    fi
    
    sleep 30
done

# Final status checks
echo ""
echo "🔍 Checking External Secrets status..."
kubectl get externalsecrets -A
kubectl get secrets -n ${PROJECT_NAME}-dev | grep iot-secrets || echo "   Secrets still being created..."

echo ""
echo "🌐 Getting service endpoints (dev environment)..."
kubectl get services -n ${PROJECT_NAME}-dev 2>/dev/null || echo "   Services not yet created"

echo ""
echo "📊 Final status check (dev environment)..."
kubectl get all -n ${PROJECT_NAME}-dev 2>/dev/null || echo "   Resources not yet created"

echo ""
echo "=========================================="
echo "Production GitOps IoT Stack Deployment Complete!"
echo "=========================================="
echo "✅ EKS Cluster: $CLUSTER_NAME"
echo "✅ Region: $AWS_REGION"
echo "✅ Project Name: $PROJECT_NAME"
echo "✅ External Secrets: Fetching from AWS Parameter Store"
echo "✅ Environments: ${PROJECT_NAME}-dev, ${PROJECT_NAME}-staging, ${PROJECT_NAME}-prod"
echo "✅ Storage: gp3 (default), gp2 (compatibility)"
echo ""
echo "🎯 ArgoCD: Username=admin, Password=$ARGOCD_PASSWORD"
echo "   Namespace: $ARGOCD_NAMESPACE"
echo "   Version: $ARGOCD_VERSION"
echo "   Applications: iot-stack-dev, iot-stack-staging, iot-stack-prod"
echo ""
echo "🔐 Security: No secrets committed to Git!"
echo "   Configuration stored in AWS Parameter Store under /${PROJECT_NAME}/*"
echo "   External Secrets Operator manages secret injection"
echo ""
echo "📦 Helm deployments:"
echo "   - External Secrets Operator: external-secrets-system namespace"
echo "   - External Secrets Config: external-secrets-config (if using Helm chart)"
echo ""
echo "🔍 Monitor GitOps deployment:"
echo "   kubectl get applications -n $ARGOCD_NAMESPACE"
echo "   kubectl get externalsecrets -A"
echo "   kubectl get secrets -n ${PROJECT_NAME}-dev | grep iot-secrets"
echo "   helm list -A"
echo ""
echo "🌐 Check all environments:"
echo "   kubectl get all -n ${PROJECT_NAME}-dev"
echo "   kubectl get all -n ${PROJECT_NAME}-staging"
echo "   kubectl get all -n ${PROJECT_NAME}-prod"
echo ""
echo "🌐 ArgoCD UI will be available once LoadBalancer is provisioned (~5 minutes)"
echo "🚀 IoT services deployed via production GitOps with External Secrets!"
echo "=========================================="