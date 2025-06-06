#!/usr/bin/env bash
# status.sh - Check status of both VM and AKS deployments
set -e

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
    echo "   • TimescaleDB: postgresql://iotuser:iotpass@$VM_IP:5432/iotdb"
    echo "   • MQTT: mqtt://$VM_IP:1883"
    echo "   • Grafana: http://$VM_IP:3000"
    echo "   • SSH: nathan@$VM_IP"
    
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

# Check AKS deployment
echo "☸️  AKS Deployment Status:"
echo "----------------------------------------"

AKS_DIR="terraform-aks"
if [[ -d "$AKS_DIR" && -f "$AKS_DIR/terraform.tfstate" ]]; then
  cd "$AKS_DIR"
  
  CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null || echo "")
  RESOURCE_GROUP=$(terraform output -raw resource_group_name 2>/dev/null || echo "")
  
  if [[ -n "$CLUSTER_NAME" && "$CLUSTER_NAME" != "null" ]]; then
    echo "✅ AKS Cluster Active: $CLUSTER_NAME"
    echo "   Resource Group: $RESOURCE_GROUP"
    
    # Check if kubectl can access the cluster
    if kubectl get nodes &>/dev/null; then
      echo "   🟢 kubectl: Connected"
      
      # Get node information
      NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
      READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
      
      echo "   📊 Nodes: $READY_NODES/$NODE_COUNT ready"
      
      # Check for deployments
      echo "   📦 Deployed Services:"
      DEPLOYMENTS=$(kubectl get deployments --all-namespaces --no-headers 2>/dev/null | wc -l)
      if [[ $DEPLOYMENTS -gt 0 ]]; then
        kubectl get deployments --all-namespaces --no-headers 2>/dev/null | while read namespace name ready uptodate available age; do
          echo "     • $name (namespace: $namespace) - $ready ready"
        done
      else
        echo "     • No services deployed yet"
      fi
      
      # Check for services with external IPs
      echo "   🌐 External Services:"
      kubectl get services --all-namespaces --no-headers 2>/dev/null | grep -E "(LoadBalancer|NodePort)" | while read namespace name type cluster_ip external_ip ports age; do
        if [[ "$external_ip" != "<none>" && "$external_ip" != "<pending>" ]]; then
          echo "     • $name: $external_ip"
        fi
      done || echo "     • No external services found"
      
    else
      echo "   🔴 kubectl: Cannot connect to cluster"
    fi
  else
    echo "❌ AKS: Not deployed or no valid cluster name"
  fi
  
  cd ..
else
  echo "❌ AKS: No deployment found"
fi

echo ""
echo "=========================================="
echo "Commands:"
echo "🖥️  VM: ./deploy.sh | ./destroy.sh | ./taillogs.sh"
echo "☸️  AKS: ./deploy-aks.sh | ./destroy-aks.sh"
echo "📊 Status: ./status.sh"
echo "=========================================="