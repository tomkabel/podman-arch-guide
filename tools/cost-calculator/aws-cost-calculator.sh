#!/usr/bin/env bash
# AWS Cost Calculator for Podman Workloads
# Calculates AWS costs including EC2, EBS, NAT Gateway, Load Balancer, and Support

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-}"

calc() {
    local val="$1"
    awk "BEGIN {printf \"%.6f\", $val}" 2>/dev/null || echo "0"
}

calc_round() {
    local val="$1"
    awk "BEGIN {printf \"%.2f\", $val}" 2>/dev/null || echo "0"
}

calc_int() {
    local val="$1"
    awk "BEGIN {printf \"%.0f\", $val}" 2>/dev/null || echo "0"
}

usage() {
    cat <<EOF
AWS Cost Calculator for Podman Workloads

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --instance-type TYPE          EC2 instance type (default: t3.medium)
    --instance-count NUM          Number of instances (default: 3)
    --pricing-model MODEL        on-demand, reserved, or spot (default: on-demand)
    --reserved-term YEARS        Reserved term in years: 1 or 3 (default: 1)
    --reserved-payment PAYMENT   all-upfront, partial-upfront, no-upfront (default: partial-upfront)
    --ebs-size-gb SIZE           EBS root volume size in GB (default: 30)
    --ebs-volume-type TYPE       gp2, gp3, io1, io2, st1, sc1 (default: gp3)
    --ebs-iops NUM               EBS IOPS for io1/io2/gp3 (default: 3000)
    --data-transfer-gb NUM       Monthly data transfer in GB (default: 100)
    --nat-gateway-gb NUM         NAT Gateway data processing in GB (default: 100)
    --lb-type TYPE               alb, nlb, or clb (default: alb)
    --lb-requests-million NUM    Monthly load balancer requests in millions (default: 10)
    --support-tier TIER          basic, developer, business, enterprise (default: business)
    --config FILE                Load parameters from config file
    --json                       Output JSON format
    --help                       Show this help message

CONFIG FILE FORMAT (YAML-like):
    instance_type: t3.medium
    instance_count: 3
    pricing_model: on-demand
    reserved_term: 1
    reserved_payment: partial-upfront
    ebs_size_gb: 30
    ebs_volume_type: gp3
    ebs_iops: 3000
    data_transfer_gb: 100
    nat_gateway_gb: 100
    lb_type: alb
    lb_requests_million: 10
    support_tier: business

EXAMPLES:
    $0 --instance-type t3.large --instance-count 5 --pricing-model reserved
    $0 --config aws-config.yaml --json
    $0 --instance-type m5.xlarge --spot --json

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
                    reserved_term) RESERVED_TERM="$value" ;;
                    reserved_payment) RESERVED_PAYMENT="$value" ;;
                    ebs_size_gb) EBS_SIZE_GB="$value" ;;
                    ebs_volume_type) EBS_VOLUME_TYPE="$value" ;;
                    ebs_iops) EBS_IOPS="$value" ;;
                    data_transfer_gb) DATA_TRANSFER_GB="$value" ;;
                    nat_gateway_gb) NAT_GATEWAY_GB="$value" ;;
                    lb_type) LB_TYPE="$value" ;;
                    lb_requests_million) LB_REQUESTS_MILLION="$value" ;;
                    support_tier) SUPPORT_TIER="$value" ;;
                esac
            fi
        done < "$config_file"
    fi
}

calculate_ec2_cost() {
    local instance_type="$1"
    local count="$2"
    local pricing_model="$3"
    local term="$4"
    local payment="$5"
    
    local hourly_rate=0
    local on_demand_rate=0
    
    case "$instance_type" in
        t3.micro)
            on_demand_rate=0.0104
            ;;
        t3.small)
            on_demand_rate=0.0208
            ;;
        t3.medium)
            on_demand_rate=0.0416
            ;;
        t3.large)
            on_demand_rate=0.0832
            ;;
        t3.xlarge)
            on_demand_rate=0.1664
            ;;
        t3.2xlarge)
            on_demand_rate=0.3328
            ;;
        m5.metal)
            on_demand_rate=0.768
            ;;
        m5.xlarge)
            on_demand_rate=0.192
            ;;
        m5.large)
            on_demand_rate=0.096
            ;;
        m5.medium)
            on_demand_rate=0.048
            ;;
        m5.small)
            on_demand_rate=0.024
            ;;
        m5n.xlarge)
            on_demand_rate=0.23
            ;;
        m5n.large)
            on_demand_rate=0.115
            ;;
        c5.xlarge)
            on_demand_rate=0.17
            ;;
        c5.large)
            on_demand_rate=0.085
            ;;
        c5.medium)
            on_demand_rate=0.0425
            ;;
        c5n.xlarge)
            on_demand_rate=0.204
            ;;
        c5n.large)
            on_demand_rate=0.102
            ;;
        r5.xlarge)
            on_demand_rate=0.252
            ;;
        r5.large)
            on_demand_rate=0.126
            ;;
        r5.medium)
            on_demand_rate=0.063
            ;;
        i3.xlarge)
            on_demand_rate=0.312
            ;;
        i3.large)
            on_demand_rate=0.156
            ;;
        p3.2xlarge)
            on_demand_rate=3.06
            ;;
        p3.8xlarge)
            on_demand_rate=12.24
            ;;
        g4dn.xlarge)
            on_demand_rate=0.526
            ;;
        g4dn.2xlarge)
            on_demand_rate=0.752
            ;;
        *)
            on_demand_rate=0.05
            ;;
    esac
    
    hourly_rate=$on_demand_rate
    
    if [[ "$pricing_model" == "reserved" ]]; then
        local discount=0
        case "$term" in
            1) discount=0.37 ;;
            3) discount=0.60 ;;
        esac
        
        case "$payment" in
            all-upfront) discount=$(awk "BEGIN {print $discount + 0.15}") ;;
            partial-upfront) discount=$(awk "BEGIN {print $discount + 0.05}") ;;
            no-upfront) ;;
        esac
        
        hourly_rate=$(awk "BEGIN {print $on_demand_rate * (1 - $discount)}")
    elif [[ "$pricing_model" == "spot" ]]; then
        local spot_discount=0.70
        hourly_rate=$(awk "BEGIN {print $on_demand_rate * (1 - $spot_discount)}")
    fi
    
    local monthly_hours=730
    local monthly_cost=$(awk "BEGIN {print $hourly_rate * $monthly_hours * $count}")
    
    echo "$monthly_cost"
    echo "$hourly_rate"
}

calculate_ebs_cost() {
    local size_gb="$1"
    local volume_type="$2"
    local iops="$3"
    
    local storage_cost=0
    local iops_cost=0
    
    case "$volume_type" in
        gp3)
            storage_cost=$(calc "$size_gb * 0.08" )
            if [[ "$iops" -gt 3000 ]]; then
                iops_cost=$(calc "($iops - 3000) * 0.005" )
            fi
            ;;
        gp2)
            storage_cost=$(calc "$size_gb * 0.10" )
            ;;
        io1)
            storage_cost=$(calc "$size_gb * 0.125" )
            iops_cost=$(calc "$iops * 0.065" )
            ;;
        io2)
            storage_cost=$(calc "$size_gb * 0.10" )
            iops_cost=$(calc "$iops * 0.045" )
            ;;
        st1)
            storage_cost=$(calc "$size_gb * 0.045" )
            ;;
        sc1)
            storage_cost=$(calc "$size_gb * 0.025" )
            ;;
    esac
    
    local total=$(calc "$storage_cost + $iops_cost" )
    echo "$total"
}

calculate_data_transfer_cost() {
    local data_gb="$1"
    local cost_per_gb=0.09
    
    local total=$(calc "$data_gb * $cost_per_gb" )
    echo "$total"
}

calculate_nat_gateway_cost() {
    local data_gb="$1"
    
    local hourly_charge=0.045
    local data_processing=$(calc "$data_gb * 0.045" )
    local hourly_monthly=$(calc "$hourly_charge * 730" )
    local total=$(calc "$hourly_monthly + $data_processing" )
    
    echo "$total"
}

calculate_lb_cost() {
    local lb_type="$1"
    local requests_million="$2"
    
    local hourly_charge=0
    local request_cost=0
    
    case "$lb_type" in
        alb)
            hourly_charge=0.0225
            request_cost=$(calc "$requests_million * 0.008" )
            ;;
        nlb)
            hourly_charge=0.0225
            request_cost=0
            ;;
        clb)
            hourly_charge=0.025
            request_cost=$(calc "$requests_million * 0.008" )
            ;;
    esac
    
    local hourly_monthly=$(calc "$hourly_charge * 730" )
    local total=$(calc "$hourly_monthly + $request_cost" )
    
    echo "$total"
}

calculate_support_cost() {
    local support_tier="$1"
    local monthly_usage="$2"
    
    local cost=0
    local percentage=0
    
    case "$support_tier" in
        basic)
            cost=0
            ;;
        developer)
            percentage=0.03
            cost=100
            ;;
        business)
            percentage=0.03
            if [[ $(calc "$monthly_usage < 10000" ) -eq 1 ]]; then
                cost=100
            elif [[ $(calc "$monthly_usage < 50000" ) -eq 1 ]]; then
                cost=300
            elif [[ $(calc "$monthly_usage < 250000" ) -eq 1 ]]; then
                cost=1500
            else
                cost=5000
            fi
            ;;
        enterprise)
            percentage=0.03
            cost=15000
            ;;
    esac
    
    local usage_cost=$(calc "$monthly_usage * $percentage" )
    local total=$(calc "$cost + $usage_cost" )
    
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
    "provider": "aws",
    "currency": "USD",
    "monthly_costs": {
        "ec2": {
            "instance_type": "$INSTANCE_TYPE",
            "instance_count": $INSTANCE_COUNT,
            "pricing_model": "$PRICING_MODEL",
            "hourly_rate": $EC2_HOURLY_RATE,
            "monthly_cost": $EC2_MONTHLY_COST
        },
        "ebs": {
            "size_gb": $EBS_SIZE_GB,
            "volume_type": "$EBS_VOLUME_TYPE",
            "iops": $EBS_IOPS,
            "monthly_cost": $EBS_MONTHLY_COST
        },
        "data_transfer": {
            "data_gb": $DATA_TRANSFER_GB,
            "monthly_cost": $DATA_TRANSFER_COST
        },
        "nat_gateway": {
            "data_gb": $NAT_GATEWAY_GB,
            "monthly_cost": $NAT_GATEWAY_COST
        },
        "load_balancer": {
            "lb_type": "$LB_TYPE",
            "requests_million": $LB_REQUESTS_MILLION,
            "monthly_cost": $LB_COST
        },
        "support": {
            "tier": "$SUPPORT_TIER",
            "monthly_cost": $SUPPORT_COST
        }
    },
    "total_monthly_cost": $TOTAL_MONTHLY_COST,
    "total_yearly_cost": $TOTAL_YEARLY_COST,
    "assumptions": {
        "hours_per_month": 730,
        "pricing_model": "$PRICING_MODEL",
        "data_transfer_rate_per_gb": 0.09,
        "nat_gateway_hourly": 0.045,
        "nat_gateway_data_rate_per_gb": 0.045,
        "support_percentage": 0.03
    },
    "reserved_instance_analysis": {
        "on_demand_hourly": $ON_DEMAND_RATE,
        "reserved_hourly": $EC2_HOURLY_RATE,
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
AWS COST CALCULATION FOR PODMAN WORKLOADS
================================================================================

EC2 Instance Costs:
  Instance Type:     $INSTANCE_TYPE
  Instance Count:    $INSTANCE_COUNT
  Pricing Model:     $PRICING_MODEL
  Hourly Rate:       \$$(printf "%.4f" $EC2_HOURLY_RATE) per instance
  Monthly Cost:      \$$(printf "%.2f" $EC2_MONTHLY_COST)

EBS Storage Costs:
  Volume Size:       $EBS_SIZE_GB GB
  Volume Type:       $EBS_VOLUME_TYPE
  IOPS:              $EBS_IOPS
  Monthly Cost:      \$$(printf "%.2f" $EBS_MONTHLY_COST)

Data Transfer Costs:
  Data Transfer:     $DATA_TRANSFER_GB GB
  Monthly Cost:      \$$(printf "%.2f" $DATA_TRANSFER_COST)

NAT Gateway Costs:
  Data Processed:    $NAT_GATEWAY_GB GB
  Monthly Cost:      \$$(printf "%.2f" $NAT_GATEWAY_COST)

Load Balancer Costs:
  LB Type:           $LB_TYPE
  Requests:          $LB_REQUESTS_MILLION million/month
  Monthly Cost:      \$$(printf "%.2f" $LB_COST)

Support Costs:
  Tier:              $SUPPORT_TIER
  Monthly Cost:      \$$(printf "%.2f" $SUPPORT_COST)

================================================================================
TOTAL MONTHLY COST:  \$$(printf "%.2f" $TOTAL_MONTHLY_COST)
TOTAL YEARLY COST:   \$$(printf "%.2f" $TOTAL_YEARLY_COST)
================================================================================

Reserved Instance Analysis (Comparison with On-Demand):
  On-Demand Rate:    \$$(printf "%.4f" $ON_DEMAND_RATE)/hour
  Reserved Rate:     \$$(printf "%.4f" $EC2_HOURLY_RATE)/hour
  Monthly Savings:   \$$(printf "%.2f" $MONTHLY_SAVINGS)
  Yearly Savings:    \$$(printf "%.2f" $YEARLY_SAVINGS)
  Upfront Cost:      \$$(printf "%.2f" $UPFRONT_COST)
  Break-Even:        $BREAK_EVEN_DAYS days

================================================================================
ASSUMPTIONS:
- 730 hours per month
- Data transfer: \$0.09/GB (varies by region)
- NAT Gateway: \$0.045/hour + \$0.045/GB data processing
- ALB: \$0.0225/hour + \$0.008/million requests
- Support: varies by tier (3% of monthly usage for Business+)
- Prices are estimates and vary by AWS region
================================================================================
EOF
}

INSTANCE_TYPE="${instance_type:-t3.medium}"
INSTANCE_COUNT="${instance_count:-3}"
PRICING_MODEL="${pricing_model:-on-demand}"
RESERVED_TERM="${reserved_term:-1}"
RESERVED_PAYMENT="${reserved_payment:-partial-upfront}"
EBS_SIZE_GB="${ebs_size_gb:-30}"
EBS_VOLUME_TYPE="${ebs_volume_type:-gp3}"
EBS_IOPS="${ebs_iops:-3000}"
DATA_TRANSFER_GB="${data_transfer_gb:-100}"
NAT_GATEWAY_GB="${nat_gateway_gb:-100}"
LB_TYPE="${lb_type:-alb}"
LB_REQUESTS_MILLION="${lb_requests_million:-10}"
SUPPORT_TIER="${support_tier:-business}"
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
        --reserved-term)
            RESERVED_TERM="$2"
            shift 2
            ;;
        --reserved-payment)
            RESERVED_PAYMENT="$2"
            shift 2
            ;;
        --ebs-size-gb)
            EBS_SIZE_GB="$2"
            shift 2
            ;;
        --ebs-volume-type)
            EBS_VOLUME_TYPE="$2"
            shift 2
            ;;
        --ebs-iops)
            EBS_IOPS="$2"
            shift 2
            ;;
        --data-transfer-gb)
            DATA_TRANSFER_GB="$2"
            shift 2
            ;;
        --nat-gateway-gb)
            NAT_GATEWAY_GB="$2"
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
        --support-tier)
            SUPPORT_TIER="$2"
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

EC2_OUTPUT=($(calculate_ec2_cost "$INSTANCE_TYPE" "$INSTANCE_COUNT" "$PRICING_MODEL" "$RESERVED_TERM" "$RESERVED_PAYMENT"))
EC2_MONTHLY_COST="${EC2_OUTPUT[0]}"
EC2_HOURLY_RATE="${EC2_OUTPUT[1]}"

ON_DEMAND_RATE=0
case "$INSTANCE_TYPE" in
    t3.micro) ON_DEMAND_RATE=0.0104 ;;
    t3.small) ON_DEMAND_RATE=0.0208 ;;
    t3.medium) ON_DEMAND_RATE=0.0416 ;;
    t3.large) ON_DEMAND_RATE=0.0832 ;;
    t3.xlarge) ON_DEMAND_RATE=0.1664 ;;
    t3.2xlarge) ON_DEMAND_RATE=0.3328 ;;
    m5.xlarge) ON_DEMAND_RATE=0.192 ;;
    m5.large) ON_DEMAND_RATE=0.096 ;;
    m5.medium) ON_DEMAND_RATE=0.048 ;;
    m5.small) ON_DEMAND_RATE=0.024 ;;
    m5n.xlarge) ON_DEMAND_RATE=0.23 ;;
    m5n.large) ON_DEMAND_RATE=0.115 ;;
    c5.xlarge) ON_DEMAND_RATE=0.17 ;;
    c5.large) ON_DEMAND_RATE=0.085 ;;
    c5.medium) ON_DEMAND_RATE=0.0425 ;;
    c5n.xlarge) ON_DEMAND_RATE=0.204 ;;
    c5n.large) ON_DEMAND_RATE=0.102 ;;
    r5.xlarge) ON_DEMAND_RATE=0.252 ;;
    r5.large) ON_DEMAND_RATE=0.126 ;;
    r5.medium) ON_DEMAND_RATE=0.063 ;;
    i3.xlarge) ON_DEMAND_RATE=0.312 ;;
    i3.large) ON_DEMAND_RATE=0.156 ;;
    p3.2xlarge) ON_DEMAND_RATE=3.06 ;;
    p3.8xlarge) ON_DEMAND_RATE=12.24 ;;
    g4dn.xlarge) ON_DEMAND_RATE=0.526 ;;
    g4dn.2xlarge) ON_DEMAND_RATE=0.752 ;;
    *) ON_DEMAND_RATE=0.05 ;;
esac

MONTHLY_SAVINGS=$(calc "($ON_DEMAND_RATE * 730 * $INSTANCE_COUNT) - $EC2_MONTHLY_COST" )
YEARLY_SAVINGS=$(calc "$MONTHLY_SAVINGS * 12" )

if [[ "$PRICING_MODEL" == "reserved" ]]; then
    case "$RESERVED_PAYMENT" in
        all-upfront)
            case "$RESERVED_TERM" in
                1) UPFRONT_COST=$(calc "$ON_DEMAND_RATE * 730 * 12 * 0.55" ) ;;
                3) UPFRONT_COST=$(calc "$ON_DEMAND_RATE * 730 * 36 * 0.40" ) ;;
            esac
            ;;
        partial-upfront)
            case "$RESERVED_TERM" in
                1) UPFRONT_COST=$(calc "$ON_DEMAND_RATE * 730 * 12 * 0.20" ) ;;
                3) UPFRONT_COST=$(calc "$ON_DEMAND_RATE * 730 * 36 * 0.15" ) ;;
            esac
            ;;
        no-upfront)
            UPFRONT_COST=0
            ;;
    esac
else
    UPFRONT_COST=0
fi

BREAK_EVEN_DAYS=$(calculate_ri_break_even "$ON_DEMAND_RATE" "$EC2_HOURLY_RATE" "$UPFRONT_COST")

EBS_MONTHLY_COST=$(calculate_ebs_cost "$EBS_SIZE_GB" "$EBS_VOLUME_TYPE" "$EBS_IOPS")
DATA_TRANSFER_COST=$(calculate_data_transfer_cost "$DATA_TRANSFER_GB")
NAT_GATEWAY_COST=$(calculate_nat_gateway_cost "$NAT_GATEWAY_GB")
LB_COST=$(calculate_lb_cost "$LB_TYPE" "$LB_REQUESTS_MILLION")

TOTAL_BEFORE_SUPPORT=$(calc "$EC2_MONTHLY_COST + $EBS_MONTHLY_COST + $DATA_TRANSFER_COST + $NAT_GATEWAY_COST + $LB_COST" )
SUPPORT_COST=$(calculate_support_cost "$SUPPORT_TIER" "$TOTAL_BEFORE_SUPPORT")

TOTAL_MONTHLY_COST=$(calc "$TOTAL_BEFORE_SUPPORT + $SUPPORT_COST" )
TOTAL_YEARLY_COST=$(calc "$TOTAL_MONTHLY_COST * 12" )

if [[ "$OUTPUT_JSON" == "true" ]]; then
    output_json
else
    output_human_readable
fi
