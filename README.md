# IoTs6 AWS Open Source Stack

A complete IoT monitoring platform that combines AWS cloud infrastructure with open-source technologies. This project provides multiple deployment options: traditional VM-based deployment, modern Kubernetes cluster deployment, and production-grade GitOps with multi-environment management.

## Quick Start

1. Clone the repository
2. Install prerequisites (AWS CLI, Terraform, kubectl, Helm, Ansible)
3. Run `aws configure` to authenticate with AWS
4. Create a Datadog API key at https://us5.datadoghq.com/organization-settings/api-keys
5. Copy `cp .env.example .env` and configure all settings (passwords, Datadog API key, etc.)
6. Deploy: `./deploy-eks.sh` (GitOps/Kubernetes) or `./deploy.sh` (VM)

## Deployment Options

### Option 1: GitOps Kubernetes Deployment 
```bash
# Deploy EKS cluster with ArgoCD and multi-environment GitOps
./deploy-eks.sh

# Check GitOps applications
kubectl get applications -n ${ARGOCD_NAMESPACE}

# Access ArgoCD UI (credentials shown after deployment)
kubectl get svc argocd-server -n ${ARGOCD_NAMESPACE}

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
7. Datadog monitors cluster health, resource usage, and application performance

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
**Secret Management:** External Secrets Operator with AWS Parameter Store integration  
**Infrastructure Monitoring:** Datadog for metrics, logs, and APM  
**Package Management:** Helm charts for Kubernetes deployments  
**Deployment:** Terraform for infrastructure, Ansible for VM configuration

## Prerequisites

- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) installed
- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.0
- [kubectl](https://kubernetes.io/docs/tasks/tools/) (for Kubernetes deployment)
- [Helm](https://helm.sh/docs/intro/install/) >= 3.0 (for GitOps deployment)
- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html) (for VM deployment)
- Active AWS account with appropriate permissions
- Datadog account (free tier available) for infrastructure monitoring
  - Create an API key at https://us5.datadoghq.com/organization-settings/api-keys
  - Add to `.env` as `DATADOG_API_KEY` and set `DATADOG_SITE=us5.datadoghq.com`

## Access After Deployment

### GitOps Kubernetes Deployment:
- **ArgoCD Dashboard:** https://[ARGOCD_LOADBALANCER] (admin/[generated_password])
- **Grafana (Production):** http://[GRAFANA_LB]:3000 (${GRAFANA_ADMIN_USER}/${GRAFANA_ADMIN_PASSWORD})
- **MQTT Broker (Production):** mqtt://[MQTT_LB]:1883
- **Datadog Dashboard:** https://app.datadoghq.com (view cluster metrics and logs)
- **Multi-Environment Access:**
  - Dev: `kubectl get services -n ${EKS_NAMESPACE}-dev`
  - Staging: `kubectl get services -n ${EKS_NAMESPACE}-staging`  
  - Production: `kubectl get services -n ${EKS_NAMESPACE}-prod`

### VM Deployment:
- **Grafana Dashboard:** http://[VM_IP]:3000 (${GRAFANA_ADMIN_USER}/${GRAFANA_ADMIN_PASSWORD})
- **MQTT Broker:** mqtt://[VM_IP]:1883
- **Database:** postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@[VM_IP]:5432/${POSTGRES_DB}
- **SSH Access:** ${ANSIBLE_USER}@[VM_IP]

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

## Production Secret Management

This project implements enterprise-grade secret management using AWS native services:

**Automatic Secret Flow:**
1. Your `.env` configuration is stored in AWS Parameter Store
2. External Secrets Operator fetches secrets from Parameter Store
3. Kubernetes secrets are created automatically in each namespace
4. Applications consume secrets without knowing the source

**Benefits:**
- Zero secrets in Git - Configuration never leaves AWS
- Automatic updates - Change secrets in Parameter Store, pods restart automatically  
- Team collaboration - Multiple developers share same secure configuration
- Audit trail - All secret access logged in CloudTrail
- Enterprise ready - Meets compliance requirements

**Configuration Management:**
```bash
# View stored configuration
aws ssm get-parameters-by-path --path "/iots6/" --recursive

# Check External Secrets status
kubectl get externalsecrets -A
kubectl get secrets -n iots6-prod | grep iot-secrets
```

## Kubernetes Services

Each environment includes:

- **TimescaleDB:** PostgreSQL database with TimescaleDB extension
- **Mosquitto:** MQTT broker for device communication
- **IoT Service:** Python service that processes MQTT messages and stores data
- **Grafana:** Web-based monitoring dashboard

Supporting services (cluster-wide):
- **Datadog Agent:** Collects metrics and logs from all pods and nodes
- **External Secrets Operator:** Syncs secrets from AWS Parameter Store
- **ArgoCD:** GitOps deployment automation

All services use persistent storage with automatic volume permission management.

## Project Structure

```
├── README.md
├── deploy.sh                 # VM deployment
├── deploy-eks.sh             # EKS + GitOps deployment
├── destroy.sh                # VM teardown
├── destroy-eks.sh            # EKS cluster teardown
├── read_db.sh                # Database query utility
├── requirements.txt          # System requirements
├── set-aws-env.sh           # AWS environment setup
├── status.sh                # Check deployment status
├── taillogs.sh              # Container log monitoring
├── ansible/                 # VM configuration playbooks
│   ├── ansible.cfg
│   ├── inventory/
│   └── playbooks/
├── argocd/                  # GitOps configuration
│   └── applicationsets/     # Multi-environment management
├── datadog-chart/           # Datadog Helm deployment
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
├── external-secrets-config/ # External Secrets Helm chart
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
├── iot-stack-chart/         # Helm chart for IoT services
│   ├── Chart.yaml
│   ├── templates/           # Kubernetes templates
│   ├── values.yaml          # Default configuration
│   ├── values-dev.yaml      # Development environment
│   └── values-prod.yaml     # Production environment
├── services/                # Application container code
│   └── iot_service/
├── terraform/               # VM infrastructure code
│   ├── main.tf
│   ├── outputs.tf
│   ├── variables.tf
│   └── scripts/
└── terraform-eks/          # EKS infrastructure code
    └── main.tf
```

## Monitoring and Management

### Infrastructure Monitoring (Datadog)
```bash
# Check Datadog agent status
kubectl get pods -n datadog

# View agent logs
kubectl logs -l app=datadog -n datadog

# Access Datadog dashboard
# https://app.datadoghq.com
```

### GitOps Management
```bash
# Check all GitOps applications
kubectl get applications -n ${ARGOCD_NAMESPACE}

# View application details
kubectl describe application iot-stack-dev -n ${ARGOCD_NAMESPACE}

# Force sync an application
kubectl patch application iot-stack-dev -n ${ARGOCD_NAMESPACE} --type=merge -p='{"spec":{"syncPolicy":{"automated":null}}}'

# Access ArgoCD UI
kubectl port-forward svc/argocd-server -n ${ARGOCD_NAMESPACE} 8080:443
```

### Multi-Environment Status
```bash
# Check all environments
kubectl get pods -n ${EKS_NAMESPACE}-dev
kubectl get pods -n ${EKS_NAMESPACE}-staging
kubectl get pods -n ${EKS_NAMESPACE}-prod

# Check services across environments
kubectl get services -n ${EKS_NAMESPACE}-dev
kubectl get services -n ${EKS_NAMESPACE}-staging
kubectl get services -n ${EKS_NAMESPACE}-prod
```

### Service Logs and Debugging
```bash
# View logs for specific environment and service
kubectl logs -f deployment/${GRAFANA_CONTAINER_NAME} -n ${EKS_NAMESPACE}-dev
kubectl logs -f deployment/${TIMESCALE_CONTAINER_NAME} -n ${EKS_NAMESPACE}-prod

# Check all resources in an environment
kubectl get all -n ${EKS_NAMESPACE}-staging

# View recent events
kubectl get events -n ${EKS_NAMESPACE}-dev --sort-by=.metadata.creationTimestamp
```

### Database Management
```bash
# Access TimescaleDB in specific environment
kubectl exec -it deployment/${TIMESCALE_CONTAINER_NAME} -n ${EKS_NAMESPACE}-prod -- psql -U ${POSTGRES_USER} -d ${POSTGRES_DB}

# Check database connectivity
kubectl exec deployment/${TIMESCALE_CONTAINER_NAME} -n ${EKS_NAMESPACE}-dev -- pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}

# View sensor data
kubectl exec -it deployment/${TIMESCALE_CONTAINER_NAME} -n ${EKS_NAMESPACE}-prod -- psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c "SELECT * FROM sensor_data LIMIT 10;"
```

## Troubleshooting

### Common Issues
- **Deployment fails:** Check `aws configure` status and account permissions
- **ArgoCD not syncing:** Verify Git repository access and branch settings
- **Services not accessible:** Check LoadBalancer status with `kubectl get services`
- **Pod startup issues:** Check logs with `kubectl logs` and events with `kubectl get events`
- **Volume permission errors:** Check init container logs and security contexts
- **Datadog not connecting:** Verify API key in Parameter Store and External Secret sync

### GitOps Debugging
```bash
# Check ArgoCD server logs
kubectl logs deployment/argocd-server -n ${ARGOCD_NAMESPACE}

# Check application controller logs
kubectl logs deployment/argocd-application-controller -n ${ARGOCD_NAMESPACE}

# Force refresh application from Git
kubectl annotate application iot-stack-dev -n ${ARGOCD_NAMESPACE} argocd.argoproj.io/refresh=hard

# Delete and recreate problematic application
kubectl delete application iot-stack-staging -n ${ARGOCD_NAMESPACE}
kubectl apply -f argocd/applicationsets/iot-environments.yaml
```

### Performance Tuning
```bash
# Check resource usage
kubectl top nodes
kubectl top pods -n ${EKS_NAMESPACE}-prod

# Scale deployments
kubectl scale deployment ${TIMESCALE_CONTAINER_NAME} -n ${EKS_NAMESPACE}-prod --replicas=2

# Update resource limits in values files and commit to Git
```

## Security Notes

**Production-Grade Secret Management:**
- Configuration stored securely in AWS Parameter Store (encrypted at rest)
- External Secrets Operator automatically injects secrets into Kubernetes
- Zero secrets committed to Git repository - ever
- IAM roles control access to configuration data
- All secret access logged via AWS CloudTrail
- Datadog API key stored in Parameter Store, not in code

**Best Practices Implemented:**
- Copy `.env.example` to `.env` and customize all credentials
- Never commit `.env`, `terraform.tfstate`, or `kubeconfig` files
- Kubernetes secrets are automatically created from AWS Parameter Store
- ArgoCD generates secure admin passwords on each deployment
- Production deployments use proper security contexts and init containers
- External Secrets refreshes configuration automatically (hourly)

**Enterprise Security Features:**
- AWS IAM-based access control to secrets
- Encryption in transit and at rest
- Automatic secret rotation support
- Audit logging for all configuration access

## Configuration Reference

All configuration is managed through environment variables. See `.env.example` for:

- **Database Settings:** Credentials and connection details
- **Infrastructure Settings:** AWS regions, cluster names, storage sizes
- **Project Settings:** Project name for Kubernetes resource labeling
- **GitOps Settings:** ArgoCD version, namespace configuration
- **Security Settings:** All passwords and authentication details
- **Monitoring Settings:** Datadog API key and site configuration

## Contributing

1. Make changes to Helm charts in `iot-stack-chart/`
2. Update environment-specific values in `values-dev.yaml` or `values-prod.yaml`
3. Commit and push changes to trigger GitOps deployment
4. Monitor deployment through ArgoCD UI or kubectl commands

## Related Projects

- **picosensor** - MicroPython sensor firmware for Raspberry Pi Pico W
- **aws_serveconfig** - Device configuration and management server