#!/usr/bin/env bash
# status.sh - Check status of both VM and EKS deployments
set -e

# Load environment variables
if [[ -f .env ]]; then
  source .env
else
  echo "⚠️  Warning: .env file not found. Some values may not display correctly."
fi

echo "=========================================="
echo "IoTS6 Deployment Status Check"
echo "=========================================="

# Check VM deployment
echo "🖥️  VM Deployment Status:"
echo "----------------------------------------"

VM_DIR="terraform"
if [[ -d "$VM_DIR" && -f "$VM_DIR/terraform.tfstate" ]]; then
  cd "$VM_DIR"
  
  VM_IP=$(terraform output -raw vm_ip 2>/dev/null || echo "")
  VM_NAME=$(terraform output -raw vm_name 2>/dev/null || echo "")
  
  if [[ -n "$VM_IP" && "$VM_IP" != "null" ]]; then
    echo "✅ VM Active: $VM_NAME"
    echo "   IP: $VM_IP"
    echo "   Services:"
    echo "   • TimescaleDB: postgresql://${POSTGRES_USER:-iotuser}:***@$VM_IP:5432/${POSTGRES_DB:-iotdb}"
    echo "   • MQTT: mqtt://$VM_IP:1883"
    echo "   • Grafana: http://$VM_IP:3000"
    echo "   • SSH: ${SSH_USER:-ec2-user}@$VM_IP"
    
    # Test if we can reach the VM
    if ping -c 1 -W 2 "$VM_IP" &>/dev/null; then
      echo "   🟢 Network: Reachable"
    else
      echo "   🔴 Network: Unreachable"
    fi
  else
    echo "❌ VM: Not deployed or no valid IP"
  fi
  
  cd ..
else
  echo "❌ VM: No deployment found"
fi

echo ""

# Check EKS deployment
echo "☸️  EKS Deployment Status:"
echo "----------------------------------------"

EKS_DIR="terraform-eks"
if [[ -d "$EKS_DIR" && -f "$EKS_DIR/terraform.tfstate" ]]; then
  cd "$EKS_DIR"
  
  CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null || echo "")
  
  if [[ -n "$CLUSTER_NAME" && "$CLUSTER_NAME" != "null" ]]; then
    echo "✅ EKS Cluster Active: $CLUSTER_NAME"
    
    # Check if kubectl can access the cluster
    if kubectl get nodes &>/dev/null; then
      echo "   🟢 kubectl: Connected"
      
      # Get node information
      NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
      READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
      
      echo "   📊 Nodes: $READY_NODES/$NODE_COUNT ready"
      
      # Check for ArgoCD
      if kubectl get namespace argocd &>/dev/null; then
        echo "   🔄 ArgoCD: Deployed"
        APPS=$(kubectl get applications -n argocd --no-headers 2>/dev/null | wc -l)
        echo "     • Applications: $APPS"
      fi
      
      # Check for services with external IPs
      echo "   🌐 External Services:"
      kubectl get services --all-namespaces --no-headers 2>/dev/null | grep -E "(LoadBalancer)" | while read namespace name type cluster_ip external_ip ports age; do
        if [[ "$external_ip" != "<none>" && "$external_ip" != "<pending>" ]]; then
          echo "     • $name: $external_ip"
        fi
      done || echo "     • No external services found"
      
    else
      echo "   🔴 kubectl: Cannot connect to cluster"
    fi
  else
    echo "❌ EKS: Not deployed or no valid cluster name"
  fi
  
  cd ..
else
  echo "❌ EKS: No deployment found"
fi

echo ""
echo "=========================================="
echo "Commands:"
echo "🖥️  VM: ./deploy.sh | ./destroy.sh | ./taillogs.sh"
echo "☸️  EKS: ./deploy-eks.sh | ./destroy-eks.sh"
echo "📊 Status: ./status.sh"
echo "=========================================="