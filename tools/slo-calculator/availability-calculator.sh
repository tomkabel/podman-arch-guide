#!/usr/bin/env bash
# Availability Calculator - Calculate composite availability for Podman workloads
# Determines overall system availability based on component availability

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

calc() {
    awk "BEGIN {printf \"%.2f\", $1}" 2>/dev/null || echo "0"
}

usage() {
    cat <<EOF
Availability Calculator - Calculate composite availability for Podman workloads

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --components FILE            JSON file with component list
    --component-spec SPEC        Component specification (format: name:availability%,repeatable)
    --deployment-count NUM       Number of pod replicas (default: 3)
    --region-count NUM           Number of regions (default: 1)
    --load-balancer-avail NUM    Load balancer availability % (default: 99.99)
    --database-avail NUM         Database availability % (default: 99.95)
    --cache-avail NUM            Cache availability % (default: 99.9)
    --pod-replicas NUM           Pod replica count (default: 3)
    --pod-avail NUM              Per-pod availability % (default: 99.5)
    --json                       Output JSON format
    --help                       Show this help message

COMPONENT SPEC FORMAT:
  --component-spec "loadbalancer:99.99" --component-spec "database:99.95"
  
  Or use JSON file:
  --components components.json

COMPONENTS JSON FORMAT:
  {
    "components": [
      {"name": "loadbalancer", "availability": 99.99, "redundant": true},
      {"name": "database", "availability": 99.95, "redundant": false},
      {"name": "cache", "availability": 99.9, "redundant": true},
      {"name": "api", "availability": 99.5, "redundant": true, "replicas": 3}
    ]
  }

EXAMPLES:
    $0 --pod-replicas 3 --pod-avail 99.5 --load-balancer-avail 99.99
    $0 --components components.json --json
    $0 --component-spec "lb:99.99" --component-spec "db:99.95" --component-spec "cache:99.9"

EOF
    exit "${1:-0}"
}

parse_components_json() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        echo "Error: Components file not found: $file" >&2
        return 1
    fi
    
    python3 -c "
import json
import sys

with open('$file') as f:
    data = json.load(f)
    for c in data.get('components', []):
        name = c.get('name', 'unknown')
        avail = c.get('availability', 100)
        print(f'{name}:{avail}')
" 2>/dev/null || echo "database:99.95"
}

parse_component_spec() {
    local spec="$1"
    echo "$spec"
}

calculate_series_availability() {
    local availability1="$1"
    local availability2="$2"
    
    local avail1=$(echo "$availability1 / 100" )
    local avail2=$(echo "$availability2 / 100" )
    
    local combined=$(echo "$avail1 * $avail2" )
    local percentage=$(echo "$combined * 100" )
    
    echo "$percentage"
}

calculate_parallel_availability() {
    local component_avail="$1"
    local replica_count="$2"
    
    local avail=$(echo "$component_avail / 100" )
    
    local combined=$(echo "1 - (1 - $avail)^$replica_count" )
    local percentage=$(echo "$combined * 100" )
    
    echo "$percentage"
}

calculate_mtfbf() {
    local availability="$1"
    
    local avail_decimal=$(echo "$availability / 100" )
    local mtbf_hours=$(echo "$avail_decimal / (1 - $avail_decimal) * 8760" )
    
    echo "$mtbf_hours"
}

find_weakest_link() {
    local components=("$@")
    
    local lowest_avail=100
    local weakest=""
    
    for comp in "${components[@]}"; do
        local name="${comp%%:*}"
        local avail="${comp##*:}"
        
        if (( $(echo "$avail < $lowest_avail" ) )); then
            lowest_avail=$avail
            weakest="$name"
        fi
    done
    
    echo "$weakest"
}

calculate_improvement_needed() {
    local current_avail="$1"
    local target_avail="$2"
    
    local improvement=$(echo "$target_avail - $current_avail" )
    
    if (( $(echo "$improvement <= 0" ) )); then
        echo "0"
        return
    fi
    
    echo "$improvement"
}

output_json() {
    cat <<EOF
{
    "tool": "availability-calculator",
    "system_configuration": {
        "deployment_count": $POD_REPLICAS,
        "region_count": $REGION_COUNT,
        "component_count": ${#COMPONENTS[@]}
    },
    "component_availability": {
$(generate_json_components)
    },
    "composite_availability": {
        "overall_availability": $COMPOSITE_AVAILABILITY,
        "series_components": $SERIES_AVAILABILITY,
        "parallel_components": $PARALLEL_AVAILABILITY,
        "multi_region_availability": $MULTI_REGION_AVAILABILITY
    },
    "analysis": {
        "weakest_link": "$WEAKEST_LINK",
        "mtbf_hours": $MTBF_HOURS,
        "annual_downtime_minutes": $ANNUAL_DOWNTIME,
        "improvement_needed_to_target": $IMPROVEMENT_NEEDED
    },
    "recommendations": [
        "Focus improvements on $WEAKEST_LINK component",
        "Consider redundant deployments for critical components",
        "Implement multi-region for >= 99.99% availability"
    ]
}
EOF
}

generate_json_components() {
    local first=true
    for comp in "${COMPONENTS[@]}"; do
        local name="${comp%%:*}"
        local avail="${comp##*:}"
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo ","
        fi
        echo -n "        \"$name\": $avail"
    done
    echo ""
}

output_human_readable() {
    cat <<EOF
================================================================================
AVAILABILITY CALCULATOR - COMPOSITE SYSTEM AVAILABILITY
================================================================================

System Configuration:
  Pod Replicas:        $POD_REPLICAS
  Region Count:       $REGION_COUNT
  Component Count:    ${#COMPONENTS[@]}

================================================================================
COMPONENT AVAILABILITY
================================================================================

$(for comp in "${COMPONENTS[@]}"; do
    local name="${comp%%:*}"
    local avail="${comp##*:}"
    printf "  %-20s %s%%\n" "$name:" "$avail"
done)

================================================================================
COMPOSITE AVAILABILITY CALCULATION
================================================================================

Series Components (must ALL work):
  Overall Availability: $SERIES_AVAILABILITY%

Parallel Components (N+1 redundancy):
  Overall Availability: $PARALLEL_AVAILABILITY%

Multi-Region (disaster recovery):
  Overall Availability: $MULTI_REGION_AVAILABILITY%

COMBINED SYSTEM AVAILABILITY: $COMPOSITE_AVAILABILITY%

================================================================================
AVAILABILITY ANALYSIS
================================================================================

Weakest Link: $WEAKEST_LINK

System Metrics:
  MTBF:           $MTBF_HOURS hours
  Annual Downtime: $ANNUAL_DOWNTIME minutes

To reach 99.99% (four nines): $(echo "99.99 - $COMPOSITE_AVAILABILITY"  | xargs printf "%.3f")% improvement needed

================================================================================
RECOMMENDATIONS
================================================================================

$(if [[ "$WEAKEST_LINK" == "pod" || "$WEAKEST_LINK" == "api" ]]; then
cat <<POD
1. Improve pod availability:
   - Increase replica count to at least 3
   - Implement pod anti-affinity rules
   - Add readiness and liveness probes
   - Set appropriate resource requests/limits
POD
fi)

$(if [[ "$WEAKEST_LINK" == "database" ]]; then
cat <<DB
2. Improve database availability:
   - Use managed database with automatic failover
   - Implement read replicas for read-heavy workloads
   - Consider database proxy for connection pooling
DB
fi)

$(if [[ "$WEAKEST_LINK" == "cache" ]]; then
cat <<CACHE
3. Improve cache availability:
   - Use Redis cluster mode for automatic sharding
   - Implement cache fallback to database
   - Set appropriate TTL for cache entries
CACHE
fi)

$(if (( $(echo "$COMPOSITE_AVAILABILITY < 99.9" ) )); then
cat <<HIGH
4. For higher availability:
   - Implement multi-region deployment
   - Add CDN for static content
   - Use managed services with SLA guarantees
HIGH
fi)

================================================================================
AVAILABILITY QUICK REFERENCE
================================================================================
  Availability%   | Annual Downtime  | Classification
  ----------------|------------------|------------------
  90%             | 36.5 days        | Low
  99%             | 87.6 hours      | Standard
  99.9%           | 8.76 hours      | High
  99.95%          | 4.38 hours      | Very High
  99.99%          | 52.6 minutes    | Ultra
  99.999%         | 5.26 minutes    | Critical
EOF
}

POD_REPLICAS=3
REGION_COUNT=1
LOAD_BALANCER_AVAIL=99.99
DATABASE_AVAIL=99.95
CACHE_AVAIL=99.9
POD_AVAIL=99.5
COMPONENTS_FILE=""
COMPONENT_SPECS=()
OUTPUT_JSON=false
COMPONENTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --components)
            COMPONENTS_FILE="$2"
            shift 2
            ;;
        --component-spec)
            COMPONENT_SPECS+=("$2")
            shift 2
            ;;
        --deployment-count|--pod-replicas)
            POD_REPLICAS="$2"
            shift 2
            ;;
        --region-count)
            REGION_COUNT="$2"
            shift 2
            ;;
        --load-balancer-avail)
            LOAD_BALANCER_AVAIL="$2"
            shift 2
            ;;
        --database-avail)
            DATABASE_AVAIL="$2"
            shift 2
            ;;
        --cache-avail)
            CACHE_AVAIL="$2"
            shift 2
            ;;
        --pod-avail)
            POD_AVAIL="$2"
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

if [[ -n "$COMPONENTS_FILE" ]]; then
    while IFS= read -r line; do
        COMPONENTS+=("$line")
    done < <(parse_components_json "$COMPONENTS_FILE")
fi

for spec in "${COMPONENT_SPECS[@]}"; do
    COMPONENTS+=("$(parse_component_spec "$spec")")
done

if [[ ${#COMPONENTS[@]} -eq 0 ]]; then
    COMPONENTS+=("loadbalancer:$LOAD_BALANCER_AVAIL")
    COMPONENTS+=("database:$DATABASE_AVAIL")
    COMPONENTS+=("cache:$CACHE_AVAIL")
    COMPONENTS+=("pod:$POD_AVAIL")
fi

PARALLEL_AVAILABILITY=$(calculate_parallel_availability "$POD_AVAIL" "$POD_REPLICAS")

first_comp=true
for comp in "${COMPONENTS[@]}"; do
    if [[ "$first_comp" == "true" ]]; then
        SERIES_ACCUM="${comp##*:}"
        first_comp=false
    else
        SERIES_ACCUM=$(calculate_series_availability "$SERIES_ACCUM" "${comp##*:}")
    fi
done
SERIES_AVAILABILITY=$SERIES_ACCUM

MULTI_REGION_AVAILABILITY=$SERIES_AVAILABILITY
if [[ "$REGION_COUNT" -gt 1 ]]; then
    MULTI_REGION_AVAILABILITY=$(calculate_parallel_availability "$SERIES_AVAILABILITY" "$REGION_COUNT")
fi

COMPOSITE_AVAILABILITY=$(calculate_series_availability "$SERIES_AVAILABILITY" "$PARALLEL_AVAILABILITY")

if [[ "$REGION_COUNT" -gt 1 ]]; then
    COMPOSITE_AVAILABILITY=$(calculate_parallel_availability "$COMPOSITE_AVAILABILITY" "$REGION_COUNT")
fi

WEAKEST_LINK=$(find_weakest_link "${COMPONENTS[@]}")

MTBF_HOURS=$(calculate_mtfbf "$COMPOSITE_AVAILABILITY")

avail_decimal=$(echo "$COMPOSITE_AVAILABILITY / 100" )
annual_unavail=$(echo "(1 - $avail_decimal) * 8760" )
ANNUAL_DOWNTIME=$(echo "$annual_unavail * 60" )

IMPROVEMENT_NEEDED=$(calculate_improvement_needed "$COMPOSITE_AVAILABILITY" 99.99)

if [[ "$OUTPUT_JSON" == "true" ]]; then
    output_json
else
    output_human_readable
fi
