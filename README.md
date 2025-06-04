# IoTs6 AWS Open Source Stack

A complete IoT monitoring platform that combines AWS cloud infrastructure with open-source technologies. This project shows how to build a production IoT system using cost-effective open-source tools on AWS EC2.

## Architecture

**Infrastructure:** AWS EC2 (t3.small) provisioned with Terraform  
**Message Broker:** Mosquitto MQTT  
**Database:** TimescaleDB for time-series data  
**Visualization:** Grafana dashboards  
**Data Processing:** Python MQTT consumer  
**Deployment:** Ansible with Docker containers  

## What It Does

Collects sensor data from IoT devices and processes it through a complete IoT stack:

1. IoT devices publish temperature/humidity/pressure data via MQTT
2. Mosquitto broker handles message routing  
3. Python service processes and stores sensor data
4. TimescaleDB stores time-series data with automatic partitioning
5. Grafana provides real-time monitoring dashboards

## Quick Start

```bash
# Configure AWS credentials
aws configure

# Deploy everything
./deploy.sh

# Or deploy with integrated provisioners
./deploy.sh --local-exec

# Monitor logs
./taillogs.sh

# Check database
./read_db.sh

# Clean up
./destroy.sh
```

## Requirements

- Azure subscription
- Terraform and Ansible installed
- SSH key at `~/.ssh/[your_key_name]`

## Access

After deployment:
- Grafana Dashboard: `http://[VM_IP]:3000` (admin/admin)
- MQTT Broker: `mqtt://[VM_IP]:1883` 
- Database: `postgresql://[db_user]:[db_password]@[VM_IP]:5432/[db_name]`

## Related Projects

- [picosensor_net] - MicroPython sensor firmware
- [aws_serveconfig] - Device configuration server