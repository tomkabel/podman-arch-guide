#!/usr/bin/env bash
# Scale Planner - Calculate scaling thresholds for Podman workloads
# Determines when to scale horizontally based on resource usage

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

calc() {
    awk "BEGIN {printf \"%.2f\", $1}" 2>/dev/null || echo "0"
}

usage() {
    cat <<EOF
Scale Planner - Calculate scaling thresholds for Podman workloads

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --current-pods NUM          Current number of pods (default: 3)
    --cpu-per-podcores NUM      CPU cores per pod (default: 0.5)
    --memory-per-podgb NUM     Memory in GB per pod (default: 1)
    --cpu-utilization-pct NUM  Target CPU utilization % (default: 70)
    --memory-utilization-pct NUM Target memory utilization % (default: 80)
    --current-cpu-cores NUM     Total CPU cores available (default: 6)
    --current-memory-gb NUM     Total memory in GB (default: 16)
    --growth-rate-pct NUM      Monthly growth rate % (default: 10)
    --max-pods NUM              Maximum pods allowed (default: 20)
    --min-pods NUM              Minimum pods required (default: 2)
    --hpa-enabled               Output Kubernetes HPA YAML (default: false)
    --output-format FORMAT      Output format: yaml, json, or both (default: human)
    --help                      Show this help message

EXAMPLES:
    $0 --current-pods 3 --cpu-per-podcores 1 --current-cpu-cores 8
    $0 --current-pods 5 --growth-rate-pct 15 --hpa-enabled --output-format yaml
    $0 --current-pods 3 --cpu-utilization-pct 80 --memory-utilization-pct 85

EOF
    exit "${1:-0}"
}

calculate_cpu_trigger() {
    local current_pods="$1"
    local cpu_per_pod="$2"
    local current_cpu_cores="$3"
    local target_cpu_util="$4"
    
    local total_cpu_used=$(echo "$current_pods * $cpu_per_pod" )
    local cpu_per_trigger=$(echo "$current_cpu_cores * $target_cpu_util / 100" )
    local available_cpu=$(echo "$current_cpu_cores - $total_cpu_used" )
    
    local additional_cpu_needed=$(echo "$cpu_per_trigger - $available_cpu" )
    if (( $(echo "$additional_cpu_needed < 0" ) )); then
        additional_cpu_needed=0
    fi
    
    local scale_up_trigger=$(echo "($total_cpu_used / $current_cpu_cores) * 100" )
    
    echo "$scale_up_trigger"
    echo "$additional_cpu_needed"
}

calculate_memory_trigger() {
    local current_pods="$1"
    local memory_per_pod="$2"
    local current_memory_gb="$3"
    local target_mem_util="$4"
    
    local total_memory_used=$(echo "$current_pods * $memory_per_pod" )
    local memory_per_trigger=$(echo "$current_memory_gb * $target_mem_util / 100" )
    local available_memory=$(echo "$current_memory_gb - $total_memory_used" )
    
    local additional_memory_needed=$(echo "$memory_per_trigger - $available_memory" )
    if (( $(echo "$additional_memory_needed < 0" ) )); then
        additional_memory_needed=0
    fi
    
    local scale_up_trigger=$(echo "($total_memory_used / $current_memory_gb) * 100" )
    
    echo "$scale_up_trigger"
    echo "$additional_memory_needed"
}

calculate_scale_up_threshold() {
    local current_pods="$1"
    local scale_trigger="$2"
    local scale_increment="$3"
    local max_pods="$4"
    
    local new_pods=$current_pods
    
    while [[ $new_pods -lt $max_pods ]]; do
        new_pods=$((new_pods + scale_increment))
    done
    
    echo "$new_pods"
}

calculate_scale_down_threshold() {
    local current_pods="$1"
    local scale_decrement="$2"
    local min_pods="$3"
    
    local new_pods=$current_pods
    
    while [[ $new_pods -gt $min_pods ]]; do
        new_pods=$((new_pods - scale_decrement))
    done
    
    echo "$new_pods"
}

project_growth() {
    local current_pods="$1"
    local growth_rate_pct="$2"
    local months="$3"
    
    local projected=$(echo "$current_pods" )
    local growth_factor=$(echo "1 + $growth_rate_pct / 100" )
    
    for ((i=0; i<months; i++)); do
        projected=$(echo "$projected * $growth_factor" )
    done
    
    echo "$projected"
}

estimate_monthly_cost() {
    local pod_count="$1"
    local cpu_per_pod="$2"
    local memory_per_pod="$3"
    local cost_per_vcpu_hour=0.05
    local cost_per_gb_hour=0.01
    
    local monthly_cpu_cost=$(echo "$cpu_per_pod * $pod_count * 730 * $cost_per_vcpu_hour" )
    local monthly_memory_cost=$(echo "$memory_per_pod * $pod_count * 730 * $cost_per_gb_hour" )
    local total=$(echo "$monthly_cpu_cost + $monthly_memory_cost" )
    
    echo "$total"
}

output_yaml() {
    cat <<EOF
---
# Kubernetes Horizontal Pod Autoscaler Configuration
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: podman-workload-hpa
  namespace: podman
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: podman-workload
  minReplicas: $MIN_PODS
  maxReplicas: $MAX_PODS
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: $CPU_UTILIZATION_PCT
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: $MEMORY_UTILIZATION_PCT
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 50
        periodSeconds: 15
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Percent
        value: 100
        periodSeconds: 15
      - type: Pods
        value: 2
        periodSeconds: 15
      selectPolicy: Max
---
# Podman Scaling Configuration
apiVersion: v1
kind: ConfigMap
metadata:
  name: podman-scaling-config
  namespace: podman
data:
  scale-config.yaml: |
    current_pods: $CURRENT_PODS
    cpu_per_pod: $CPU_PER_POD
    memory_per_pod: $MEMORY_PER_POD
    cpu_trigger_threshold: "$CPU_SCALE_UP_TRIGGER"
    memory_trigger_threshold: "$MEMORY_SCALE_UP_TRIGGER"
    scale_up_increment: 2
    scale_down_decrement: 1
    min_pods: $MIN_PODS
    max_pods: $MAX_PODS
    growth_rate: $GROWTH_RATE_PCT%
    projected_pods_6mo: "$(printf "%.1f" $PROJECTED_PODS_6MO)"
    projected_pods_12mo: "$(printf "%.1f" $PROJECTED_PODS_12MO)"
EOF
}

output_json() {
    cat <<EOF
{
    "tool": "scale-planner",
    "current_configuration": {
        "current_pods": $CURRENT_PODS,
        "cpu_per_pod": $CPU_PER_POD,
        "memory_per_pod": $MEMORY_PER_POD,
        "total_cpu_cores": $CURRENT_CPU_CORES,
        "total_memory_gb": $CURRENT_MEMORY_GB,
        "cpu_utilization_target": $CPU_UTILIZATION_PCT,
        "memory_utilization_target": $MEMORY_UTILIZATION_PCT
    },
    "scaling_thresholds": {
        "cpu_scale_up_trigger": "$CPU_SCALE_UP_TRIGGER",
        "memory_scale_up_trigger": "$MEMORY_SCALE_UP_TRIGGER",
        "cpu_additional_needed": "$CPU_ADDITIONAL_NEEDED",
        "memory_additional_needed": "$MEMORY_ADDITIONAL_NEEDED"
    },
    "scaling_configuration": {
        "min_pods": $MIN_PODS,
        "max_pods": $MAX_PODS,
        "scale_up_increment": 2,
        "scale_down_decrement": 1,
        "scale_up_stabilization_seconds": 0,
        "scale_down_stabilization_seconds": 300
    },
    "projected_growth": {
        "growth_rate": $GROWTH_RATE_PCT,
        "projected_pods_6_months": $(printf "%.1f" $PROJECTED_PODS_6MO),
        "projected_pods_12_months": $(printf "%.1f" $PROJECTED_PODS_12MO)
    },
    "cost_estimates": {
        "current_monthly_cost": $(printf "%.2f" $CURRENT_MONTHLY_COST),
        "projected_monthly_cost_6mo": $(printf "%.2f" $PROJECTED_MONTHLY_COST_6MO),
        "projected_monthly_cost_12mo": $(printf "%.2f" $PROJECTED_MONTHLY_COST_12MO)
    }
}
EOF
}

output_human_readable() {
    cat <<EOF
================================================================================
SCALE PLANNER - PODMAN WORKLOAD SCALING THRESHOLDS
================================================================================

Current Configuration:
  Current Pods:       $CURRENT_PODS
  CPU per Pod:        $CPU_PER_POD cores
  Memory per Pod:     $MEMORY_PER_POD GB
  Total CPU Cores:    $CURRENT_CPU_CORES
  Total Memory:       $CURRENT_MEMORY_GB GB

Target Utilization:
  CPU Utilization:    $CPU_UTILIZATION_PCT%
  Memory Utilization: $MEMORY_UTILIZATION_PCT%

================================================================================
SCALING THRESHOLDS
================================================================================

Scale-Up Triggers (when to add pods):
  CPU:      At $CPU_SCALE_UP_TRIGGER% utilization ($CPU_ADDITIONAL_NEEDED cores needed)
  Memory:  At $MEMORY_SCALE_UP_TRIGGER% utilization ($MEMORY_ADDITIONAL_NEEDED GB needed)

Scale-Down Triggers (when to remove pods):
  CPU:      Below $((CPU_UTILIZATION_PCT / 2))% utilization
  Memory:   Below $((MEMORY_UTILIZATION_PCT / 2))% utilization

Scaling Boundaries:
  Minimum Pods:       $MIN_PODS
  Maximum Pods:        $MAX_PODS
  Scale-Up Increment:  2 pods
  Scale-Down Decrement: 1 pod

================================================================================
GROWTH PROJECTIONS
================================================================================

Monthly Growth Rate: $GROWTH_RATE_PCT%

  Projected Pods (6 months): $(printf "%.1f" $PROJECTED_PODS_6MO)
  Projected Pods (12 months): $(printf "%.1f" $PROJECTED_PODS_12MO)

Resource Requirements at 12 Months:
  CPU Cores Needed: $(printf "%.1f" $(echo "$PROJECTED_PODS_12MO * $CPU_PER_POD" ))
  Memory Needed:    $(printf "%.1f" $(echo "$PROJECTED_PODS_12MO * $MEMORY_PER_POD" )) GB

================================================================================
COST ESTIMATES
================================================================================

Current Monthly Cost:     \$$(printf "%.2f" $CURRENT_MONTHLY_COST)
Monthly Cost (6 months):  \$$(printf "%.2f" $PROJECTED_MONTHLY_COST_6MO)
Monthly Cost (12 months): \$$(printf "%.2f" $PROJECTED_MONTHLY_COST_12MO)
Yearly Cost (current):    \$$(printf "%.2f" $(echo "$CURRENT_MONTHLY_COST * 12" ))
Yearly Cost (projected):   \$$(printf "%.2f" $(echo "$PROJECTED_MONTHLY_COST_12MO * 12" ))

================================================================================
RECOMMENDATIONS
================================================================================

1. Set HPA metrics:
   - CPU threshold: $CPU_UTILIZATION_PCT%
   - Memory threshold: $MEMORY_UTILIZATION_PCT%

2. Monitor for growth rate changes - adjust if actual growth differs from $GROWTH_RATE_PCT%

3. Plan infrastructure scaling:
   - Current capacity sufficient until $(printf "%.0f" $PROJECTED_PODS_6MO) pods
   - Consider adding nodes when approaching $MAX_PODS

4. Cost optimization:
   - Use spot/preemptible instances for non-production workloads
   - Reserve capacity for predictable baseline traffic
EOF
}

CURRENT_PODS=3
CPU_PER_POD=0.5
MEMORY_PER_POD=1
CPU_UTILIZATION_PCT=70
MEMORY_UTILIZATION_PCT=80
CURRENT_CPU_CORES=6
CURRENT_MEMORY_GB=16
GROWTH_RATE_PCT=10
MAX_PODS=20
MIN_PODS=2
HPA_ENABLED=false
OUTPUT_FORMAT="human"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --current-pods)
            CURRENT_PODS="$2"
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
        --cpu-utilization-pct)
            CPU_UTILIZATION_PCT="$2"
            shift 2
            ;;
        --memory-utilization-pct)
            MEMORY_UTILIZATION_PCT="$2"
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
        --growth-rate-pct)
            GROWTH_RATE_PCT="$2"
            shift 2
            ;;
        --max-pods)
            MAX_PODS="$2"
            shift 2
            ;;
        --min-pods)
            MIN_PODS="$2"
            shift 2
            ;;
        --hpa-enabled)
            HPA_ENABLED=true
            shift
            ;;
        --output-format)
            OUTPUT_FORMAT="$2"
            shift 2
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

CPU_OUTPUT=($(calculate_cpu_trigger "$CURRENT_PODS" "$CPU_PER_POD" "$CURRENT_CPU_CORES" "$CPU_UTILIZATION_PCT"))
CPU_SCALE_UP_TRIGGER="${CPU_OUTPUT[0]}"
CPU_ADDITIONAL_NEEDED="${CPU_OUTPUT[1]}"

MEMORY_OUTPUT=($(calculate_memory_trigger "$CURRENT_PODS" "$MEMORY_PER_POD" "$CURRENT_MEMORY_GB" "$MEMORY_UTILIZATION_PCT"))
MEMORY_SCALE_UP_TRIGGER="${MEMORY_OUTPUT[0]}"
MEMORY_ADDITIONAL_NEEDED="${MEMORY_OUTPUT[1]}"

PROJECTED_PODS_6MO=$(project_growth "$CURRENT_PODS" "$GROWTH_RATE_PCT" 6)
PROJECTED_PODS_12MO=$(project_growth "$CURRENT_PODS" "$GROWTH_RATE_PCT" 12)

CURRENT_MONTHLY_COST=$(estimate_monthly_cost "$CURRENT_PODS" "$CPU_PER_POD" "$MEMORY_PER_POD")
PROJECTED_MONTHLY_COST_6MO=$(estimate_monthly_cost "$PROJECTED_PODS_6MO" "$CPU_PER_POD" "$MEMORY_PER_POD")
PROJECTED_MONTHLY_COST_12MO=$(estimate_monthly_cost "$PROJECTED_PODS_12MO" "$CPU_PER_POD" "$MEMORY_PER_POD")

case "$OUTPUT_FORMAT" in
    json)
        output_json
        ;;
    yaml)
        output_yaml
        ;;
    both)
        output_yaml
        echo ""
        output_json
        ;;
    *)
        output_human_readable
        if [[ "$HPA_ENABLED" == "true" ]]; then
            echo ""
            output_yaml
        fi
        ;;
esac
