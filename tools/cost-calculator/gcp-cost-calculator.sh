#!/usr/bin/env bash
# GCP Cost Calculator for Podman Workloads
# Calculates GCP costs including Compute Engine, Persistent Disk, Network Egress, Cloud Load Balancing, and Cloud SQL

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-}"

calc() {
    awk "BEGIN {printf \"%.2f\", $1}" 2>/dev/null || echo "0"
}

usage() {
    cat <<EOF
GCP Cost Calculator for Podman Workloads

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --instance-type TYPE         Compute Engine machine type (default: e2-medium)
    --instance-count NUM         Number of instances (default: 3)
    --pricing-model MODEL        on-demand, committed, or preemptible (default: on-demand)
    --committed-vcpus NUM        Committed vCPUs for committed use (default: 0)
    --committed-memory-gb NUM    Committed memory in GB (default: 0)
    --disk-size-gb SIZE          Boot disk size in GB (default: 30)
    --disk-type TYPE             pd-standard, pd-ssd, pd-balanced (default: pd-balanced)
    --disk-iops NUM              Target IOPS for pd-extreme (default: 0)
    --additional-disk-size GB   Additional PD size in GB (default: 0)
    --additional-disk-type TYPE  Additional disk type (default: pd-balanced)
    --network-egress-gb NUM      Monthly network egress in GB (default: 100)
    --lb-type TYPE               lb-type: http, https, tcp, ssl (default: https)
    --lb-requests-million NUM    Monthly LB requests in millions (default: 10)
    --sql-enabled                Enable Cloud SQL (default: false)
    --sql-tier TYPE              cloudsql-tier: db-f1-micro, db-g1-small, db-n1-standard-1 (default: db-n1-standard-1)
    --sql-storage-gb NUM         Cloud SQL storage in GB (default: 100)
    --config FILE                Load parameters from config file
    --json                       Output JSON format
    --help                       Show this help message

CONFIG FILE FORMAT (YAML-like):
    instance_type: e2-medium
    instance_count: 3
    pricing_model: on-demand
    committed_vcpus: 0
    committed_memory_gb: 0
    disk_size_gb: 30
    disk_type: pd-balanced
    disk_iops: 0
    additional_disk_size: 0
    additional_disk_type: pd-balanced
    network_egress_gb: 100
    lb_type: https
    lb_requests_million: 10
    sql_enabled: false
    sql_tier: db-n1-standard-1
    sql_storage_gb: 100

EXAMPLES:
    $0 --instance-type n2-standard-2 --instance-count 5 --committed-vcpus 10 --json
    $0 --config gcp-config.yaml
    $0 --instance-type n1-standard-1 --preemptible --json

EOF
    exit "${1:-0}"
}

parse_config() {
    local config_file="$1"
    if [[ -f "$config_file" ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ "$line" =~ ^[[:space:]]*$ ]] && continue
            if [[ "$line" =~ ^([^:]+):[[:space:]]*(.+)$ ]]; then
                local key="${BASH_REMATCH[1]}"
                local value="${BASH_REMATCH[2]}"
                case "$key" in
                    instance_type) INSTANCE_TYPE="$value" ;;
                    instance_count) INSTANCE_COUNT="$value" ;;
                    pricing_model) PRICING_MODEL="$value" ;;
                    committed_vcpus) COMMITTED_VCPUS="$value" ;;
                    committed_memory_gb) COMMITTED_MEMORY_GB="$value" ;;
                    disk_size_gb) DISK_SIZE_GB="$value" ;;
                    disk_type) DISK_TYPE="$value" ;;
                    disk_iops) DISK_IOPS="$value" ;;
                    additional_disk_size) ADDITIONAL_DISK_SIZE="$value" ;;
                    additional_disk_type) ADDITIONAL_DISK_TYPE="$value" ;;
                    network_egress_gb) NETWORK_EGRESS_GB="$value" ;;
                    lb_type) LB_TYPE="$value" ;;
                    lb_requests_million) LB_REQUESTS_MILLION="$value" ;;
                    sql_enabled) SQL_ENABLED="$value" ;;
                    sql_tier) SQL_TIER="$value" ;;
                    sql_storage_gb) SQL_STORAGE_GB="$value" ;;
                esac
            fi
        done < "$config_file"
    fi
}

calculate_gce_cost() {
    local machine_type="$1"
    local count="$2"
    local pricing_model="$3"
    
    local vcpus=0
    local memory_gb=0
    local on_demand_hourly=0
    
    case "$machine_type" in
        e2-micro)
            vcpus=2
            memory_gb=1
            on_demand_hourly=0.0084
            ;;
        e2-small)
            vcpus=2
            memory_gb=2
            on_demand_hourly=0.0168
            ;;
        e2-medium)
            vcpus=2
            memory_gb=4
            on_demand_hourly=0.0336
            ;;
        e2-large)
            vcpus=4
            memory_gb=8
            on_demand_hourly=0.0672
            ;;
        e2-xlarge)
            vcpus=8
            memory_gb=16
            on_demand_hourly=0.1344
            ;;
        n1-standard-1)
            vcpus=1
            memory_gb=3.75
            on_demand_hourly=0.0475
            ;;
        n1-standard-2)
            vcpus=2
            memory_gb=7.5
            on_demand_hourly=0.095
            ;;
        n1-standard-4)
            vcpus=4
            memory_gb=15
            on_demand_hourly=0.19
            ;;
        n1-standard-8)
            vcpus=8
            memory_gb=30
            on_demand_hourly=0.38
            ;;
        n1-standard-16)
            vcpus=16
            memory_gb=60
            on_demand_hourly=0.76
            ;;
        n1-standard-32)
            vcpus=32
            memory_gb=120
            on_demand_hourly=1.52
            ;;
        n1-standard-64)
            vcpus=64
            memory_gb=240
            on_demand_hourly=3.04
            ;;
        n1-highmem-2)
            vcpus=2
            memory_gb=13
            on_demand_hourly=0.118
            ;;
        n1-highmem-4)
            vcpus=4
            memory_gb=26
            on_demand_hourly=0.237
            ;;
        n1-highmem-8)
            vcpus=8
            memory_gb=52
            on_demand_hourly=0.475
            ;;
        n2-standard-2)
            vcpus=2
            memory_gb=8
            on_demand_hourly=0.10
            ;;
        n2-standard-4)
            vcpus=4
            memory_gb=16
            on_demand_hourly=0.20
            ;;
        n2-standard-8)
            vcpus=8
            memory_gb=32
            on_demand_hourly=0.40
            ;;
        n2-standard-16)
            vcpus=16
            memory_gb=64
            on_demand_hourly=0.80
            ;;
        n2-standard-32)
            vcpus=32
            memory_gb=128
            on_demand_hourly=1.60
            ;;
        n2-highmem-2)
            vcpus=2
            memory_gb=16
            on_demand_hourly=0.13
            ;;
        n2-highmem-4)
            vcpus=4
            memory_gb=32
            on_demand_hourly=0.26
            ;;
        n2-highmem-8)
            vcpus=8
            memory_gb=64
            on_demand_hourly=0.52
            ;;
        c2-standard-4)
            vcpus=4
            memory_gb=16
            on_demand_hourly=0.25
            ;;
        c2-standard-8)
            vcpus=8
            memory_gb=32
            on_demand_hourly=0.50
            ;;
        *)
            vcpus=2
            memory_gb=4
            on_demand_hourly=0.05
            ;;
    esac
    
    local hourly_rate=$on_demand_hourly
    
    if [[ "$pricing_model" == "preemptible" ]]; then
        local preemptible_discount=0.60
        hourly_rate=$(calc "$on_demand_hourly * (1 - $preemptible_discount)" )
    elif [[ "$pricing_model" == "committed" ]]; then
        local committed_discount=0.57
        hourly_rate=$(calc "$on_demand_hourly * (1 - $committed_discount)" )
    fi
    
    local monthly_hours=730
    local monthly_cost=$(calc "$hourly_rate * $monthly_hours * $count" )
    
    echo "$monthly_cost"
    echo "$hourly_rate"
}

calculate_committed_use_cost() {
    local vcpus="$1"
    local memory_gb="$2"
    
    local vcpu_hourly=0.041667
    local memory_hourly=0.005469
    
    local vcpu_cost=$(calc "$vcpus * $vcpu_hourly * 730" )
    local memory_cost=$(calc "$memory_gb * $memory_hourly * 730" )
    
    local total=$(calc "$vcpu_cost + $memory_cost" )
    echo "$total"
}

calculate_disk_cost() {
    local size_gb="$1"
    local disk_type="$2"
    
    local cost_per_gb=0
    
    case "$disk_type" in
        pd-standard)
            cost_per_gb=0.02
            ;;
        pd-balanced)
            cost_per_gb=0.04
            ;;
        pd-ssd)
            cost_per_gb=0.08
            ;;
        pd-extreme)
            cost_per_gb=0.10
            ;;
    esac
    
    local total=$(calc "$size_gb * $cost_per_gb" )
    echo "$total"
}

calculate_network_egress_cost() {
    local egress_gb="$1"
    
    local cost=0
    
    if (( $(calc "$egress_gb <= 1" ) )); then
        cost=0
    elif (( $(calc "$egress_gb <= 1024" ) )); then
        cost=$(calc "($egress_gb - 1) * 0.12" )
    elif (( $(calc "$egress_gb <= 10240" ) )); then
        cost=$(calc "1023 * 0.12 + ($egress_gb - 1024) * 0.08" )
    else
        cost=$(calc "1023 * 0.12 + 9216 * 0.08 + ($egress_gb - 10240) * 0.05" )
    fi
    
    echo "$cost"
}

calculate_lb_cost() {
    local lb_type="$1"
    local requests_million="$2"
    
    local hourly_charge=0
    local request_cost=0
    
    case "$lb_type" in
        http|https)
            hourly_charge=0.025
            request_cost=$(calc "$requests_million * 0.008" )
            ;;
        tcp|ssl)
            hourly_charge=0.020
            ;;
    esac
    
    local hourly_monthly=$(calc "$hourly_charge * 730" )
    local total=$(calc "$hourly_monthly + $request_cost" )
    
    echo "$total"
}

calculate_cloudsql_cost() {
    local tier="$1"
    local storage_gb="$2"
    
    local hourly_rate=0
    local storage_rate=0.15
    
    case "$tier" in
        db-f1-micro)
            hourly_rate=0.015
            ;;
        db-g1-small)
            hourly_rate=0.06
            ;;
        db-n1-standard-1)
            hourly_rate=0.10
            ;;
        db-n1-standard-2)
            hourly_rate=0.20
            ;;
        db-n1-standard-4)
            hourly_rate=0.40
            ;;
        db-n1-highmem-2)
            hourly_rate=0.30
            ;;
        db-n1-highmem-4)
            hourly_rate=0.60
            ;;
    esac
    
    local instance_cost=$(calc "$hourly_rate * 730" )
    local storage_cost=$(calc "$storage_gb * $storage_rate" )
    local total=$(calc "$instance_cost + $storage_cost" )
    
    echo "$total"
}

calculate_break_even() {
    local on_demand_hourly="$1"
    local committed_hourly="$2"
    local upfront_cost="$3"
    
    local hourly_savings=$(calc "$on_demand_hourly - $committed_hourly" )
    
    if (( $(calc "$hourly_savings <= 0" ) )); then
        echo "0"
        return
    fi
    
    local break_even_hours=$(calc "$upfront_cost / $hourly_savings" )
    local break_even_days=$(calc "$break_even_hours / 24" )
    
    echo "$break_even_days"
}

output_json() {
    cat <<EOF
{
    "provider": "gcp",
    "currency": "USD",
    "monthly_costs": {
        "compute_engine": {
            "machine_type": "$INSTANCE_TYPE",
            "instance_count": $INSTANCE_COUNT,
            "pricing_model": "$PRICING_MODEL",
            "hourly_rate": $GCE_HOURLY_RATE,
            "monthly_cost": $GCE_MONTHLY_COST
        },
        "committed_use": {
            "committed_vcpus": $COMMITTED_VCPUS,
            "committed_memory_gb": $COMMITTED_MEMORY_GB,
            "monthly_cost": $COMMITTED_COST
        },
        "boot_disk": {
            "size_gb": $DISK_SIZE_GB,
            "disk_type": "$DISK_TYPE",
            "monthly_cost": $BOOT_DISK_COST
        },
        "additional_disk": {
            "size_gb": $ADDITIONAL_DISK_SIZE,
            "disk_type": "$ADDITIONAL_DISK_TYPE",
            "monthly_cost": $ADDITIONAL_DISK_COST
        },
        "network_egress": {
            "egress_gb": $NETWORK_EGRESS_GB,
            "monthly_cost": $NETWORK_EGRESS_COST
        },
        "load_balancer": {
            "lb_type": "$LB_TYPE",
            "requests_million": $LB_REQUESTS_MILLION,
            "monthly_cost": $LB_COST
        },
        "cloud_sql": {
            "enabled": $SQL_ENABLED_BOOL,
            "tier": "$SQL_TIER",
            "storage_gb": $SQL_STORAGE_GB,
            "monthly_cost": $SQL_COST
        }
    },
    "total_monthly_cost": $TOTAL_MONTHLY_COST,
    "total_yearly_cost": $TOTAL_YEARLY_COST,
    "assumptions": {
        "hours_per_month": 730,
        "network_tiers": "Free tier: 1GB, tier 1: 1-1024GB @ \$0.12/GB, tier 2: 1-10TB @ \$0.08/GB, tier 3: 10TB+ @ \$0.05/GB",
        "committed_discount": "57% for committed use",
        "preemptible_discount": "60% for preemptible instances"
    },
    "committed_use_analysis": {
        "on_demand_hourly": $ON_DEMAND_RATE,
        "committed_hourly": $GCE_HOURLY_RATE,
        "monthly_savings": $MONTHLY_SAVINGS,
        "yearly_savings": $YEARLY_SAVINGS,
        "upfront_cost": $COMMITTED_UPFRONT,
        "break_even_days": $BREAK_EVEN_DAYS
    }
}
EOF
}

output_human_readable() {
    cat <<EOF
================================================================================
GCP COST CALCULATION FOR PODMAN WORKLOADS
================================================================================

Compute Engine Costs:
  Machine Type:      $INSTANCE_TYPE
  Instance Count:   $INSTANCE_COUNT
  Pricing Model:    $PRICING_MODEL
  Hourly Rate:      \$$(printf "%.4f" $GCE_HOURLY_RATE) per instance
  Monthly Cost:     \$$(printf "%.2f" $GCE_MONTHLY_COST)

Committed Use (if applicable):
  Committed vCPUs:   $COMMITTED_VCPUS
  Committed Memory: $COMMITTED_MEMORY_GB GB
  Monthly Cost:     \$$(printf "%.2f" $COMMITTED_COST)

Boot Disk Costs:
  Disk Size:        $DISK_SIZE_GB GB
  Disk Type:        $DISK_TYPE
  Monthly Cost:     \$$(printf "%.2f" $BOOT_DISK_COST)

Additional Disk Costs:
  Disk Size:        $ADDITIONAL_DISK_SIZE GB
  Disk Type:        $ADDITIONAL_DISK_TYPE
  Monthly Cost:     \$$(printf "%.2f" $ADDITIONAL_DISK_COST)

Network Egress Costs:
  Data Egress:      $NETWORK_EGRESS_GB GB/month
  Monthly Cost:     \$$(printf "%.2f" $NETWORK_EGRESS_COST)

Load Balancer Costs:
  LB Type:          $LB_TYPE
  Requests:         $LB_REQUESTS_MILLION million/month
  Monthly Cost:     \$$(printf "%.2f" $LB_COST)

$(if [[ "$SQL_ENABLED_BOOL" == "true" ]]; then
cat <<SQL
Cloud SQL Costs:
  Tier:             $SQL_TIER
  Storage:          $SQL_STORAGE_GB GB
  Monthly Cost:     \$$(printf "%.2f" $SQL_COST)

SQL
fi)
================================================================================
TOTAL MONTHLY COST:  \$$(printf "%.2f" $TOTAL_MONTHLY_COST)
TOTAL YEARLY COST:   \$$(printf "%.2f" $TOTAL_YEARLY_COST)
================================================================================

$(if [[ "$PRICING_MODEL" == "committed" || "$COMMITTED_VCPUS" -gt 0 ]]; then
cat <<COMMIT
Committed Use Discount Analysis:
  On-Demand Rate:    \$$(printf "%.4f" $ON_DEMAND_RATE)/hour
  Committed Rate:    \$$(printf "%.4f" $GCE_HOURLY_RATE)/hour
  Monthly Savings:   \$$(printf "%.2f" $MONTHLY_SAVINGS)
  Yearly Savings:    \$$(printf "%.2f" $YEARLY_SAVINGS)
  Upfront Cost:     \$$(printf "%.2f" $COMMITTED_UPFRONT)
  Break-Even:       $BREAK_EVEN_DAYS days
COMMIT
fi)
================================================================================
ASSUMPTIONS:
- 730 hours per month
- Network egress: tiered pricing (Free: 1GB, Tier1: \$0.12/GB, Tier2: \$0.08/GB, Tier3: \$0.05/GB)
- Committed use: 57% discount for 1-year or 3-year commitment
- Preemptible: 60% discount but may be terminated with 30-second notice
- Cloud SQL: \$0.15/GB/month for storage
- Prices are estimates and vary by GCP region
================================================================================
EOF
}

INSTANCE_TYPE="${instance_type:-e2-medium}"
INSTANCE_COUNT="${instance_count:-3}"
PRICING_MODEL="${pricing_model:-on-demand}"
COMMITTED_VCPUS="${committed_vcpus:-0}"
COMMITTED_MEMORY_GB="${committed_memory_gb:-0}"
DISK_SIZE_GB="${disk_size_gb:-30}"
DISK_TYPE="${disk_type:-pd-balanced}"
DISK_IOPS="${disk_iops:-0}"
ADDITIONAL_DISK_SIZE="${additional_disk_size:-0}"
ADDITIONAL_DISK_TYPE="${additional_disk_type:-pd-balanced}"
NETWORK_EGRESS_GB="${network_egress_gb:-100}"
LB_TYPE="${lb_type:-https}"
LB_REQUESTS_MILLION="${lb_requests_million:-10}"
SQL_ENABLED="${sql_enabled:-false}"
SQL_TIER="${sql_tier:-db-n1-standard-1}"
SQL_STORAGE_GB="${sql_storage_gb:-100}"
OUTPUT_JSON=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance-type)
            INSTANCE_TYPE="$2"
            shift 2
            ;;
        --instance-count)
            INSTANCE_COUNT="$2"
            shift 2
            ;;
        --pricing-model)
            PRICING_MODEL="$2"
            shift 2
            ;;
        --committed-vcpus)
            COMMITTED_VCPUS="$2"
            shift 2
            ;;
        --committed-memory-gb)
            COMMITTED_MEMORY_GB="$2"
            shift 2
            ;;
        --disk-size-gb)
            DISK_SIZE_GB="$2"
            shift 2
            ;;
        --disk-type)
            DISK_TYPE="$2"
            shift 2
            ;;
        --disk-iops)
            DISK_IOPS="$2"
            shift 2
            ;;
        --additional-disk-size)
            ADDITIONAL_DISK_SIZE="$2"
            shift 2
            ;;
        --additional-disk-type)
            ADDITIONAL_DISK_TYPE="$2"
            shift 2
            ;;
        --network-egress-gb)
            NETWORK_EGRESS_GB="$2"
            shift 2
            ;;
        --lb-type)
            LB_TYPE="$2"
            shift 2
            ;;
        --lb-requests-million)
            LB_REQUESTS_MILLION="$2"
            shift 2
            ;;
        --sql-enabled)
            SQL_ENABLED="true"
            shift
            ;;
        --sql-tier)
            SQL_TIER="$2"
            shift 2
            ;;
        --sql-storage-gb)
            SQL_STORAGE_GB="$2"
            shift 2
            ;;
        --config)
            CONFIG_FILE="$2"
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

if [[ -n "$CONFIG_FILE" ]]; then
    parse_config "$CONFIG_FILE"
fi

if [[ "$SQL_ENABLED" == "true" ]]; then
    SQL_ENABLED_BOOL="true"
else
    SQL_ENABLED_BOOL="false"
fi

GCE_OUTPUT=($(calculate_gce_cost "$INSTANCE_TYPE" "$INSTANCE_COUNT" "$PRICING_MODEL"))
GCE_MONTHLY_COST="${GCE_OUTPUT[0]}"
GCE_HOURLLY_RATE="${GCE_OUTPUT[1]}"
GCE_HOURLY_RATE=$GCE_HOURLLY_RATE

if [[ "$COMMITTED_VCPUS" -gt 0 || "$COMMITTED_MEMORY_GB" -gt 0 ]]; then
    COMMITTED_COST=$(calculate_committed_use_cost "$COMMITTED_VCPUS" "$COMMITTED_MEMORY_GB")
else
    COMMITTED_COST=0
fi

BOOT_DISK_COST=$(calculate_disk_cost "$DISK_SIZE_GB" "$DISK_TYPE")
ADDITIONAL_DISK_COST=$(calculate_disk_cost "$ADDITIONAL_DISK_SIZE" "$ADDITIONAL_DISK_TYPE")
NETWORK_EGRESS_COST=$(calculate_network_egress_cost "$NETWORK_EGRESS_GB")
LB_COST=$(calculate_lb_cost "$LB_TYPE" "$LB_REQUESTS_MILLION")

if [[ "$SQL_ENABLED" == "true" ]]; then
    SQL_COST=$(calculate_cloudsql_cost "$SQL_TIER" "$SQL_STORAGE_GB")
else
    SQL_COST=0
fi

if [[ "$PRICING_MODEL" == "on-demand" ]]; then
    case "$INSTANCE_TYPE" in
        e2-micro) ON_DEMAND_RATE=0.0084 ;;
        e2-small) ON_DEMAND_RATE=0.0168 ;;
        e2-medium) ON_DEMAND_RATE=0.0336 ;;
        e2-large) ON_DEMAND_RATE=0.0672 ;;
        e2-xlarge) ON_DEMAND_RATE=0.1344 ;;
        n1-standard-1) ON_DEMAND_RATE=0.0475 ;;
        n1-standard-2) ON_DEMAND_RATE=0.095 ;;
        n1-standard-4) ON_DEMAND_RATE=0.19 ;;
        n1-standard-8) ON_DEMAND_RATE=0.38 ;;
        n1-standard-16) ON_DEMAND_RATE=0.76 ;;
        n1-standard-32) ON_DEMAND_RATE=1.52 ;;
        n1-highmem-2) ON_DEMAND_RATE=0.118 ;;
        n1-highmem-4) ON_DEMAND_RATE=0.237 ;;
        n1-highmem-8) ON_DEMAND_RATE=0.475 ;;
        n2-standard-2) ON_DEMAND_RATE=0.10 ;;
        n2-standard-4) ON_DEMAND_RATE=0.20 ;;
        n2-standard-8) ON_DEMAND_RATE=0.40 ;;
        n2-standard-16) ON_DEMAND_RATE=0.80 ;;
        n2-highmem-2) ON_DEMAND_RATE=0.13 ;;
        n2-highmem-4) ON_DEMAND_RATE=0.26 ;;
        n2-highmem-8) ON_DEMAND_RATE=0.52 ;;
        c2-standard-4) ON_DEMAND_RATE=0.25 ;;
        c2-standard-8) ON_DEMAND_RATE=0.50 ;;
        *) ON_DEMAND_RATE=0.05 ;;
    esac
    
    MONTHLY_SAVINGS=$(calc "($ON_DEMAND_RATE * 730 * $INSTANCE_COUNT) - $GCE_MONTHLY_COST" )
    YEARLY_SAVINGS=$(calc "$MONTHLY_SAVINGS * 12" )
    COMMITTED_UPFRONT=$(calc "$GCE_MONTHLY_COST * 12 * 0.10" )
    BREAK_EVEN_DAYS=$(calculate_break_even "$ON_DEMAND_RATE" "$GCE_HOURLY_RATE" "$COMMITTED_UPFRONT")
else
    ON_DEMAND_RATE=$GCE_HOURLY_RATE
    MONTHLY_SAVINGS=0
    YEARLY_SAVINGS=0
    COMMITTED_UPFRONT=0
    BREAK_EVEN_DAYS=0
fi

TOTAL_MONTHLY_COST=$(calc "$GCE_MONTHLY_COST + $COMMITTED_COST + $BOOT_DISK_COST + $ADDITIONAL_DISK_COST + $NETWORK_EGRESS_COST + $LB_COST + $SQL_COST" )
TOTAL_YEARLY_COST=$(calc "$TOTAL_MONTHLY_COST * 12" )

if [[ "$OUTPUT_JSON" == "true" ]]; then
    output_json
else
    output_human_readable
fi
