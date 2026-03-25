#!/usr/bin/env bash
# Cloud Cost Comparison Tool
# Compares costs across AWS, GCP, and Azure for the same workload

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

calc() {
    awk "BEGIN {printf \"%.2f\", $1}" 2>/dev/null || echo "0"
}

usage() {
    cat <<EOF
Cloud Cost Comparison Tool

Compares infrastructure costs across AWS, GCP, and Azure for equivalent workloads.

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --workload-profile PROFILE    Workload type: small, medium, large, custom (default: medium)
    --instance-vcpus NUM         Number of vCPUs per instance (default: 2)
    --instance-memory-gb NUM     Memory in GB per instance (default: 4)
    --instance-count NUM         Number of instances (default: 3)
    --storage-gb NUM             Total storage in GB (default: 100)
    --network-egress-gb NUM      Monthly network egress in GB (default: 100)
    --lb-requests-million NUM    Monthly LB requests in millions (default: 10)
    --db-enabled                 Include managed database (default: false)
    --aws-reserved               Use reserved instances for AWS (default: false)
    --gcp-committed              Use committed use for GCP (default: false)
    --azure-reserved             Use reserved VMs for Azure (default: false)
    --term-years NUM             Reserved/Committed term in years: 1 or 3 (default: 1)
    --json                       Output JSON format
    --help                       Show this help message

WORKLOAD PROFILES:
    small     - 1 vCPU, 2GB RAM, 1 instance, 30GB storage
    medium    - 2 vCPU, 4GB RAM, 3 instances, 100GB storage
    large     - 4 vCPU, 8GB RAM, 5 instances, 500GB storage

EXAMPLES:
    $0 --workload-profile medium --json
    $0 --instance-vcpus 4 --instance-memory-gb 16 --instance-count 5
    $0 --aws-reserved --gcp-committed --azure-reserved --term-years 3 --json

EOF
    exit "${1:-0}"
}

get_aws_equivalent() {
    local vcpus="$1"
    local memory_gb="$2"
    
    local instance_type=""
    
    if [[ "$vcpus" -le 2 && "$memory_gb" -le 4 ]]; then
        instance_type="t3.medium"
    elif [[ "$vcpus" -le 2 && "$memory_gb" -le 8 ]]; then
        instance_type="t3.large"
    elif [[ "$vcpus" -le 4 && "$memory_gb" -le 8 ]]; then
        instance_type="m5.large"
    elif [[ "$vcpus" -le 4 && "$memory_gb" -le 16 ]]; then
        instance_type="m5.xlarge"
    elif [[ "$vcpus" -le 8 && "$memory_gb" -le 16 ]]; then
        instance_type="m5.xlarge"
    elif [[ "$vcpus" -le 8 && "$memory_gb" -le 32 ]]; then
        instance_type="r5.2xlarge"
    else
        instance_type="m5.2xlarge"
    fi
    
    echo "$instance_type"
}

get_gcp_equivalent() {
    local vcpus="$1"
    local memory_gb="$2"
    
    local machine_type=""
    
    if [[ "$vcpus" -le 2 && "$memory_gb" -le 4 ]]; then
        machine_type="e2-medium"
    elif [[ "$vcpus" -le 2 && "$memory_gb" -le 8 ]]; then
        machine_type="e2-large"
    elif [[ "$vcpus" -le 4 && "$memory_gb" -le 8 ]]; then
        machine_type="n2-standard-2"
    elif [[ "$vcpus" -le 4 && "$memory_gb" -le 16 ]]; then
        machine_type="n2-standard-4"
    elif [[ "$vcpus" -le 8 && "$memory_gb" -le 16 ]]; then
        machine_type="n2-standard-8"
    elif [[ "$vcpus" -le 8 && "$memory_gb" -le 32 ]]; then
        machine_type="n2-highmem-4"
    else
        machine_type="n2-standard-8"
    fi
    
    echo "$machine_type"
}

get_azure_equivalent() {
    local vcpus="$1"
    local memory_gb="$2"
    
    local vm_size=""
    
    if [[ "$vcpus" -le 2 && "$memory_gb" -le 4 ]]; then
        vm_size="Standard_B2s"
    elif [[ "$vcpus" -le 2 && "$memory_gb" -le 8 ]]; then
        vm_size="Standard_B2ms"
    elif [[ "$vcpus" -le 4 && "$memory_gb" -le 8 ]]; then
        vm_size="Standard_D2s_v3"
    elif [[ "$vcpus" -le 4 && "$memory_gb" -le 16 ]]; then
        vm_size="Standard_D4s_v3"
    elif [[ "$vcpus" -le 8 && "$memory_gb" -le 16 ]]; then
        vm_size="Standard_D8s_v3"
    elif [[ "$vcpus" -le 8 && "$memory_gb" -le 32 ]]; then
        vm_size="Standard_E4s_v3"
    else
        vm_size="Standard_D8s_v3"
    fi
    
    echo "$vm_size"
}

calculate_aws_cost() {
    local instance_type="$1"
    local count="$2"
    local storage_gb="$3"
    local network_gb="$4"
    local lb_requests="$5"
    local use_reserved="$6"
    local term="$7"
    
    local hourly_rate=0
    case "$instance_type" in
        t3.medium) hourly_rate=0.0416 ;;
        t3.large) hourly_rate=0.0832 ;;
        m5.large) hourly_rate=0.096 ;;
        m5.xlarge) hourly_rate=0.192 ;;
        m5.2xlarge) hourly_rate=0.384 ;;
        r5.2xlarge) hourly_rate=0.504 ;;
        *) hourly_rate=0.10 ;;
    esac
    
    if [[ "$use_reserved" == "true" ]]; then
        local discount=0.40
        if [[ "$term" -eq 3 ]]; then
            discount=0.62
        fi
        hourly_rate=$(calc "$hourly_rate * (1 - $discount)" )
    fi
    
    local compute_cost=$(calc "$hourly_rate * 730 * $count" )
    local storage_cost=$(calc "$storage_gb * 0.08" )
    local network_cost=$(calc "$network_gb * 0.09" )
    local lb_cost=$(calc "0.0225 * 730 + $lb_requests * 0.008" )
    
    local total=$(calc "$compute_cost + $storage_cost + $network_cost + $lb_cost" )
    echo "$total"
}

calculate_gcp_cost() {
    local machine_type="$1"
    local count="$2"
    local storage_gb="$3"
    local network_gb="$4"
    local lb_requests="$5"
    local use_committed="$6"
    local vcpus="$7"
    local memory_gb="$8"
    
    local hourly_rate=0
    case "$machine_type" in
        e2-medium) hourly_rate=0.0336 ;;
        e2-large) hourly_rate=0.0672 ;;
        n2-standard-2) hourly_rate=0.10 ;;
        n2-standard-4) hourly_rate=0.20 ;;
        n2-standard-8) hourly_rate=0.40 ;;
        n2-highmem-4) hourly_rate=0.26 ;;
        *) hourly_rate=0.12 ;;
    esac
    
    local committed_cost=0
    if [[ "$use_committed" == "true" ]]; then
        committed_cost=$(calc "$vcpus * 0.041667 * 730 + $memory_gb * 0.005469 * 730" )
        hourly_rate=$(calc "$hourly_rate * 0.43" )
    fi
    
    local compute_cost=$(calc "$hourly_rate * 730 * $count" )
    if [[ "$use_committed" == "true" ]]; then
        compute_cost=$committed_cost
    fi
    
    local storage_cost=$(calc "$storage_gb * 0.04" )
    
    local network_cost=0
    if (( $(calc "$network_gb > 1" ) )); then
        network_cost=$(calc "($network_gb - 1) * 0.12" )
    fi
    
    local lb_cost=$(calc "0.025 * 730 + $lb_requests * 0.008" )
    
    local total=$(calc "$compute_cost + $storage_cost + $network_cost + $lb_cost" )
    echo "$total"
}

calculate_azure_cost() {
    local vm_size="$1"
    local count="$2"
    local storage_gb="$3"
    local network_gb="$4"
    local lb_requests="$5"
    local use_reserved="$6"
    local term="$7"
    
    local hourly_rate=0
    case "$vm_size" in
        Standard_B2s) hourly_rate=0.0416 ;;
        Standard_B2ms) hourly_rate=0.0832 ;;
        Standard_D2s_v3) hourly_rate=0.096 ;;
        Standard_D4s_v3) hourly_rate=0.192 ;;
        Standard_D8s_v3) hourly_rate=0.384 ;;
        Standard_E4s_v3) hourly_rate=0.252 ;;
        *) hourly_rate=0.12 ;;
    esac
    
    if [[ "$use_reserved" == "true" ]]; then
        local discount=0.40
        if [[ "$term" -eq 3 ]]; then
            discount=0.62
        fi
        hourly_rate=$(calc "$hourly_rate * (1 - $discount)" )
    fi
    
    local compute_cost=$(calc "$hourly_rate * 730 * $count" )
    local storage_cost=$(calc "$storage_gb * 0.038" )
    
    local network_cost=0
    if (( $(calc "$network_gb > 5" ) )); then
        network_cost=$(calc "($network_gb - 5) * 0.087" )
    fi
    
    local lb_cost=$(calc "0.025 * 730 + $lb_requests * 0.005" )
    
    local total=$(calc "$compute_cost + $storage_cost + $network_cost + $lb_cost" )
    echo "$total"
}

get_savings_recommendations() {
    local aws_cost="$1"
    local gcp_cost="$2"
    local azure_cost="$3"
    
    local cheapest=""
    local min_cost="$aws_cost"
    
    if (( $(calc "$gcp_cost < $min_cost" ) )); then
        min_cost="$gcp_cost"
        cheapest="gcp"
    fi
    
    if (( $(calc "$azure_cost < $min_cost" ) )); then
        min_cost="$azure_cost"
        cheapest="azure"
    fi
    
    if [[ "$cheapest" == "aws" ]]; then
        echo "AWS is cheapest. Consider reserved instances for 1-3 year commitments for additional savings of 40-60%."
    elif [[ "$cheapest" == "gcp" ]]; then
        echo "GCP is cheapest. Consider committed use for sustained use discounts of up to 57%."
    else
        echo "Azure is cheapest. Consider Azure Reserved VM Instances for 1-3 year commitments for additional savings of 40-62%."
    fi
}

output_json() {
    local savings_aws=$(calc "$AWS_ON_DEMAND - $AWS_COST" )
    local savings_gcp=$(calc "$GCP_ON_DEMAND - $GCP_COST" )
    local savings_azure=$(calc "$AZURE_ON_DEMAND - $AZURE_COST" )
    
    cat <<EOF
{
    "provider": "comparison",
    "currency": "USD",
    "workload_specification": {
        "vcpus_per_instance": $INSTANCE_VCPUS,
        "memory_gb_per_instance": $INSTANCE_MEMORY_GB,
        "instance_count": $INSTANCE_COUNT,
        "total_storage_gb": $STORAGE_GB,
        "network_egress_gb": $NETWORK_EGRESS_GB,
        "lb_requests_million": $LB_REQUESTS_MILLION
    },
    "instance_equivalents": {
        "aws": "$AWS_INSTANCE_TYPE",
        "gcp": "$GCP_MACHINE_TYPE",
        "azure": "$AZURE_VM_SIZE"
    },
    "on_demand_costs": {
        "aws": $AWS_ON_DEMAND,
        "gcp": $GCP_ON_DEMAND,
        "azure": $AZURE_ON_DEMAND
    },
    "discounted_costs": {
        "aws": {
            "model": "$AWS_PRICING_MODEL",
            "monthly_cost": $AWS_COST,
            "yearly_cost": $(calc "$AWS_COST * 12" ),
            "savings": $savings_aws
        },
        "gcp": {
            "model": "$GCP_PRICING_MODEL",
            "monthly_cost": $GCP_COST,
            "yearly_cost": $(calc "$GCP_COST * 12" ),
            "savings": $savings_gcp
        },
        "azure": {
            "model": "$AZURE_PRICING_MODEL",
            "monthly_cost": $AZURE_COST,
            "yearly_cost": $(calc "$AZURE_COST * 12" ),
            "savings": $savings_azure
        }
    },
    "recommendations": {
        "cheapest_provider": "$CHEAPEST",
        "monthly_savings_tips": "$(get_savings_recommendations "$AWS_COST" "$GCP_COST" "$AZURE_COST")",
        "spot_preemptible_savings": "Consider spot/preemptible/spot instances for non-production workloads - savings of 60-70%",
        "committed_use": "For production workloads with predictable usage, commit to 1-3 year terms for 40-62% savings"
    }
}
EOF
}

output_human_readable() {
    cat <<EOF
================================================================================
CLOUD COST COMPARISON
================================================================================

Workload Specification:
  vCPUs per Instance:    $INSTANCE_VCPUS
  Memory per Instance:  $INSTANCE_MEMORY_GB GB
  Instance Count:       $INSTANCE_COUNT
  Total Storage:        $STORAGE_GB GB
  Network Egress:       $NETWORK_EGRESS_GB GB/month
  LB Requests:          $LB_REQUESTS_MILLION million/month

================================================================================
INSTANCE EQUIVALENTS
================================================================================
  AWS:  $AWS_INSTANCE_TYPE
  GCP:  $GCP_MACHINE_TYPE
  Azure: $AZURE_VM_SIZE

================================================================================
ON-DEMAND COSTS (Monthly)
================================================================================
  AWS:   \$$(printf "%.2f" $AWS_ON_DEMAND)
  GCP:   \$$(printf "%.2f" $GCP_ON_DEMAND)
  Azure: \$$(printf "%.2f" $AZURE_ON_DEMAND)

================================================================================
DISCOUNTED COSTS (Monthly)
================================================================================
  AWS:   \$$(printf "%.2f" $AWS_COST)  ($AWS_PRICING_MODEL - Save \$$(printf "%.2f" $(calc "$AWS_ON_DEMAND - $AWS_COST" )))
  GCP:   \$$(printf "%.2f" $GCP_COST)  ($GCP_PRICING_MODEL - Save \$$(printf "%.2f" $(calc "$GCP_ON_DEMAND - $GCP_COST" )))
  Azure: \$$(printf "%.2f" $AZURE_COST)  ($AZURE_PRICING_MODEL - Save \$$(printf "%.2f" $(calc "$AZURE_ON_DEMAND - $AZURE_COST" )))

================================================================================
YEARLY COST SUMMARY
================================================================================
  AWS:   \$$(printf "%.2f" $(calc "$AWS_COST * 12" ))
  GCP:   \$$(printf "%.2f" $(calc "$GCP_COST * 12" ))
  Azure: \$$(printf "%.2f" $(calc "$AZURE_COST * 12" ))

================================================================================
RECOMMENDATIONS
================================================================================

$(get_savings_recommendations "$AWS_COST" "$GCP_COST" "$AZURE_COST")

Spot/Preemptible Options:
  For non-production or fault-tolerant workloads, consider:
  - AWS Spot Instances: up to 70% savings
  - GCP Preemptible VMs: up to 60% savings
  - Azure Spot VMs: up to 65% savings

Committed Use Discounts:
  For production workloads with predictable usage:
  - AWS Reserved Instances: 40-62% savings (1-3 year)
  - GCP Committed Use: 57% savings (1-3 year)
  - Azure Reserved VMs: 40-62% savings (1-3 year)

================================================================================
ADDITIONAL COST CONSIDERATIONS
================================================================================
- Data transfer costs vary significantly by region and direction
- Managed services (RDS, Cloud SQL, Azure SQL) have separate pricing
- Egress costs often exceed compute costs at scale
- Consider Reserved/Committed plans for production workloads
- Use spot/preemptible for batch processing and dev/test
================================================================================
EOF
}

WORKLOAD_PROFILE="${workload_profile:-medium}"
INSTANCE_VCPUS=2
INSTANCE_MEMORY_GB=4
INSTANCE_COUNT=3
STORAGE_GB=100
NETWORK_EGRESS_GB=100
LB_REQUESTS_MILLION=10
DB_ENABLED=false
AWS_RESERVED=false
GCP_COMMITTED=false
AZURE_RESERVED=false
TERM_YEARS=1
OUTPUT_JSON=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workload-profile)
            WORKLOAD_PROFILE="$2"
            shift 2
            ;;
        --instance-vcpus)
            INSTANCE_VCPUS="$2"
            shift 2
            ;;
        --instance-memory-gb)
            INSTANCE_MEMORY_GB="$2"
            shift 2
            ;;
        --instance-count)
            INSTANCE_COUNT="$2"
            shift 2
            ;;
        --storage-gb)
            STORAGE_GB="$2"
            shift 2
            ;;
        --network-egress-gb)
            NETWORK_EGRESS_GB="$2"
            shift 2
            ;;
        --lb-requests-million)
            LB_REQUESTS_MILLION="$2"
            shift 2
            ;;
        --db-enabled)
            DB_ENABLED=true
            shift
            ;;
        --aws-reserved)
            AWS_RESERVED=true
            shift
            ;;
        --gcp-committed)
            GCP_COMMITTED=true
            shift
            ;;
        --azure-reserved)
            AZURE_RESERVED=true
            shift
            ;;
        --term-years)
            TERM_YEARS="$2"
            shift 2
            ;;
        --json)
            OUTPUT_JSON=true
            shift
            ;;
        --help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage 1
            ;;
    esac
done

case "$WORKLOAD_PROFILE" in
    small)
        INSTANCE_VCPUS=1
        INSTANCE_MEMORY_GB=2
        INSTANCE_COUNT=1
        STORAGE_GB=30
        ;;
    medium)
        INSTANCE_VCPUS=2
        INSTANCE_MEMORY_GB=4
        INSTANCE_COUNT=3
        STORAGE_GB=100
        ;;
    large)
        INSTANCE_VCPUS=4
        INSTANCE_MEMORY_GB=8
        INSTANCE_COUNT=5
        STORAGE_GB=500
        ;;
esac

AWS_INSTANCE_TYPE=$(get_aws_equivalent "$INSTANCE_VCPUS" "$INSTANCE_MEMORY_GB")
GCP_MACHINE_TYPE=$(get_gcp_equivalent "$INSTANCE_VCPUS" "$INSTANCE_MEMORY_GB")
AZURE_VM_SIZE=$(get_azure_equivalent "$INSTANCE_VCPUS" "$INSTANCE_MEMORY_GB")

if [[ "$AWS_RESERVED" == "true" ]]; then
    AWS_PRICING_MODEL="reserved"
else
    AWS_PRICING_MODEL="on-demand"
fi

if [[ "$GCP_COMMITTED" == "true" ]]; then
    GCP_PRICING_MODEL="committed"
else
    GCP_PRICING_MODEL="on-demand"
fi

if [[ "$AZURE_RESERVED" == "true" ]]; then
    AZURE_PRICING_MODEL="reserved"
else
    AZURE_PRICING_MODEL="on-demand"
fi

AWS_ON_DEMAND=$(calculate_aws_cost "$AWS_INSTANCE_TYPE" "$INSTANCE_COUNT" "$STORAGE_GB" "$NETWORK_EGRESS_GB" "$LB_REQUESTS_MILLION" "false" "$TERM_YEARS")
GCP_ON_DEMAND=$(calculate_gcp_cost "$GCP_MACHINE_TYPE" "$INSTANCE_COUNT" "$STORAGE_GB" "$NETWORK_EGRESS_GB" "$LB_REQUESTS_MILLION" "false" "$INSTANCE_VCPUS" "$INSTANCE_MEMORY_GB")
AZURE_ON_DEMAND=$(calculate_azure_cost "$AZURE_VM_SIZE" "$INSTANCE_COUNT" "$STORAGE_GB" "$NETWORK_EGRESS_GB" "$LB_REQUESTS_MILLION" "false" "$TERM_YEARS")

AWS_COST=$(calculate_aws_cost "$AWS_INSTANCE_TYPE" "$INSTANCE_COUNT" "$STORAGE_GB" "$NETWORK_EGRESS_GB" "$LB_REQUESTS_MILLION" "$AWS_RESERVED" "$TERM_YEARS")
GCP_COST=$(calculate_gcp_cost "$GCP_MACHINE_TYPE" "$INSTANCE_COUNT" "$STORAGE_GB" "$NETWORK_EGRESS_GB" "$LB_REQUESTS_MILLION" "$GCP_COMMITTED" "$INSTANCE_VCPUS" "$INSTANCE_MEMORY_GB")
AZURE_COST=$(calculate_azure_cost "$AZURE_VM_SIZE" "$INSTANCE_COUNT" "$STORAGE_GB" "$NETWORK_EGRESS_GB" "$LB_REQUESTS_MILLION" "$AZURE_RESERVED" "$TERM_YEARS")

CHEAPEST="aws"
MIN_COST="$AWS_COST"

if (( $(calc "$GCP_COST < $MIN_COST" ) )); then
    CHEAPEST="gcp"
    MIN_COST="$GCP_COST"
fi

if (( $(calc "$AZURE_COST < $MIN_COST" ) )); then
    CHEAPEST="azure"
    MIN_COST="$AZURE_COST"
fi

if [[ "$OUTPUT_JSON" == "true" ]]; then
    output_json
else
    output_human_readable
fi
