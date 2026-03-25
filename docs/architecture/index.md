---
layout: default
title: Architecture Guide
nav_order: 3
---

# Architecture Guide

Design principles, technology choices, and infrastructure patterns.

## Design Principles

1. **Rootless by Default** - All containers run as non-root except reverse proxy
2. **Quadlets over Compose** - Systemd integration for production
3. **WireGuard over VXLAN** - Encrypted, NAT-friendly networking
4. **Ceph over NFS** - Distributed, resilient storage
5. **DNS over Consul** - Service discovery

## Technology Stack

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Container Runtime | Podman | Rootless, daemonless, systemd-native |
| Networking | WireGuard | Encrypted mesh, no multicast |
| Storage | Ceph | Distributed, self-healing |
| Service Discovery | DNS | Simple, no external deps |
| Orchestration | Quadlets | Systemd integration |

## Security Model

- Rootless containers with UserNS
- SELinux enforcement
- Resource limits on all containers
- Network policies for isolation

## Network Architecture

- WireGuard mesh for node-to-node
- Single VIP with Keepalived
- HAProxy for load balancing

## Storage Architecture

- Ceph OSDs on each node
- RBD for block volumes
- CephFS for shared filesystems

## High Availability

- 3-node minimum cluster
- No single point of failure
- Automatic failover
- Data replication factor 3

## Multi-Cloud Considerations

- Infrastructure-as-code with Terraform
- Cloud-agnostic tooling
- Cost optimization per cloud

## See Also

- [Multi-Node Deployment](multi-node-deployment/)
- [Monitoring](../monitoring/)
- [Cost Optimization](../cost-optimization/)
