# IoTs6 AWS Open Source Stack

A complete IoT monitoring platform that combines AWS cloud infrastructure with open-source technologies. This project provides two deployment options: traditional VM-based deployment and modern Kubernetes cluster deployment.

## Quick Start

1. Clone the repository
2. Install prerequisites (AWS CLI, Terraform, kubectl)
3. Run `aws configure` to authenticate with AWS
4. Copy and configure environment: `cp .env.example .env`
5. Deploy: `./deploy-eks.sh` (Kubernetes) or `./deploy.sh` (VM)

## Architecture

**Cloud Platform:** Amazon Web Services  
**Infrastructure Options:**  
- VM deployment with Docker containers
- Kubernetes cluster (3-node EKS)

**Message Broker:** Mosquitto MQTT  
**Database:** TimescaleDB for time-series data  
**Visualization:** Grafana dashboards  
**Data Processing:** Python MQTT consumer service  
**Deployment:** Terraform for infrastructure, Ansible for VM configuration

## What It Does

Processes sensor data from IoT devices through a complete monitoring stack:

1. IoT devices publish sensor data via MQTT
2. Mosquitto broker handles message routing and queuing
3. Python service consumes MQTT messages and processes data
4. TimescaleDB stores time-series sensor data efficiently
5. Grafana provides real-time dashboards and monitoring

## Prerequisites

- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) installed
- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.0
- [kubectl](https://kubernetes.io/docs/tasks/tools/) (for Kubernetes deployment)
- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html) (for VM deployment)
- Active AWS account

## Deployment Options

### Option 1: Single VM Deployment
```bash
# Deploy complete stack on one AWS VM
./deploy.sh

# Monitor container logs
./taillogs.sh

# Clean up resources
./destroy.sh
```

### Option 2: Kubernetes Cluster Deployment
```bash
# Deploy 3-node EKS cluster with all IoT services
./deploy-eks.sh

# Check deployment status
./status.sh

# Clean up cluster
./destroy-eks.sh
```

## Configuration

Copy the example environment file and customize:
```bash
cp .env.example .env
# Edit .env with your preferred settings
```

## Access After Deployment

### VM Deployment:
- Grafana Dashboard: http://[VM_IP]:3000 (admin/admin)
- MQTT Broker: mqtt://[VM_IP]:1883
- Database: postgresql://iotuser:iotpass@[VM_IP]:5432/iotdb
- SSH Access: ubuntu@[VM_IP]

### Kubernetes Deployment:
- TimescaleDB: [EXTERNAL_IP]:5432
- Mosquitto MQTT: [EXTERNAL_IP]:1883
- Grafana Dashboard: http://[EXTERNAL_IP]:3000 (admin/admin)
- Check service IPs: kubectl get services -n your-namespace

## Project Structure

```
├── deploy.sh                 # VM deployment script
├── deploy-eks.sh             # EKS cluster deployment script
├── destroy.sh                # VM teardown script
├── destroy-eks.sh            # EKS cluster teardown script
├── status.sh                 # Check both deployment types
├── terraform/                # VM infrastructure code
├── terraform-eks/            # EKS infrastructure code
├── kubernetes/               # Kubernetes manifests
│   ├── namespace/            # Namespace configuration
│   ├── secrets/              # Credential management
│   ├── configmaps/           # Application configuration
│   ├── storage/              # Persistent volume claims
│   ├── deployments/          # Application deployments
│   └── services/             # Load balancer services
├── ansible/                  # VM configuration playbooks
├── services/                 # Application container code
└── .env.example             # Configuration template
```

## Kubernetes Services

The Kubernetes deployment creates the following services:

- **TimescaleDB**: PostgreSQL database with TimescaleDB extension
- **Mosquitto**: MQTT broker for device communication
- **IoT Service**: Python service that processes MQTT messages and stores data
- **Grafana**: Web-based monitoring dashboard

All services use persistent storage and are exposed via AWS LoadBalancers for external access.

## Monitoring and Management

### Basic Status Checks
```bash
# Check all deployments and services
kubectl get all -n your-namespace

# Check pod status and readiness
kubectl get pods -n your-namespace

# Check service external IPs
kubectl get services -n your-namespace

# Check persistent volume claims
kubectl get pvc -n your-namespace

# Overall cluster status
./status.sh
```

### Service Logs and Debugging
```bash
# View real-time logs for each service
kubectl logs -f deployment/iot-service -n your-namespace
kubectl logs -f deployment/timescaledb -n your-namespace
kubectl logs -f deployment/mosquitto -n your-namespace
kubectl logs -f deployment/grafana -n your-namespace

# Get recent logs (last 50 lines)
kubectl logs deployment/[service-name] -n your-namespace --tail=50

# Describe pod for detailed status and events
kubectl describe pod -l app=[service-name] -n your-namespace
```

### Database Management
```bash
# Access TimescaleDB directly
kubectl exec -it deployment/timescaledb -n your-namespace -- psql -U iotuser -d iotdb

# Check database connectivity
kubectl exec deployment/timescaledb -n your-namespace -- pg_isready -U iotuser -d iotdb

# View sensor data
kubectl exec -it deployment/timescaledb -n your-namespace -- psql -U iotuser -d iotdb -c "SELECT * FROM sensor_data LIMIT 10;"
```

### Troubleshooting Commands
```bash
# Check cluster events (useful for debugging failures)
kubectl get events -n your-namespace --sort-by=.metadata.creationTimestamp

# Check node resources
kubectl top nodes

# Check pod resource usage
kubectl top pods -n your-namespace

# Test service connectivity
kubectl exec -it deployment/iot-service -n your-namespace -- ping timescaledb
kubectl exec -it deployment/iot-service -n your-namespace -- ping mosquitto

# Force restart a problematic deployment
kubectl rollout restart deployment/[service-name] -n your-namespace

# Delete and recreate a deployment
kubectl delete deployment [service-name] -n your-namespace
envsubst < kubernetes/deployments/[service-name].yaml | kubectl apply -f -
```

### Environment Management
```bash
# Load environment variables for manual commands
set -a
source .env
set +a

# Apply individual manifests with environment substitution
envsubst < kubernetes/deployments/[service-name].yaml | kubectl apply -f -
envsubst < kubernetes/storage/[service-name]-pvc.yaml | kubectl apply -f -

# Check current environment variables
echo $NAMESPACE
echo $TIMESCALEDB_STORAGE_SIZE
```

## Troubleshooting

- **Deployment fails**: Check `aws configure` status and account permissions
- **Services not accessible**: Verify LoadBalancer IPs with `kubectl get services -n your-namespace`
- **Pod errors**: Check logs with `kubectl logs -f deployment/[service-name] -n your-namespace`

## Security Notes

- Copy .env.example to .env and customize credentials
- Never commit .env, terraform.tfstate, or kubeconfig files
- SSH keys are automatically generated during deployment
- Default passwords should be changed for production use
- Kubernetes secrets are automatically created from environment variables

## Related Projects

- picosensor - MicroPython sensor firmware for Raspberry Pi Pico W
- aws_serveconfig - Device configuration and management server