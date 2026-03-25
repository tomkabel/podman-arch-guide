#!/usr/bin/env bash
# Growth Projector - Project capacity needs for Podman workloads
# Analyzes historical growth data and projects future infrastructure requirements

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

calc() {
    awk "BEGIN {printf \"%.2f\", $1}" 2>/dev/null || echo "0"
}

usage() {
    cat <<EOF
Growth Projector - Project capacity needs for Podman workloads

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --current-pods NUM          Current number of pods (default: 3)
    --current-cpu-cores NUM     Current CPU cores (default: 6)
    --current-memory-gb NUM     Current memory in GB (default: 16)
    --cpu-per-podcores NUM      CPU cores per pod (default: 0.5)
    --memory-per-podgb NUM      Memory per pod in GB (default: 1)
    --historical-growth FILE    Path to historical growth data CSV
    --growth-rate-pct NUM       Monthly growth rate % (default: 10)
    --growth-scenario SCENARIO  conservative, moderate, aggressive (default: moderate)
    --projection-months NUM     Months to project (default: 12)
    --cost-per-vcpu-hour NUM    Cost per vCPU per hour (default: 0.05)
    --cost-per-gb-hour NUM      Cost per GB memory per hour (default: 0.01)
    --json                      Output JSON format
    --help                      Show this help message

HISTORICAL GROWTH DATA FILE FORMAT (CSV):
    month,pods,cpu_cores,memory_gb
    2024-01,10,20,40
    2024-02,12,24,48
    2024-03,15,30,60

EXAMPLES:
    $0 --current-pods 5 --growth-rate-pct 15 --projection-months 24
    $0 --current-pods 10 --growth-scenario aggressive --json
    $0 --historical-growth growth-data.csv --json

EOF
    exit "${1:-0}"
}

parse_historical_data() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        echo "Error: Historical data file not found: $file" >&2
        return 1
    fi
    
    local pods_line=""
    local cores_line=""
    local memory_line=""
    
    pods_line=$(grep -E "^pods," "$file" 2>/dev/null || echo "")
    cores_line=$(grep -E "^cpu_cores," "$file" 2>/dev/null || echo "")
    memory_line=$(grep -E "^memory_gb," "$file" 2>/dev/null || echo "")
    
    if [[ -n "$pods_line" ]]; then
        local pods_data=$(echo "$pods_line" | cut -d',' -f2- | tr ',' ' ')
        local pods_arr=($pods_data)
        
        local total=0
        local count=${#pods_arr[@]}
        for val in "${pods_arr[@]}"; do
            total=$(echo "$total + $val" )
        done
        
        if [[ $count -gt 1 ]]; then
            local first=${pods_arr[0]}
            local last=${pods_arr[-1]}
            local growth=$(echo "($last - $first) / $first * 100 / $count" )
            GROWTH_RATE_PCT=$(printf "%.0f" "$growth")
        fi
    fi
}

calculate_compound_growth() {
    local current_value="$1"
    local rate_pct="$2"
    local months="$3"
    
    local rate=$(echo "$rate_pct / 100" )
    local result=$current_value
    
    for ((i=0; i<months; i++)); do
        result=$(echo "$result * (1 + $rate)" )
    done
    
    echo "$result"
}

calculate_linear_growth() {
    local current_value="$1"
    local rate_pct="$2"
    local months="$3"
    
    local monthly_increase=$(echo "$current_value * $rate_pct / 100" )
    local result=$(echo "$current_value + ($monthly_increase * $months)" )
    
    echo "$result"
}

calculate_growth_scenario() {
    local current_value="$1"
    local base_rate="$2"
    local months="$3"
    local scenario="$4"
    
    local rate_pct=$base_rate
    
    case "$scenario" in
        conservative)
            rate_pct=$(echo "$base_rate * 0.5" )
            ;;
        aggressive)
            rate_pct=$(echo "$base_rate * 1.5" )
            ;;
        moderate|*)
            rate_pct=$base_rate
            ;;
    esac
    
    calculate_compound_growth "$current_value" "$rate_pct" "$months"
}

generate_timeline() {
    local current_pods="$1"
    local rate_pct="$2"
    local months="$3"
    local scenario="$4"
    
    local rate=$rate_pct
    case "$scenario" in
        conservative) rate=$(echo "$rate_pct * 0.5" ) ;;
        aggressive) rate=$(echo "$rate_pct * 1.5" ) ;;
    esac
    
    local current=$current_pods
    
    echo "Month,Pods,CPU_Cores,Memory_GB,Estimated_Cost"
    
    for ((i=0; i<=months; i++)); do
        local cpu=$(echo "$current * $CPU_PER_POD" )
        local memory=$(echo "$current * $MEMORY_PER_POD" )
        local cost=$(echo "$current * ($CPU_PER_POD * $COST_PER_VCPU_HOUR + $MEMORY_PER_POD * $COST_PER_GB_HOUR) * 730" )
        
        echo "$i,$(printf "%.1f" $current),$(printf "%.1f" $cpu),$(printf "%.1f" $memory),\$$(printf "%.2f" $cost)"
        
        current=$(echo "$current * (1 + $rate / 100)" )
    done
}

calculate_infrastructure_journey() {
    local current_pods="$1"
    local current_cpu="$2"
    local current_memory="$3"
    local target_pods="$4"
    local cpu_per_pod="$5"
    local memory_per_pod="$6"
    
    local needed_cpu=$(echo "$target_pods * $cpu_per_pod" )
    local needed_memory=$(echo "$target_pods * $memory_per_pod" )
    
    local cpu_ratio=$(echo "$needed_cpu / $current_cpu" )
    local memory_ratio=$(echo "$needed_memory / $current_memory" )
    
    local scaling_events=1
    if (( $(echo "$cpu_ratio > 2" ) )); then
        scaling_events=2
    fi
    if (( $(echo "$cpu_ratio > 4" ) )); then
        scaling_events=3
    fi
    if (( $(echo "$cpu_ratio > 8" ) )); then
        scaling_events=4
    fi
    
    echo "$scaling_events"
}

output_json() {
    cat <<EOF
{
    "tool": "growth-projector",
    "current_state": {
        "pods": $CURRENT_PODS,
        "cpu_cores": $CURRENT_CPU_CORES,
        "memory_gb": $CURRENT_MEMORY_GB,
        "cpu_per_pod": $CPU_PER_POD,
        "memory_per_pod": $MEMORY_PER_POD
    },
    "growth_assumptions": {
        "base_growth_rate": $GROWTH_RATE_PCT,
        "scenario": "$GROWTH_SCENARIO",
        "cost_per_vcpu_hour": $COST_PER_VCPU_HOUR,
        "cost_per_gb_hour": $COST_PER_GB_HOUR
    },
    "projections": {
        "6_months": {
            "pods": $(printf "%.1f" $PROJECTED_PODS_6MO),
            "cpu_cores_needed": $(printf "%.1f" $(echo "$PROJECTED_PODS_6MO * $CPU_PER_POD" )),
            "memory_gb_needed": $(printf "%.1f" $(echo "$PROJECTED_PODS_6MO * $MEMORY_PER_POD" )),
            "monthly_cost": $(printf "%.2f" $COST_6MO),
            "cumulative_cost": $(printf "%.2f" $CUMULATIVE_COST_6MO)
        },
        "12_months": {
            "pods": $(printf "%.1f" $PROJECTED_PODS_12MO),
            "cpu_cores_needed": $(printf "%.1f" $(echo "$PROJECTED_PODS_12MO * $CPU_PER_POD" )),
            "memory_gb_needed": $(printf "%.1f" $(echo "$PROJECTED_PODS_12MO * $MEMORY_PER_POD" )),
            "monthly_cost": $(printf "%.2f" $COST_12MO),
            "cumulative_cost": $(printf "%.2f" $CUMULATIVE_COST_12MO)
        },
        "36_months": {
            "pods": $(printf "%.1f" $PROJECTED_PODS_36MO),
            "cpu_cores_needed": $(printf "%.1f" $(echo "$PROJECTED_PODS_36MO * $CPU_PER_POD" )),
            "memory_gb_needed": $(printf "%.1f" $(echo "$PROJECTED_PODS_36MO * $MEMORY_PER_POD" )),
            "monthly_cost": $(printf "%.2f" $COST_36MO),
            "cumulative_cost": $(printf "%.2f" $CUMULATIVE_COST_36MO)
        }
    },
    "infrastructure_journey": {
        "scaling_events_to_12mo": $SCALING_EVENTS,
        "recommendations": [
            "Plan for capacity increase starting month 3",
            "Consider reserved capacity for baseline pods",
            "Monitor actual growth vs projected for adjustments"
        ]
    }
}
EOF
}

output_human_readable() {
    cat <<EOF
================================================================================
GROWTH PROJECTOR - PODMAN WORKLOAD CAPACITY PROJECTIONS
================================================================================

Current State:
  Pods:         $CURRENT_PODS
  CPU Cores:    $CURRENT_CPU_CORES
  Memory:       $CURRENT_MEMORY_GB GB
  CPU per Pod:  $CPU_PER_POD cores
  Memory/Pod:   $MEMORY_PER_POD GB

Growth Assumptions:
  Base Growth Rate: $GROWTH_RATE_PCT% per month
  Scenario:        $GROWTH_SCENARIO

================================================================================
CAPACITY PROJECTIONS
================================================================================

6 MONTHS:
  Target Pods:      $(printf "%.1f" $PROJECTED_PODS_6MO)
  CPU Cores Needed:  $(printf "%.1f" $(echo "$PROJECTED_PODS_6MO * $CPU_PER_POD" ))
  Memory Needed:     $(printf "%.1f" $(echo "$PROJECTED_PODS_6MO * $MEMORY_PER_POD" )) GB
  Monthly Cost:     \$$(printf "%.2f" $COST_6MO)
  Cumulative Cost:   \$$(printf "%.2f" $CUMULATIVE_COST_6MO)

12 MONTHS:
  Target Pods:      $(printf "%.1f" $PROJECTED_PODS_12MO)
  CPU Cores Needed:  $(printf "%.1f" $(echo "$PROJECTED_PODS_12MO * $CPU_PER_POD" ))
  Memory Needed:     $(printf "%.1f" $(echo "$PROJECTED_PODS_12MO * $MEMORY_PER_POD" )) GB
  Monthly Cost:     \$$(printf "%.2f" $COST_12MO)
  Cumulative Cost:   \$$(printf "%.2f" $CUMULATIVE_COST_12MO)

36 MONTHS:
  Target Pods:      $(printf "%.1f" $PROJECTED_PODS_36MO)
  CPU Cores Needed:  $(printf "%.1f" $(echo "$PROJECTED_PODS_36MO * $CPU_PER_POD" ))
  Memory Needed:     $(printf "%.1f" $(echo "$PROJECTED_PODS_36MO * $MEMORY_PER_POD" )) GB
  Monthly Cost:     \$$(printf "%.2f" $COST_36MO)
  Cumulative Cost:   \$$(printf "%.2f" $CUMULATIVE_COST_36MO)

================================================================================
INFRASTRUCTURE JOURNEY
================================================================================

Scaling Events to 12 Months: $SCALING_EVENTS

$(generate_timeline "$CURRENT_PODS" "$GROWTH_RATE_PCT" 12 "$GROWTH_SCENARIO")

================================================================================
RECOMMENDATIONS
================================================================================

1. Short-term (0-6 months):
   - Current capacity should handle growth
   - Monitor usage and adjust HPA thresholds if needed

2. Medium-term (6-12 months):
   - Plan for additional node(s) around month 6-8
   - Consider reserved instances for baseline capacity

3. Long-term (12+ months):
   - $(if [[ $SCALING_EVENTS -ge 3 ]]; then
   echo "Significant scaling required - consider multi-node cluster architecture"
   else
   echo "Moderate growth - standard scaling should suffice"
   fi)
   - Evaluate managed Kubernetes vs self-hosted

4. Cost Optimization:
   - Use spot/preemptible for non-production pods
   - Reserve baseline capacity with committed use discounts
   - Implement auto-scaling to match demand

================================================================================
NOTES
================================================================================
- Projections assume consistent growth rate
- Actual growth may vary - review projections quarterly
- Add 20% buffer to projected capacity for safety
- Consider geographic distribution for high availability
EOF
}

CURRENT_PODS=3
CURRENT_CPU_CORES=6
CURRENT_MEMORY_GB=16
CPU_PER_POD=0.5
MEMORY_PER_POD=1
HISTORICAL_GROWTH_FILE=""
GROWTH_RATE_PCT=10
GROWTH_SCENARIO="moderate"
PROJECTION_MONTHS=12
COST_PER_VCPU_HOUR=0.05
COST_PER_GB_HOUR=0.01
OUTPUT_JSON=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --current-pods)
            CURRENT_PODS="$2"
            shift 2
            ;;
        --current-cpu-cores)
            CURRENT_CPU_CORES="$2"
            shift 2
            ;;
        --current-memory-gb)
            CURRENT_MEMORY_GB="$2"
            shift 2
            ;;
        --cpu-per-podcores)
            CPU_PER_POD="$2"
            shift 2
            ;;
        --memory-per-podgb)
            MEMORY_PER_POD="$2"
            shift 2
            ;;
        --historical-growth)
            HISTORICAL_GROWTH_FILE="$2"
            shift 2
            ;;
        --growth-rate-pct)
            GROWTH_RATE_PCT="$2"
            shift 2
            ;;
        --growth-scenario)
            GROWTH_SCENARIO="$2"
            shift 2
            ;;
        --projection-months)
            PROJECTION_MONTHS="$2"
            shift 2
            ;;
        --cost-per-vcpu-hour)
            COST_PER_VCPU_HOUR="$2"
            shift 2
            ;;
        --cost-per-gb-hour)
            COST_PER_GB_HOUR="$2"
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

if [[ -n "$HISTORICAL_GROWTH_FILE" ]]; then
    parse_historical_data "$HISTORICAL_GROWTH_FILE"
fi

PROJECTED_PODS_6MO=$(calculate_growth_scenario "$CURRENT_PODS" "$GROWTH_RATE_PCT" 6 "$GROWTH_SCENARIO")
PROJECTED_PODS_12MO=$(calculate_growth_scenario "$CURRENT_PODS" "$GROWTH_RATE_PCT" 12 "$GROWTH_SCENARIO")
PROJECTED_PODS_36MO=$(calculate_growth_scenario "$CURRENT_PODS" "$GROWTH_RATE_PCT" 36 "$GROWTH_SCENARIO")

estimate_cost() {
    local pod_count="$1"
    local cost_per_vcpu="$2"
    local cost_per_gb="$3"
    
    local monthly=$(echo "$pod_count * ($CPU_PER_POD * $cost_per_vcpu + $MEMORY_PER_POD * $cost_per_gb) * 730" )
    echo "$monthly"
}

COST_6MO=$(estimate_cost "$PROJECTED_PODS_6MO" "$COST_PER_VCPU_HOUR" "$COST_PER_GB_HOUR")
COST_12MO=$(estimate_cost "$PROJECTED_PODS_12MO" "$COST_PER_VCPU_HOUR" "$COST_PER_GB_HOUR")
COST_36MO=$(estimate_cost "$PROJECTED_PODS_36MO" "$COST_PER_VCPU_HOUR" "$COST_PER_GB_HOUR")

current_cost=$(estimate_cost "$CURRENT_PODS" "$COST_PER_VCPU_HOUR" "$COST_PER_GB_HOUR")
CUMULATIVE_COST_6MO=$(echo "$current_cost * 6" )
CUMULATIVE_COST_12MO=$(echo "$current_cost * 12" )

cumulative_12mo=0
for ((i=1; i<=12; i++)); do
    pods=$(calculate_growth_scenario "$CURRENT_PODS" "$GROWTH_RATE_PCT" "$i" "$GROWTH_SCENARIO")
    cost=$(estimate_cost "$pods" "$COST_PER_VCPU_HOUR" "$COST_PER_GB_HOUR")
    cumulative_12mo=$(echo "$cumulative_12mo + $cost" )
done
CUMULATIVE_COST_12MO=$cumulative_12mo

cumulative_36mo=0
for ((i=1; i<=36; i++)); do
    pods=$(calculate_growth_scenario "$CURRENT_PODS" "$GROWTH_RATE_PCT" "$i" "$GROWTH_SCENARIO")
    cost=$(estimate_cost "$pods" "$COST_PER_VCPU_HOUR" "$COST_PER_GB_HOUR")
    cumulative_36mo=$(echo "$cumulative_36mo + $cost" )
done
CUMULATIVE_COST_36MO=$cumulative_36mo

SCALING_EVENTS=$(calculate_infrastructure_journey "$CURRENT_PODS" "$CURRENT_CPU_CORES" "$CURRENT_MEMORY_GB" "$PROJECTED_PODS_12MO" "$CPU_PER_POD" "$MEMORY_PER_POD")

if [[ "$OUTPUT_JSON" == "true" ]]; then
    output_json
else
    output_human_readable
fi
