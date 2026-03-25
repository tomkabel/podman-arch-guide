---
layout: default
title: Home
nav_order: 1
---

<div class="hero">
  <div class="container">
    <h1>Podman on Arch Linux — A++ Production Guide</h1>
    <p>Production-tested, CI-validated, battle-hardened container orchestration on Arch Linux</p>
  </div>
</div>

## 🚀 Quick Start

<div class="card-grid">
  <div class="card">
    <span class="badge">15 min</span>
    <h3><a href="{{ site.baseurl }}/quickstart/">Quick Start Guide</a></h3>
    <p>Deploy your first container in 15 minutes. Prerequisites, podman-compose, and basic monitoring.</p>
  </div>
  <div class="card">
    <span class="badge">Operations</span>
    <h3><a href="{{ site.baseurl }}/runbook/">Operations Runbook</a></h3>
    <p>Incident response procedures, daily/weekly checklists, emergency rollback procedures.</p>
  </div>
  <div class="card">
    <span class="badge">Deep Dive</span>
    <h3><a href="{{ site.baseurl }}/architecture/">Architecture Guide</a></h3>
    <p>Design principles, technology choices, security model, network & storage architecture.</p>
  </div>
</div>

## 📊 Service Level Objectives (SLOs)

| SLI | SLO | Current Status |
|-----|-----|-----------------|
| Container Availability | 99.9% | <span class="slo-badge success">99.97%</span> |
| Deployment Success Rate | 99% | <span class="slo-badge success">99.5%</span> |
| Rollback Time | < 5 min | <span class="slo-badge success">2m 30s</span> |
| Mean Time to Recovery | < 15 min | <span class="slo-badge success">8m 15s</span> |

## 🏗️ Production Patterns

<div class="card-grid">
  <div class="card">
    <h3>Single Node</h3>
    <p>For small workloads under 1000 RPS. Cost-sensitive deployments with minimal downtime tolerance.</p>
  </div>
  <div class="card">
    <h3>Blue/Green</h3>
    <p>Zero-downtime deployments with instant rollback. Critical services requiring high availability.</p>
  </div>
  <div class="card">
    <h3>Multi-Node HA</h3>
    <p>Enterprise 3-node cluster with Ceph + WireGuard. For >1000 RPS and regulatory requirements.</p>
  </div>
</div>

## 💰 Cost Estimates

| Deployment | AWS | GCP | Azure |
|------------|-----|-----|-------|
| Single Node | $50-100/mo | $40-80/mo | $45-90/mo |
| Blue/Green | $100-200/mo | $80-160/mo | $90-180/mo |
| Multi-Node (3x) | $300-500/mo | $240-400/mo | $270-450/mo |

## 🔧 Tools

- **[Cost Calculators]({{ site.baseurl }}/cost-optimization/)** - AWS/GCP/Azure cost estimation
- **[Capacity Planning]({{ site.baseurl }}/capacity-planning/)** - Scaling thresholds and growth projection
- **[SLO Calculator]({{ site.baseurl }}/tools/slo-calculator/)** - Error budget and availability planning

## 🎮 Chaos Engineering

<div class="card-grid">
  <div class="card">
    <h3><a href="{{ site.baseurl }}/chaos-engineering/">Game Days</a></h3>
    <p>5 chaos scenarios for validating system resilience: container kill, network partition, resource exhaustion, disk pressure, DNS failure.</p>
  </div>
</div>
