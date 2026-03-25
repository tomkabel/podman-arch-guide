#!/usr/bin/env bash
# SLO Calculator - Calculate Service Level Objectives for Podman workloads
# Determines error budgets, allowed downtime, MTTR targets, and required redundancy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

calc() {
    awk "BEGIN {printf \"%.2f\", $1}" 2>/dev/null || echo "0"
}

usage() {
    cat <<EOF
SLO Calculator - Calculate Service Level Objectives for Podman workloads

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --availability-target NUM   Target availability % (default: 99.9)
    --service-name NAME         Service name (default: podman-service)
    --deployment-count NUM      Number of replicas/pods (default: 3)
    --mttr-minutes NUM          Mean Time To Recovery in minutes (default: 30)
    --maintenance-hours NUM     Scheduled maintenance hours/month (default: 4)
    --incidents-per-month NUM   Expected incidents per month (default: 1)
    --incident-duration-min NUM Average incident duration in minutes (default: 15)
    --json                     Output JSON format
    --help                     Show this help message

COMMON AVAILABILITY TARGETS:
  99%       - "two nines"     - 87.6 hours downtime/year
  99.9%     - "three nines"   - 8.76 hours downtime/year
  99.95%    - "three nines five" - 4.38 hours downtime/year
  99.99%    - "four nines"     - 52.6 minutes downtime/year
  99.999%   - "five nines"    - 5.26 minutes downtime/year

EXAMPLES:
    $0 --availability-target 99.9 --deployment-count 3
    $0 --availability-target 99.99 --deployment-count 5 --mttr-minutes 15 --json
    $0 --service-name api-gateway --incidents-per-month 2

EOF
    exit "${1:-0}"
}

calculate_error_budget() {
    local availability_target="$1"
    
    local error_budget=$(echo "100 - $availability_target" )
    echo "$error_budget"
}

calculate_allowed_downtime() {
    local availability_target="$1"
    local period="$2"
    
    local uptime=$(echo "$availability_target / 100" )
    local allowed_downtime=0
    
    case "$period" in
        year)
            allowed_downtime=$(echo "8760 * (1 - $uptime)" )
            ;;
        month)
            allowed_downtime=$(echo "730 * (1 - $uptime)" )
            ;;
        week)
            allowed_downtime=$(echo "168 * (1 - $uptime)" )
            ;;
        day)
            allowed_downtime=$(echo "24 * (1 - $uptime)" )
            ;;
    esac
    
    echo "$allowed_downtime"
}

calculate_actual_uptime() {
    local incidents_per_month="$1"
    local incident_duration="$2"
    local maintenance_hours="$3"
    local deployment_count="$4"
    
    local total_incident_minutes=$(echo "$incidents_per_month * $incident_duration" )
    local total_downtime_minutes=$(echo "$total_incident_minutes + ($maintenance_hours * 60)" )
    
    local if_single_failure=$(echo "$total_downtime_minutes * (1 - 1/$deployment_count)" )
    
    local monthly_minutes=43200
    local actual_uptime=$(echo "100 * (1 - $total_downtime_minutes / $monthly_minutes)" )
    
    echo "$actual_uptime"
}

calculate_required_redundancy() {
    local availability_target="$1"
    local mttr_minutes="$2"
    
    local n_plus_1=1
    
    if (( $(echo "$availability_target >= 99.9" ) )); then
        n_plus_1=2
    fi
    
    if (( $(echo "$availability_target >= 99.99" ) )); then
        n_plus_1=3
    fi
    
    local annual_allowed=$(calculate_allowed_downtime "$availability_target" "year")
    local mttr_hours=$(echo "$mttr_minutes / 60" )
    local max_annual_failures=$(echo "$annual_allowed / $mttr_hours" )
    
    echo "$n_plus_1"
}

calculate_mttr_target() {
    local availability_target="$1"
    local incidents_per_year="$2"
    
    local allowed_downtime=$(calculate_allowed_downtime "$availability_target" "year")
    local mttr=$(echo "$allowed_downtime / $incidents_per_year" )
    
    local mttr_hours=$(echo "$mttr" )
    
    echo "$mttr"
}

calculate_availability_reachable() {
    local deployment_count="$1"
    local mttr_minutes="$2"
    local monthly_minutes="$3"
    
    local single_failure_duration=$(echo "$mttr_minutes / $monthly_minutes * 100" )
    local probability_of_failure=$(echo "1 / $deployment_count" )
    
    local unavailability=$(echo "$single_failure_duration * $probability_of_failure" )
    local availability=$(echo "100 - $unavailability" )
    
    echo "$availability"
}

output_json() {
    cat <<EOF
{
    "tool": "slo-calculator",
    "service": "$SERVICE_NAME",
    "configuration": {
        "availability_target": $AVAILABILITY_TARGET,
        "deployment_count": $DEPLOYMENT_COUNT,
        "mttr_minutes": $MTTR_MINUTES,
        "maintenance_hours_per_month": $MAINTENANCE_HOURS,
        "incidents_per_month": $INCIDENTS_PER_MONTH,
        "incident_duration_minutes": $INCIDENT_DURATION
    },
    "error_budget": {
        "percentage": $ERROR_BUDGET,
        "per_year_minutes": $(calculate_allowed_downtime "$AVAILABILITY_TARGET" "year" ),
        "per_month_minutes": $(calculate_allowed_downtime "$AVAILABILITY_TARGET" "month" ),
        "per_week_minutes": $(calculate_allowed_downtime "$AVAILABILITY_TARGET" "week" ),
        "per_day_minutes": $(calculate_allowed_downtime "$AVAILABILITY_TARGET" "day" )
    },
    "availability_analysis": {
        "actual_uptime": $ACTUAL_UPTIME,
        "achievement": "$(if (( $(echo "$ACTUAL_UPTIME >= $AVAILABILITY_TARGET" ) )); then echo "MEETS_TARGET"; else echo "BELOW_TARGET"; fi)",
        "deployment_based_availability": $DEPLOYMENT_BASED_AVAILABILITY
    },
    "redundancy_requirements": {
        "recommended_replicas": $REQUIRED_REDUNDANCY,
        "strategy": "$(case "$REQUIRED_REDUNDANCY" in 1) echo "N+0 (single)" ;; 2) echo "N+1 (hot standby)" ;; 3) echo "N+2 (high availability)" ;; esac)"
    },
    "mttr_analysis": {
        "current_mttr_minutes": $MTTR_MINUTES,
        "target_mttr_minutes": $TARGET_MTTR,
        "recommended_mttr_minutes": $RECOMMENDED_MTTR
    }
}
EOF
}

output_human_readable() {
    cat <<EOF
================================================================================
SLO CALCULATOR - SERVICE LEVEL OBJECTIVES FOR PODMAN WORKLOADS
================================================================================

Service: $SERVICE_NAME

Configuration:
  Target Availability:  $AVAILABILITY_TARGET%
  Deployment Count:    $DEPLOYMENT_COUNT replicas
  MTTR:                $MTTR_MINUTES minutes
  Maintenance:         $MAINTENANCE_HOURS hours/month
  Expected Incidents:  $INCIDENTS_PER_MONTH per month
  Incident Duration:  $INCIDENT_DURATION minutes

================================================================================
ERROR BUDGET
================================================================================

Error Budget:          $ERROR_BUDGET%

Allowed Downtime (Year):   $(calculate_allowed_downtime "$AVAILABILITY_TARGET" "year"  | xargs printf "%.1f") hours
Allowed Downtime (Month):  $(calculate_allowed_downtime "$AVAILABILITY_TARGET" "month"  | xargs printf "%.1f") hours
Allowed Downtime (Week):   $(calculate_allowed_downtime "$AVAILABILITY_TARGET" "week"  | xargs printf "%.1f") hours
Allowed Downtime (Day):    $(calculate_allowed_downtime "$AVAILABILITY_TARGET" "day"  | xargs printf "%.1f") hours

================================================================================
AVAILABILITY ANALYSIS
================================================================================

Based on your configuration:
  Actual Uptime:   $ACTUAL_UPTIME%
  
  Target Met:      $(if (( $(echo "$ACTUAL_UPTIME >= $AVAILABILITY_TARGET" ) )); then echo "YES - Target is achievable"; else echo "NO - Configuration needs improvement"; fi)

With $DEPLOYMENT_COUNT replicas, theoretical availability: $DEPLOYMENT_BASED_AVAILABILITY%

================================================================================
REQUIRED REDUNDANCY
================================================================================

Recommended Replicas: $REQUIRED_REDUNDANCY
Strategy:            $(case "$REQUIRED_REDUNDANCY" in 1) echo "N+0 - Single instance" ;; 2) echo "N+1 - Hot standby for failure" ;; 3) echo "N+2 - High availability with zero-downtime updates" ;; esac)

To achieve $AVAILABILITY_TARGET% with $MTTR_MINUTES minute MTTR:
  - Need minimum $REQUIRED_REDUNDANCY replicas
  - Implement health checks with $(echo "$MTTR_MINUTES * 0.1"  | xargs printf "%.0f") second timeout
  - Set pod restart policy to Always

================================================================================
MTTR TARGETS
================================================================================

Current MTTR:          $MTTR_MINUTES minutes
Target MTTR:           $TARGET_MTTR minutes (for $AVAILABILITY_TARGET% annual)

Recommended MTTR:       $RECOMMENDED_MTTR minutes

To achieve your SLO, you must maintain an MTTR of $RECOMMENDED_MTTR minutes or less.

================================================================================
RECOMMENDATIONS
================================================================================

$(if (( $(echo "$ACTUAL_UPTIME < $AVAILABILITY_TARGET" ) )); then
cat <<ADJUST
1. Improve availability through:
   - Increase deployment count to $REQUIRED_REDUNDANCY
   - Reduce MTTR to $RECOMMENDED_MTTR minutes
   - Reduce maintenance window or move to off-peak
   - Improve incident response automation

2. Observability:
   - Implement Prometheus metrics
   - Set up alerting with PagerDuty or similar
   - Create runbooks for common failures
ADJUST
else
cat <<GOOD
1. Your configuration meets the target - maintain current setup

2. For continuous improvement:
   - Reduce MTTR through automation
   - Implement chaos engineering
   - Add redundancy for future growth
GOOD
fi)

================================================================================
SLO QUICK REFERENCE
================================================================================
  99%    = 87.6 hours/year downtime    = 7.3 hours/month
  99.9%  = 8.76 hours/year downtime   = 43.8 minutes/month
  99.95% = 4.38 hours/year downtime   = 21.9 minutes/month
  99.99% = 52.6 minutes/year downtime = 4.4 minutes/month
  99.999% = 5.26 minutes/year downtime = 0.44 minutes/month
EOF
}

SERVICE_NAME="${service_name:-podman-service}"
AVAILABILITY_TARGET=99.9
DEPLOYMENT_COUNT=3
MTTR_MINUTES=30
MAINTENANCE_HOURS=4
INCIDENTS_PER_MONTH=1
INCIDENT_DURATION=15
OUTPUT_JSON=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --availability-target)
            AVAILABILITY_TARGET="$2"
            shift 2
            ;;
        --service-name)
            SERVICE_NAME="$2"
            shift 2
            ;;
        --deployment-count)
            DEPLOYMENT_COUNT="$2"
            shift 2
            ;;
        --mttr-minutes)
            MTTR_MINUTES="$2"
            shift 2
            ;;
        --maintenance-hours)
            MAINTENANCE_HOURS="$2"
            shift 2
            ;;
        --incidents-per-month)
            INCIDENTS_PER_MONTH="$2"
            shift 2
            ;;
        --incident-duration-min)
            INCIDENT_DURATION="$2"
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

ERROR_BUDGET=$(calculate_error_budget "$AVAILABILITY_TARGET")

ACTUAL_UPTIME=$(calculate_actual_uptime "$INCIDENTS_PER_MONTH" "$INCIDENT_DURATION" "$MAINTENANCE_HOURS" "$DEPLOYMENT_COUNT")

DEPLOYMENT_BASED_AVAILABILITY=$(calculate_availability_reachable "$DEPLOYMENT_COUNT" "$MTTR_MINUTES" 43200)

REQUIRED_REDUNDANCY=$(calculate_required_redundancy "$AVAILABILITY_TARGET" "$MTTR_MINUTES")

incidents_per_year=$(echo "$INCIDENTS_PER_MONTH * 12" )
TARGET_MTTR=$(calculate_mttr_target "$AVAILABILITY_TARGET" "$incidents_per_year")

RECOMMENDED_MTTR=$MTTR_MINUTES
if (( $(echo "$MTTR_MINUTES > 30" ) )); then
    RECOMMENDED_MTTR=30
fi
if (( $(echo "$AVAILABILITY_TARGET >= 99.99" ) )); then
    RECOMMENDED_MTTR=15
fi

if [[ "$OUTPUT_JSON" == "true" ]]; then
    output_json
else
    output_human_readable
fi
