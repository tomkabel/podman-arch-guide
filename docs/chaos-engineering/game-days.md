# Chaos Engineering Game Days

Validate your system's resilience through controlled failures.

## Game Day Schedule

| Week | Scenario | Focus | Success Criteria |
|------|----------|-------|------------------|
| 1 | Container Kill | Recovery time | < 2 min recovery |
| 2 | Node Failure | Failover | Service stays available |
| 3 | Network Partition | Split-brain prevention | No data corruption |
| 4 | Resource Exhaustion | Graceful degradation | Error rate < 1% |
| 5 | Database Corruption | Backup/restore | RTO < 15 min |

## Scenario 1: Container Kill

```bash
#!/bin/bash
# chaos-kill-container.sh

CONTAINER=${1:-$(podman ps -q | shuf -n 1)}
TIMEOUT=${2:-120}

echo "🎯 Chaos: Killing container $CONTAINER"
echo "Timeout: ${TIMEOUT}s"

# Record start time
START=$(date +%s)

# Kill container
podman kill $CONTAINER

# Wait for recovery
echo "Waiting for recovery..."
while true; do
    if podman ps | grep -q $CONTAINER; then
        END=$(date +%s)
        DURATION=$((END - START))
        echo "✅ Recovered in ${DURATION}s"
        
        if [[ $DURATION -lt $TIMEOUT ]]; then
            echo "SUCCESS: Recovery within SLO"
        else
            echo "FAIL: Recovery exceeded ${TIMEOUT}s SLO"
        fi
        break
    fi
    
    if [[ $(($(date +%s) - START)) -gt $((TIMEOUT * 2)) ]]; then
        echo "FAIL: No recovery after $((TIMEOUT * 2))s"
        break
    fi
    
    sleep 1
done
```

## Scenario 2: Node Failure

```bash
#!/bin/bash
# chaos-node-failure.sh

NODE=${1:-node2}
DURATION=${2:-300}  # 5 minutes

echo "🎯 Chaos: Simulating $NODE failure for ${DURATION}s"

# Isolate node (simulate failure)
ssh $NODE "sudo iptables -A INPUT -j DROP"

# Monitor service availability
echo "Monitoring service availability..."
for i in $(seq 1 $((DURATION / 10))); do
    if curl -sf http://webapp.example.com/health > /dev/null; then
        echo "$(date): Service OK"
    else
        echo "$(date): ❌ Service DOWN"
    fi
    sleep 10
done

# Restore node
ssh $NODE "sudo iptables -F"
echo "✅ Node restored"

# Verify recovery
sleep 30
if curl -sf http://webapp.example.com/health > /dev/null; then
    echo "✅ Full recovery confirmed"
else
    echo "❌ Recovery failed - manual intervention needed"
fi
```

## Scenario 3: Network Partition

```bash
#!/bin/bash
# chaos-network-partition.sh

NODE1=${1:-node1}
NODE2=${2:-node2}
DURATION=${3:-60}

echo "🎯 Chaos: Network partition between $NODE1 and $NODE2"

# Create partition
ssh $NODE1 "sudo iptables -A OUTPUT -d $(host $NODE2 | awk '{print $4}') -j DROP"
ssh $NODE2 "sudo iptables -A OUTPUT -d $(host $NODE1 | awk '{print $4}') -j DROP"

sleep $DURATION

# Heal partition
ssh $NODE1 "sudo iptables -F"
ssh $NODE2 "sudo iptables -F"

echo "✅ Partition healed"

# Verify no split-brain
# (Custom check based on your consensus mechanism)
```

## Scenario 4: Resource Exhaustion

```bash
#!/bin/bash
# chaos-resource-exhaustion.sh

TYPE=${1:-memory}  # memory, cpu, disk
TARGET=${2:-webapp}

case $TYPE in
    memory)
        echo "🎯 Chaos: Memory exhaustion on $TARGET"
        podman exec $TARGET sh -c "cat /dev/zero | head -c 1G | tail" &
        ;;
    cpu)
        echo "🎯 Chaos: CPU exhaustion on $TARGET"
        podman exec $TARGET sh -c "while :; do :; done" &
        ;;
    disk)
        echo "🎯 Chaos: Disk exhaustion on $TARGET"
        podman exec $TARGET sh -c "dd if=/dev/zero of=/tmp/fill bs=1M count=1024"
        ;;
esac

# Monitor
echo "Monitoring for graceful degradation..."
sleep 30

# Cleanup
podman exec $TARGET sh -c "pkill -9 -f 'cat /dev/zero'; rm -f /tmp/fill" 2>/dev/null || true
```

## Post-Game Review Template

```markdown
# Game Day Review: [Date]

## Scenario
[What we tested]

## Expected Behavior
[What should happen]

## Actual Behavior
[What actually happened]

## Metrics
- Recovery Time: ___
- Error Rate: ___
- Data Loss: ___

## Issues Found
1. [Issue description]
   - Impact: [severity]
   - Fix: [action item]

## Action Items
- [ ] [Owner] [Task] [Due date]
```

---

**Next**: [Post-Incident Reviews](../incident-response/postmortem-template.md)
