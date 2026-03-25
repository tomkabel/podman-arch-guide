# Cloud Cost Optimization Guide

Production-tested strategies for minimizing infrastructure costs while maintaining reliability.

## Quick Cost Comparison

| Deployment Pattern | AWS (us-east-1) | GCP (us-central1) | Azure (East US) | On-Prem |
|-------------------|-----------------|-------------------|-----------------|---------|
| **Single Node** | $45-90/mo | $38-76/mo | $42-84/mo | $25-50/mo |
| **Blue/Green** | $90-180/mo | $76-152/mo | $84-168/mo | $50-100/mo |
| **Multi-Node (3x)** | $270-450/mo | $228-380/mo | $252-420/mo | $150-250/mo |

*Based on: 4 vCPU, 16 GB RAM, 500 GB SSD per node*

## Cost Optimization Strategies

### 1. Right-Sizing

```bash
# Analyze actual resource usage
podman stats --no-stream --format "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"

# Adjust based on p95 usage, not peak
echo "Formula: limit = p95_usage * 1.2"
```

**Example**: If container uses average 200MB but peaks at 512MB:
- Don't set limit to 512MB (waste)
- Set to 300MB (p95 * 1.2) with swap

### 2. Spot/Preemptible Instances

**AWS Spot**: 60-90% savings
```bash
# Spot instance request
aws ec2 request-spot-instances \
    --instance-type t3.medium \
    --spot-price "0.02" \
    --launch-specification file://spot-spec.json
```

**GCP Preemptible**: 60-91% savings
```bash
# Preemptible VM
gcloud compute instances create podman-node \
    --preemptible \
    --machine-type n1-standard-4
```

**Azure Spot**: Up to 90% savings
```bash
az vm create \
    --resource-group myRG \
    --name podman-node \
    --priority Spot \
    --max-price 0.05
```

**Handling Preemption**:
```bash
# systemd service for graceful shutdown
# /etc/systemd/system/podman-spot-handler.service
[Unit]
Description=Handle Spot Instance Preemption

[Service]
Type=oneshot
ExecStart=/usr/local/bin/drain-and-shutdown.sh

[Install]
WantedBy=multi-user.target
```

### 3. Reserved Capacity

**AWS Savings Plans**: Up to 72% for 1-3 year commitment
**GCP Committed Use**: Up to 57% discount
**Azure Reserved**: Up to 72% discount

**When to use**: Baseline capacity that's always needed

### 4. Storage Optimization

| Storage Type | Cost/GB/Month | Use Case |
|--------------|---------------|----------|
| AWS gp3 | $0.08 | General purpose |
| AWS io2 | $0.125 | High IOPS databases |
| GCP pd-ssd | $0.048 | Boot disks |
| Azure Premium SSD | $0.132 | Production workloads |

**Optimization**:
```bash
# Move logs to cheaper storage
# Keep application data on fast storage
# Archive old data to object storage

# Example: Tiered storage policy
# < 30 days: Hot (SSD)
# 30-90 days: Warm (HDD)
# > 90 days: Cold (S3/GCS/Azure Blob)
```

### 5. Network Cost Reduction

**Data Transfer Costs** (AWS example):
- Within AZ: Free
- Between AZs: $0.01/GB
- To Internet: $0.09/GB

**Strategies**:
- Keep containers in same AZ when possible
- Use VPC endpoints (no NAT Gateway charges)
- Compress logs before transfer
- Use CloudFront/Cloudflare for egress caching

## Cost Calculator

```bash
#!/bin/bash
# cost-calculator.sh
# Calculate estimated monthly cost

NODES=${1:-1}
CPU_PER_NODE=${2:-4}      # vCPUs
MEM_PER_NODE=${3:-16}     # GB
DISK_PER_NODE=${4:-500}   # GB
BANDWIDTH=${5:-1000}      # GB/month

# AWS Pricing (us-east-1, on-demand)
AWS_CPU_HOUR=0.0416       # t3.medium per vCPU
AWS_MEM_HOUR=0.0208       # per GB
AWS_DISK_GB=0.08          # gp3 SSD
AWS_BANDWIDTH_GB=0.09     # Outbound

# Calculate
COMPUTE_HOURS=$((NODES * 730))  # 730 hours/month
CPU_COST=$(echo "$COMPUTE_HOURS * $CPU_PER_NODE * $AWS_CPU_HOUR" | bc)
MEM_COST=$(echo "$COMPUTE_HOURS * $MEM_PER_NODE * $AWS_MEM_HOUR" | bc)
DISK_COST=$(echo "$NODES * $DISK_PER_NODE * $AWS_DISK_GB" | bc)
BW_COST=$(echo "$BANDWIDTH * $AWS_BANDWIDTH_GB" | bc)

TOTAL=$(echo "$CPU_COST + $MEM_COST + $DISK_COST + $BW_COST" | bc)

echo "=== AWS Cost Estimate (us-east-1) ==="
echo "Nodes: $NODES ($CPU_PER_NODE vCPU, ${MEM_PER_NODE}GB, ${DISK_PER_NODE}GB disk)"
echo ""
echo "Compute: \$$CPU_COST"
echo "Memory:  \$$MEM_COST"
echo "Storage: \$$DISK_COST"
echo "Bandwidth: \$$BW_COST"
echo "-------------------"
echo "Total:   \$$TOTAL/month"
echo ""
echo "With Spot (70% savings): \$(echo "$TOTAL * 0.3" | bc)/month"
echo "With Reserved (40% savings): \$(echo "$TOTAL * 0.6" | bc)/month"
```

## Multi-Cloud Cost Comparison Tool

```bash
#!/bin/bash
# multi-cloud-cost.sh

RESOURCES='{
  "nodes": 3,
  "vcpu": 4,
  "memory_gb": 16,
  "disk_gb": 500,
  "bandwidth_gb": 1000
}'

echo "=== Multi-Cloud Cost Comparison ==="
echo "Resources: $(echo $RESOURCES | jq -r '.nodes') nodes, $(echo $RESOURCES | jq -r '.vcpu') vCPU, $(echo $RESOURCES | jq -r '.memory_gb')GB RAM"
echo ""

# AWS
aws_total=$(calculate_aws "$RESOURCES")
echo "AWS:    \$$aws_total/month"

# GCP  
gcp_total=$(calculate_gcp "$RESOURCES")
echo "GCP:    \$$gcp_total/month"

# Azure
azure_total=$(calculate_azure "$RESOURCES")
echo "Azure:  \$$azure_total/month"

# Find cheapest
cheapest=$(echo -e "AWS:$aws_total\nGCP:$gcp_total\nAzure:$azure_total" | sort -t: -k2 -n | head -1)
echo ""
echo "Cheapest: $(echo $cheapest | cut -d: -f1)"
```

## Budget Alerts

```yaml
# AWS Budgets
 budgets:
  - name: Podman-Production
    amount: 500
    currency: USD
    time_unit: MONTHLY
    notifications:
      - threshold: 80
        notification_type: ACTUAL
      - threshold: 100
        notification_type: FORECASTED
```

## Cost Allocation Tags

```bash
# Tag resources for cost tracking
aws ec2 create-tags \
    --resources i-1234567890abcdef0 \
    --tags Key=Project,Value=webapp \
           Key=Environment,Value=production \
           Key=Owner,Value=platform-team
```

## Monthly Cost Review Checklist

- [ ] Review AWS/GCP/Azure bill for unexpected charges
- [ ] Check for unused resources (orphaned volumes, old snapshots)
- [ ] Verify reserved capacity matches actual usage
- [ ] Review spot instance interruption rates
- [ ] Optimize storage tiers based on access patterns
- [ ] Check data transfer costs (inter-AZ, egress)

---

**Tools**: [Cost Calculator](tools/cost-calculator/) | [AWS Pricing](https://aws.amazon.com/pricing/) | [GCP Pricing](https://cloud.google.com/pricing)
