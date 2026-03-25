#!/bin/bash
# Health Check Aggregator Script
# Aggregates health status from both blue and green environments

HEALTH_FILE="/tmp/blue-green-health.json"

check_container_health() {
    local name=$1
    local color=$2

    if ! podman ps --format "{{.Names}}" | grep -q "^${name}$"; then
        echo "not_running"
        return
    fi

    local status
    status=$(podman healthcheck run "$name" 2>&1)
    if [[ $? -eq 0 ]]; then
        echo "healthy"
    else
        echo "unhealthy"
    fi
}

check_app_health() {
    local color=$1
    local response

    response=$(podman exec "app-${color}" wget -qO- http://localhost:8080/health 2>/dev/null || echo "")

    if [[ "$response" == *"\"status\":\"healthy\""* ]]; then
        echo "healthy"
    else
        echo "unhealthy"
    fi
}

# Main health check
main() {
    local blue_healthy=false
    local green_healthy=false
    local active_color=${ACTIVE_COLOR:-blue}

    # Check blue environment
    local blue_app=$(check_container_health "app-blue" "blue")
    local blue_db=$(check_container_health "postgres-blue" "blue")
    local blue_redis=$(check_container_health "redis-blue" "blue")

    if [[ "$blue_app" == "healthy" && "$blue_db" == "healthy" && "$blue_redis" == "healthy" ]]; then
        blue_healthy=true
    fi

    # Check green environment
    local green_app=$(check_container_health "app-green" "green")
    local green_db=$(check_container_health "postgres-green" "green")
    local green_redis=$(check_container_health "redis-green" "green")

    if [[ "$green_app" == "healthy" && "$green_db" == "healthy" && "$green_redis" == "healthy" ]]; then
        green_healthy=true
    fi

    # Output JSON
    cat > "$HEALTH_FILE" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "active_color": "${active_color}",
    "environments": {
        "blue": {
            "healthy": ${blue_healthy},
            "containers": {
                "app": "${blue_app}",
                "postgres": "${blue_db}",
                "redis": "${blue_redis}"
            }
        },
        "green": {
            "healthy": ${green_healthy},
            "containers": {
                "app": "${green_app}",
                "postgres": "${green_db}",
                "redis": "${green_redis}"
            }
        }
    }
}
EOF

    echo "Health check complete: blue=${blue_healthy}, green=${green_healthy}"
}

main "$@"
