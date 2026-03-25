#!/usr/bin/env bash
# Azure Cost Calculator for Podman Workloads
# Calculates Azure costs including Virtual Machines, Managed Disks, Bandwidth, and Load Balancer

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-}"

calc() {
    awk "BEGIN {printf \"%.2f\", $1}" 2>/dev/null || echo "0"
}

usage() {
    cat <<EOF
Azure Cost Calculator for Podman Workloads

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --vm-size TYPE              VM size (default: Standard_B2s)
    --vm-count NUM              Number of VMs (default: 3)
    --pricing-model MODEL       on-demand, reserved, or spot (default: on-demand)
    --reserved-term YEARS       Reserved term in years: 1 or 3 (default: 1)
    --reserved-payment PAYMENT  all-upfront, partial-upfront, no-upfront (default: partial-upfront)
    --os-disk-size-gb SIZE      OS disk size in GB (default: 30)
    --os-disk-type TYPE         managed disk type: Standard_LRS, StandardSSD_LRS, Premium_LRS, UltraSSD_LRS (default: StandardSSD_LRS)
    --data-disk-size-gb SIZE    Data disk size in GB (default: 0)
    --data-disk-type TYPE       Data managed disk type (default: StandardSSD_LRS)
    --data-disk-iops NUM        Data disk IOPS for UltraSSD (default: 0)
    --bandwidth-gb NUM          Monthly bandwidth in GB (default: 100)
    --lb-type TYPE              lb-type: basic, standard (default: standard)
    --lb-requests-million NUM   Monthly LB requests in millions (default: 10)
    --lb-rule-count NUM         Number of LB rules (default: 1)
    --config FILE               Load parameters from config file
    --json                      Output JSON format
    --help                      Show this help message

CONFIG FILE FORMAT (YAML-like):
    vm_size: Standard_B2s
    vm_count: 3
    pricing_model: on-demand
    reserved_term: 1
    reserved_payment: partial-upfront
    os_disk_size_gb: 30
    os_disk_type: StandardSSD_LRS
    data_disk_size_gb: 0
    data_disk_type: StandardSSD_LRS
    data_disk_iops: 0
    bandwidth_gb: 100
    lb_type: standard
    lb_requests_million: 10
    lb_rule_count: 1

EXAMPLES:
    $0 --vm-size Standard_D2s_v3 --vm-count 5 --reserved-term 3 --json
    $0 --config azure-config.yaml
    $0 --vm-size Standard_E2s_v3 --spot --json

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
                    vm_size) VM_SIZE="$value" ;;
                    vm_count) VM_COUNT="$value" ;;
                    pricing_model) PRICING_MODEL="$value" ;;
                    reserved_term) RESERVED_TERM="$value" ;;
                    reserved_payment) RESERVED_PAYMENT="$value" ;;
                    os_disk_size_gb) OS_DISK_SIZE_GB="$value" ;;
                    os_disk_type) OS_DISK_TYPE="$value" ;;
                    data_disk_size_gb) DATA_DISK_SIZE_GB="$value" ;;
                    data_disk_type) DATA_DISK_TYPE="$value" ;;
                    data_disk_iops) DATA_DISK_IOPS="$value" ;;
                    bandwidth_gb) BANDWIDTH_GB="$value" ;;
                    lb_type) LB_TYPE="$value" ;;
                    lb_requests_million) LB_REQUESTS_MILLION="$value" ;;
                    lb_rule_count) LB_RULE_COUNT="$value" ;;
                esac
            fi
        done < "$config_file"
    fi
}

calculate_vm_cost() {
    local vm_size="$1"
    local count="$2"
    local pricing_model="$3"
    local term="$4"
    local payment="$5"
    
    local vcpus=0
    local memory_gb=0
    local on_demand_hourly=0
    
    case "$vm_size" in
        Standard_B1s)
            vcpus=1
            memory_gb=1
            on_demand_hourly=0.0104
            ;;
        Standard_B2s)
            vcpus=2
            memory_gb=4
            on_demand_hourly=0.0416
            ;;
        Standard_B2ms)
            vcpus=2
            memory_gb=8
            on_demand_hourly=0.0832
            ;;
        Standard_B4ms)
            vcpus=4
            memory_gb=16
            on_demand_hourly=0.1664
            ;;
        Standard_B8ms)
            vcpus=8
            memory_gb=32
            on_demand_hourly=0.3328
            ;;
        Standard_D2s_v3)
            vcpus=2
            memory_gb=8
            on_demand_hourly=0.096
            ;;
        Standard_D4s_v3)
            vcpus=4
            memory_gb=16
            on_demand_hourly=0.192
            ;;
        Standard_D8s_v3)
            vcpus=8
            memory_gb=32
            on_demand_hourly=0.384
            ;;
        Standard_D16s_v3)
            vcpus=16
            memory_gb=64
            on_demand_hourly=0.768
            ;;
        Standard_D32s_v3)
            vcpus=32
            memory_gb=128
            on_demand_hourly=1.536
            ;;
        Standard_D2s_v4)
            vcpus=2
            memory_gb=8
            on_demand_hourly=0.086
            ;;
        Standard_D4s_v4)
            vcpus=4
            memory_gb=16
            on_demand_hourly=0.172
            ;;
        Standard_D8s_v4)
            vcpus=8
            memory_gb=32
            on_demand_hourly=0.344
            ;;
        Standard_E2s_v3)
            vcpus=2
            memory_gb=16
            on_demand_hourly=0.126
            ;;
        Standard_E4s_v3)
            vcpus=4
            memory_gb=32
            on_demand_hourly=0.252
            ;;
        Standard_E8s_v3)
            vcpus=8
            memory_gb=64
            on_demand_hourly=0.504
            ;;
        Standard_E16s_v3)
            vcpus=16
            memory_gb=128
            on_demand_hourly=1.008
            ;;
        Standard_E2s_v4)
            vcpus=2
            memory_gb=16
            on_demand_hourly=0.116
            ;;
        Standard_E4s_v4)
            vcpus=4
            memory_gb=32
            on_demand_hourly=0.232
            ;;
        Standard_E8s_v4)
            vcpus=8
            memory_gb=64
            on_demand_hourly=0.464
            ;;
        Standard_F2s_v2)
            vcpus=2
            memory_gb=4
            on_demand_hourly=0.084
            ;;
        Standard_F4s_v2)
            vcpus=4
            memory_gb=8
            on_demand_hourly=0.168
            ;;
        Standard_F8s_v2)
            vcpus=8
            memory_gb=16
            on_demand_hourly=0.336
            ;;
        Standard_F16s_v2)
            vcpus=16
            memory_gb=32
            on_demand_hourly=0.672
            ;;
        Standard_A1_v2)
            vcpus=1
            memory_gb=2
            on_demand_hourly=0.024
            ;;
        Standard_A2_v2)
            vcpus=2
            memory_gb=4
            on_demand_hourly=0.048
            ;;
        Standard_A4_v2)
            vcpus=4
            memory_gb=8
            on_demand_hourly=0.096
            ;;
        Standard_A8_v2)
            vcpus=8
            memory_gb=16
            on_demand_hourly=0.192
            ;;
        Standard_M8ms)
            vcpus=8
            memory_gb=224
            on_demand_hourly=0.94
            ;;
        Standard_M16ms)
            vcpus=16
            memory_gb=448
            on_demand_hourly=1.88
            ;;
        *)
            vcpus=2
            memory_gb=4
            on_demand_hourly=0.05
            ;;
    esac
    
    local hourly_rate=$on_demand_hourly
    
    if [[ "$pricing_model" == "reserved" ]]; then
        local discount=0
        case "$term" in
            1) discount=0.40 ;;
            3) discount=0.62 ;;
        esac
        
        case "$payment" in
            all-upfront) discount=$(calc "$discount + 0.12" ) ;;
            partial-upfront) discount=$(calc "$discount + 0.04" ) ;;
            no-upfront) ;;
        esac
        
        hourly_rate=$(calc "$on_demand_rate * (1 - $discount)"  2>/dev/null || echo "$on_demand_hourly * (1 - $discount)" )
    elif [[ "$pricing_model" == "spot" ]]; then
        local spot_discount=0.65
        hourly_rate=$(calc "$on_demand_hourly * (1 - $spot_discount)" )
    fi
    
    local monthly_hours=730
    local monthly_cost=$(calc "$hourly_rate * $monthly_hours * $count" )
    
    echo "$monthly_cost"
    echo "$hourly_rate"
    echo "$on_demand_hourly"
}

calculate_managed_disk_cost() {
    local size_gb="$1"
    local disk_type="$2"
    local iops="$3"
    
    local cost_per_gb=0
    
    case "$disk_type" in
        Standard_LRS)
            cost_per_gb=0.024
            ;;
        StandardSSD_LRS)
            cost_per_gb=0.038
            ;;
        Premium_LRS)
            cost_per_gb=0.08
            ;;
        UltraSSD_LRS)
            cost_per_gb=0.10
            ;;
    esac
    
    local storage_cost=$(calc "$size_gb * $cost_per_gb" )
    
    local iops_cost=0
    if [[ "$disk_type" == "UltraSSD_LRS" && "$iops" -gt 0 ]]; then
        iops_cost=$(calc "$iops * 0.000012" )
    fi
    
    local total=$(calc "$storage_cost + $iops_cost" )
    echo "$total"
}

calculate_bandwidth_cost() {
    local bandwidth_gb="$1"
    
    local cost=0
    
    if (( $(calc "$bandwidth_gb <= 5" ) )); then
        cost=0
    elif (( $(calc "$bandwidth_gb <= 1024" ) )); then
        cost=$(calc "($bandwidth_gb - 5) * 0.087" )
    elif (( $(calc "$bandwidth_gb <= 10240" ) )); then
        cost=$(calc "1019 * 0.087 + ($bandwidth_gb - 1024) * 0.083" )
    elif (( $(calc "$bandwidth_gb <= 51200" ) )); then
        cost=$(calc "1019 * 0.087 + 9216 * 0.083 + ($bandwidth_gb - 10240) * 0.07" )
    else
        cost=$(calc "1019 * 0.087 + 9216 * 0.083 + 40960 * 0.07 + ($bandwidth_gb - 51200) * 0.05" )
    fi
    
    echo "$cost"
}

calculate_lb_cost() {
    local lb_type="$1"
    local requests_million="$2"
    local rule_count="$3"
    
    local hourly_charge=0
    local data_charge=0
    
    case "$lb_type" in
        basic)
            hourly_charge=0.025
            ;;
        standard)
            hourly_charge=0.025
            data_charge=$(calc "$requests_million * 0.005" )
            ;;
    esac
    
    local hourly_monthly=$(calc "$hourly_charge * 730" )
    local rule_cost=$(calc "$rule_count * 0.01 * 730" )
    local total=$(calc "$hourly_monthly + $data_charge + $rule_cost" )
    
    echo "$total"
}

calculate_ri_break_even() {
    local on_demand_hourly="$1"
    local reserved_hourly="$2"
    local upfront_cost="$3"
    
    local hourly_savings=$(calc "$on_demand_hourly - $reserved_hourly" )
    
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
    "provider": "azure",
    "currency": "USD",
    "monthly_costs": {
        "virtual_machine": {
            "vm_size": "$VM_SIZE",
            "vm_count": $VM_COUNT,
            "pricing_model": "$PRICING_MODEL",
            "hourly_rate": $VM_HOURLY_RATE,
            "on_demand_hourly": $VM_ON_DEMAND_RATE,
            "monthly_cost": $VM_MONTHLY_COST
        },
        "os_disk": {
            "size_gb": $OS_DISK_SIZE_GB,
            "disk_type": "$OS_DISK_TYPE",
            "monthly_cost": $OS_DISK_COST
        },
        "data_disk": {
            "size_gb": $DATA_DISK_SIZE_GB,
            "disk_type": "$DATA_DISK_TYPE",
            "iops": $DATA_DISK_IOPS,
            "monthly_cost": $DATA_DISK_COST
        },
        "bandwidth": {
            "bandwidth_gb": $BANDWIDTH_GB,
            "monthly_cost": $BANDWIDTH_COST
        },
        "load_balancer": {
            "lb_type": "$LB_TYPE",
            "requests_million": $LB_REQUESTS_MILLION,
            "rule_count": $LB_RULE_COUNT,
            "monthly_cost": $LB_COST
        }
    },
    "total_monthly_cost": $TOTAL_MONTHLY_COST,
    "total_yearly_cost": $TOTAL_YEARLY_COST,
    "assumptions": {
        "hours_per_month": 730,
        "bandwidth_tiers": "Free: 5GB, Tier1: 5GB-1TB @ \$0.087/GB, Tier2: 1-10TB @ \$0.083/GB, Tier3: 10-50TB @ \$0.07/GB, Tier4: 50TB+ @ \$0.05/GB",
        "reserved_discount": "40-62% for reserved instances",
        "spot_discount": "65% for spot VMs"
    },
    "reserved_instance_analysis": {
        "on_demand_hourly": $VM_ON_DEMAND_RATE,
        "reserved_hourly": $VM_HOURLY_RATE,
        "monthly_savings": $MONTHLY_SAVINGS,
        "yearly_savings": $YEARLY_SAVINGS,
        "upfront_cost": $UPFRONT_COST,
        "break_even_days": $BREAK_EVEN_DAYS
    }
}
EOF
}

output_human_readable() {
    cat <<EOF
================================================================================
AZURE COST CALCULATION FOR PODMAN WORKLOADS
================================================================================

Virtual Machine Costs:
  VM Size:           $VM_SIZE
  VM Count:          $VM_COUNT
  Pricing Model:    $PRICING_MODEL
  Hourly Rate:      \$$(printf "%.4f" $VM_HOURLY_RATE) per VM
  Monthly Cost:     \$$(printf "%.2f" $VM_MONTHLY_COST)

OS Managed Disk:
  Disk Size:        $OS_DISK_SIZE_GB GB
  Disk Type:        $OS_DISK_TYPE
  Monthly Cost:     \$$(printf "%.2f" $OS_DISK_COST)

Data Managed Disk:
  Disk Size:        $DATA_DISK_SIZE_GB GB
  Disk Type:        $DATA_DISK_TYPE
  IOPS:             $DATA_DISK_IOPS
  Monthly Cost:     \$$(printf "%.2f" $DATA_DISK_COST)

Bandwidth Costs:
  Bandwidth:        $BANDWIDTH_GB GB/month
  Monthly Cost:     \$$(printf "%.2f" $BANDWIDTH_COST)

Load Balancer Costs:
  LB Type:          $LB_TYPE
  Requests:         $LB_REQUESTS_MILLION million/month
  Rule Count:      $LB_RULE_COUNT
  Monthly Cost:     \$$(printf "%.2f" $LB_COST)

================================================================================
TOTAL MONTHLY COST:  \$$(printf "%.2f" $TOTAL_MONTHLY_COST)
TOTAL YEARLY COST:   \$$(printf "%.2f" $TOTAL_YEARLY_COST)
================================================================================

$(if [[ "$PRICING_MODEL" == "reserved" ]]; then
cat <<RESERVED
Reserved Instance Analysis:
  On-Demand Rate:    \$$(printf "%.4f" $VM_ON_DEMAND_RATE)/hour
  Reserved Rate:     \$$(printf "%.4f" $VM_HOURLY_RATE)/hour
  Monthly Savings:   \$$(printf "%.2f" $MONTHLY_SAVINGS)
  Yearly Savings:    \$$(printf "%.2f" $YEARLY_SAVINGS)
  Upfront Cost:      \$$(printf "%.2f" $UPFRONT_COST)
  Break-Even:        $BREAK_EVEN_DAYS days

RESERVED
fi)
================================================================================
ASSUMPTIONS:
- 730 hours per month
- Bandwidth: tiered pricing (Free: 5GB, Tier1: \$0.087/GB, Tier2: \$0.083/GB, Tier3: \$0.07/GB, Tier4: \$0.05/GB)
- Reserved instances: 40% (1yr) to 62% (3yr) discount
- Spot VMs: 65% discount but may be evicted
- Standard Load Balancer includes data processing charges
- Prices are estimates and vary by Azure region
================================================================================
EOF
}

VM_SIZE="${vm_size:-Standard_B2s}"
VM_COUNT="${vm_count:-3}"
PRICING_MODEL="${pricing_model:-on-demand}"
RESERVED_TERM="${reserved_term:-1}"
RESERVED_PAYMENT="${reserved_payment:-partial-upfront}"
OS_DISK_SIZE_GB="${os_disk_size_gb:-30}"
OS_DISK_TYPE="${os_disk_type:-StandardSSD_LRS}"
DATA_DISK_SIZE_GB="${data_disk_size_gb:-0}"
DATA_DISK_TYPE="${data_disk_type:-StandardSSD_LRS}"
DATA_DISK_IOPS="${data_disk_iops:-0}"
BANDWIDTH_GB="${bandwidth_gb:-100}"
LB_TYPE="${lb_type:-standard}"
LB_REQUESTS_MILLION="${lb_requests_million:-10}"
LB_RULE_COUNT="${lb_rule_count:-1}"
OUTPUT_JSON=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vm-size)
            VM_SIZE="$2"
            shift 2
            ;;
        --vm-count)
            VM_COUNT="$2"
            shift 2
            ;;
        --pricing-model)
            PRICING_MODEL="$2"
            shift 2
            ;;
        --reserved-term)
            RESERVED_TERM="$2"
            shift 2
            ;;
        --reserved-payment)
            RESERVED_PAYMENT="$2"
            shift 2
            ;;
        --os-disk-size-gb)
            OS_DISK_SIZE_GB="$2"
            shift 2
            ;;
        --os-disk-type)
            OS_DISK_TYPE="$2"
            shift 2
            ;;
        --data-disk-size-gb)
            DATA_DISK_SIZE_GB="$2"
            shift 2
            ;;
        --data-disk-type)
            DATA_DISK_TYPE="$2"
            shift 2
            ;;
        --data-disk-iops)
            DATA_DISK_IOPS="$2"
            shift 2
            ;;
        --bandwidth-gb)
            BANDWIDTH_GB="$2"
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
        --lb-rule-count)
            LB_RULE_COUNT="$2"
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

VM_OUTPUT=($(calculate_vm_cost "$VM_SIZE" "$VM_COUNT" "$PRICING_MODEL" "$RESERVED_TERM" "$RESERVED_PAYMENT"))
VM_MONTHLY_COST="${VM_OUTPUT[0]}"
VM_HOURLY_RATE="${VM_OUTPUT[1]}"
VM_ON_DEMAND_RATE="${VM_OUTPUT[2]}"

OS_DISK_COST=$(calculate_managed_disk_cost "$OS_DISK_SIZE_GB" "$OS_DISK_TYPE" 0)
DATA_DISK_COST=$(calculate_managed_disk_cost "$DATA_DISK_SIZE_GB" "$DATA_DISK_TYPE" "$DATA_DISK_IOPS")
BANDWIDTH_COST=$(calculate_bandwidth_cost "$BANDWIDTH_GB")
LB_COST=$(calculate_lb_cost "$LB_TYPE" "$LB_REQUESTS_MILLION" "$LB_RULE_COUNT")

if [[ "$PRICING_MODEL" == "reserved" ]]; then
    MONTHLY_SAVINGS=$(calc "($VM_ON_DEMAND_RATE * 730 * $VM_COUNT) - $VM_MONTHLY_COST" )
    YEARLY_SAVINGS=$(calc "$MONTHLY_SAVINGS * 12" )
    
    case "$RESERVED_PAYMENT" in
        all-upfront)
            case "$RESERVED_TERM" in
                1) UPFRONT_COST=$(calc "$VM_ON_DEMAND_RATE * 730 * 12 * 0.48" ) ;;
                3) UPFRONT_COST=$(calc "$VM_ON_DEMAND_RATE * 730 * 36 * 0.26" ) ;;
            esac
            ;;
        partial-upfront)
            case "$RESERVED_TERM" in
                1) UPFRONT_COST=$(calc "$VM_ON_DEMAND_RATE * 730 * 12 * 0.16" ) ;;
                3) UPFRONT_COST=$(calc "$VM_ON_DEMAND_RATE * 730 * 36 * 0.08" ) ;;
            esac
            ;;
        no-upfront)
            UPFRONT_COST=0
            ;;
    esac
    
    BREAK_EVEN_DAYS=$(calculate_ri_break_even "$VM_ON_DEMAND_RATE" "$VM_HOURLY_RATE" "$UPFRONT_COST")
else
    MONTHLY_SAVINGS=0
    YEARLY_SAVINGS=0
    UPFRONT_COST=0
    BREAK_EVEN_DAYS=0
fi

TOTAL_MONTHLY_COST=$(calc "$VM_MONTHLY_COST + $OS_DISK_COST + $DATA_DISK_COST + $BANDWIDTH_COST + $LB_COST" )
TOTAL_YEARLY_COST=$(calc "$TOTAL_MONTHLY_COST * 12" )

if [[ "$OUTPUT_JSON" == "true" ]]; then
    output_json
else
    output_human_readable
fi
