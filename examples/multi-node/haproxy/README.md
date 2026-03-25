# HAProxy Load Balancer Configuration
# High-performance TCP/HTTP load balancing

## Overview

HAProxy provides:
- **Layer 4/7 Load Balancing**: TCP and HTTP load balancing
- **Health Checks**: Automatic server monitoring
- **SSL/TLS Termination**: Offload encryption from backends
- **Session Persistence**: Sticky sessions when needed
- **Rate Limiting**: DDoS protection

## Architecture

```
                       Internet
                          │
                          ▼
                  ┌───────────────┐
                  │   Keepalived  │
                  │     (VIP)     │  192.168.1.100
                  └───────┬───────┘
                          │
           ┌──────────────┼──────────────┐
           │              │              │
    ┌──────▼──────┐ ┌─────▼─────┐ ┌─────▼─────┐
    │  HAProxy    │ │  HAProxy  │ │  HAProxy  │
    │   Node 1    │ │  Node 2   │ │  Node 3   │
    │  (Active)   │ │ (Backup)  │ │ (Backup)  │
    └──────┬──────┘ └─────┬─────┘ └─────┬─────┘
           │              │              │
           └──────────────┼──────────────┘
                          │
           ┌──────────────┼──────────────┐
           │              │              │
    ┌──────▼──────┐ ┌─────▼─────┐ ┌─────▼─────┐
    │  App Pod    │ │  App Pod  │ │  App Pod  │
    │   Node 1    │ │  Node 2   │ │  Node 3   │
    └─────────────┘ └───────────┘ └───────────┘
```

## Quick Start

### 1. Generate Configuration

```bash
cd multi-node
./setup-cluster.sh
```

### 2. Deploy HAProxy

```bash
# On each node
scp haproxy/haproxy.cfg root@node:/etc/haproxy/
scp haproxy/services/* root@node:/etc/haproxy/services/
scp -r certs root@node:/etc/

ssh root@node "systemctl enable haproxy && systemctl restart haproxy"
```

Or use Podman:
```bash
podman-compose -f docker-compose.yml up -d haproxy
```

### 3. Verify

```bash
# Check HAProxy status
curl http://localhost:8404/stats

# Test load balancing
for i in {1..10}; do curl -s http://localhost/health; done
```

## Configuration

### haproxy.cfg - Main Configuration

```conf
global
    log stdout local0 info
    maxconn 4096
    user haproxy
    group haproxy
    daemon

    # Performance tuning
    nbthread 4
    cpu-map auto:1/1-4 0-3

    # SSL settings
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256
    ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets
    ssl-dh-param-file /etc/ssl/certs/dhparam.pem

defaults
    log global
    mode http
    option httplog
    option dontlognull
    option log-health-checks
    option forwardfor

    timeout connect 5s
    timeout client 30s
    timeout server 30s
    timeout http-request 10s
    timeout http-keep-alive 10s

    default-server inter 5s fall 3 rise 2

    # Stats
    stats enable
    stats uri /stats
    stats refresh 10s
    stats admin if TRUE

# Frontend - HTTP to HTTPS redirect
frontend http_in
    bind *:80
    redirect scheme https if !{ ssl_fc }

# Frontend - HTTPS
frontend https_in
    bind *:443 ssl crt /etc/ssl/certs/combined.pem alpn h2,http/1.1

    # Security headers
    http-response set-header X-Frame-Options SAMEORIGIN
    http-response set-header X-Content-Type-Options nosniff
    http-response set-header X-XSS-Protection "1; mode=block"
    http-response set-header Strict-Transport-Security "max-age=63072000"

    # ACLs
    acl is_health path /health
    acl is_api path_beg /api

    # Routes
    use_backend health_backend if is_health
    use_backend api_backend if is_api
    default_backend app_backend

# Backend - Application Servers
backend app_backend
    balance roundrobin
    option httpchk GET /health
    http-check expect status 200

    # Servers from Consul service discovery
    server-template app 5 _app._tcp.service.consul:8080 check

    # Fallback static servers
    server app1 10.200.0.1:8080 check backup
    server app2 10.200.0.2:8080 check backup
    server app3 10.200.0.3:8080 check backup

# Backend - API Servers
backend api_backend
    balance leastconn
    option httpchk GET /api/health
    http-check expect status 200

    server api1 10.200.0.1:8080 check
    server api2 10.200.0.2:8080 check
    server api3 10.200.0.3:8080 check

# Backend - Health Check
backend health_backend
    http-request return status 200 content-type "application/json" lf-string '{"status":"healthy"}'
```

### Service Discovery with Consul

```conf
# Enable Consul DNS for service discovery
resolvers consul
    nameserver consul 127.0.0.1:8600
    accepted_payload_size 8192
    hold valid 10s

backend app_backend
    balance roundrobin
    option httpchk GET /health
    
    # Use Consul for service discovery
    server-template app 10 _app._tcp.service.consul:8080 check resolvers consul resolve-opts allow-dup-ip resolve-prefer ipv4
```

## Load Balancing Algorithms

### Round Robin (Default)
```conf
backend app
    balance roundrobin
    server app1 10.0.0.1:8080
    server app2 10.0.0.2:8080
```

### Least Connections
```conf
backend api
    balance leastconn
    server api1 10.0.0.1:8080
    server api2 10.0.0.2:8080
```

### Source IP Hash (Session Persistence)
```conf
backend app
    balance source
    hash-type consistent
    server app1 10.0.0.1:8080
    server app2 10.0.0.2:8080
```

### URI Hash
```conf
backend cache
    balance uri
    hash-type consistent
    http-check send meth GET uri /health
    server cache1 10.0.0.1:8080
    server cache2 10.0.0.2:8080
```

## Health Checks

### HTTP Health Check
```conf
backend app
    option httpchk GET /health
    http-check expect status 200
    http-check expect string "healthy"
    server app1 10.0.0.1:8080 check inter 5s fall 3 rise 2
```

### TCP Health Check
```conf
backend database
    option tcp-check
    tcp-check connect port 5432
    tcp-check send P\x00\x00\x00\x08\x00\x00\x00\x00
    tcp-check expect binary 52\x00\x00\x00
    server db1 10.0.0.1:5432 check
```

### Custom Health Check Script
```conf
backend app
    option external-check
    external-check command /etc/haproxy/checks/app-check.sh
    server app1 10.0.0.1:8080 check
```

## SSL/TLS Configuration

### Certificate Bundle

Combine certificates into a single PEM file:
```bash
cat server.crt intermediate.crt ca.crt > combined.pem
cat server.key >> combined.pem
```

### SSL Options
```conf
frontend https
    bind *:443 ssl crt /etc/ssl/certs/combined.pem \
        no-sslv3 \
        no-tlsv10 \
        no-tlsv11 \
        no-tls-tickets \
        ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256 \
        alpn h2,http/1.1
```

### Backend SSL
```conf
backend secure_app
    server app1 10.0.0.1:8443 ssl verify required ca-file /etc/ssl/certs/ca.crt
```

## Rate Limiting & Security

### Connection Limits
```conf
frontend http
    bind *:80
    
    # Limit concurrent connections per IP
    stick-table type ip size 100k expire 30s store conn_cur
    tcp-request connection track-sc0 src
    tcp-request connection reject if { sc_conn_cur(0) gt 50 }
```

### Request Rate Limiting
```conf
frontend http
    # Track request rate per IP
    stick-table type ip size 100k expire 10s store http_req_rate(10s)
    http-request track-sc0 src
    
    # Block if more than 100 requests in 10 seconds
    http-request deny if { sc_http_req_rate(0) gt 100 }
```

### DDoS Protection
```conf
global
    # Performance tuning for high connection counts
    maxconn 100000
    nbproc 4

defaults
    # Timeouts for slowloris protection
    timeout http-request 10s
    timeout http-keep-alive 2s
    timeout connect 5s
```

## Monitoring

### Stats Page
Access at: `http://localhost:8404/stats`

Configuration:
```conf
listen stats
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 10s
    stats admin if TRUE
    stats show-desc "Multi-Node Cluster"
    stats show-legends
    stats auth admin:password
```

### Prometheus Metrics
```conf
frontend prometheus
    bind *:8405
    http-request use-service prometheus-exporter if { path /metrics }
```

### Logging
```conf
global
    log stdout local0 info
    
defaults
    log global
    option httplog
    option log-health-checks
    
    # Custom log format
    log-format "%ci:%cp [%tr] %ft %b/%s %Tw/%Tc/%Tt %B %ts \
                %ac/%fc/%bc/%sc/%rc %sq/%bq"
```

## Troubleshooting

### Check Configuration
```bash
# Validate config
haproxy -c -f /etc/haproxy/haproxy.cfg

# Test with verbose output
haproxy -db -f /etc/haproxy/haproxy.cfg
```

### View Stats
```bash
# Socket commands
echo "show stat" | socat stdio /var/run/haproxy.sock
echo "show servers state" | socat stdio /var/run/haproxy.sock

# Runtime commands
echo "set server app/app1 state drain" | socat stdio /var/run/haproxy.sock
```

### Common Issues

**1. Cannot Bind to Port**
```bash
# Check if port is in use
ss -tlnp | grep :80

# Check SELinux
getsebool -a | grep haproxy
setsebool haproxy_connect_any on
```

**2. SSL Certificate Errors**
```bash
# Verify certificate chain
openssl s_client -connect localhost:443 -servername example.com

# Check certificate expiration
openssl x509 -in /etc/ssl/certs/server.crt -noout -dates
```

**3. Backend Down**
```bash
# Test backend manually
curl -v http://backend:8080/health

# Check HAProxy logs
journalctl -u haproxy -f
```

## Performance Tuning

### Kernel Parameters
```bash
# /etc/sysctl.conf
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.netfilter.nf_conntrack_max = 1000000
```

### HAProxy Settings
```conf
global
    # Use multiple threads
    nbthread 8
    
    # Increase buffer sizes
    tune.ssl.default-dh-param 2048
    tune.bufsize 32768
    tune.maxrewrite 1024
    
    # Connection limits
    maxconn 100000
```
