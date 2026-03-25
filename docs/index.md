---
layout: default
title: Home
nav_order: 1
---

<div class="hero animate-fade-in-up">
  <span class="section-label">// system ready</span>
  <h1>Podman on Arch Linux</h1>
  <p class="hero-subtitle">A++ Production Guide — Production-tested, CI-validated, battle-hardened container orchestration</p>
  
  <div class="terminal-prompt animate-fade-in" style="animation-delay: 0.3s;">
    <span class="prompt">user@arch</span>:<span class="path">~</span>$ <span class="command">podman run --rm -it archlinux:latest</span>
  </div>
</div>

---

## Quick Start

<div class="card-grid">
  <div class="card animate-fade-in-up" style="animation-delay: 0.1s;">
    <span class="badge">15 min</span>
    <h3><a href="{{ site.baseurl }}/quickstart/">Quickstart Guide</a></h3>
    <p>Deploy your first container in 15 minutes. Prerequisites, podman-compose, and basic monitoring setup.</p>
  </div>
  <div class="card animate-fade-in-up" style="animation-delay: 0.2s;">
    <span class="badge">ops</span>
    <h3><a href="{{ site.baseurl }}/runbook/">Operations Runbook</a></h3>
    <p>Incident response procedures, daily/weekly checklists, emergency rollback and recovery playbooks.</p>
  </div>
  <div class="card animate-fade-in-up" style="animation-delay: 0.3s;">
    <span class="badge">arch</span>
    <h3><a href="{{ site.baseurl }}/architecture/">Architecture Guide</a></h3>
    <p>Design principles, technology choices, security model, network & storage architecture deep-dive.</p>
  </div>
</div>

---

## Service Level Objectives

| SLI | SLO Target | Current |
|-----|------------|---------|
| Container Availability | 99.9% | <span class="slo-badge success">99.97%</span> |
| Deployment Success Rate | 99% | <span class="slo-badge success">99.5%</span> |
| Rollback Time | < 5 min | <span class="slo-badge success">2m 30s</span> |
| Mean Time to Recovery | < 15 min | <span class="slo-badge success">8m 15s</span> |

---

## Production Patterns

<div class="card-grid">
  <div class="card animate-fade-in-up" style="animation-delay: 0.2s;">
    <h3>▸ Single Node</h3>
    <p>Small workloads under 1000 RPS. Cost-sensitive deployments with minimal downtime tolerance.</p>
  </div>
  <div class="card animate-fade-in-up" style="animation-delay: 0.3s;">
    <h3>▸ Blue/Green</h3>
    <p>Zero-downtime deployments with instant rollback. Critical services requiring high availability.</p>
  </div>
  <div class="card animate-fade-in-up" style="animation-delay: 0.4s;">
    <h3>▸ Multi-Node HA</h3>
    <p>Enterprise 3-node cluster with Ceph + WireGuard. For >1000 RPS and regulatory requirements.</p>
  </div>
</div>

---

## Monthly Cost Estimates

| Deployment | AWS | GCP | Azure |
|------------|-----|-----|-------|
| Single Node | <code>$50-100</code> | <code>$40-80</code> | <code>$45-90</code> |
| Blue/Green | <code>$100-200</code> | <code>$80-160</code> | <code>$90-180</code> |
| Multi-Node (3x) | <code>$300-500</code> | <code>$240-400</code> | <code>$270-450</code> |

---

## Tools & Resources

<div class="card-grid">
  <div class="card animate-fade-in-up" style="animation-delay: 0.3s;">
    <span class="badge">cost</span>
    <h3><a href="{{ site.baseurl }}/cost-optimization/">Cost Calculators</a></h3>
    <p>AWS, GCP, and Azure cost estimation and optimization strategies.</p>
  </div>
  <div class="card animate-fade-in-up" style="animation-delay: 0.4s;">
    <span class="badge">scale</span>
    <h3><a href="{{ site.baseurl }}/capacity-planning/">Capacity Planning</a></h3>
    <p>Scaling thresholds, growth projection formulas, and resource planning.</p>
  </div>
  <div class="card animate-fade-in-up" style="animation-delay: 0.5s;">
    <span class="badge">chaos</span>
    <h3><a href="{{ site.baseurl }}/chaos-engineering/">Chaos Engineering</a></h3>
    <p>5 game day scenarios for validating system resilience and recovery.</p>
  </div>
  <div class="card animate-fade-in-up" style="animation-delay: 0.6s;">
    <span class="badge">monitor</span>
    <h3><a href="{{ site.baseurl }}/monitoring/">Monitoring & Alerts</a></h3>
    <p>SLI/SLO implementation with Prometheus rules and Grafana dashboards.</p>
  </div>
</div>

---

<div class="terminal-prompt" style="margin-top: var(--space-2xl);">
  <span class="prompt">user@arch</span>:<span class="path">~/docs</span>$ <span class="command">ls -la /production-ready/</span>
</div>