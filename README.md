# IoTs6 AWS Open Source Stack

A complete IoT monitoring platform that combines AWS cloud infrastructure with open-source technologies. This project provides multiple deployment options: traditional VM-based deployment, modern Kubernetes cluster deployment, and production-grade GitOps with multi-environment management.

## Quick Start

1. Clone the repository
2. Install prerequisites (AWS CLI, Terraform, kubectl, Helm)
3. Run `aws configure` to authenticate with AWS
4. Copy and configure environment: `cp .env.example .env`
5. Deploy: `./deploy-eks.sh` (GitOps/Kubernetes) or `./deploy.sh` (VM)

## Deployment Options

### Option 1: GitOps Kubernetes Deployment (Recommended)
```bash
# Deploy EKS cluster with ArgoCD and multi-environment GitOps
./deploy-eks.sh

# Check GitOps applications
kubectl get applications -n argocd

# Access ArgoCD UI (credentials shown after deployment)
kubectl get svc argocd-server -n argocd

# Clean up cluster
./destroy-eks.sh
```

### Option 2: Single VM Deployment
```bash
# Deploy complete stack on one AWS VM
./deploy.sh

# Monitor container logs
./taillogs.sh

# Clean up resources
./destroy.sh
```

## Configuration

Copy the example environment file and customize all settings:
```bash
cp .env.example .env
# Edit .env with your specific configuration
```

**Important:** No values are hardcoded. All configuration comes from your `.env` file.

## What It Does

Processes sensor data from IoT devices through a complete monitoring stack:

1. IoT devices publish sensor data via MQTT
2. Mosquitto broker handles message routing and queuing
3. Python service consumes MQTT messages and processes data
4. TimescaleDB stores time-series sensor data efficiently
5. Grafana provides real-time dashboards and monitoring
6. ArgoCD automatically manages deployments from Git changes

## Architecture

**Cloud Platform:** Amazon Web Services  
**Infrastructure Options:**  
- VM deployment with Docker containers
- Kubernetes cluster (3-node EKS) with GitOps
- Multi-environment GitOps (dev/staging/prod)

**Message Broker:** Mosquitto MQTT  
**Database:** TimescaleDB for time-series data  
**Visualization:** Grafana dashboards  
**Data Processing:** Python MQTT consumer service  
**GitOps:** ArgoCD with ApplicationSet for multi-environment management  
**Package Management:** Helm charts for Kubernetes deployments  
**Deployment:** Terraform for infrastructure, Ansible for VM configuration

## Prerequisites

- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) installed
- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.0
- [kubectl](https://kubernetes.io/docs/tasks/tools/) (for Kubernetes deployment)
- [Helm](https://helm.sh/docs/intro/install/) >= 3.0 (for GitOps deployment)
- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html) (for VM deployment)
- Active AWS account with appropriate permissions

## Access After Deployment

### GitOps Kubernetes Deployment:
- **ArgoCD Dashboard:** https://[ARGOCD_LOADBALANCER] (admin/[generated_password])
- **Grafana (Production):** http://[GRAFANA_LB]:3000 (admin/[generated_password])
- **MQTT Broker (Production):** mqtt://[MQTT_LB]:1883
- **Multi-Environment Access:**
  - Dev: `kubectl get services -n ${NAMESPACE}-dev`
  - Staging: `kubectl get services -n ${NAMESPACE}-staging`  
  - Production: `kubectl get services -n ${NAMESPACE}-prod`

### VM Deployment:
- **Grafana Dashboard:** http://[VM_IP]:3000 (admin/[your_password])
- **MQTT Broker:** mqtt://[VM_IP]:1883
- **Database:** postgresql://[your_user]:[your_password]@[VM_IP]:5432/[your_db]
- **SSH Access:** [your_user]@[VM_IP]

## GitOps Features

The GitOps deployment automatically creates and manages:

- **Three Environments:** Development, Staging, and Production
- **ArgoCD ApplicationSet:** Manages all environments from a single configuration
- **Automatic Deployments:** Git changes trigger deployments across environments
- **Environment-Specific Settings:** Different resource sizes and configurations per environment
- **Self-Healing:** ArgoCD automatically fixes configuration drift

### Environment Differences:
- **Development:** Smaller resources, debug logging, internal services only
- **Staging:** Medium resources, standard logging, internal testing
- **Production:** Full resources, optimized logging, external LoadBalancers

## Kubernetes Services

Each environment includes:

- **TimescaleDB:** PostgreSQL database with TimescaleDB extension
- **Mosquitto:** MQTT broker for device communication
- **IoT Service:** Python service that processes MQTT messages and stores data
- **Grafana:** Web-based monitoring dashboard

All services use persistent storage with automatic volume permission management.

## Project Structure

```
├── deploy.sh                 # VM deployment script
├── deploy-eks.sh             # EKS + GitOps deployment script
├── destroy.sh                # VM teardown script
├── destroy-eks.sh            # EKS cluster teardown script
├── status.sh                 # Check deployment status
├── iot-stack-chart/          # Helm chart for IoT services
│   ├── templates/            # Kubernetes templates
│   ├── values.yaml           # Default configuration
│   ├── values-dev.yaml       # Development environment
│   └── values-prod.yaml      # Production environment
├── argocd/                   # GitOps configuration
│   └── applicationsets/      # Multi-environment management
├── terraform/                # VM infrastructure code
├── terraform-eks/            # EKS infrastructure code
├── kubernetes/               # Legacy Kubernetes manifests
├── ansible/                  # VM configuration playbooks
├── services/                 # Application container code
└── .env.example             # Configuration template
```

## Monitoring and Management

### GitOps Management
```bash
# Check all GitOps applications
kubectl get applications -n argocd

# View application details
kubectl describe application iot-stack-dev -n argocd

# Force sync an application
kubectl patch application iot-stack-dev -n argocd --type=merge -p='{"spec":{"syncPolicy":{"automated":null}}}'

# Access ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

### Multi-Environment Status
```bash
# Check all environments
kubectl get pods -n ${NAMESPACE}-dev
kubectl get pods -n ${NAMESPACE}-staging
kubectl get pods -n ${NAMESPACE}-prod

# Check services across environments
kubectl get services -n ${NAMESPACE}-dev
kubectl get services -n ${NAMESPACE}-staging
kubectl get services -n ${NAMESPACE}-prod
```

### Service Logs and Debugging
```bash
# View logs for specific environment and service
kubectl logs -f deployment/grafana -n ${NAMESPACE}-dev
kubectl logs -f deployment/timescaledb -n ${NAMESPACE}-prod

# Check all resources in an environment
kubectl get all -n ${NAMESPACE}-staging

# View recent events
kubectl get events -n ${NAMESPACE}-dev --sort-by=.metadata.creationTimestamp
```

### Database Management
```bash
# Access TimescaleDB in specific environment
kubectl exec -it deployment/timescaledb -n ${NAMESPACE}-prod -- psql -U ${POSTGRES_USER} -d ${POSTGRES_DB}

# Check database connectivity
kubectl exec deployment/timescaledb -n ${NAMESPACE}-dev -- pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}

# View sensor data
kubectl exec -it deployment/timescaledb -n ${NAMESPACE}-prod -- psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c "SELECT * FROM sensor_data LIMIT 10;"
```

## Troubleshooting

### Common Issues
- **Deployment fails:** Check `aws configure` status and account permissions
- **ArgoCD not syncing:** Verify Git repository access and branch settings
- **Services not accessible:** Check LoadBalancer status with `kubectl get services`
- **Pod startup issues:** Check logs with `kubectl logs` and events with `kubectl get events`
- **Volume permission errors:** Check init container logs and security contexts

### GitOps Debugging
```bash
# Check ArgoCD server logs
kubectl logs deployment/argocd-server -n argocd

# Check application controller logs
kubectl logs deployment/argocd-application-controller -n argocd

# Force refresh application from Git
kubectl annotate application iot-stack-dev -n argocd argocd.argoproj.io/refresh=hard

# Delete and recreate problematic application
kubectl delete application iot-stack-staging -n argocd
kubectl apply -f argocd/applicationsets/iot-environments.yaml
```

### Performance Tuning
```bash
# Check resource usage
kubectl top nodes
kubectl top pods -n ${NAMESPACE}-prod

# Scale deployments
kubectl scale deployment timescaledb -n ${NAMESPACE}-prod --replicas=2

# Update resource limits in values files and commit to Git
```

## Security Notes

- Copy `.env.example` to `.env` and customize all credentials
- Never commit `.env`, `terraform.tfstate`, or `kubeconfig` files
- All passwords are automatically generated or configurable via environment variables
- Kubernetes secrets are automatically created from environment variables
- ArgoCD generates secure admin passwords on each deployment
- Production deployments use proper security contexts and init containers

## Configuration Reference

All configuration is managed through environment variables. See `.env.example` for:

- **Database Settings:** Credentials and connection details
- **Infrastructure Settings:** AWS regions, cluster names, storage sizes
- **GitOps Settings:** ArgoCD version, namespace configuration
- **Security Settings:** All passwords and authentication details

## Contributing

1. Make changes to Helm charts in `iot-stack-chart/`
2. Update environment-specific values in `values-dev.yaml` or `values-prod.yaml`
3. Commit and push changes to trigger GitOps deployment
4. Monitor deployment through ArgoCD UI or kubectl commands

## Related Projects

- **picosensor** - MicroPython sensor firmware for Raspberry Pi Pico W
- **aws_serveconfig** - Device configuration and management server