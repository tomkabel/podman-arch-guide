#!/usr/bin/env bash
#===============================================================================
# health-check.sh - Comprehensive Podman Health Check Script
#===============================================================================
# Description: Performs comprehensive health checks including container runtime,
#              application endpoints, resource usage, network connectivity,
#              and storage health. Outputs JSON for monitoring integration.
# Author: DevOps Team
# Version: 1.0.0
#===============================================================================
#
# Exit Codes (Nagios-style):
#   0 - OK (All checks passed)
#   1 - WARNING (Some checks warning)
#   2 - CRITICAL (Some checks failed)
#   3 - UNKNOWN (Check could not be performed)
#
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="1.0.0"

# Nagios exit codes
readonly EXIT_OK=0
readonly EXIT_WARN=1
readonly EXIT_CRIT=2
readonly EXIT_UNKNOWN=3

# Thresholds
readonly CPU_WARN_THRESHOLD="${CPU_WARN_THRESHOLD:-80}"
readonly CPU_CRIT_THRESHOLD="${CPU_CRIT_THRESHOLD:-95}"
readonly MEM_WARN_THRESHOLD="${MEM_WARN_THRESHOLD:-80}"
readonly MEM_CRIT_THRESHOLD="${MEM_CRIT_THRESHOLD:-95}"
readonly DISK_WARN_THRESHOLD="${DISK_WARN_THRESHOLD:-85}"
readonly DISK_CRIT_THRESHOLD="${DISK_CRIT_THRESHOLD:-95}"
readonly RESTART_WARN_COUNT="${RESTART_WARN_COUNT:-3}"
readonly RESTART_CRIT_COUNT="${RESTART_CRIT_COUNT:-5}"

# Check toggles
readonly CHECK_CONTAINER="${CHECK_CONTAINER:-true}"
readonly CHECK_APPLICATION="${CHECK_APPLICATION:-true}"
readonly CHECK_RESOURCE="${CHECK_RESOURCE:-true}"
readonly CHECK_NETWORK="${CHECK_NETWORK:-true}"
readonly CHECK_STORAGE="${CHECK_STORAGE:-true}"

#-------------------------------------------------------------------------------
# Global State
#-------------------------------------------------------------------------------
declare -i OVERALL_STATUS=$EXIT_OK
declare -A CHECK_RESULTS
declare -a MESSAGES=()

#-------------------------------------------------------------------------------
# Colors
#-------------------------------------------------------------------------------
declare -r RED='\033[0;31m'
declare -r GREEN='\033[0;32m'
declare -r YELLOW='\033[1;33m'
declare -r BLUE='\033[0;34m'
declare -r NC='\033[0m'

#-------------------------------------------------------------------------------
# Logging
#-------------------------------------------------------------------------------
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        ERROR)   echo -e "${RED}[$timestamp] [ERROR] $message${NC}" >&2 ;;
        WARN)    echo -e "${YELLOW}[$timestamp] [WARN] $message${NC}" ;;
        SUCCESS) echo -e "${GREEN}[$timestamp] [OK] $message${NC}" ;;
        INFO)    echo -e "${BLUE}[$timestamp] [INFO] $message${NC}" ;;
        *)       echo "[$timestamp] [$level] $message" ;;
    esac
}

#-------------------------------------------------------------------------------
# Status Management
#-------------------------------------------------------------------------------
update_status() {
    local new_status=$1
    local message="$2"
    
    MESSAGES+=("$message")
    
    # Update to most severe status
    if [[ $new_status -gt $OVERALL_STATUS ]]; then
        OVERALL_STATUS=$new_status
    fi
}

status_text() {
    case $1 in
        $EXIT_OK)       echo "OK" ;;
        $EXIT_WARN)     echo "WARNING" ;;
        $EXIT_CRIT)     echo "CRITICAL" ;;
        $EXIT_UNKNOWN)  echo "UNKNOWN" ;;
        *)              echo "UNKNOWN" ;;
    esac
}

#-------------------------------------------------------------------------------
# Utility Functions
#-------------------------------------------------------------------------------
get_containers() {
    local filter="${1:-}"
    if [[ -n "$filter" ]]; then
        podman ps -a --filter "$filter" --format '{{.Names}}' 2>/dev/null || true
    else
        podman ps -a --format '{{.Names}}' 2>/dev/null || true
    fi
}

container_exists() {
    podman container exists "$1" 2>/dev/null
}

#-------------------------------------------------------------------------------
# Container Runtime Health Checks
#-------------------------------------------------------------------------------
check_container_runtime() {
    log INFO "Checking container runtime health..."
    
    local containers
    containers=$(get_containers)
    
    if [[ -z "$containers" ]]; then
        update_status $EXIT_UNKNOWN "No containers found"
        return
    fi
    
    local running=0
    local exited=0
    local unhealthy=0
    local oom_killed=0
    local high_restarts=0
    
    while IFS= read -r container; do
        [[ -z "$container" ]] && continue
        
        # Check container state
        local state
        state=$(podman inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
        
        case "$state" in
            running)
                ((running++))
                
                # Check health status
                local health
                health=$(podman inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")
                
                if [[ "$health" == "unhealthy" ]]; then
                    ((unhealthy++))
                    update_status $EXIT_CRIT "Container $container is unhealthy"
                fi
                
                # Check OOM kills
                local oom
                oom=$(podman inspect --format='{{.State.OOMKilled}}' "$container" 2>/dev/null || echo "false")
                if [[ "$oom" == "true" ]]; then
                    ((oom_killed++))
                    update_status $EXIT_CRIT "Container $container was OOM killed"
                fi
                
                # Check restart count
                local restart_count
                restart_count=$(podman inspect --format='{{.RestartCount}}' "$container" 2>/dev/null || echo "0")
                
                if [[ "$restart_count" -ge $RESTART_CRIT_COUNT ]]; then
                    ((high_restarts++))
                    update_status $EXIT_CRIT "Container $container has $restart_count restarts"
                elif [[ "$restart_count" -ge $RESTART_WARN_COUNT ]]; then
                    ((high_restarts++))
                    update_status $EXIT_WARN "Container $container has $restart_count restarts"
                fi
                ;;
            exited|dead)
                ((exited++))
                local exit_code
                exit_code=$(podman inspect --format='{{.State.ExitCode}}' "$container" 2>/dev/null || echo "0")
                update_status $EXIT_CRIT "Container $container is $state (exit code: $exit_code)"
                ;;
        esac
    done <<< "$containers"
    
    CHECK_RESULTS[containers_total]=$(echo "$containers" | wc -l)
    CHECK_RESULTS[containers_running]=$running
    CHECK_RESULTS[containers_exited]=$exited
    CHECK_RESULTS[containers_unhealthy]=$unhealthy
    CHECK_RESULTS[containers_oom_killed]=$oom_killed
    CHECK_RESULTS[containers_high_restarts]=$high_restarts
    
    log INFO "Container runtime: $running running, $exited exited, $unhealthy unhealthy"
}

#-------------------------------------------------------------------------------
# Application Health Checks
#-------------------------------------------------------------------------------
check_application_health() {
    log INFO "Checking application health..."
    
    local endpoints_checked=0
    local endpoints_ok=0
    local endpoints_failed=0
    
    # Check containers with HEALTHCHECK defined
    local containers
    containers=$(get_containers)
    
    while IFS= read -r container; do
        [[ -z "$container" ]] && continue
        
        # Get container labels for health check endpoints
        local labels
        labels=$(podman inspect --format='{{json .Config.Labels}}' "$container" 2>/dev/null || echo "{}")
        
        # Check for custom health check URL in labels
        local health_url
        health_url=$(echo "$labels" | jq -r '.["healthcheck.url"] // empty' 2>/dev/null || true)
        
        if [[ -n "$health_url" ]]; then
            ((endpoints_checked++))
            
            # Get container IP
            local container_ip
            container_ip=$(podman inspect --format='{{.NetworkSettings.IPAddress}}' "$container" 2>/dev/null || true)
            
            # Replace placeholder in URL
            health_url="${health_url//\{\{IP\}\}/$container_ip}"
            health_url="${health_url//\{\{CONTAINER\}\}/$container}"
            
            if curl -sf --max-time 10 "$health_url" > /dev/null 2>&1; then
                ((endpoints_ok++))
                log SUCCESS "Health check passed for $container: $health_url"
            else
                ((endpoints_failed++))
                update_status $EXIT_CRIT "Health check failed for $container: $health_url"
            fi
        fi
        
        # Check exposed ports
        local ports
        ports=$(podman inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{end}} {{end}}' "$container" 2>/dev/null || true)
        
        if [[ -n "$ports" ]]; then
            for port in $ports; do
                if [[ -n "$port" ]]; then
                    ((endpoints_checked++))
                    
                    local host_ip="localhost"
                    if curl -sf --max-time 5 "http://${host_ip}:${port}" > /dev/null 2>&1 || \
                       curl -sf --max-time 5 "https://${host_ip}:${port}" > /dev/null 2>&1; then
                        ((endpoints_ok++))
                    else
                        # Port might be TCP only, not HTTP
                        if timeout 5 bash -c "</dev/tcp/${host_ip}/${port}" 2>/dev/null; then
                            ((endpoints_ok++))
                        else
                            ((endpoints_failed++))
                            update_status $EXIT_WARN "Port $port not responding on $container"
                        fi
                    fi
                fi
            done
        fi
    done <<< "$containers"
    
    CHECK_RESULTS[endpoints_checked]=$endpoints_checked
    CHECK_RESULTS[endpoints_ok]=$endpoints_ok
    CHECK_RESULTS[endpoints_failed]=$endpoints_failed
    
    log INFO "Application health: $endpoints_ok/$endpoints_checked endpoints OK"
}

#-------------------------------------------------------------------------------
# Resource Health Checks
#-------------------------------------------------------------------------------
check_resource_health() {
    log INFO "Checking resource health..."
    
    # System-level checks
    local cpu_usage
    cpu_usage=$(awk '{u=$2+$4; t=$2+$4+$5; if (t==0) print 0; else print 100*u/t}' <(grep 'cpu ' /proc/stat) 2>/dev/null || echo "0")
    cpu_usage=${cpu_usage%.*}
    
    local mem_info
    mem_info=$(free | grep Mem)
    local mem_total
    mem_total=$(echo "$mem_info" | awk '{print $2}')
    local mem_used
    mem_used=$(echo "$mem_info" | awk '{print $3}')
    local mem_usage
    mem_usage=$((mem_used * 100 / mem_total))
    
    local disk_usage
    disk_usage=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
    
    local inode_usage
    inode_usage=$(df -i / | awk 'NR==2 {print $5}' | tr -d '%')
    
    # Evaluate thresholds
    if [[ "$cpu_usage" -ge $CPU_CRIT_THRESHOLD ]]; then
        update_status $EXIT_CRIT "CPU usage is ${cpu_usage}% (threshold: ${CPU_CRIT_THRESHOLD}%)"
    elif [[ "$cpu_usage" -ge $CPU_WARN_THRESHOLD ]]; then
        update_status $EXIT_WARN "CPU usage is ${cpu_usage}% (threshold: ${CPU_WARN_THRESHOLD}%)"
    fi
    
    if [[ "$mem_usage" -ge $MEM_CRIT_THRESHOLD ]]; then
        update_status $EXIT_CRIT "Memory usage is ${mem_usage}% (threshold: ${MEM_CRIT_THRESHOLD}%)"
    elif [[ "$mem_usage" -ge $MEM_WARN_THRESHOLD ]]; then
        update_status $EXIT_WARN "Memory usage is ${mem_usage}% (threshold: ${MEM_WARN_THRESHOLD}%)"
    fi
    
    if [[ "$disk_usage" -ge $DISK_CRIT_THRESHOLD ]]; then
        update_status $EXIT_CRIT "Disk usage is ${disk_usage}% (threshold: ${DISK_CRIT_THRESHOLD}%)"
    elif [[ "$disk_usage" -ge $DISK_WARN_THRESHOLD ]]; then
        update_status $EXIT_WARN "Disk usage is ${disk_usage}% (threshold: ${DISK_WARN_THRESHOLD}%)"
    fi
    
    if [[ "$inode_usage" -ge 90 ]]; then
        update_status $EXIT_CRIT "Inode usage is ${inode_usage}%"
    elif [[ "$inode_usage" -ge 80 ]]; then
        update_status $EXIT_WARN "Inode usage is ${inode_usage}%"
    fi
    
    CHECK_RESULTS[cpu_usage]=$cpu_usage
    CHECK_RESULTS[mem_usage]=$mem_usage
    CHECK_RESULTS[disk_usage]=$disk_usage
    CHECK_RESULTS[inode_usage]=$inode_usage
    
    log INFO "Resources: CPU ${cpu_usage}%, Memory ${mem_usage}%, Disk ${disk_usage}%, Inode ${inode_usage}%"
    
    # Container-specific resource checks
    local containers
    containers=$(podman ps --format '{{.Names}}' 2>/dev/null || true)
    
    while IFS= read -r container; do
        [[ -z "$container" ]] && continue
        
        local stats
        stats=$(podman stats --no-stream --format '{{.CPUPerc}},{{.MemPerc}}' "$container" 2>/dev/null || echo "0%,0%")
        
        local container_cpu
        container_cpu=$(echo "$stats" | cut -d',' -f1 | tr -d '%')
        local container_mem
        container_mem=$(echo "$stats" | cut -d',' -f2 | tr -d '%')
        
        if [[ "${container_cpu%.*}" -ge $CPU_CRIT_THRESHOLD ]]; then
            update_status $EXIT_CRIT "Container $container CPU usage is ${container_cpu}%"
        fi
        
        if [[ "${container_mem%.*}" -ge $MEM_CRIT_THRESHOLD ]]; then
            update_status $EXIT_CRIT "Container $container memory usage is ${container_mem}%"
        fi
    done <<< "$containers"
}

#-------------------------------------------------------------------------------
# Network Health Checks
#-------------------------------------------------------------------------------
check_network_health() {
    log INFO "Checking network health..."
    
    local dns_ok=true
    local connectivity_ok=true
    
    # DNS resolution test
    local dns_servers=("8.8.8.8" "1.1.1.1")
    local dns_working=false
    
    for dns in "${dns_servers[@]}"; do
        if timeout 5 nslookup google.com "$dns" > /dev/null 2>&1; then
            dns_working=true
            break
        fi
    done
    
    if ! $dns_working; then
        dns_ok=false
        update_status $EXIT_CRIT "DNS resolution failing"
    fi
    
    # Outbound connectivity
    local test_hosts=("google.com" "cloudflare.com" "github.com")
    local hosts_reachable=0
    
    for host in "${test_hosts[@]}"; do
        if timeout 5 curl -s --max-time 5 "https://$host" > /dev/null 2>&1; then
            ((hosts_reachable++))
        fi
    done
    
    if [[ $hosts_reachable -eq 0 ]]; then
        connectivity_ok=false
        update_status $EXIT_CRIT "No outbound connectivity"
    elif [[ $hosts_reachable -lt ${#test_hosts[@]} ]]; then
        update_status $EXIT_WARN "Partial outbound connectivity ($hosts_reachable/${#test_hosts[@]} hosts)"
    fi
    
    # Check container network connectivity
    local containers
    containers=$(podman ps --format '{{.Names}}' 2>/dev/null || true)
    local containers_with_network=0
    local containers_network_ok=0
    
    while IFS= read -r container; do
        [[ -z "$container" ]] && continue
        ((containers_with_network++))
        
        # Try to reach internet from container
        if podman exec "$container" ping -c 1 -W 3 8.8.8.8 > /dev/null 2>&1 || \
           podman exec "$container" curl -s --max-time 5 https://google.com > /dev/null 2>&1; then
            ((containers_network_ok++))
        else
            update_status $EXIT_WARN "Container $container has no network connectivity"
        fi
    done <<< "$containers"
    
    CHECK_RESULTS[dns_ok]=$dns_ok
    CHECK_RESULTS[connectivity_ok]=$connectivity_ok
    CHECK_RESULTS[containers_network_ok]=$containers_network_ok
    CHECK_RESULTS[containers_network_total]=$containers_with_network
    
    log INFO "Network: DNS=$dns_ok, Connectivity=$connectivity_ok, Containers=$containers_network_ok/$containers_with_network"
}

#-------------------------------------------------------------------------------
# Storage Health Checks
#-------------------------------------------------------------------------------
check_storage_health() {
    log INFO "Checking storage health..."
    
    # Check volume mounts
    local volumes
    volumes=$(podman volume ls -q 2>/dev/null || true)
    local volumes_ok=0
    local volumes_failed=0
    
    while IFS= read -r volume; do
        [[ -z "$volume" ]] && continue
        
        local mountpoint
        mountpoint=$(podman volume inspect "$volume" --format '{{.Mountpoint}}' 2>/dev/null || true)
        
        if [[ -d "$mountpoint" ]]; then
            # Test read/write
            local testfile="${mountpoint}/.healthcheck_$$"
            if touch "$testfile" 2>/dev/null && rm -f "$testfile" 2>/dev/null; then
                ((volumes_ok++))
            else
                ((volumes_failed++))
                update_status $EXIT_CRIT "Volume $volume is not writable"
            fi
        else
            ((volumes_failed++))
            update_status $EXIT_CRIT "Volume $volume mountpoint not found"
        fi
    done <<< "$volumes"
    
    # Check for storage corruption (basic fs check)
    local fs_errors=0
    if command -v dmesg &> /dev/null; then
        fs_errors=$(dmesg 2>/dev/null | grep -c "I/O error\|filesystem error\|corruption" || echo "0")
        if [[ "$fs_errors" -gt 0 ]]; then
            update_status $EXIT_CRIT "Detected $fs_errors storage errors in dmesg"
        fi
    fi
    
    # Check container volume mounts
    local containers
    containers=$(podman ps --format '{{.Names}}' 2>/dev/null || true)
    local mounts_ok=0
    local mounts_failed=0
    
    while IFS= read -r container; do
        [[ -z "$container" ]] && continue
        
        local mounts
        mounts=$(podman inspect --format='{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' "$container" 2>/dev/null || true)
        
        if [[ -n "$mounts" ]]; then
            # Verify mount is accessible in container
            if podman exec "$container" ls / > /dev/null 2>&1; then
                ((mounts_ok++))
            else
                ((mounts_failed++))
                update_status $EXIT_CRIT "Container $container has inaccessible mounts"
            fi
        fi
    done <<< "$containers"
    
    CHECK_RESULTS[volumes_ok]=$volumes_ok
    CHECK_RESULTS[volumes_failed]=$volumes_failed
    CHECK_RESULTS[storage_errors]=$fs_errors
    CHECK_RESULTS[mounts_ok]=$mounts_ok
    CHECK_RESULTS[mounts_failed]=$mounts_failed
    
    log INFO "Storage: $volumes_ok volumes OK, $mounts_ok container mounts OK"
}

#-------------------------------------------------------------------------------
# JSON Output
#-------------------------------------------------------------------------------
output_json() {
    local timestamp
    timestamp=$(date -Iseconds)
    
    cat << EOF
{
    "timestamp": "$timestamp",
    "status": $(status_text $OVERALL_STATUS),
    "status_code": $OVERALL_STATUS,
    "checks": {
        "container": {
            "enabled": $CHECK_CONTAINER,
            "total": ${CHECK_RESULTS[containers_total]:-0},
            "running": ${CHECK_RESULTS[containers_running]:-0},
            "exited": ${CHECK_RESULTS[containers_exited]:-0},
            "unhealthy": ${CHECK_RESULTS[containers_unhealthy]:-0},
            "oom_killed": ${CHECK_RESULTS[containers_oom_killed]:-0},
            "high_restarts": ${CHECK_RESULTS[containers_high_restarts]:-0}
        },
        "application": {
            "enabled": $CHECK_APPLICATION,
            "endpoints_checked": ${CHECK_RESULTS[endpoints_checked]:-0},
            "endpoints_ok": ${CHECK_RESULTS[endpoints_ok]:-0},
            "endpoints_failed": ${CHECK_RESULTS[endpoints_failed]:-0}
        },
        "resource": {
            "enabled": $CHECK_RESOURCE,
            "cpu_usage": ${CHECK_RESULTS[cpu_usage]:-0},
            "memory_usage": ${CHECK_RESULTS[mem_usage]:-0},
            "disk_usage": ${CHECK_RESULTS[disk_usage]:-0},
            "inode_usage": ${CHECK_RESULTS[inode_usage]:-0}
        },
        "network": {
            "enabled": $CHECK_NETWORK,
            "dns_ok": ${CHECK_RESULTS[dns_ok]:-false},
            "connectivity_ok": ${CHECK_RESULTS[connectivity_ok]:-false},
            "containers_network_ok": ${CHECK_RESULTS[containers_network_ok]:-0},
            "containers_network_total": ${CHECK_RESULTS[containers_network_total]:-0}
        },
        "storage": {
            "enabled": $CHECK_STORAGE,
            "volumes_ok": ${CHECK_RESULTS[volumes_ok]:-0},
            "volumes_failed": ${CHECK_RESULTS[volumes_failed]:-0},
            "storage_errors": ${CHECK_RESULTS[storage_errors]:-0},
            "mounts_ok": ${CHECK_RESULTS[mounts_ok]:-0},
            "mounts_failed": ${CHECK_RESULTS[mounts_failed]:-0}
        }
    },
    "messages": [$(printf '"%s",' "${MESSAGES[@]}" | sed 's/,$//')]
}
EOF
}

#-------------------------------------------------------------------------------
# Text Output
#-------------------------------------------------------------------------------
output_text() {
    echo "========================================"
    echo "Podman Health Check Report"
    echo "Status: $(status_text $OVERALL_STATUS)"
    echo "========================================"
    echo ""
    
    if [[ ${#MESSAGES[@]} -gt 0 ]]; then
        echo "Issues Found:"
        for msg in "${MESSAGES[@]}"; do
            echo "  - $msg"
        done
        echo ""
    else
        echo "All checks passed!"
        echo ""
    fi
    
    echo "Container Summary:"
    echo "  Total: ${CHECK_RESULTS[containers_total]:-0}"
    echo "  Running: ${CHECK_RESULTS[containers_running]:-0}"
    echo "  Exited: ${CHECK_RESULTS[containers_exited]:-0}"
    echo "  Unhealthy: ${CHECK_RESULTS[containers_unhealthy]:-0}"
    echo ""
    
    echo "Resource Usage:"
    echo "  CPU: ${CHECK_RESULTS[cpu_usage]:-0}%"
    echo "  Memory: ${CHECK_RESULTS[mem_usage]:-0}%"
    echo "  Disk: ${CHECK_RESULTS[disk_usage]:-0}%"
    echo "  Inode: ${CHECK_RESULTS[inode_usage]:-0}%"
}

#-------------------------------------------------------------------------------
# Usage
#-------------------------------------------------------------------------------
usage() {
    cat << EOF
${SCRIPT_NAME} v${VERSION} - Comprehensive Podman Health Check

USAGE:
    ${SCRIPT_NAME} [OPTIONS]

OPTIONS:
    --check-container           Enable container runtime checks (default: true)
    --check-application         Enable application health checks (default: true)
    --check-resource            Enable resource usage checks (default: true)
    --check-network             Enable network health checks (default: true)
    --check-storage             Enable storage health checks (default: true)
    --skip-checks               Skip all checks (useful with --check-* flags)
    -j, --json                  Output results as JSON
    -q, --quiet                 Quiet mode (only output status code)
    -h, --help                  Show this help message
    -v, --version               Show version information

THRESHOLDS (via environment variables):
    CPU_WARN_THRESHOLD          CPU warning threshold (default: 80)
    CPU_CRIT_THRESHOLD          CPU critical threshold (default: 95)
    MEM_WARN_THRESHOLD          Memory warning threshold (default: 80)
    MEM_CRIT_THRESHOLD          Memory critical threshold (default: 95)
    DISK_WARN_THRESHOLD         Disk warning threshold (default: 85)
    DISK_CRIT_THRESHOLD         Disk critical threshold (default: 95)
    RESTART_WARN_COUNT          Container restart warning (default: 3)
    RESTART_CRIT_COUNT          Container restart critical (default: 5)

EXIT CODES (Nagios-style):
    0 - OK (All checks passed)
    1 - WARNING (Some checks warning)
    2 - CRITICAL (Some checks failed)
    3 - UNKNOWN (Check could not be performed)

EXAMPLES:
    # Run all checks
    ${SCRIPT_NAME}

    # Output JSON for monitoring
    ${SCRIPT_NAME} --json

    # Check only containers and resources
    ${SCRIPT_NAME} --skip-checks --check-container --check-resource

    # Quiet check for scripting
    ${SCRIPT_NAME} -q && echo "All healthy" || echo "Issues detected"

EOF
}

#-------------------------------------------------------------------------------
# Argument Parsing
#-------------------------------------------------------------------------------
parse_args() {
    local output_json=false
    local quiet=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --check-container)
                CHECK_CONTAINER=true
                shift
                ;;
            --check-application)
                CHECK_APPLICATION=true
                shift
                ;;
            --check-resource)
                CHECK_RESOURCE=true
                shift
                ;;
            --check-network)
                CHECK_NETWORK=true
                shift
                ;;
            --check-storage)
                CHECK_STORAGE=true
                shift
                ;;
            --skip-checks)
                CHECK_CONTAINER=false
                CHECK_APPLICATION=false
                CHECK_RESOURCE=false
                CHECK_NETWORK=false
                CHECK_STORAGE=false
                shift
                ;;
            -j|--json)
                output_json=true
                shift
                ;;
            -q|--quiet)
                quiet=true
                shift
                ;;
            -h|--help)
                usage
                exit $EXIT_OK
                ;;
            -v|--version)
                echo "${SCRIPT_NAME} version ${VERSION}"
                exit $EXIT_OK
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit $EXIT_UNKNOWN
                ;;
        esac
    done
    
    # Store output preference
    OUTPUT_JSON=$output_json
    QUIET=$quiet
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    parse_args "$@"
    
    # Run checks
    [[ "$CHECK_CONTAINER" == "true" ]] && check_container_runtime
    [[ "$CHECK_APPLICATION" == "true" ]] && check_application_health
    [[ "$CHECK_RESOURCE" == "true" ]] && check_resource_health
    [[ "$CHECK_NETWORK" == "true" ]] && check_network_health
    [[ "$CHECK_STORAGE" == "true" ]] && check_storage_health
    
    # Output results
    if [[ "${QUIET:-false}" == "true" ]]; then
        # Only output status code
        :  # No output in quiet mode
    elif [[ "${OUTPUT_JSON:-false}" == "true" ]]; then
        output_json
    else
        output_text
    fi
    
    exit $OVERALL_STATUS
}

main "$@"
